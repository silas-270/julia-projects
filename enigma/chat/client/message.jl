# Eine Chatnachricht, wie UI und Verbindung sie austauschen.
using Dates

struct ChatMessage
    name::Union{String,Nothing}   # nothing = Systemmeldung
    text::String                  # Klartext (bzw. Buchstabensalat bei falschem Schlüssel)
    wire::String                  # Geheimtext, wie er über die Leitung ging ("" bei Systemmeldungen)
    time::String
end

ChatMessage(name, text, wire="") = ChatMessage(name, text, wire, Dates.format(now(), "HH:MM"))
