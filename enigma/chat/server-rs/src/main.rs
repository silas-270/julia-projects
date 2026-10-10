// Chat-Server: nimmt WebSocket-Verbindungen an und leitet jede Nachricht an alle anderen weiter.
// Jeder Client gehört zu einem Modus (clean/turing); Modi sind getrennte Chats und sehen sich nicht.
// Protokoll: ws://host/?username=NAME&mode=MODUS; Nachrichten gehen als "name: text" raus,
// Beitritt/Verlassen als "* name ist beigetreten" / "* name hat den Chat verlassen".
// Start: chat-server (Port aus der Umgebungsvariable PORT, Standard 8080)
use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
    time::Duration,
};

use futures_util::{SinkExt, StreamExt};
use tokio::{net::TcpListener, sync::mpsc};
use tokio_tungstenite::{
    accept_hdr_async_with_config,
    tungstenite::{handshake::server::{Request, Response}, protocol::WebSocketConfig, Message},
};

struct Client {
    mode: String,
    tx: mpsc::UnboundedSender<Message>,
}

type Clients = Arc<Mutex<HashMap<u64, Client>>>;

// Sendet msg an alle Clients im Modus `mode`, außer an `except`.
fn broadcast(clients: &Clients, msg: &str, mode: &str, except: Option<u64>) {
    for (id, c) in clients.lock().unwrap().iter() {
        if Some(*id) != except && c.mode == mode {
            let _ = c.tx.send(Message::Text(msg.into()));
        }
    }
}

fn percent_decode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' && i + 2 < b.len() {
            if let (Some(h), Some(l)) = ((b[i + 1] as char).to_digit(16), (b[i + 2] as char).to_digit(16)) {
                out.push((h * 16 + l) as u8);
                i += 3;
                continue;
            }
        }
        out.push(b[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

// Username und Modus aus der URL (?username=...&mode=...); ohne Angabe "anonym" bzw. "clean".
fn login_from(query: &str) -> (String, String) {
    let (mut name, mut mode) = (String::new(), String::new());
    for pair in query.split('&') {
        match pair.split_once('=') {
            Some(("username", v)) => name = percent_decode(v).trim().chars().take(32).collect(),
            Some(("mode", v)) => mode = percent_decode(v).trim().chars().take(16).collect(),
            _ => {}
        }
    }
    (
        if name.is_empty() { "anonym".into() } else { name },
        if mode.is_empty() { "clean".into() } else { mode },
    )
}

async fn handle(stream: tokio::net::TcpStream, id: u64, clients: Clients) {
    let mut query = String::new();
    let config = WebSocketConfig::default().max_message_size(Some(64 * 1024));
    let ws = accept_hdr_async_with_config(
        stream,
        |req: &Request, resp: Response| {
            query = req.uri().query().unwrap_or("").to_string();
            Ok(resp)
        },
        Some(config),
    )
    .await;
    let Ok(ws) = ws else { return };
    let (name, mode) = login_from(&query);
    let (mut sink, mut stream) = ws.split();
    let (tx, mut rx) = mpsc::unbounded_channel::<Message>();

    clients.lock().unwrap().insert(id, Client { mode: mode.clone(), tx });
    broadcast(&clients, &format!("* {name} ist beigetreten"), &mode, Some(id));

    // Schreiber: leitet Nachrichten an den Client und hält die Verbindung mit Pings offen (Proxys).
    let writer = tokio::spawn(async move {
        let mut ping = tokio::time::interval(Duration::from_secs(30));
        loop {
            tokio::select! {
                msg = rx.recv() => match msg {
                    Some(m) => if sink.send(m).await.is_err() { break },
                    None => break,
                },
                _ = ping.tick() => if sink.send(Message::Ping(Vec::new().into())).await.is_err() { break },
            }
        }
    });

    while let Some(Ok(msg)) = stream.next().await {
        match msg {
            Message::Text(t) => broadcast(&clients, &format!("{name}: {t}"), &mode, Some(id)),
            Message::Close(_) => break,
            _ => {}
        }
    }

    clients.lock().unwrap().remove(&id);
    broadcast(&clients, &format!("* {name} hat den Chat verlassen"), &mode, None);
    writer.abort();
}

#[tokio::main(flavor = "current_thread")]
async fn main() {
    let port = std::env::var("PORT").unwrap_or_else(|_| "8080".into());
    let listener = TcpListener::bind(format!("0.0.0.0:{port}")).await.expect("Port nicht verfügbar");
    println!("Chat-Server läuft auf ws://0.0.0.0:{port}");
    let clients: Clients = Arc::default();
    for id in 0u64.. {
        let Ok((stream, _)) = listener.accept().await else { continue };
        tokio::spawn(handle(stream, id, clients.clone()));
    }
}
