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
