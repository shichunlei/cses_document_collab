//! Second-stage tests use real native checkpoints, replicas, locks and SQLite.

use super::yrs;
use super::*;
use std::collections::BTreeMap;
use yrs::{
    types::{Attrs, ToJson},
    TransactionMut,
};

fn remote_edit(peer: &Doc, edit: impl FnOnce(&mut TransactionMut<'_>)) -> Vec<u8> {
    let capture = Arc::new(Mutex::new(Vec::new()));
    let sink = capture.clone();
    let subscription = peer
        .observe_update_v1(move |_, event| *sink.lock() = event.update.clone())
        .unwrap();
    {
        let mut txn = peer.transact_mut();
        edit(&mut txn);
    }
    drop(subscription);
    let update = capture.lock().clone();
    update
}

fn map_at(doc: &Doc, block_id: &str, key: &str) -> yrs::MapRef {
    let txn = doc.transact();
    let block = policy::block_map(&txn.get_map("blocks").unwrap(), &txn, block_id).unwrap();
    policy::block_map(&block, &txn, key).unwrap()
}

fn child_ids(doc: &Doc, id: &str) -> Vec<String> {
    policy::Graph::read(doc, "doc").unwrap().nodes[id]
        .children
        .clone()
}

fn props(doc: &Doc, id: &str) -> Any {
    map_at(doc, id, "props").to_json(&doc.transact())
}

fn mark(key: &str, value: Any) -> Attrs {
    [(key.into(), value)].into_iter().collect()
}

fn patch(key: &str, value: Option<Any>) -> BTreeMap<String, Option<Any>> {
    [(key.to_owned(), value)].into_iter().collect()
}

fn sync_change(history: &HistoryPrototype, peer: &Doc, change: HistoryChange) {
    integrate(peer, &change.v1_update);
    let local = history.state.doc.transact();
    let remote = peer.transact();
    // Runtime redone boundaries can prevent struct coalescing. Encoded bytes
    // need not match across replicas; identities, deletes and shared data must.
    assert_eq!(local.snapshot(), remote.snapshot());
    assert_eq!(
        local.get_map("blocks").unwrap().to_json(&local),
        remote.get_map("blocks").unwrap().to_json(&remote)
    );
}

fn lock(history: &mut HistoryPrototype, peer: &Doc, id: &str, owner: Option<&str>, template: bool) {
    let meta = map_at(peer, id, "meta");
    let update = remote_edit(peer, |txn| {
        if let Some(owner) = owner {
            meta.insert(txn, "lock", owner);
        } else {
            meta.remove(txn, "lock");
        }
        if template {
            meta.insert(txn, "lockKind", "template");
        } else {
            meta.remove(txn, "lockKind");
        }
    });
    history.apply_remote(&update).unwrap();
}

#[test]
fn inserted_deleted_block_and_nested_content_survive_repeated_native_history() {
    let (_dir, mut h, peer) = seeded("ab");
    let c = h.insert_callout("doc", 1, "box").unwrap();
    sync_change(&h, &peer, c);
    let c = h.insert_paragraph("box", 0, "new", "你好🌟").unwrap();
    sync_change(&h, &peer, c);
    let c = h
        .format_text("new", 0, 2, mark("a:bold", Any::Bool(true)))
        .unwrap();
    sync_change(&h, &peer, c);
    let c = h.delete_block("box").unwrap();
    sync_change(&h, &peer, c);
    for _ in 0..6 {
        let c = h.undo().unwrap();
        sync_change(&h, &peer, c);
        assert_eq!(h.read_text("new").unwrap(), "你好🌟");
        assert_eq!(
            character_formats(&h.state.doc, "new")[0].1.get("a:bold"),
            Some(&Any::Bool(true))
        );
        let c = h.redo().unwrap();
        sync_change(&h, &peer, c);
        assert!(h.read_text("new").is_err());
    }
    for _ in 0..4 {
        let c = h.undo().unwrap();
        sync_change(&h, &peer, c);
    }
    assert_eq!(child_ids(&h.state.doc, "doc"), ["p", "q"]);
    for _ in 0..4 {
        let c = h.redo().unwrap();
        sync_change(&h, &peer, c);
    }
    assert_eq!(child_ids(&h.state.doc, "doc"), ["p", "q"]);
}

#[test]
fn property_history_restores_repeated_map_values_without_losing_remote_keys() {
    let (_dir, mut h, peer) = seeded("ab");
    let original = props(&h.state.doc, "p");
    for level in [1, 2] {
        let c = h
            .patch_paragraph_properties("p", patch("heading", Some(Any::Number(level as f64))))
            .unwrap();
        sync_change(&h, &peer, c);
    }
    let remote_props = map_at(&peer, "p", "props");
    h.apply_remote(&remote_edit(&peer, |txn| {
        remote_props.insert(txn, "remote-style", "keep");
    }))
    .unwrap();
    for _ in 0..5 {
        for expected in [Some(Any::Number(1.0)), None] {
            let c = h.undo().unwrap();
            sync_change(&h, &peer, c);
            let values = map_at(&h.state.doc, "p", "props");
            let txn = h.state.doc.transact();
            assert_eq!(values.get(&txn, "heading"), expected.map(Out::Any));
            assert_eq!(
                values.get(&txn, "remote-style"),
                Some(Out::Any(Any::from("keep")))
            );
        }
        for expected in [1.0, 2.0] {
            let c = h.redo().unwrap();
            sync_change(&h, &peer, c);
            assert_eq!(
                map_at(&h.state.doc, "p", "props").get(&h.state.doc.transact(), "heading"),
                Some(Out::Any(Any::Number(expected)))
            );
        }
    }
    assert!(matches!(original, Any::Map(_)));
}

#[test]
fn remote_overwrite_of_same_property_is_not_reverted_by_local_undo() {
    let (_dir, mut h, peer) = seeded("ab");
    let c = h
        .patch_paragraph_properties("p", patch("heading", Some(Any::Number(1.0))))
        .unwrap();
    sync_change(&h, &peer, c);
    let remote_props = map_at(&peer, "p", "props");
    h.apply_remote(&remote_edit(&peer, |txn| {
        remote_props.insert(txn, "heading", 3_i64);
    }))
    .unwrap();
    let c = h.undo().unwrap();
    sync_change(&h, &peer, c);
    assert_eq!(
        map_at(&h.state.doc, "p", "props").get(&h.state.doc.transact(), "heading"),
        Some(Out::Any(Any::Number(3.0)))
    );
}

#[test]
fn formatting_undo_keeps_remote_marks_and_inserted_characters() {
    let (_dir, mut h, peer) = seeded("abc");
    let c = h
        .format_text("p", 0, 3, mark("a:bold", Any::Bool(true)))
        .unwrap();
    sync_change(&h, &peer, c);
    let update = remote_edit(&peer, |txn| {
        let text = text_target(txn, "p").unwrap();
        text.format(txn, 0, 3, mark("a:italic", Any::Bool(true)));
        text.insert(txn, 1, "R");
    });
    h.apply_remote(&update).unwrap();
    for _ in 0..5 {
        let c = h.undo().unwrap();
        sync_change(&h, &peer, c);
        assert_eq!(h.read_text("p").unwrap(), "aRbc");
        let formats = character_formats(&h.state.doc, "p");
        assert!(formats
            .iter()
            .all(|(_, attrs)| attrs.get("a:italic") == Some(&Any::Bool(true))));
        for (value, attrs) in &formats {
            if *value != 'R' {
                assert_ne!(attrs.get("a:bold"), Some(&Any::Bool(true)));
            }
        }
        let c = h.redo().unwrap();
        sync_change(&h, &peer, c);
        assert!(character_formats(&h.state.doc, "p")
            .iter()
            .all(|(_, attrs)| attrs.get("a:italic") == Some(&Any::Bool(true))));
    }
}

#[test]
fn true_concurrent_sibling_insertion_survives_local_structure_undo() {
    let (_dir, mut h, peer) = seeded("ab");
    let local = h.insert_paragraph("doc", 1, "local", "L").unwrap();
    // Independent peer has not received the local insertion yet.
    let remote = remote_edit(&peer, |txn| {
        let blocks = txn.get_map("blocks").unwrap();
        let block = blocks.insert(txn, "remote", MapPrelim::default());
        block.insert(txn, "id", "remote");
        block.insert(txn, "flavour", "paragraph");
        block.insert(txn, "nodeType", "editable");
        block.insert(txn, "props", MapPrelim::default());
        block.insert(txn, "meta", MapPrelim::default());
        block.insert(txn, "children", TextPrelim::new("R"));
        let root = policy::block_map(&blocks, txn, "doc").unwrap();
        let Some(Out::YArray(order)) = root.get(txn, "children") else {
            panic!()
        };
        order.insert(txn, 1, "remote");
    });
    h.apply_remote(&remote).unwrap();
    integrate(&peer, &local.v1_update);
    let c = h.undo().unwrap();
    sync_change(&h, &peer, c);
    assert_eq!(child_ids(&h.state.doc, "doc"), ["p", "remote", "q"]);
    let c = h.redo().unwrap();
    sync_change(&h, &peer, c);
    assert_eq!(h.read_text("remote").unwrap(), "R");
}

#[test]
fn move_undo_preserves_remote_text_and_restores_exact_sibling_order() {
    let (_dir, mut h, peer) = seeded("ab");
    let c = h.insert_callout("doc", 2, "box").unwrap();
    sync_change(&h, &peer, c);
    let c = h.move_block("p", "box", 0).unwrap();
    sync_change(&h, &peer, c);
    h.apply_remote(&peer_replace(&peer, "p", 1, 0, "R"))
        .unwrap();
    for _ in 0..5 {
        let c = h.undo().unwrap();
        sync_change(&h, &peer, c);
        assert_eq!(child_ids(&h.state.doc, "doc"), ["p", "q", "box"]);
        assert_eq!(h.read_text("p").unwrap(), "aRb");
        let c = h.redo().unwrap();
        sync_change(&h, &peer, c);
        assert_eq!(child_ids(&h.state.doc, "box"), ["p"]);
    }
}

#[test]
fn competing_remote_move_causes_atomic_conflict_instead_of_duplicate_block() {
    let (_dir, mut h, peer) = seeded("ab");
    let c = h.insert_callout("doc", 2, "box").unwrap();
    sync_change(&h, &peer, c);
    let c = h.move_block("p", "box", 0).unwrap();
    sync_change(&h, &peer, c);
    let update = remote_edit(&peer, |txn| {
        let blocks = txn.get_map("blocks").unwrap();
        let box_map = policy::block_map(&blocks, txn, "box").unwrap();
        let Some(Out::YArray(children)) = box_map.get(txn, "children") else {
            panic!()
        };
        children.remove_range(txn, 0, 1);
        let root = policy::block_map(&blocks, txn, "doc").unwrap();
        let Some(Out::YArray(children)) = root.get(txn, "children") else {
            panic!()
        };
        children.insert(txn, 1, "p");
    });
    h.apply_remote(&update).unwrap();
    let before = snapshot(&h);
    assert!(h
        .undo()
        .unwrap_err()
        .starts_with("HISTORY_STRUCTURE_CONFLICT"));
    assert_eq!(snapshot(&h), before);
    assert_eq!(child_ids(&h.state.doc, "doc"), ["q", "p", "box"]);
}

#[test]
fn access_revocation_blocks_all_commands_and_undo_without_consuming_history() {
    let (_dir, mut h, peer) = seeded("ab");
    h.replace_text("p", 0, 0, "X").unwrap();
    h.set_write_access("doc", false).unwrap();
    let before = snapshot(&h);
    for result in [
        h.replace_text("p", 0, 0, "N"),
        h.format_text("p", 0, 1, mark("a:bold", Any::Bool(true))),
        h.patch_paragraph_properties("p", patch("heading", Some(Any::Number(1.0)))),
        h.insert_paragraph("doc", 0, "new", "N"),
        h.delete_block("p"),
        h.move_block("p", "doc", 1),
        h.undo(),
        h.redo(),
    ] {
        assert!(result.unwrap_err().starts_with("HISTORY_READ_ONLY"));
        assert_eq!(snapshot(&h), before);
    }
    h.apply_remote(&peer_replace(&peer, "q", 0, 0, "R"))
        .unwrap();
    h.set_write_access("doc", true).unwrap();
    h.undo().unwrap();
    assert_eq!(h.read_text("p").unwrap(), "ab");
}

#[test]
fn explicit_owner_and_template_locks_block_commands_and_history_until_unlocked() {
    for template in [false, true] {
        let (_dir, mut h, peer) = seeded("ab");
        let c = h
            .format_text("p", 0, 1, mark("a:bold", Any::Bool(true)))
            .unwrap();
        sync_change(&h, &peer, c);
        lock(&mut h, &peer, "p", Some("same-current-user"), template);
        let before = snapshot(&h);
        for result in [
            h.undo(),
            h.replace_text("p", 0, 0, "X"),
            h.delete_block("p"),
            h.move_block("p", "doc", 1),
        ] {
            assert!(result.unwrap_err().starts_with("HISTORY_LOCKED"));
            assert_eq!(snapshot(&h), before);
        }
        lock(&mut h, &peer, "p", None, false);
        let c = h.undo().unwrap();
        sync_change(&h, &peer, c);
        assert_ne!(
            character_formats(&h.state.doc, "p")[0].1.get("a:bold"),
            Some(&Any::Bool(true))
        );
    }
}

#[test]
fn inherited_and_hidden_descendant_locks_guard_structure_and_redo() {
    let (_dir, mut h, peer) = seeded("ab");
    let c = h.insert_callout("doc", 2, "box").unwrap();
    sync_change(&h, &peer, c);
    let c = h.move_block("p", "box", 0).unwrap();
    sync_change(&h, &peer, c);
    lock(&mut h, &peer, "box", Some("owner"), false);
    let before = snapshot(&h);
    assert!(h
        .format_text("p", 0, 1, mark("a:bold", Any::Bool(true)))
        .is_err());
    assert!(h.insert_paragraph("box", 0, "new", "x").is_err());
    assert!(h.undo().is_err());
    assert_eq!(snapshot(&h), before);
    lock(&mut h, &peer, "box", None, false);
    lock(&mut h, &peer, "p", Some("owner"), false);
    let before = snapshot(&h);
    assert!(h.delete_block("box").is_err());
    assert!(h.move_block("box", "doc", 0).is_err());
    assert_eq!(snapshot(&h), before);
    lock(&mut h, &peer, "p", None, false);
    let c = h.undo().unwrap();
    sync_change(&h, &peer, c);
    lock(&mut h, &peer, "box", Some("owner"), true);
    let before = snapshot(&h);
    assert!(h.redo().is_err());
    assert_eq!(snapshot(&h), before);
    lock(&mut h, &peer, "box", None, false);
    let c = h.redo().unwrap();
    sync_change(&h, &peer, c);
}

#[test]
fn unrelated_locked_sibling_does_not_block_insertion_or_writable_text() {
    let (_dir, mut h, peer) = seeded("ab");
    lock(&mut h, &peer, "p", Some("owner"), false);
    let c = h.insert_paragraph("doc", 0, "new", "x").unwrap();
    sync_change(&h, &peer, c);
    let c = h.replace_text("q", 0, 0, "N").unwrap();
    sync_change(&h, &peer, c);
    let c = h.undo().unwrap();
    sync_change(&h, &peer, c);
    let c = h.undo().unwrap();
    sync_change(&h, &peer, c);
    assert_eq!(child_ids(&h.state.doc, "doc"), ["p", "q"]);
}

#[test]
fn invalid_structure_format_and_orphan_targets_are_atomic() {
    let (_dir, mut h, peer) = seeded("a🌟b");
    let c = h.insert_callout("doc", 2, "box").unwrap();
    sync_change(&h, &peer, c);
    let before = snapshot(&h);
    for result in [
        h.move_block("box", "box", 0),
        h.delete_block("doc"),
        h.move_block("doc", "box", 0),
        h.insert_paragraph("doc", 100, "new", "x"),
        h.insert_paragraph("p", 0, "new", "x"),
        h.insert_paragraph("doc", 0, "p", "x"),
        h.format_text("p", 2, 1, mark("a:bold", Any::Bool(true))),
        h.patch_paragraph_properties("p", patch("lock", Some(Any::from("owner")))),
        h.patch_paragraph_properties("p", patch("heading", Some(Any::Number(7.0)))),
    ] {
        assert!(result.is_err());
        assert_eq!(snapshot(&h), before);
    }
    let update = remote_edit(&peer, |txn| {
        let root = policy::block_map(&txn.get_map("blocks").unwrap(), txn, "doc").unwrap();
        let Some(Out::YArray(children)) = root.get(txn, "children") else {
            panic!()
        };
        children.remove_range(txn, 0, 1);
    });
    h.apply_remote(&update).unwrap();
    let before = snapshot(&h);
    assert!(h
        .replace_text("p", 0, 0, "x")
        .unwrap_err()
        .starts_with("HISTORY_TARGET_NOT_REACHABLE"));
    assert!(h
        .format_text("p", 0, 1, mark("a:bold", Any::Bool(true)))
        .is_err());
    assert_eq!(snapshot(&h), before);
}

#[derive(Clone, Copy)]
enum Command {
    Format,
    Props,
    Insert,
    Delete,
    Move,
}

fn perform(h: &mut HistoryPrototype, command: Command) -> Result<HistoryChange, String> {
    match command {
        Command::Format => h.format_text("p", 0, 1, mark("a:bold", Any::Bool(true))),
        Command::Props => {
            h.patch_paragraph_properties("p", patch("heading", Some(Any::Number(1.0))))
        }
        Command::Insert => h.insert_paragraph("doc", 0, "new", "N"),
        Command::Delete => h.delete_block("p"),
        Command::Move => h.move_block("p", "doc", 1),
    }
}

fn command_failure(command: Command, failure: Failure) {
    let (directory, mut h, peer) = seeded("ab");
    install_failure(&h, failure);
    let before = snapshot(&h);
    assert!(perform(&mut h, command).is_err());
    assert_eq!(snapshot(&h), before);
    h.connection
        .execute_batch("DROP TRIGGER fail_history;")
        .unwrap();
    let c = perform(&mut h, command).unwrap();
    sync_change(&h, &peer, c);
    for undo in [true, false] {
        install_failure_again(&h, failure);
        let before = snapshot(&h);
        let failed = if undo { h.undo() } else { h.redo() };
        assert!(failed.is_err());
        assert_eq!(snapshot(&h), before);
        h.connection
            .execute_batch("DROP TRIGGER fail_history;")
            .unwrap();
        let c = if undo {
            h.undo().unwrap()
        } else {
            h.redo().unwrap()
        };
        sync_change(&h, &peer, c);
    }
    let expected = h.state.doc.transact().snapshot();
    let expected_blocks = h
        .state
        .doc
        .transact()
        .get_map("blocks")
        .unwrap()
        .to_json(&h.state.doc.transact());
    drop(h);
    let restored =
        HistoryPrototype::open(directory.path().join("history.sqlite"), "cache").unwrap();
    assert_eq!(restored.state.doc.transact().snapshot(), expected);
    assert_eq!(
        restored
            .state
            .doc
            .transact()
            .get_map("blocks")
            .unwrap()
            .to_json(&restored.state.doc.transact()),
        expected_blocks
    );
}

fn install_failure_again(h: &HistoryPrototype, failure: Failure) {
    match failure {
        Failure::Write => install_failure(h, failure),
        Failure::Commit => h.connection.execute_batch("CREATE TRIGGER fail_history AFTER INSERT ON document_updates BEGIN INSERT INTO history_guard_child VALUES (1); END;").unwrap(),
    }
}

macro_rules! command_failure_test {
    ($name:ident, $command:ident, $failure:ident) => {
        #[test]
        fn $name() {
            command_failure(Command::$command, Failure::$failure);
        }
    };
}
command_failure_test!(format_write_failure, Format, Write);
command_failure_test!(format_commit_failure, Format, Commit);
command_failure_test!(props_write_failure, Props, Write);
command_failure_test!(props_commit_failure, Props, Commit);
command_failure_test!(insert_write_failure, Insert, Write);
command_failure_test!(insert_commit_failure, Insert, Commit);
command_failure_test!(delete_write_failure, Delete, Write);
command_failure_test!(delete_commit_failure, Delete, Commit);
command_failure_test!(move_write_failure, Move, Write);
command_failure_test!(move_commit_failure, Move, Commit);

#[test]
fn undo_insertion_rejects_removing_new_remote_content_and_children() {
    for add_child in [false, true] {
        let (_dir, mut h, peer) = seeded("ab");
        let c = if add_child {
            h.insert_callout("doc", 1, "new").unwrap()
        } else {
            h.insert_paragraph("doc", 1, "new", "local").unwrap()
        };
        sync_change(&h, &peer, c);
        if add_child {
            let other_dir = TempDir::new().unwrap();
            let mut remote =
                HistoryPrototype::open(other_dir.path().join("peer.sqlite"), "peer").unwrap();
            remote.apply_remote(&full_update(&peer)).unwrap();
            remote.set_write_access("doc", true).unwrap();
            let c = remote
                .insert_paragraph("new", 0, "remote-child", "remote")
                .unwrap();
            integrate(&peer, &c.v1_update);
            h.apply_remote(&c.v1_update).unwrap();
        } else {
            h.apply_remote(&peer_replace(&peer, "new", 0, 0, "REMOTE"))
                .unwrap();
        }
        let before = snapshot(&h);
        assert!(h
            .undo()
            .unwrap_err()
            .starts_with("HISTORY_STRUCTURE_CONFLICT"));
        assert_eq!(snapshot(&h), before);
        assert_eq!(
            h.read_text(if add_child { "remote-child" } else { "new" })
                .unwrap(),
            if add_child { "remote" } else { "REMOTElocal" }
        );
    }
}

#[test]
fn redo_deletion_rejects_removing_remote_edits_after_restore() {
    let (_dir, mut h, peer) = seeded("ab");
    let c = h.delete_block("p").unwrap();
    sync_change(&h, &peer, c);
    let c = h.undo().unwrap();
    sync_change(&h, &peer, c);
    h.apply_remote(&peer_replace(&peer, "p", 0, 0, "R"))
        .unwrap();
    let before = snapshot(&h);
    assert!(h
        .redo()
        .unwrap_err()
        .starts_with("HISTORY_STRUCTURE_CONFLICT"));
    assert_eq!(snapshot(&h), before);
}

#[test]
fn skipped_obsolete_group_cannot_bypass_older_locked_group() {
    let (_dir, mut h, peer) = seeded("ab");
    let c = h.replace_text("p", 0, 0, "L").unwrap();
    sync_change(&h, &peer, c);
    let c = h.replace_text("q", 0, 0, "X").unwrap();
    sync_change(&h, &peer, c);
    h.apply_remote(&peer_replace(&peer, "q", 0, 1, "")).unwrap();
    lock(&mut h, &peer, "p", Some("owner"), false);
    let before = snapshot(&h);
    assert!(h.undo().unwrap_err().starts_with("HISTORY_LOCKED"));
    assert_eq!(snapshot(&h), before);
    lock(&mut h, &peer, "p", None, false);
    let c = h.undo().unwrap();
    sync_change(&h, &peer, c);
    assert_eq!(h.read_text("p").unwrap(), "ab");
    assert_eq!(h.history_state().undo_depth, 0);
}

#[test]
fn native_checkpoint_rejects_gc_and_preserves_independent_storage() {
    assert!(Doc::new().fork_for_history().is_err());
    let (_dir, mut h, _peer) = seeded("ab");
    h.patch_paragraph_properties("p", patch("heading", Some(Any::Number(1.0))))
        .unwrap();
    h.patch_paragraph_properties("p", patch("heading", Some(Any::Number(2.0))))
        .unwrap();
    h.undo().unwrap();
    let before = snapshot(&h);
    let mut candidate = h.fork().unwrap();
    candidate.history.undo_blocking();
    assert_eq!(snapshot(&h), before);
    assert!(
        !map_at(&candidate.doc, "p", "props").contains_key(&candidate.doc.transact(), "heading")
    );
    assert_eq!(
        map_at(&h.state.doc, "p", "props").get(&h.state.doc.transact(), "heading"),
        Some(Out::Any(Any::Number(1.0)))
    );
}

#[test]
fn read_only_by_default_and_formal_root_cannot_be_rebound_or_spoofed() {
    let directory = TempDir::new().unwrap();
    let mut h = HistoryPrototype::open(directory.path().join("history.sqlite"), "cache").unwrap();
    h.apply_remote(&full_update(&fixture("ab"))).unwrap();
    let before = snapshot(&h);
    assert!(h.replace_text("p", 0, 0, "x").is_err());
    assert_eq!(snapshot(&h), before);
    assert!(h
        .set_write_access("p", true)
        .unwrap_err()
        .starts_with("HISTORY_INVALID_ROOT"));
    h.set_write_access("doc", true).unwrap();
    assert!(h
        .set_write_access("p", true)
        .unwrap_err()
        .starts_with("HISTORY_ROOT_MISMATCH"));
    h.replace_text("p", 0, 0, "x").unwrap();
}

#[test]
fn property_removal_and_explicit_null_restore_distinct_original_states() {
    let (_dir, mut h, peer) = seeded("ab");
    let c = h
        .patch_paragraph_properties("p", patch("heading", Some(Any::Null)))
        .unwrap();
    sync_change(&h, &peer, c);
    let c = h
        .patch_paragraph_properties("p", patch("heading", None))
        .unwrap();
    sync_change(&h, &peer, c);
    for expected in [Some(Out::Any(Any::Null)), None] {
        let c = h.undo().unwrap();
        sync_change(&h, &peer, c);
        assert_eq!(
            map_at(&h.state.doc, "p", "props").get(&h.state.doc.transact(), "heading"),
            expected
        );
    }
}

#[test]
fn remote_same_mark_override_survives_local_format_undo() {
    let (_dir, mut h, peer) = seeded("abc");
    let c = h
        .format_text("p", 0, 3, mark("a:bold", Any::Bool(true)))
        .unwrap();
    sync_change(&h, &peer, c);
    let remote = remote_edit(&peer, |txn| {
        text_target(txn, "p")
            .unwrap()
            .format(txn, 0, 1, mark("a:bold", Any::Bool(false)));
    });
    h.apply_remote(&remote).unwrap();
    let c = h.undo().unwrap();
    sync_change(&h, &peer, c);
    assert_ne!(
        character_formats(&h.state.doc, "p")[0].1.get("a:bold"),
        Some(&Any::Bool(true))
    );
    let c = h.redo().unwrap();
    sync_change(&h, &peer, c);
    assert_ne!(
        character_formats(&h.state.doc, "p")[0].1.get("a:bold"),
        Some(&Any::Bool(true))
    );
}

#[test]
fn unknown_hidden_descendant_lock_prevents_container_delete_and_history_undo() {
    let (_dir, mut h, peer) = seeded("ab");
    let c = h.insert_callout("doc", 2, "box").unwrap();
    sync_change(&h, &peer, c);
    let update = remote_edit(&peer, |txn| {
        let blocks = txn.get_map("blocks").unwrap();
        let hidden = blocks.insert(txn, "hidden", MapPrelim::default());
        hidden.insert(txn, "id", "hidden");
        hidden.insert(txn, "flavour", "unknown-future-block");
        hidden.insert(txn, "nodeType", "void");
        hidden.insert(txn, "props", MapPrelim::default());
        let meta = hidden.insert(txn, "meta", MapPrelim::default());
        meta.insert(txn, "lock", "owner");
        let parent = policy::block_map(&blocks, txn, "box").unwrap();
        let Some(Out::YArray(children)) = parent.get(txn, "children") else {
            panic!()
        };
        children.insert(txn, 0, "hidden");
    });
    h.apply_remote(&update).unwrap();
    let before = snapshot(&h);
    assert!(h
        .delete_block("box")
        .unwrap_err()
        .starts_with("HISTORY_LOCKED"));
    assert!(h.undo().unwrap_err().starts_with("HISTORY_LOCKED"));
    assert_eq!(snapshot(&h), before);
}

#[test]
fn revision_documents_remain_read_only_without_bypassing_pending_changes() {
    let (_dir, mut h, _peer) = seeded("ab");
    h.replace_text("p", 0, 0, "X").unwrap();
    let peer = peer_doc();
    integrate(&peer, &h.encode_full_update());
    let revisions = peer.get_or_insert_map("bc:revisions");
    let update = remote_edit(&peer, |txn| {
        revisions.insert(txn, "r1", "opaque");
    });
    h.apply_remote(&update).unwrap();
    let before = snapshot(&h);
    assert!(h
        .undo()
        .unwrap_err()
        .starts_with("HISTORY_UNSUPPORTED_REVISIONS"));
    assert!(h
        .format_text("p", 0, 1, mark("a:bold", Any::Bool(true)))
        .is_err());
    assert_eq!(snapshot(&h), before);
}

#[test]
fn paragraph_defaults_and_spacing_are_atomic_and_keep_unknown_properties() {
    let (_dir, mut h, peer) = seeded("ab");
    let original = props(&h.state.doc, "p");
    let values = [
        (
            "textDefaults".to_owned(),
            Some(Any::Map(std::sync::Arc::new(
                [
                    ("a:bold".to_owned(), Any::Bool(true)),
                    ("s:fontWeight".to_owned(), Any::from("600")),
                ]
                .into_iter()
                .collect(),
            ))),
        ),
        ("lh".to_owned(), Some(Any::Number(1.5))),
        ("psa".to_owned(), Some(Any::Number(8.0))),
        ("nextParagraphStyle".to_owned(), Some(Any::from("body"))),
    ]
    .into_iter()
    .collect();
    let c = h.patch_paragraph_properties("p", values).unwrap();
    sync_change(&h, &peer, c);
    assert_eq!(h.history_state().undo_depth, 1);
    let c = h.undo().unwrap();
    sync_change(&h, &peer, c);
    assert_eq!(props(&h.state.doc, "p"), original);
    let c = h.redo().unwrap();
    sync_change(&h, &peer, c);
    assert_eq!(
        map_at(&h.state.doc, "p", "props").get(&h.state.doc.transact(), "lh"),
        Some(Out::Any(Any::Number(1.5)))
    );
}
