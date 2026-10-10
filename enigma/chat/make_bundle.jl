# Erzeugt enigma-chat.jl: den gesamten Client in einer Datei (zum Weitergeben).
# Aufruf: julia make_bundle.jl   (nach Änderungen an client/*.jl erneut ausführen)
const HEADER = raw"""
# Enigma-Chat – Client in einer Datei.
# Start:  julia enigma-chat.jl
# Beim ersten Start wird HTTP.jl automatisch in eine eigene Umgebung installiert (dauert ein paar Minuten).
import Pkg
Pkg.activate("enigma-chat"; shared=true, io=devnull)
if !haskey(Pkg.project().dependencies, "HTTP")
    println("Erstmalige Einrichtung: installiere HTTP.jl (kann ein paar Minuten dauern) ...")
    Pkg.add("HTTP")
end
"""

# Liest eine Datei und ersetzt jede Zeile include("datei.jl") rekursiv durch deren Inhalt.
function inline(path)
    dir = dirname(path)
    out = String[]
    for line in eachline(path)
        m = match(r"^include\(\"(.+)\"\)\s*$", line)
        push!(out, m === nothing ? line : inline(joinpath(dir, m[1])))
    end
    join(out, "\n")
end

src = joinpath(@__DIR__, "client", "client.jl")
dest = joinpath(@__DIR__, "enigma-chat.jl")
write(dest, strip(HEADER) * "\n\n" * inline(src) * "\n")
println("geschrieben: $dest ($(length(readlines(dest))) Zeilen)")
