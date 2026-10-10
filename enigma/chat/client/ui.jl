# UI: alles, was das Terminal betrifft (Zeichnen, Tasten, Eingabezeile). Kennt das Netzwerk
# und die Verschlüsselung nicht.
#
# Zwei Modi:
#   clean:  Kopfzeile, Nachrichtenbereich, Eingabezeile. Nachrichten nur im Klartext.
#   turing: zusätzlich Lampenfeld (3 Zeilen über der Eingabe); jede Nachricht zeigt Geheimtext und Klartext.

const RESET, DIM, BOLD, INVERT = "\e[0m", "\e[2m", "\e[1m", "\e[7m"
const COLORS = [31, 32, 33, 34, 35, 36, 91, 92, 93, 94, 95, 96]
const LAMP_ROWS = ["QWERTZUIO", "ASDFGHJK", "PYXCVBNML"]   # Tastaturlayout der Enigma

struct Screen
    rows::Int
    cols::Int
    title::String
    turing::Bool
end

# letzte Zeile des Nachrichtenbereichs; darunter folgen (im Turing-Modus) das Lampenfeld und die Eingabezeile
region_bottom(s::Screen) = s.rows - 1 - (s.turing ? length(LAMP_ROWS) : 0)

color(name) = "\e[$(COLORS[mod1(sum(codeunits(name)), length(COLORS))])m"

# --- Start-Dialog (normaler Zeilenmodus) ---

function ask(question)
    print(BOLD, question, RESET)
    line = readline(keep=true)
    isempty(line) && exit(0)   # nur bei Ctrl-D leer, sonst endet die Zeile mit \n
    strip(line)
end

function show_welcome()
    print("\e[2J\e[H")
    println(BOLD, "Chat", RESET, "\n")
end

# --- Chat-Bildschirm ---

set_raw(on) = ccall(:jl_tty_set_mode, Int32, (Ptr{Cvoid}, Int32), stdin.handle, on ? 1 : 0)

# Bildschirm aufbauen, Scrollbereich setzen, Raw-Modus an. Beim Beenden wird alles zurückgesetzt.
function open_screen(title; turing)
    rows, cols = displaysize(stdout)
    s = Screen(rows, cols, title, turing)
    print("\e[2J")
    draw_header(s)
    print("\e[2;$(region_bottom(s))r")        # Scrollbereich: nur der Nachrichtenbereich
    set_raw(true)
    atexit(() -> (set_raw(false); print("\e[r\e[$rows;1H\e[2K\n")))
    s
end

function draw_header(s::Screen)
    left = " $(s.title)"
    right = (s.turing ? "Turing-Modus" : "Clean-Modus") * " "
    left = first(left, max(0, s.cols - textwidth(right) - 1))     # bei Platzmangel den Titel kürzen
    pad = max(1, s.cols - textwidth(left) - textwidth(right))
    print("\e7\e[1;1H", INVERT, first(left * " "^pad * right, s.cols), RESET, "\e8")
end

function format_message(m::ChatMessage, turing)
    m.name === nothing && return DIM * "* " * replace(m.text, "\n" => "\n  ") * RESET
    c = color(m.name)
    turing || return string(c, BOLD, m.name, RESET, ": ", m.text)
    string(c, "┌ ", BOLD, m.name, RESET, DIM, " · ", m.time, " · ", count(isletter, m.wire), " Buchstaben", RESET, "\n",
           c, "│ ", RESET, DIM, m.wire, RESET, "\n",
           c, "└ ", RESET, m.text)
end

# Nachricht im Nachrichtenbereich ausgeben, ohne die Eingabe zu stören.
function show_message(s::Screen, m::ChatMessage)
    print("\e7\e[$(region_bottom(s));1H\n", format_message(m, s.turing), "\e8")
end

show_notice(s::Screen, text) = show_message(s, ChatMessage(nothing, text))

# Lampenfeld zeichnen; der Buchstabe `lit` leuchtet (nothing = alle aus).
function draw_lamps(s::Screen, lit)
    io = IOBuffer()
    print(io, "\e7")
    for (i, row) in enumerate(LAMP_ROWS)
        width = 4 * length(row) - 1
        print(io, "\e[$(region_bottom(s) + i);1H\e[2K", " "^max(0, (s.cols - width) ÷ 2))
        for (j, c) in enumerate(row)
            j > 1 && print(io, " ")
            print(io, c == lit ? "\e[1;30;103m($c)$RESET" : "$DIM($c)$RESET")
        end
    end
    print(io, "\e8")
    print(String(take!(io)))
end

# --- Eingabezeile ---

# Zeile unten neu zeichnen (horizontal scrollend, falls länger als das Fenster) und Cursor setzen.
function redraw(s::Screen, buf, pos)
    width = s.cols - 3
    first = max(0, pos - width + 1)
    visible = String(buf[first+1:min(length(buf), first + width)])
    print("\e[$(s.rows);1H\e[2K", BOLD, "> ", RESET, visible, "\e[$(s.rows);$(3 + pos - first)H")
end

# Liest eine Taste; Escape-Sequenzen werden zu Symbolen zusammengefasst.
function readkey()
    c = read(stdin, Char)
    c == '\e' || return c
    n = read(stdin, Char)
    n == 'O' && (read(stdin, Char); return :none)    # F1-F4 (ESC O x) verschlucken
    n == '[' || return n == 'b' ? :wordleft : n == 'f' ? :wordright : :none
    seq = ""
    while true
        k = read(stdin, Char)
        seq *= k
        '@' <= k <= '~' && break
    end
    seq == "D" && return :left
    seq == "C" && return :right
    seq in ("H", "1~", "7~") && return :home
    seq in ("F", "4~", "8~") && return :end_
    seq == "3~" && return :delete
    seq in ("1;5D", "1;3D") && return :wordleft
    seq in ("1;5C", "1;3C") && return :wordright
    :none
end

function wordleft(buf, pos)
    while pos > 0 && buf[pos] == ' '; pos -= 1; end
    while pos > 0 && buf[pos] != ' '; pos -= 1; end
    pos
end
function wordright(buf, pos)
    while pos < length(buf) && buf[pos+1] == ' '; pos += 1; end
    while pos < length(buf) && buf[pos+1] != ' '; pos += 1; end
    pos
end

# Zeileneingabe im Raw-Modus. Gibt nothing zurück bei Ctrl-D/Ctrl-C.
# lamp(text) liefert den Buchstaben, der im Lampenfeld leuchten soll (nur im Turing-Modus).
function read_input(s::Screen; lamp=nothing)
    buf, pos = Char[], 0
    update_lamps() = s.turing && draw_lamps(s, lamp === nothing ? nothing : lamp(String(buf)))
    update_lamps()
    redraw(s, buf, pos)
    while true
        k = readkey()
        if k == '\r' || k == '\n'
            return String(buf)
        elseif k == '\x04' && isempty(buf) || k == '\x03'
            return nothing
        elseif k == '\x7f' || k == '\b'
            pos > 0 && (deleteat!(buf, pos); pos -= 1)
        elseif k == :delete || k == '\x04'
            pos < length(buf) && deleteat!(buf, pos + 1)
        elseif k == :left || k == '\x02'
            pos = max(0, pos - 1)
        elseif k == :right || k == '\x06'
            pos = min(length(buf), pos + 1)
        elseif k == :wordleft
            pos = wordleft(buf, pos)
        elseif k == :wordright
            pos = wordright(buf, pos)
        elseif k == :home || k == '\x01'
            pos = 0
        elseif k == :end_ || k == '\x05'
            pos = length(buf)
        elseif k == '\x17'        # Ctrl-W: Wort davor löschen
            start = wordleft(buf, pos)
            deleteat!(buf, start+1:pos); pos = start
        elseif k == '\x15'        # Ctrl-U: alles davor löschen
            deleteat!(buf, 1:pos); pos = 0
        elseif k isa Char && !iscntrl(k)
            insert!(buf, pos + 1, k); pos += 1
        end
        update_lamps()
        redraw(s, buf, pos)
    end
end
