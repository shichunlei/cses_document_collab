use axum::extract::ws::{Message as WsMessage, WebSocket, WebSocketUpgrade};
use axum::extract::{Path, State};
use axum::response::Response;
use axum::routing::get;
use axum::Router;
use futures_util::{SinkExt, StreamExt};
use parking_lot::Mutex;
use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use tokio::sync::broadcast;
use yrs::sync::{Message, SyncMessage};
use yrs::updates::decoder::Decode;
use yrs::updates::encoder::Encode;
use yrs::{Doc, OffsetKind, Options, ReadTxn, Transact, Update};

static NEXT_CLIENT_ID: AtomicU64 = AtomicU64::new(1);

#[derive(Default)]
struct ServerState {
    rooms: Mutex<HashMap<String, Arc<Room>>>,
}

struct Room {
    doc: Mutex<Doc>,
    broadcast: broadcast::Sender<(u64, Vec<u8>)>,
}

impl Room {
    fn new() -> Self {
        let (broadcast, _) = broadcast::channel(256);
        Self {
            doc: Mutex::new(Doc::with_options(Options {
                offset_kind: OffsetKind::Utf16,
                skip_gc: true,
                ..Options::default()
            })),
            broadcast,
        }
    }

    fn initial_sync_step1(&self) -> Vec<u8> {
        let doc = self.doc.lock();
        let state_vector = doc.transact().state_vector();
        Message::Sync(SyncMessage::SyncStep1(state_vector)).encode_v1()
    }

    fn handle(&self, bytes: &[u8]) -> Result<(Option<Vec<u8>>, bool), String> {
        let message = Message::decode_v1(bytes)
            .map_err(|error| format!("invalid y-websocket frame: {error}"))?;

        match message {
            Message::Sync(SyncMessage::SyncStep1(state_vector)) => {
                let doc = self.doc.lock();
                let update = doc.transact().encode_state_as_update_v1(&state_vector);
                let reply = Message::Sync(SyncMessage::SyncStep2(update)).encode_v1();
                Ok((Some(reply), false))
            }
            Message::Sync(SyncMessage::SyncStep2(update))
            | Message::Sync(SyncMessage::Update(update)) => {
                if !update.is_empty() {
                    let update = Update::decode_v1(&update)
                        .map_err(|error| format!("invalid Yjs V1 update: {error}"))?;
                    let doc = self.doc.lock();
                    doc.transact_mut()
                        .apply_update(update)
                        .map_err(|error| format!("cannot apply Yjs update: {error}"))?;
                }
                Ok((None, true))
            }
            Message::Awareness(_) | Message::AwarenessQuery | Message::Custom(_, _) => {
                Ok((None, true))
            }
            Message::Auth(_) => Ok((None, false)),
        }
    }
}

impl ServerState {
    fn room(&self, name: String) -> Arc<Room> {
        self.rooms
            .lock()
            .entry(name)
            .or_insert_with(|| Arc::new(Room::new()))
            .clone()
    }
}

#[tokio::main]
async fn main() {
    let state = Arc::new(ServerState::default());
    let app = Router::new()
        .route("/{room}", get(websocket_handler))
        .with_state(state);
    let listener = tokio::net::TcpListener::bind("0.0.0.0:1234")
        .await
        .expect("bind demo server");

    println!("CSES y-websocket demo server: ws://0.0.0.0:1234/<room>");
    println!("State is held in memory only. Press Ctrl+C to stop.");
    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown_signal())
        .await
        .expect("serve websocket");
}

async fn websocket_handler(
    Path(room_name): Path<String>,
    State(state): State<Arc<ServerState>>,
    upgrade: WebSocketUpgrade,
) -> Response {
    let room = state.room(room_name);
    let client_id = NEXT_CLIENT_ID.fetch_add(1, Ordering::Relaxed);
    upgrade.on_upgrade(move |socket| serve_socket(socket, room, client_id))
}

async fn serve_socket(socket: WebSocket, room: Arc<Room>, client_id: u64) {
    let (mut sink, mut source) = socket.split();
    let mut room_messages = room.broadcast.subscribe();

    if sink
        .send(WsMessage::Binary(room.initial_sync_step1().into()))
        .await
        .is_err()
    {
        return;
    }

    loop {
        tokio::select! {
            incoming = source.next() => {
                let Some(Ok(incoming)) = incoming else {
                    break;
                };
                match incoming {
                    WsMessage::Binary(bytes) => {
                        match room.handle(&bytes) {
                            Ok((reply, should_broadcast)) => {
                                if let Some(reply) = reply {
                                    if sink.send(WsMessage::Binary(reply.into())).await.is_err() {
                                        break;
                                    }
                                }
                                if should_broadcast {
                                    let _ = room.broadcast.send((client_id, bytes.to_vec()));
                                }
                            }
                            Err(error) => {
                                eprintln!("client {client_id}: {error}");
                            }
                        }
                    }
                    WsMessage::Ping(payload) => {
                        if sink.send(WsMessage::Pong(payload)).await.is_err() {
                            break;
                        }
                    }
                    WsMessage::Close(_) => break,
                    WsMessage::Text(_) | WsMessage::Pong(_) => {}
                }
            }
            broadcast = room_messages.recv() => {
                match broadcast {
                    Ok((sender_id, bytes)) if sender_id != client_id => {
                        if sink.send(WsMessage::Binary(bytes.into())).await.is_err() {
                            break;
                        }
                    }
                    Ok(_) => {}
                    Err(broadcast::error::RecvError::Lagged(skipped)) => {
                        eprintln!("client {client_id} lagged by {skipped} messages");
                        let step1 = room.initial_sync_step1();
                        if sink.send(WsMessage::Binary(step1.into())).await.is_err() {
                            break;
                        }
                    }
                    Err(broadcast::error::RecvError::Closed) => break,
                }
            }
        }
    }
}

async fn shutdown_signal() {
    let _ = tokio::signal::ctrl_c().await;
}

#[cfg(test)]
mod tests {
    use super::*;
    use yrs::{Array, GetString, Map, Text};

    #[test]
    fn room_applies_update_and_answers_sync_step_one() {
        let source = Doc::with_options(Options {
            offset_kind: OffsetKind::Utf16,
            skip_gc: true,
            ..Options::default()
        });
        let source_order = source.get_or_insert_array("cses_mobile_block_order");
        let source_meta = source.get_or_insert_map("cses_mobile_block_meta");
        let source_text = source.get_or_insert_text("cses_mobile_block_text:title");
        let before = source.transact().state_vector();
        {
            let mut transaction = source.transact_mut();
            source_order.push_back(&mut transaction, "title");
            source_meta.insert(&mut transaction, "title", "heading_1");
            source_text.insert(&mut transaction, 0, "mobile block schema");
        }
        let update = source.transact().encode_state_as_update_v1(&before);

        let room = Room::new();
        let update_message = Message::Sync(SyncMessage::Update(update)).encode_v1();
        let (_, should_broadcast) = room.handle(&update_message).expect("apply update");
        assert!(should_broadcast);

        let replica = Doc::with_options(Options {
            offset_kind: OffsetKind::Utf16,
            skip_gc: true,
            ..Options::default()
        });
        let replica_order = replica.get_or_insert_array("cses_mobile_block_order");
        let replica_meta = replica.get_or_insert_map("cses_mobile_block_meta");
        let replica_text = replica.get_or_insert_text("cses_mobile_block_text:title");
        let step1 =
            Message::Sync(SyncMessage::SyncStep1(replica.transact().state_vector())).encode_v1();
        let (reply, should_broadcast) = room.handle(&step1).expect("handle step one");
        assert!(!should_broadcast);

        let reply = Message::decode_v1(&reply.expect("step two reply")).expect("decode step two");
        let Message::Sync(SyncMessage::SyncStep2(update)) = reply else {
            panic!("expected sync step two");
        };
        replica
            .transact_mut()
            .apply_update(Update::decode_v1(&update).expect("decode update"))
            .expect("apply update");

        let transaction = replica.transact();
        assert_eq!(replica_order.len(&transaction), 1);
        assert!(replica_meta.get(&transaction, "title").is_some());
        assert_eq!(replica_text.get_string(&transaction), "mobile block schema");
    }
}
