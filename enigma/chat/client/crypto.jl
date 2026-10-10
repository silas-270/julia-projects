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

include("enigma.jl")

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
