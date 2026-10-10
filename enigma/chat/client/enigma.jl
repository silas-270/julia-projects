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
