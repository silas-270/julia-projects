FROM rust:1-slim AS build
WORKDIR /app
COPY Cargo.toml Cargo.lock ./
COPY src src
RUN cargo build --release

FROM debian:bookworm-slim
COPY --from=build /app/target/release/chat-server /usr/local/bin/chat-server
CMD ["chat-server"]
