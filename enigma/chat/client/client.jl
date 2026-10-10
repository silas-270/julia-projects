# Chat-Client: verbindet UI und Verbindung.
# Start: julia --project=. client/client.jl
#
# Modi (beim Start wählbar):
#   clean:  Klartext-Chat, normale Verschlüsselung (beliebiger Text inkl. Emojis)
#   turing: authentischer Enigma-Funkspruch (nur Buchstaben), zeigt Geheimtext + Klartext und das Lampenfeld
# Die Modi sind getrennte Chats (der Server leitet nur innerhalb eines Modus weiter). Befehl in beiden Modi: !print zeigt den Enigma-Stand.
include("message.jl")
include("ui.jl")
include("crypto.jl")
include("connection.jl")

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
