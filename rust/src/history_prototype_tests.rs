//! Regression tests exercise actual Yrs peers and SQLite statement/commit errors.

use super::yrs;
use super::*;
use tempfile::TempDir;
use yrs::undo::StackItem;
use yrs::{Any, Array, ArrayPrelim, MapPrelim, TextPrelim};

fn fixture(text: &str) -> Doc {
    let doc = peer_doc();
    {
        let blocks = doc.get_or_insert_map("blocks");
        let mut txn = doc.transact_mut();
        let root = blocks.insert(&mut txn, "doc", MapPrelim::default());
        root.insert(&mut txn, "id", "doc");
        root.insert(&mut txn, "flavour", "root");
        root.insert(&mut txn, "nodeType", "root");
        root.insert(&mut txn, "props", MapPrelim::default());
        root.insert(&mut txn, "meta", MapPrelim::default());
        root.insert(&mut txn, "children", ArrayPrelim::from(["p", "q"]));
        for (id, value) in [("p", text), ("q", "other")] {
            let block = blocks.insert(&mut txn, id, MapPrelim::default());
            block.insert(&mut txn, "id", id);
            block.insert(&mut txn, "flavour", "paragraph");
            block.insert(&mut txn, "nodeType", "editable");
            let props = block.insert(&mut txn, "props", MapPrelim::default());
            props.insert(&mut txn, "future-prop", "preserve");
            let meta = block.insert(&mut txn, "meta", MapPrelim::default());
            meta.insert(&mut txn, "audit", "peer-owned");
            block.insert(&mut txn, "children", TextPrelim::new(value));
        }
    }
    doc
}

fn peer_doc() -> Doc {
    Doc::with_options(Options {
        offset_kind: OffsetKind::Utf16,
        skip_gc: true,
        ..Default::default()
    })
}

fn seeded(text: &str) -> (TempDir, HistoryPrototype, Doc) {
    let directory = TempDir::new().unwrap();
    let mut history =
        HistoryPrototype::open(directory.path().join("history.sqlite"), "cache").unwrap();
    let peer = fixture(text);
    history.apply_remote(&full_update(&peer)).unwrap();
    history.set_write_access("doc", true).unwrap();
    (directory, history, peer)
}

fn integrate(peer: &Doc, bytes: &[u8]) {
    if !bytes.is_empty() {
        peer.transact_mut()
            .apply_update(Update::decode_v1(bytes).unwrap())
            .unwrap();
    }
}

fn peer_replace(peer: &Doc, id: &str, index: u32, delete: u32, insert: &str) -> Vec<u8> {
    let capture = Arc::new(Mutex::new(Vec::new()));
    let output = capture.clone();
    let subscription = peer
        .observe_update_v1(move |_, event| *output.lock() = event.update.clone())
        .unwrap();
    {
        let mut txn = peer.transact_mut();
        let text = text_target(&txn, id).unwrap();
        if delete > 0 {
            text.remove_range(&mut txn, index, delete);
        }
        if !insert.is_empty() {
            text.insert(&mut txn, index, insert);
        }
    }
    drop(subscription);
    let result = capture.lock().clone();
    result
}

fn peer_text(peer: &Doc, id: &str) -> String {
    let txn = peer.transact();
    text_target(&txn, id).unwrap().get_string(&txn)
}

fn character_formats(doc: &Doc, id: &str) -> Vec<(char, yrs::types::Attrs)> {
    let txn = doc.transact();
    text_target(&txn, id)
        .unwrap()
        .diff(&txn, |_| ())
        .into_iter()
        .flat_map(|run| {
            let Out::Any(Any::String(value)) = run.insert else {
                panic!()
            };
            let attributes = run.attributes.map(|a| *a).unwrap_or_default();
            value
                .chars()
                .map(|value| (value, attributes.clone()))
                .collect::<Vec<_>>()
        })
        .collect()
}

fn rows(history: &HistoryPrototype) -> Vec<Vec<u8>> {
    history
        .connection
        .prepare("SELECT payload FROM document_updates WHERE document_id = ?1 ORDER BY sequence")
        .unwrap()
        .query_map([&history.document_id], |row| row.get(0))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap()
}

#[derive(Debug, PartialEq, Eq)]
struct Snapshot {
    content: Vec<u8>,
    vector: Vec<u8>,
    undo: Vec<StackItem<HistoryMeta>>,
    redo: Vec<StackItem<HistoryMeta>>,
    accepted_actions: usize,
    updates: Vec<Vec<u8>>,
}

fn snapshot(history: &HistoryPrototype) -> Snapshot {
    Snapshot {
        content: history.encode_full_update(),
        vector: history.encode_state_vector(),
        undo: history.state.history.undo_stack().to_vec(),
        redo: history.state.history.redo_stack().to_vec(),
        accepted_actions: history.accepted_actions,
        updates: rows(history),
    }
}

#[test]
fn local_undo_and_redo_preserve_remote_prefix_and_converge() {
    let (_directory, mut history, peer) = seeded("ab");
    let local = history.replace_text("p", 1, 0, "X").unwrap();
    integrate(&peer, &local.v1_update);
    history
        .apply_remote(&peer_replace(&peer, "p", 0, 0, "Z"))
        .unwrap();
    assert_eq!(history.history_state().undo_depth, 1);
    assert_eq!(history.read_text("p").unwrap(), "ZaXb");
    let undone = history.undo().unwrap();
    integrate(&peer, &undone.v1_update);
    assert_eq!(history.read_text("p").unwrap(), "Zab");
    assert_eq!(peer_text(&peer, "p"), "Zab");
    let redone = history.redo().unwrap();
    integrate(&peer, &redone.v1_update);
    assert_eq!(history.read_text("p").unwrap(), "ZaXb");
    assert_eq!(peer_text(&peer, "p"), "ZaXb");
}

#[test]
fn remote_edit_in_other_block_retains_local_history() {
    let (_directory, mut history, peer) = seeded("ab");
    integrate(
        &peer,
        &history.replace_text("p", 1, 0, "X").unwrap().v1_update,
    );
    history
        .apply_remote(&peer_replace(&peer, "q", 0, 0, "REMOTE"))
        .unwrap();
    integrate(&peer, &history.undo().unwrap().v1_update);
    assert_eq!(history.read_text("p").unwrap(), "ab");
    assert_eq!(history.read_text("q").unwrap(), "REMOTEother");
    assert_eq!(peer_text(&peer, "q"), "REMOTEother");
}

#[test]
fn undo_local_delete_restores_text_without_removing_remote_insert() {
    let (_directory, mut history, peer) = seeded("abc");
    integrate(
        &peer,
        &history.replace_text("p", 1, 1, "").unwrap().v1_update,
    );
    history
        .apply_remote(&peer_replace(&peer, "p", 0, 0, "Z"))
        .unwrap();
    integrate(&peer, &history.undo().unwrap().v1_update);
    assert_eq!(history.read_text("p").unwrap(), "Zabc");
    assert_eq!(peer_text(&peer, "p"), "Zabc");
}

#[test]
fn undo_local_run_preserves_remote_insert_inside_that_run() {
    let (_directory, mut history, peer) = seeded("ab");
    integrate(
        &peer,
        &history.replace_text("p", 1, 0, "XYZ").unwrap().v1_update,
    );
    history
        .apply_remote(&peer_replace(&peer, "p", 2, 0, "R"))
        .unwrap();
    integrate(&peer, &history.undo().unwrap().v1_update);
    assert_eq!(history.read_text("p").unwrap(), "aRb");
    assert_eq!(peer_text(&peer, "p"), "aRb");
    integrate(&peer, &history.redo().unwrap().v1_update);
    assert_eq!(history.read_text("p").unwrap(), "aXRYZb");
    assert_eq!(peer_text(&peer, "p"), "aXRYZb");
    history.replace_text("q", 0, 0, "after-redo").unwrap();
}

#[test]
fn remote_update_preserves_redo_and_echo_does_not_capture_history() {
    let (_directory, mut history, peer) = seeded("ab");
    let local = history.replace_text("p", 1, 0, "X").unwrap();
    integrate(&peer, &local.v1_update);
    let echo = history.apply_remote(&local.v1_update).unwrap();
    assert!(!echo.changed);
    assert_eq!(history.history_state().undo_depth, 1);
    integrate(&peer, &history.undo().unwrap().v1_update);
    history
        .apply_remote(&peer_replace(&peer, "p", 0, 0, "Z"))
        .unwrap();
    assert_eq!(history.history_state().redo_depth, 1);
    integrate(&peer, &history.redo().unwrap().v1_update);
    assert_eq!(peer_text(&peer, "p"), "ZaXb");
}

#[test]
fn remote_deletion_of_local_text_makes_undo_noop_without_resurrection() {
    let (_directory, mut history, peer) = seeded("ab");
    integrate(
        &peer,
        &history.replace_text("p", 1, 0, "X").unwrap().v1_update,
    );
    history
        .apply_remote(&peer_replace(&peer, "p", 1, 1, ""))
        .unwrap();
    let before = rows(&history);
    let result = history.undo().unwrap();
    assert!(!result.changed);
    assert_eq!(rows(&history), before);
    assert_eq!(history.read_text("p").unwrap(), "ab");
    assert_eq!(history.history_state().undo_depth, 0);
    history.replace_text("p", 0, 0, "Y").unwrap();
}

#[test]
fn deletion_only_update_is_persisted_even_when_vector_does_not_advance() {
    let (_directory, mut history, peer) = seeded("abc");
    let vector = history.encode_state_vector();
    let before_rows = rows(&history).len();
    let result = history.replace_text("p", 1, 1, "").unwrap();
    assert!(result.changed);
    assert!(!result.v1_update.is_empty());
    assert_eq!(history.encode_state_vector(), vector);
    assert_eq!(rows(&history).len(), before_rows + 1);
    integrate(&peer, &result.v1_update);
    assert_eq!(peer_text(&peer, "p"), "ac");
}

#[test]
fn insertion_deletion_and_repeated_undo_redo_preserve_native_redone_links() {
    let (_directory, mut history, _peer) = seeded("");
    history.replace_text("p", 0, 0, "X").unwrap();
    history.replace_text("p", 0, 1, "").unwrap();
    for _ in 0..6 {
        history.undo().unwrap();
        assert_eq!(history.read_text("p").unwrap(), "X");
        history.undo().unwrap();
        assert_eq!(history.read_text("p").unwrap(), "");
        history.redo().unwrap();
        assert_eq!(history.read_text("p").unwrap(), "X");
        history.redo().unwrap();
        assert_eq!(history.read_text("p").unwrap(), "");
    }
}

#[test]
fn snapshot_and_stack_copy_alone_lose_native_redone_associations() {
    let (_directory, mut history, _peer) = seeded("");
    history.replace_text("p", 0, 0, "X").unwrap();
    history.replace_text("p", 0, 1, "").unwrap();
    history.undo().unwrap();
    let mut copied = NativeState::from_baseline(
        Options {
            guid: history.state.doc.guid(),
            client_id: history.state.doc.client_id(),
            offset_kind: OffsetKind::Utf16,
            skip_gc: true,
            ..Default::default()
        },
        &history.encode_full_update(),
    )
    .unwrap();
    drop(copied.history);
    copied.history = UndoManager::with_options(yrs::undo::Options {
        init_undo_stack: history.state.history.undo_stack().to_vec(),
        init_redo_stack: history.state.history.redo_stack().to_vec(),
        ..Default::default()
    });
    copied
        .history
        .expand_scope(&copied.doc, &copied.doc.get_or_insert_map("blocks"));
    copied.history.undo_blocking();
    assert_eq!(
        peer_text(&copied.doc, "p"),
        "X",
        "snapshot copy cannot undo the original insertion"
    );
    history.undo().unwrap();
    assert_eq!(
        history.read_text("p").unwrap(),
        "",
        "native checkpoint preserves the original insertion history"
    );
}

#[test]
fn replacement_is_one_group_and_noop_does_not_clear_redo() {
    let (_directory, mut history, _peer) = seeded("abc");
    history.replace_text("p", 1, 1, "XYZ").unwrap();
    assert_eq!(history.history_state().undo_depth, 1);
    history.undo().unwrap();
    let before = snapshot(&history);
    let result = history.replace_text("p", 1, 1, "b").unwrap();
    assert!(!result.changed);
    assert_eq!(snapshot(&history), before);
    history.redo().unwrap();
    assert_eq!(history.read_text("p").unwrap(), "aXYZc");
    history.undo().unwrap();
    history.replace_text("p", 0, 0, "NEW").unwrap();
    assert_eq!(history.history_state().redo_depth, 0);
}

#[test]
fn utf16_ranges_preserve_emoji_and_reject_split_surrogates_atomically() {
    let (_directory, mut history, peer) = seeded("甲😀乙");
    for (index, length) in [(2, 0), (1, 1), (0, u32::MAX), (99, 0)] {
        let before = snapshot(&history);
        assert!(history.replace_text("p", index, length, "x").is_err());
        assert_eq!(snapshot(&history), before);
    }
    integrate(
        &peer,
        &history.replace_text("p", 1, 2, "🚀").unwrap().v1_update,
    );
    assert_eq!(peer_text(&peer, "p"), "甲🚀乙");
    history.undo().unwrap();
    assert_eq!(history.read_text("p").unwrap(), "甲😀乙");
}

#[test]
fn invalid_remote_update_and_missing_target_do_not_change_history_or_storage() {
    let (_directory, mut history, _peer) = seeded("ab");
    history.replace_text("p", 1, 0, "X").unwrap();
    let before = snapshot(&history);
    assert!(history.apply_remote(&[255]).is_err());
    assert!(history.replace_text("absent", 0, 0, "X").is_err());
    assert!(history.replace_text("doc", 0, 0, "X").is_err());
    assert_eq!(snapshot(&history), before);
}

#[test]
fn cache_reopen_restores_accepted_updates_but_starts_fresh_history() {
    let (directory, mut history, peer) = seeded("abc");
    integrate(
        &peer,
        &history.replace_text("p", 1, 1, "X").unwrap().v1_update,
    );
    history
        .apply_remote(&peer_replace(&peer, "p", 0, 0, "Z"))
        .unwrap();
    history.undo().unwrap();
    history.redo().unwrap();
    let content = history.encode_full_update();
    drop(history);
    let reopened =
        HistoryPrototype::open(directory.path().join("history.sqlite"), "cache").unwrap();
    assert_eq!(reopened.read_text("p").unwrap(), "ZaXc");
    assert_eq!(reopened.encode_full_update(), content);
    assert_eq!(
        reopened.history_state(),
        HistoryState {
            undo_depth: 0,
            redo_depth: 0
        }
    );
}

#[test]
fn out_of_order_dependency_update_is_durable_even_without_visible_change() {
    let (directory, mut history, peer) = seeded("ab");
    let first = peer_replace(&peer, "p", 1, 0, "X");
    let second = peer_replace(&peer, "p", 2, 0, "Y");
    assert!(!history.apply_remote(&second).unwrap().changed);
    drop(history);
    let mut reopened =
        HistoryPrototype::open(directory.path().join("history.sqlite"), "cache").unwrap();
    reopened.apply_remote(&first).unwrap();
    assert_eq!(reopened.read_text("p").unwrap(), "aXYb");
    assert_eq!(reopened.history_state().undo_depth, 0);
}

#[test]
fn unknown_block_properties_and_metadata_survive_history_and_peer_sync() {
    let (_directory, mut history, peer) = seeded("ab");
    history.replace_text("p", 1, 0, "X").unwrap();
    history.undo().unwrap();
    history.redo().unwrap();
    integrate(&peer, &history.encode_full_update());
    let txn = peer.transact();
    let blocks = txn.get_map("blocks").unwrap();
    let Some(Out::YMap(block)) = blocks.get(&txn, "p") else {
        panic!()
    };
    for (container, key, expected) in [
        ("props", "future-prop", "preserve"),
        ("meta", "audit", "peer-owned"),
    ] {
        let Some(Out::YMap(value)) = block.get(&txn, container) else {
            panic!()
        };
        assert_eq!(value.get(&txn, key), Some(Out::Any(Any::from(expected))));
    }
}

#[test]
fn remote_format_is_preserved_when_undoing_local_characters() {
    let (_directory, mut history, peer) = seeded("ab");
    integrate(
        &peer,
        &history.replace_text("p", 1, 0, "X").unwrap().v1_update,
    );
    let before = peer.transact().state_vector();
    {
        let mut txn = peer.transact_mut();
        text_target(&txn, "p").unwrap().format(
            &mut txn,
            0,
            3,
            [("a:bold".into(), Any::Bool(true))].into_iter().collect(),
        );
    }
    let update = peer.transact().encode_state_as_update_v1(&before);
    history.apply_remote(&update).unwrap();
    integrate(&peer, &history.undo().unwrap().v1_update);
    assert_eq!(peer_text(&peer, "p"), "ab");
    let txn = peer.transact();
    for chunk in text_target(&txn, "p").unwrap().diff(&txn, |_| ()) {
        assert_eq!(
            chunk.attributes.unwrap().get("a:bold"),
            Some(&Any::Bool(true))
        );
    }
    drop(txn);
    history.redo().unwrap();
    // Force another fork after native redo to verify native history remains usable.
    history.replace_text("q", 0, 0, "next").unwrap();
}

#[test]
fn deleted_block_is_not_resurrected_by_text_undo() {
    let (_directory, mut history, peer) = seeded("ab");
    integrate(
        &peer,
        &history.replace_text("p", 1, 0, "X").unwrap().v1_update,
    );
    let before = peer.transact().state_vector();
    {
        let mut txn = peer.transact_mut();
        let blocks = txn.get_map("blocks").unwrap();
        let Some(Out::YMap(root)) = blocks.get(&txn, "doc") else {
            panic!()
        };
        let Some(Out::YArray(order)) = root.get(&txn, "children") else {
            panic!()
        };
        order.remove_range(&mut txn, 0, 1);
        blocks.remove(&mut txn, "p");
    }
    history
        .apply_remote(&peer.transact().encode_state_as_update_v1(&before))
        .unwrap();
    let result = history.undo().unwrap();
    assert!(!result.changed);
    assert!(history.read_text("p").is_err());
    assert_eq!(history.read_text("q").unwrap(), "other");
}

#[test]
fn checkpoint_preserves_native_links_and_does_not_mutate_the_source_history() {
    let (_directory, mut history, _peer) = seeded("");
    history.replace_text("p", 0, 0, "X").unwrap();
    history.replace_text("p", 0, 1, "").unwrap();
    history.undo().unwrap();
    let before = snapshot(&history);
    let mut candidate = history.fork().unwrap();
    assert_eq!(
        candidate.history.undo_stack(),
        history.state.history.undo_stack()
    );
    assert_eq!(snapshot(&history), before);
    candidate.history.undo_blocking();
    assert_eq!(peer_text(&candidate.doc, "p"), "");
    assert_eq!(history.read_text("p").unwrap(), "X");
    assert_eq!(snapshot(&history), before);
}

#[test]
fn database_lock_failure_preserves_exact_history_and_retry() {
    let (directory, mut history, _peer) = seeded("ab");
    history.replace_text("p", 1, 0, "X").unwrap();
    history
        .connection
        .busy_timeout(std::time::Duration::ZERO)
        .unwrap();
    let before = snapshot(&history);
    let blocker = Connection::open(directory.path().join("history.sqlite")).unwrap();
    blocker.execute_batch("BEGIN IMMEDIATE;").unwrap();
    assert!(history
        .undo()
        .unwrap_err()
        .starts_with("HISTORY_PERSIST_WRITE"));
    blocker.execute_batch("ROLLBACK;").unwrap();
    assert_eq!(snapshot(&history), before);
    history.undo().unwrap();
    assert_eq!(history.read_text("p").unwrap(), "ab");
}

#[test]
fn cache_document_partition_does_not_restore_another_sessions_content_or_history() {
    let (directory, mut history, _peer) = seeded("ab");
    history.replace_text("p", 1, 0, "X").unwrap();
    let other =
        HistoryPrototype::open(directory.path().join("history.sqlite"), "other-cache").unwrap();
    assert!(other.read_text("p").is_err());
    assert_eq!(
        other.history_state(),
        HistoryState {
            undo_depth: 0,
            redo_depth: 0
        }
    );
    assert!(rows(&other).is_empty());
    assert_eq!(history.read_text("p").unwrap(), "aXb");
}

#[test]
fn mixed_peer_actions_preserve_remote_characters_and_converge_after_every_step() {
    for seed in [7_u64, 23, 101, 4099] {
        let (directory, mut history, peer) = seeded("");
        let mut random = seed;
        let mut remote_counts = std::collections::BTreeMap::<char, usize>::new();
        for step in 0..100 {
            random = random.wrapping_mul(6364136223846793005).wrapping_add(1);
            let current = history.read_text("p").unwrap();
            let length = current.encode_utf16().count() as u32;
            let index = ((random >> 32) as u32) % (length + 1);
            match step % 5 {
                0 => {
                    let value = char::from(b'a' + (step % 26) as u8).to_string();
                    integrate(
                        &peer,
                        &history
                            .replace_text("p", index, 0, &value)
                            .unwrap()
                            .v1_update,
                    );
                }
                1 => {
                    let value = char::from(b'A' + (step % 26) as u8);
                    *remote_counts.entry(value).or_default() += 1;
                    history
                        .apply_remote(&peer_replace(&peer, "p", index, 0, &value.to_string()))
                        .unwrap();
                }
                2 => {
                    if let Some(position) =
                        current.chars().position(|value| value.is_ascii_lowercase())
                    {
                        integrate(
                            &peer,
                            &history
                                .replace_text("p", position as u32, 1, "")
                                .unwrap()
                                .v1_update,
                        );
                    }
                }
                3 => integrate(&peer, &history.undo().unwrap().v1_update),
                _ => integrate(&peer, &history.redo().unwrap().v1_update),
            }
            let current = history.read_text("p").unwrap();
            assert_eq!(current, peer_text(&peer, "p"), "seed={seed}, step={step}");
            let mut actual = std::collections::BTreeMap::<char, usize>::new();
            for value in current.chars().filter(char::is_ascii_uppercase) {
                *actual.entry(value).or_default() += 1;
            }
            assert_eq!(
                actual, remote_counts,
                "remote text lost: seed={seed}, step={step}"
            );
        }
        let final_text = history.read_text("p").unwrap();
        drop(history);
        let reopened =
            HistoryPrototype::open(directory.path().join("history.sqlite"), "cache").unwrap();
        assert_eq!(reopened.read_text("p").unwrap(), final_text);
    }
}

#[test]
fn remote_format_and_complete_local_delete_survive_repeated_history_checkpoints() {
    let (_directory, mut history, peer) = seeded("abc");
    let before = peer.transact().state_vector();
    {
        let mut txn = peer.transact_mut();
        text_target(&txn, "p").unwrap().format(
            &mut txn,
            0,
            2,
            [("a:bold".into(), Any::Bool(true))].into_iter().collect(),
        );
    }
    history
        .apply_remote(&peer.transact().encode_state_as_update_v1(&before))
        .unwrap();
    let original_formats = character_formats(&history.state.doc, "p");
    history.replace_text("p", 1, 0, "X").unwrap();
    history.replace_text("p", 0, 4, "").unwrap();
    for _ in 0..5 {
        history.undo().unwrap();
        assert_eq!(history.read_text("p").unwrap(), "aXbc");
        history.undo().unwrap();
        assert_eq!(history.read_text("p").unwrap(), "abc");
        assert_eq!(character_formats(&history.state.doc, "p"), original_formats);
        history.redo().unwrap();
        assert_eq!(history.read_text("p").unwrap(), "aXbc");
        history.redo().unwrap();
        assert_eq!(history.read_text("p").unwrap(), "");
    }
}

#[derive(Clone, Copy)]
enum Failure {
    Write,
    Commit,
}

#[derive(Clone, Copy)]
enum Operation {
    Local,
    Remote,
    Undo,
    Redo,
}

fn install_failure(history: &HistoryPrototype, mode: Failure) {
    let sql = match mode {
        Failure::Write => {
            "CREATE TRIGGER fail_history BEFORE INSERT ON document_updates
            BEGIN SELECT RAISE(ABORT, 'injected history write failure'); END;"
        }
        Failure::Commit => {
            "CREATE TABLE history_guard_parent(id INTEGER PRIMARY KEY);
            CREATE TABLE history_guard_child(parent INTEGER REFERENCES history_guard_parent(id)
                DEFERRABLE INITIALLY DEFERRED);
            CREATE TRIGGER fail_history AFTER INSERT ON document_updates
                BEGIN INSERT INTO history_guard_child VALUES (1); END;"
        }
    };
    history.connection.execute_batch(sql).unwrap();
}

fn failure_case(mode: Failure, operation: Operation) {
    let (directory, mut history, peer) = seeded("ab");
    integrate(
        &peer,
        &history.replace_text("p", 1, 0, "X").unwrap().v1_update,
    );
    if !matches!(operation, Operation::Undo) {
        integrate(&peer, &history.undo().unwrap().v1_update);
    }
    let remote = peer_replace(&peer, "p", 0, 0, "Z");
    if !matches!(operation, Operation::Remote) {
        history.apply_remote(&remote).unwrap();
    }
    install_failure(&history, mode);
    let before = snapshot(&history);
    let apply = |state: &mut HistoryPrototype| match operation {
        Operation::Local => state.replace_text("p", 0, 0, "N"),
        Operation::Remote => state.apply_remote(&remote),
        Operation::Undo => state.undo(),
        Operation::Redo => state.redo(),
    };
    let error = apply(&mut history).unwrap_err();
    let expected_error = match mode {
        Failure::Write => "HISTORY_PERSIST_WRITE",
        Failure::Commit => "HISTORY_PERSIST_COMMIT",
    };
    assert!(error.starts_with(expected_error), "{error}");
    assert_eq!(
        snapshot(&history),
        before,
        "content, vectors, both native stacks, accepted action count and SQLite rows must remain exact"
    );
    assert_eq!(
        history
            .connection
            .query_row(
                "SELECT COUNT(*) FROM document_updates WHERE document_id != 'cache'",
                [],
                |r| r.get::<_, i64>(0)
            )
            .unwrap(),
        0
    );
    history
        .connection
        .execute_batch("DROP TRIGGER fail_history;")
        .unwrap();
    let accepted = apply(&mut history).unwrap();
    assert!(accepted.changed);
    integrate(&peer, &accepted.v1_update);
    assert_eq!(history.read_text("p").unwrap(), peer_text(&peer, "p"));
    if matches!(operation, Operation::Local) {
        assert_eq!(history.history_state().redo_depth, 0);
    }
    let expected = history.read_text("p").unwrap();
    drop(history);
    let reopened =
        HistoryPrototype::open(directory.path().join("history.sqlite"), "cache").unwrap();
    assert_eq!(reopened.read_text("p").unwrap(), expected);
}

macro_rules! persistence_failure_test {
    ($name:ident, $failure:ident, $operation:ident) => {
        #[test]
        fn $name() {
            failure_case(Failure::$failure, Operation::$operation);
        }
    };
}

persistence_failure_test!(undo_write_failure_is_atomic_and_retryable, Write, Undo);
persistence_failure_test!(undo_commit_failure_is_atomic_and_retryable, Commit, Undo);
persistence_failure_test!(redo_write_failure_is_atomic_and_retryable, Write, Redo);
persistence_failure_test!(redo_commit_failure_is_atomic_and_retryable, Commit, Redo);
persistence_failure_test!(local_write_failure_preserves_redo, Write, Local);
persistence_failure_test!(local_commit_failure_preserves_redo, Commit, Local);
persistence_failure_test!(remote_write_failure_preserves_local_history, Write, Remote);
persistence_failure_test!(
    remote_commit_failure_preserves_local_history,
    Commit,
    Remote
);

#[path = "history_command_tests.rs"]
mod command_tests;
