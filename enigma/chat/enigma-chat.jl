# Enigma-Chat – Client in einer Datei.
# Start:  julia enigma-chat.jl
# Beim ersten Start wird HTTP.jl automatisch in eine eigene Umgebung installiert (dauert ein paar Minuten).
import Pkg
Pkg.activate("enigma-chat"; shared=true, io=devnull)
if !haskey(Pkg.project().dependencies, "HTTP")
    println("Erstmalige Einrichtung: installiere HTTP.jl (kann ein paar Minuten dauern) ...")
    Pkg.add("HTTP")
end

# Chat-Client: verbindet UI und Verbindung.
# Start: julia --project=. client/client.jl
#
# Modi (beim Start wählbar):
#   clean:  Klartext-Chat, normale Verschlüsselung (beliebiger Text inkl. Emojis)
#   turing: authentischer Enigma-Funkspruch (nur Buchstaben), zeigt Geheimtext + Klartext und das Lampenfeld
# Die Modi sind getrennte Chats (der Server leitet nur innerhalb eines Modus weiter). Befehl in beiden Modi: !print zeigt den Enigma-Stand.
# Eine Chatnachricht, wie UI und Verbindung sie austauschen.
using Dates

struct ChatMessage
    name::Union{String,Nothing}   # nothing = Systemmeldung
    text::String                  # Klartext (bzw. Buchstabensalat bei falschem Schlüssel)
    wire::String                  # Geheimtext, wie er über die Leitung ging ("" bei Systemmeldungen)
    time::String
end

ChatMessage(name, text, wire="") = ChatMessage(name, text, wire, Dates.format(now(), "HH:MM"))
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
# Verschlüsselung mit der Enigma (enigma.jl).
#
# Schlüssel: Aus einem gemeinsamen Schlüsselwort wird per SHA-256 ein kompletter Enigma-Schlüssel
# abgeleitet (3 von 5 Rotoren in Reihenfolge, Ringstellung, Grundstellung, 10 Steckerpaare, Reflektor).
#
# Pro Nachricht (wie der historische Spruchschlüssel): Der Sender würfelt eine Startstellung,
# verschlüsselt sie mit der Grundstellung und stellt sie dem Geheimtext voran. Der Empfänger kann so
# jede Nachricht einzeln entschlüsseln, ohne dass Enigma-Zustände synchron sein müssen.
#
# Die Enigma kennt nur A-Z. Je nach Modus wird der Text so in Buchstaben gewandelt:
#   normal (clean):       jedes UTF-8-Byte wird als zwei Buchstaben geschrieben (verlustfrei, auch Umlaute/Emojis)
#   authentisch (turing): nur Großbuchstaben, Leerzeichen = X, Zahlen ausgeschrieben, Rest entfällt
# Es gibt keine Erkennung eines falschen Schlüssels: Der Empfänger zeigt immer, was beim Entschlüsseln
# herauskommt (bei falschem Schlüssel also Buchstabensalat).
using SHA

using Random

struct Plugboard 
    table::Vector{Char}
end

function Plugboard(ps::AbstractVector{<:AbstractString})
    length(ps) > 10 && error("Ein Steckerbrett darf höchstens 10 Paare enthalten")
    table = collect('A':'Z')
    for p in ps
        length(p) == 2 && all(c -> 'A' <= c <= 'Z', p) || error("Ein Paar braucht genau 2 Buchstaben A-Z: $p")
        a, b = p[1], p[2]
        a == b && error("Selber Buchstabe")
        (table[a - 'A' + 1] == a && table[b - 'A' + 1] == b) || error("Buchstabe doppelt gesteckt: $p")
        table[a - 'A' + 1] = b
        table[b - 'A' + 1] = a
    end
    return Plugboard(table)
end

function apply(c::Char, p::Plugboard)
    return p.table[c - 'A' + 1]
end

Base.show(io::IO, r::Plugboard) = begin
    n_swaps = count(i < x - 'A' + 1 for (i, x) in enumerate(r.table))
    print(io, "Plugboard($n_swaps swapped $(n_swaps == 1 ? "pair" : "pairs"))")
end

Base.show(io::IO, ::MIME"text/plain", r::Plugboard) = begin
    ps = ("($('A' + i - 1), $x)" for (i, x) in enumerate(r.table) if i < x - 'A' + 1)
    if isempty(ps)
        print(io, "(none / identity)")
    else
        print(io, join(ps, ", "))
    end
end


mutable struct Rotor
    table::Vector{Char}
    inverse::Vector{Int}
    notch::Int
    ring::Int
    pos::Int

    function Rotor(table::Vector{Char}, notch::Int, ring::Int, pos::Int)
        inverse = zeros(Int, 26)
        for (i, c) in enumerate(table)
            inverse[c - 'A' + 1] = i
        end
        new(table, inverse, notch, ring, pos)
    end
end

function step!(r::Rotor)
    r.pos = mod(r.pos + 1, 26)
end

function forward(c::Char, r::Rotor)
    i = c - 'A' + 1
    j = mod1(i + r.pos - r.ring, 26)
    out = r.table[j] - 'A' + 1
    k = mod1(out - r.pos + r.ring, 26)
    return 'A' + (k - 1)
end

function backward(c::Char, r::Rotor)
    i = c - 'A' + 1
    j = mod1(i + r.pos - r.ring, 26)
    k = r.inverse[j]
    return 'A' + (mod1(k - r.pos + r.ring, 26) - 1)
end

Base.show(io::IO, r::Rotor) = print(io, "Rotor($(length(r.table)) entries, pos $r.pos)")
Base.show(io::IO, ::MIME"text/plain", r::Rotor) = print(io, join(("$('A' + i - 1)->$x" for (i, x) in enumerate(r.table)), ", ") * ", pos $r.pos")


struct Reflector
    table::Vector{Char}
end

function apply(c::Char, r::Reflector)
    return r.table[c - 'A' + 1] 
end

Base.show(io::IO, r::Reflector) = print(io, "Reflector($(length(r.table)) entries)")
Base.show(io::IO, ::MIME"text/plain", r::Reflector) = print(io, join(("($('A' + i - 1), $x)" for (i, x) in enumerate(r.table) if i < x - 'A' + 1), ", "))


struct Enigma
    plugboard::Plugboard
    rotors::Vector{Rotor}
    reflector::Reflector
end

function Enigma(rotors_size::Int; plugboard_size::Int=10, seed=nothing)
    rotors_size < 1 && error("Mindestens ein Rotor benötigt")
    plugboard_size < 0 && error("Zu kleines Schaltbrett")
    rng = seed === nothing ? Random.default_rng() : MersenneTwister(seed)

    alphabet = collect('A':'Z')
    rotors = [Rotor(shuffle(rng, alphabet), rand(rng, 0:25), rand(rng, 0:25), rand(rng, 0:25)) for _ in 1:rotors_size]

    reflector = similar(alphabet)
    for (a, b) in Iterators.partition(shuffle(rng, alphabet), 2)
        reflector[a - 'A' + 1] = b
        reflector[b - 'A' + 1] = a
    end

    plugboard = copy(alphabet)
    for (a, b) in Iterators.take(Iterators.partition(shuffle(rng, alphabet), 2), plugboard_size)
        plugboard[a - 'A' + 1] = b
        plugboard[b - 'A' + 1] = a
    end

    Enigma(Plugboard(plugboard), rotors, Reflector(reflector))
end

# Historische Teile (Verdrahtung, Kerbe = Fensterbuchstabe, bei dem der linke Nachbar mitgenommen wird)
const HISTORICAL_ROTORS = Dict(
    "I"   => ("EKMFLGDQVZNTOWYHXUSPAIBRCJ", 'Q'),
    "II"  => ("AJDKSIRUXBLHWTMCQGZNPYFVOE", 'E'),
    "III" => ("BDFHJLCPRTXVZNYEIWGAKMUSQO", 'V'),
    "IV"  => ("ESOVPZJAYQUIRHXLNFTGKDCMWB", 'J'),
    "V"   => ("VZBRGITYUPSDNHLXAWMJQOFECK", 'Z'),
)

const HISTORICAL_REFLECTORS = Dict(
    "B" => "YRUHQSLDPXNGOKMIEBFZCWVJAT",
    "C" => "FVPJIAOYEDRZXWGCTKUQSBNMHL",
)

# Historischer Schlüssel: Rotoren, Ringe und Stellungen werden wie auf den Schlüsselzetteln
# LINKS -> RECHTS angegeben. Intern ist rotors[1] der schnelle rechte Rotor.
function Enigma(rotor_names::AbstractVector{<:AbstractString};
                rings::AbstractString="A"^length(rotor_names),
                positions::AbstractString="A"^length(rotor_names),
                plugs::AbstractVector{<:AbstractString}=String[],
                reflector::AbstractString="B")
    n = length(rotor_names)
    (length(rings) == n && length(positions) == n) ||
        error("rings und positions brauchen je einen Buchstaben pro Rotor ($n)")
    haskey(HISTORICAL_REFLECTORS, reflector) || error("Unbekannter Reflektor: $reflector")

    rings, positions = collect(rings), collect(positions)
    rotors = map(n:-1:1) do k
        haskey(HISTORICAL_ROTORS, rotor_names[k]) || error("Unbekannter Rotor: $(rotor_names[k])")
        wiring, notch = HISTORICAL_ROTORS[rotor_names[k]]
        Rotor(collect(wiring), notch - 'A', rings[k] - 'A', positions[k] - 'A')
    end

    Enigma(Plugboard(plugs), rotors, Reflector(collect(HISTORICAL_REFLECTORS[reflector])))
end

# Fensteranzeige links -> rechts, wie auf der echten Maschine
window(e::Enigma) = String(['A' + r.pos for r in reverse(e.rotors)])

# Alles außer A-Z entfernen (z.B. um Geheimtext in 5er-Blöcken direkt einzufügen)
clean_text(s::AbstractString) = filter(c -> 'A' <= c <= 'Z', uppercase(s))

function step_rotors!(e::Enigma)
    steppers = [1]
    for k in 1:length(e.rotors)-1
        if e.rotors[k].pos == e.rotors[k].notch
            push!(steppers, k, k+1)
        end
    end
    foreach(k -> step!(e.rotors[k]), unique(steppers))
end

function encrypt(c::Char, e::Enigma)
    enc = c

    enc = apply(enc, e.plugboard)

    step_rotors!(e)

    for i in 1:length(e.rotors)
        enc = forward(enc, e.rotors[i])
    end
    enc = apply(enc, e.reflector)
    for i in length(e.rotors):-1:1
        enc = backward(enc, e.rotors[i])
    end

    enc = apply(enc, e.plugboard)

    return enc
end

encrypt(s::String, e::Enigma) = join(encrypt(c, e) for c in s)

Base.show(io::IO, e::Enigma) = print(io, "Enigma ($(length(e.rotors)) rotoren)")
function Base.show(io::IO, ::MIME"text/plain", e::Enigma)
    println(io, "Enigma Daten:")
    println(io, "Rotoren")
    foreach(r -> println(io, r), e.rotors)
    println(io, "Reflector")
    println(io, e.reflector)
end

struct Cipher
    rotors::Vector{String}
    rings::String
    base::String          # Grundstellung
    plugs::Vector{String}
    reflector::String
end

# Deterministischer Bytestrom aus dem Schlüsselwort (SHA-256 im Zählermodus).
function byte_stream(passphrase)
    buf, counter = UInt8[], 0
    function next()
        if isempty(buf)
            counter += 1
            buf = sha256(string(passphrase, '\0', counter))
        end
        popfirst!(buf)
    end
end

function shuffled(next, v)
    v = copy(v)
    for i in length(v):-1:2
        j = Int(next()) % i + 1
        v[i], v[j] = v[j], v[i]
    end
    v
end

function Cipher(passphrase::AbstractString)
    next = byte_stream(strip(passphrase))
    letters(n) = String([Char('A' + Int(next()) % 26) for _ in 1:n])
    rotors = shuffled(next, sort(collect(keys(HISTORICAL_ROTORS))))[1:3]
    rings, base = letters(3), letters(3)
    pool = shuffled(next, collect('A':'Z'))
    plugs = [string(pool[2i-1], pool[2i]) for i in 1:10]
    reflector = Int(next()) % 2 == 0 ? "B" : "C"
    Cipher(rotors, rings, base, plugs, reflector)
end

machine(c::Cipher, positions) =
    Enigma(c.rotors; rings=c.rings, positions=positions, plugs=c.plugs, reflector=c.reflector)

# --- Text <-> Buchstaben ---

to_letters(text) = join(string('A' + Int(b) ÷ 26, 'A' + Int(b) % 26) for b in codeunits(text))

function from_letters(s)
    iseven(length(s)) || return nothing
    pairs = [(s[i] - 'A') * 26 + (s[i+1] - 'A') for i in 1:2:length(s)]
    all(<=(255), pairs) || return nothing
    text = String(UInt8.(pairs))
    isvalid(text) ? text : nothing
end

const AUTHENTIC_MAP = Dict('Ä' => "AE", 'Ö' => "OE", 'Ü' => "UE", 'ä' => "AE", 'ö' => "OE", 'ü' => "UE",
                           'ß' => "SS", ' ' => "X")
const NUMBERS = ["NULL", "EINS", "ZWEI", "DREI", "VIER", "FUENF", "SECHS", "SIEBEN", "ACHT", "NEUN"]

function authentic_letters(text)
    io = IOBuffer()
    for c in text
        if haskey(AUTHENTIC_MAP, c)
            print(io, AUTHENTIC_MAP[c])
        elseif isdigit(c)
            print(io, NUMBERS[c - '0' + 1])
        elseif 'A' <= uppercase(c) <= 'Z'
            print(io, uppercase(c))
        end
    end
    String(take!(io))
end

# Was die Empfänger als Klartext sehen werden.
as_sent(text, authentic) = authentic ? authentic_letters(text) : String(text)

body_letters(text, authentic) = authentic ? authentic_letters(text) : to_letters(text)

# --- Nachrichten ---

new_message_key(c::Cipher) = String(rand('A':'Z', length(c.rotors)))

groups(s) = join((s[i:min(i + 4, end)] for i in 1:5:length(s)), " ")

# Klartext -> Geheimtext in 5er-Gruppen (die ersten 3 Buchstaben sind der verschlüsselte Spruchschlüssel).
function encode(c::Cipher, text::AbstractString; message_key=new_message_key(c), authentic=false)
    indicator = encrypt(message_key, machine(c, c.base))
    body = encrypt(body_letters(text, authentic), machine(c, message_key))
    groups(indicator * body)
end

# Geheimtext -> Klartext. Gibt immer etwas zurück: Lässt sich das Ergebnis nicht als Text lesen
# (falscher Schlüssel, Unsinn), sind es die rohen entschlüsselten Buchstaben.
function decode(c::Cipher, payload::AbstractString; authentic=false)
    s = clean_text(payload)
    n = length(c.rotors)
    length(s) > n || return s
    message_key = encrypt(String(s[1:n]), machine(c, c.base))
    letters = encrypt(String(s[n+1:end]), machine(c, message_key))
    authentic ? letters : something(from_letters(letters), letters)
end

# Welche Lampe leuchtet, wenn `text` mit diesem Spruchschlüssel getippt ist? (Letzter Geheimtextbuchstabe.)
# Nur dieselben Parameter wie beim späteren encode() geben dieselbe Anzeige.
function lamp_letter(c::Cipher, text; message_key, authentic)
    letters = body_letters(text, authentic)
    isempty(letters) && return nothing
    last(encrypt(letters, machine(c, message_key)))
end

# Aktueller Stand der Maschine als Text (für !print): der Schlüssel und die Rotorstellung
# für die nächste Nachricht (message_key).
function describe(c::Cipher, message_key)
    spaced(s) = join(collect(s), " ")
    join([
        "Enigma-Stand",
        "Walzenlage (links → rechts): " * join(c.rotors, " "),
        "Ringstellung:                " * spaced(c.rings),
        "Grundstellung:               " * spaced(c.base),
        "Steckerbrett:                " * join(sort(c.plugs), " "),
        "Reflektor:                   " * c.reflector,
        "Fenster nächste Nachricht:   " * spaced(message_key),
    ], "\n")
end
# Verbindung: WebSocket zum Server. Kennt das Terminal nicht, meldet Nachrichten per Callback.
# Ver- und Entschlüsselt mit dem übergebenen Cipher (crypto.jl); der Server sieht nur Geheimtext.
using HTTP
using HTTP.WebSockets

const DEFAULT_PORT = 8080
const DEFAULT_SERVER = "chat-server-production-6915.up.railway.app"   # Standard bei leerer Eingabe

struct Connection
    ws::Any
    cipher::Cipher
    mode::String
end

# Adresse -> WebSocket-URL ohne Pfad. Mit Schema (ws://, wss://, http(s)://) wird sie übernommen.
# Ohne Schema: IP/localhost bekommen ws:// und den Standardport 8080, öffentliche Hostnamen
# (z. B. bei Railway) wss:// auf Port 443; ein angegebener Port wird immer respektiert.
function normalize_address(address)
    address = rstrip(address, '/')
    m = match(r"^(wss?|https?)://(.*)$", address)
    m !== nothing && return (m[1] in ("ws", "http") ? "ws://" : "wss://") * m[2]
    local_host = occursin(r"^(localhost|\d{1,3}(\.\d{1,3}){3}|\[.*\])(:\d+)?$", address)
    occursin(r":\d+$", address) && return "$(local_host ? "ws" : "wss")://$address"
    local_host ? "ws://$address:$DEFAULT_PORT" : "wss://$address"
end

partition(s, sep) = (r = findfirst(sep, s); r === nothing ? (s, "", "") : (s[1:first(r)-1], sep, s[last(r)+1:end]))

# Server schickt "name: geheimtext" oder Systemmeldungen "* ...".
function decrypt_message(cipher, msg; authentic)
    startswith(msg, "* ") && return ChatMessage(nothing, String(msg[3:end]))
    name, sep, payload = partition(msg, ": ")
    isempty(sep) && return ChatMessage(nothing, String(msg))
    ChatMessage(String(name), decode(cipher, payload; authentic), String(payload))
end

# Verbindet (mode = "clean"/"turing": der Server trennt die Modi) und ruft f(conn) auf.
# Eingehende Nachrichten werden erst mit receive_loop(conn; ...) verarbeitet, damit die UI vorher bereit ist.
function connect(f, address, username, cipher; mode)
    url = "$address/?username=$(HTTP.URIs.escapeuri(username))&mode=$mode"
    WebSockets.open(url) do ws
        try
            f(Connection(ws, cipher, mode))
        finally
            close(ws)
        end
    end
end

# Empfängt im Hintergrund: Jede Nachricht wird entschlüsselt und als ChatMessage an on_message gegeben;
# on_close wird aufgerufen, wenn der Server die Verbindung beendet. Ein Fehler bei einer einzelnen
# Nachricht beendet den Empfang nicht.
function receive_loop(c::Connection; on_message, on_close=() -> nothing)
    @async try
        for msg in c.ws
            try
                on_message(decrypt_message(c.cipher, msg; authentic=c.mode == "turing"))
            catch
            end
        end
        on_close()
    catch
    end
end

# Verschlüsselt und sendet; gibt den Geheimtext zurück, wie er über die Leitung ging.
function send_message(c::Connection, text; kwargs...)
    wire = encode(c.cipher, text; kwargs...)
    WebSockets.send(c.ws, wire)
    wire
end

function ask_mode()
    while true
        answer = lowercase(ask("Modus (clean / turing) [clean]: "))
        answer in ("", "c", "clean") && return :clean
        answer in ("t", "turing") && return :turing
    end
end

function main()
    show_welcome()
    address = ask("Server-Adresse [$DEFAULT_SERVER]: ")
    address = normalize_address(isempty(address) ? DEFAULT_SERVER : address)
    username = ask("Username: ")
    cipher = Cipher(ask("Schlüsselwort: "))
    turing = ask_mode() == :turing

    connect(address, username, cipher; mode = turing ? "turing" : "clean") do conn
        screen = open_screen("Chat – $username @ $(replace(address, r"^wss?://" => ""))"; turing)
        receive_loop(conn; on_message = msg -> show_message(screen, msg),
                           on_close = () -> show_notice(screen, "Verbindung getrennt"))
        # Spruchschlüssel steht schon beim Tippen fest, damit das Lampenfeld den echten Geheimtext zeigt.
        message_key = new_message_key(cipher)
        while true
            lamp = turing ? text -> lamp_letter(cipher, text; message_key, authentic=true) : nothing
            line = read_input(screen; lamp)
            line === nothing && break
            line = strip(line)
            isempty(line) && continue
            if line == "!print"
                show_notice(screen, describe(cipher, message_key))
                continue
            end
            plain = as_sent(line, turing)
            isempty(plain) && continue
            wire = send_message(conn, line; message_key, authentic=turing)
            show_message(screen, ChatMessage(username, plain, wire))
            message_key = new_message_key(cipher)
        end
    end
end

main()
