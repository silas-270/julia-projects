# Chat-Server: nimmt WebSocket-Verbindungen an und leitet jede Nachricht an alle anderen weiter.
# Jeder Client gehört zu einem Modus (clean/turing); Modi sind getrennte Chats und sehen sich nicht.
# Start: julia --project=. server/server.jl [host] [port]
using HTTP
using HTTP.WebSockets

const clients = Dict{Any,Tuple{String,String}}()   # Verbindung => (Username, Modus)
const lock_ = ReentrantLock()

function broadcast(msg::String, mode; except=nothing)
    lock(lock_) do
        for (ws, (_, m)) in collect(clients)
            (ws === except || m != mode) && continue
            try
                WebSockets.send(ws, msg)
            catch
                delete!(clients, ws)
            end
        end
    end
end

# Username und Modus aus der URL (?username=...&mode=...); ohne Angabe "anonym" bzw. "clean".
function login_from(request)
    query = HTTP.queryparams(HTTP.URI(request.target))
    name = strip(get(query, "username", ""))
    mode = strip(get(query, "mode", ""))
    (isempty(name) ? "anonym" : String(name)), (isempty(mode) ? "clean" : String(mode))
end

function handle(ws)
    name, mode = login_from(ws.handshake_request)
    lock(() -> clients[ws] = (name, mode), lock_)
    broadcast("* $name ist beigetreten", mode; except=ws)
    try
        for msg in ws
            broadcast("$name: $msg", mode; except=ws)
        end
    finally
        lock(() -> delete!(clients, ws), lock_)
        broadcast("* $name hat den Chat verlassen", mode)
    end
end

function main(host="0.0.0.0", port=8080)
    println("Chat-Server läuft auf ws://$host:$port")
    WebSockets.listen(handle, host, port)
end

main(get(ARGS, 1, "0.0.0.0"), parse(Int, get(ARGS, 2, "8080")))
