//! Production-engine history regressions, separate from the isolated prototype.

use super::*;
use tempfile::TempDir;
use yrs::{ArrayPrelim, MapPrelim, TextPrelim};

fn setup() -> (TempDir, CollabEngine, Doc) {
    let dir = TempDir::new().unwrap();
    let (mut engine, _) = CollabEngine::open(
        "cache".into(),
        dir.path()
            .join("history.sqlite")
            .to_string_lossy()
            .into_owned(),
    )
    .unwrap();
    let peer = create_compatible_doc();
    let blocks = peer.get_or_insert_map("blocks");
    {
        let mut txn = peer.transact_mut();
        for (id, kind, node_type) in [
            ("doc", "root", "root"),
            ("p", "paragraph", "editable"),
            ("q", "paragraph", "editable"),
        ] {
            let block = blocks.insert(&mut txn, id, MapPrelim::default());
            block.insert(&mut txn, "id", id);
            block.insert(&mut txn, "flavour", kind);
            block.insert(&mut txn, "nodeType", node_type);
            block.insert(&mut txn, "props", MapPrelim::default());
            block.insert(&mut txn, "meta", MapPrelim::default());
            if id == "doc" {
                block.insert(&mut txn, "children", ArrayPrelim::from(["p", "q"]));
            } else {
                block.insert(
                    &mut txn,
                    "children",
                    TextPrelim::new(if id == "p" { "ab" } else { "other" }),
                );
            }
        }
    }
    engine.blockcraft_root_id = Some("doc".into());
    engine
        .apply_cses_update(
            peer.transact()
                .encode_state_as_update_v1(&StateVector::default()),
        )
        .unwrap();
    engine.history = Some(NativeHistory {
        manager: manager(&engine.doc, vec![], vec![]),
        writable: true,
    });
    (dir, engine, peer)
}

fn selection(id: &str, offset: u32) -> Option<HistorySelection> {
    let point = HistoryPoint {
        block_id: id.into(),
        offset,
    };
    Some(HistorySelection {
        anchor: point.clone(),
        focus: point,
    })
}

fn text(doc: &Doc, id: &str) -> yrs::TextRef {
    let txn = doc.transact();
    let Out::YMap(block) = txn.get_map("blocks").unwrap().get(&txn, id).unwrap() else {
        panic!()
    };
    let Some(Out::YText(text)) = block.get(&txn, "children") else {
        panic!()
    };
    text
}

fn integrate(doc: &Doc, update: &[u8]) {
    if !update.is_empty() {
        doc.transact_mut()
            .apply_update(Update::decode_v1(update).unwrap())
            .unwrap();
    }
}

fn local(engine: &mut CollabEngine, value: &str) -> Result<BlockChangeResult, String> {
    let mut blocks = engine.blocks();
    blocks[0].text = value.into();
    blocks[0].segments.clear();
    engine.history_input = Some(HistoryInput {
        before: selection("p", 1),
        after: selection("p", value.encode_utf16().count() as u32),
    });
    let result = engine.apply_block_snapshot(blocks);
    engine.history_input = None;
    result
}

#[derive(Debug, PartialEq, Eq)]
struct Snapshot {
    bytes: Vec<u8>,
    undo: Vec<StackItem<Meta>>,
    redo: Vec<StackItem<Meta>>,
    rows: Vec<Vec<u8>>,
}

fn snapshot(engine: &CollabEngine) -> Snapshot {
    let history = &engine.history.as_ref().unwrap().manager;
    Snapshot {
        bytes: engine
            .doc
            .transact()
            .encode_state_as_update_v1(&StateVector::default()),
        undo: history.undo_stack().to_vec(),
        redo: history.redo_stack().to_vec(),
        rows: load_updates(&engine.connection, &engine.document_id).unwrap(),
    }
}

#[test]
fn engine_history_preserves_remote_text_and_resolves_undo_redo_selection() {
    let (_dir, mut engine, peer) = setup();
    integrate(&peer, &local(&mut engine, "aXb").unwrap().v1_update);
    let before = peer.transact().state_vector();
    text(&peer, "p").insert(&mut peer.transact_mut(), 0, "R");
    engine
        .apply_cses_update(peer.transact().encode_state_as_update_v1(&before))
        .unwrap();
    let result = engine.replay_history(true, selection("p", 3)).unwrap();
    integrate(&peer, &result.v1_update);
    assert_eq!(engine.blocks()[0].text, "Rab");
    let restored = resolve_bookmark(
        &engine.doc,
        Some("doc"),
        result.selection_bookmark.as_ref().unwrap(),
    )
    .unwrap()
    .unwrap();
    assert_eq!(restored.anchor.offset, 2);
    let result = engine.replay_history(false, selection("p", 2)).unwrap();
    integrate(&peer, &result.v1_update);
    assert_eq!(engine.blocks()[0].text, "RaXb");
    assert_eq!(
        resolve_bookmark(
            &engine.doc,
            Some("doc"),
            result.selection_bookmark.as_ref().unwrap()
        )
        .unwrap()
        .unwrap()
        .anchor
        .offset,
        3
    );
    assert_eq!(engine.doc.transact().snapshot(), peer.transact().snapshot());
}

#[test]
fn engine_history_retains_awareness_and_native_handles_after_many_swaps() {
    let (_dir, mut engine, _peer) = setup();
    engine
        .awareness
        .set_local_state(serde_json::json!({"user":"owner"}))
        .unwrap();
    let client = engine.awareness.client_id();
    for _ in 0..8 {
        local(&mut engine, "aXb").unwrap();
        engine.replay_history(true, selection("p", 2)).unwrap();
    }
    assert_eq!(engine.awareness.client_id(), client);
    // 在线 Doc 不承载正文；正文历史回放不能改写其身份、时钟或资料。
    assert_ne!(engine.awareness.client_id(), engine.doc.client_id());
    assert_eq!(
        engine.awareness.local_state::<serde_json::Value>().unwrap()["user"],
        "owner"
    );
    assert_eq!(engine.block_order.len(&engine.doc.transact()), 0);
}

#[test]
fn native_history_locks_and_revocation_do_not_consume_groups() {
    let (_dir, mut engine, peer) = setup();
    integrate(&peer, &local(&mut engine, "aXb").unwrap().v1_update);
    let before = peer.transact().state_vector();
    {
        let mut txn = peer.transact_mut();
        let Out::YMap(block) = txn.get_map("blocks").unwrap().get(&txn, "p").unwrap() else {
            panic!()
        };
        let Some(Out::YMap(meta)) = block.get(&txn, "meta") else {
            panic!()
        };
        meta.insert(&mut txn, "lock", "owner");
    }
    engine
        .apply_cses_update(peer.transact().encode_state_as_update_v1(&before))
        .unwrap();
    let before = snapshot(&engine);
    assert!(engine.replay_history(true, selection("p", 2)).is_err());
    assert_eq!(snapshot(&engine), before);
    engine.history.as_mut().unwrap().writable = false;
    assert!(engine
        .replay_history(true, None)
        .unwrap_err()
        .starts_with("HISTORY_READ_ONLY"));
    assert_eq!(snapshot(&engine), before);
}

#[test]
fn history_bookmarks_are_directional_session_scoped_and_drop_deleted_endpoints() {
    let (_dir, engine, _peer) = setup();
    let range = HistorySelection {
        anchor: HistoryPoint {
            block_id: "q".into(),
            offset: 4,
        },
        focus: HistoryPoint {
            block_id: "p".into(),
            offset: 1,
        },
    };
    let token = bookmark(&engine.doc, Some("doc"), Some(&range))
        .unwrap()
        .unwrap();
    assert_eq!(
        resolve_bookmark(&engine.doc, Some("doc"), &token).unwrap(),
        Some(range)
    );
    assert!(resolve_bookmark(&create_compatible_doc(), None, &token).is_err());
    assert!(resolve_bookmark(&engine.doc, Some("doc"), "not-json").is_err());
    {
        let mut txn = engine.doc.transact_mut_with(REMOTE_ORIGIN);
        let blocks = txn.get_map("blocks").unwrap();
        let Out::YMap(root) = blocks.get(&txn, "doc").unwrap() else {
            panic!()
        };
        let Some(Out::YArray(children)) = root.get(&txn, "children") else {
            panic!()
        };
        children.remove_range(&mut txn, 1, 1);
    }
    assert_eq!(
        resolve_bookmark(&engine.doc, Some("doc"), &token).unwrap(),
        None
    );
}

fn failure_case(commit: bool, undo: bool) {
    let (dir, mut engine, peer) = setup();
    integrate(&peer, &local(&mut engine, "aXb").unwrap().v1_update);
    if !undo {
        let result = engine.replay_history(true, selection("p", 2)).unwrap();
        integrate(&peer, &result.v1_update);
    }
    if commit {
        engine.connection.execute_batch("CREATE TABLE guard_parent(id INTEGER PRIMARY KEY); CREATE TABLE guard_child(parent INTEGER REFERENCES guard_parent(id) DEFERRABLE INITIALLY DEFERRED); CREATE TRIGGER fail_history AFTER INSERT ON document_updates BEGIN INSERT INTO guard_child VALUES(1); END;").unwrap();
    } else {
        engine.connection.execute_batch("CREATE TRIGGER fail_history BEFORE INSERT ON document_updates BEGIN SELECT RAISE(ABORT,'history write failure'); END;").unwrap();
    }
    let before = snapshot(&engine);
    assert!(engine.replay_history(undo, selection("p", 2)).is_err());
    assert_eq!(snapshot(&engine), before);
    engine
        .connection
        .execute_batch("DROP TRIGGER fail_history;")
        .unwrap();
    let result = engine.replay_history(undo, selection("p", 2)).unwrap();
    integrate(&peer, &result.v1_update);
    let expected = engine.blocks();
    drop(engine);
    let (mut reopened, _) = CollabEngine::open(
        "cache".into(),
        dir.path()
            .join("history.sqlite")
            .to_string_lossy()
            .into_owned(),
    )
    .unwrap();
    reopened.blockcraft_root_id = Some("doc".into());
    assert_eq!(reopened.blocks(), expected);
    assert_eq!(reopened.history_state().undo_depth, 0);
}

#[test]
fn engine_undo_write_failure_is_atomic_and_retryable() {
    failure_case(false, true);
}
#[test]
fn engine_undo_commit_failure_is_atomic_and_retryable() {
    failure_case(true, true);
}
#[test]
fn engine_redo_write_failure_is_atomic_and_retryable() {
    failure_case(false, false);
}
#[test]
fn engine_redo_commit_failure_is_atomic_and_retryable() {
    failure_case(true, false);
}

#[test]
fn rejected_after_selection_is_checked_before_any_persistence() {
    let (_dir, mut engine, _peer) = setup();
    let before = snapshot(&engine);
    let mut blocks = engine.blocks();
    blocks[0].text = "aXb".into();
    blocks[0].segments.clear();
    engine.history_input = Some(HistoryInput {
        before: selection("p", 1),
        after: selection("p", 100),
    });
    assert!(engine.apply_block_snapshot(blocks).is_err());
    engine.history_input = None;
    assert_eq!(snapshot(&engine), before);
}

#[test]
fn native_structure_history_restores_deleted_maps_and_formats_repeatedly() {
    let (_dir, mut engine, _peer) = setup();
    let old = engine.blocks();
    let body = old[1..].to_vec();
    engine.history_input = Some(HistoryInput {
        before: selection("p", 1),
        after: selection("q", 1),
    });
    engine.apply_block_snapshot(body).unwrap();
    engine.history_input = None;
    for _ in 0..5 {
        engine.replay_history(true, selection("q", 1)).unwrap();
        assert_eq!(engine.blocks(), old);
        engine.replay_history(false, selection("p", 1)).unwrap();
        assert_eq!(engine.blocks().len(), 1);
    }
}

#[test]
fn history_selection_preserves_utf16_chunk_offset_after_redo() {
    let (_dir, mut engine, _peer) = setup();
    local(&mut engine, "你好😀").unwrap();
    engine.replay_history(true, selection("p", 4)).unwrap();
    let result = engine.replay_history(false, selection("p", 1)).unwrap();
    assert_eq!(
        resolve_bookmark(
            &engine.doc,
            Some("doc"),
            result.selection_bookmark.as_ref().unwrap()
        )
        .unwrap()
        .unwrap()
        .anchor
        .offset,
        4
    );
}

#[test]
fn native_redo_survives_remote_edits_but_new_local_intent_invalidates_it() {
    let (_dir, mut engine, peer) = setup();
    integrate(&peer, &local(&mut engine, "aXb").unwrap().v1_update);
    integrate(
        &peer,
        &engine
            .replay_history(true, selection("p", 2))
            .unwrap()
            .v1_update,
    );
    let before = peer.transact().state_vector();
    text(&peer, "p").insert(&mut peer.transact_mut(), 0, "R");
    engine
        .apply_cses_update(peer.transact().encode_state_as_update_v1(&before))
        .unwrap();
    assert_eq!(engine.history_state().redo_depth, 1);
    engine.replay_history(false, selection("p", 2)).unwrap();
    assert_eq!(engine.blocks()[0].text, "RaXb");
    engine.replay_history(true, selection("p", 3)).unwrap();
    local(&mut engine, "RaYb").unwrap();
    assert_eq!(engine.history_state().redo_depth, 0);
    engine.replay_history(true, selection("p", 3)).unwrap();
    assert_eq!(engine.blocks()[0].text, "Rab");
}

#[test]
fn unsupported_remote_target_does_not_consume_local_history() {
    let (_dir, mut engine, peer) = setup();
    integrate(&peer, &local(&mut engine, "aXb").unwrap().v1_update);
    let before = peer.transact().state_vector();
    {
        let mut txn = peer.transact_mut();
        let Out::YMap(block) = txn.get_map("blocks").unwrap().get(&txn, "p").unwrap() else {
            panic!()
        };
        block.insert(&mut txn, "flavour", "future-block");
    }
    engine
        .apply_cses_update(peer.transact().encode_state_as_update_v1(&before))
        .unwrap();
    let old = snapshot(&engine);
    assert!(engine
        .replay_history(true, None)
        .unwrap_err()
        .starts_with("READ_ONLY_BLOCK"));
    assert_eq!(snapshot(&engine), old);
}

/// Create an isolated persisted draft with active native history and no blocks.
fn legacy_setup() -> (TempDir, CollabEngine) {
    let directory = TempDir::new().unwrap();
    let (mut engine, _) = CollabEngine::open(
        "draft".into(),
        directory
            .path()
            .join("draft.sqlite")
            .to_string_lossy()
            .into_owned(),
    )
    .unwrap();
    engine.history = Some(NativeHistory {
        manager: manager(&engine.doc, vec![], vec![]),
        writable: true,
    });
    (directory, engine)
}

/// Build a legacy paragraph with stable `id` and plain UTF-16 `value`.
fn legacy_block(id: &str, value: &str) -> CollabBlock {
    CollabBlock {
        paragraph_style: None,
        id: id.into(),
        block_type: "paragraph".into(),
        text: value.into(),
        segments: vec![],
        checked: false,
        alignment: "left".into(),
        indent: 0,
        image: None,
        ordered: None,
        parent_id: None,
        callout_prefix: None,
        block_text_color: None,
        code: None,
        resource: None,
        replaces_id: None,
        block_background_color: None,
        block_border_color: None,
    }
}

/// Record one `blocks` command using personal `before` and `after` bookmarks.
/// The borrowed input context is cleared even when validation or SQLite fails.
fn record_local_snapshot(
    engine: &mut CollabEngine,
    blocks: Vec<CollabBlock>,
    before: Option<HistorySelection>,
    after: Option<HistorySelection>,
) -> Result<BlockChangeResult, String> {
    engine.history_input = Some(HistoryInput { before, after });
    let result = engine.apply_block_snapshot(blocks);
    engine.history_input = None;
    result
}

#[test]
fn empty_legacy_paragraph_first_text_is_recorded_persisted_and_restored() {
    let (directory, mut engine) = legacy_setup();
    engine
        .apply_block_snapshot(vec![legacy_block("empty", "")])
        .unwrap();
    record_local_snapshot(
        &mut engine,
        vec![legacy_block("empty", "你好😀")],
        selection("empty", 0),
        selection("empty", 4),
    )
    .unwrap();
    assert_eq!(engine.blocks()[0].text, "你好😀");
    assert_eq!(engine.history_state().undo_depth, 1);
    engine.replay_history(true, selection("empty", 4)).unwrap();
    assert_eq!(engine.blocks()[0].text, "");
    let redo = engine.replay_history(false, selection("empty", 0)).unwrap();
    assert_eq!(engine.blocks()[0].text, "你好😀");
    assert_eq!(
        resolve_bookmark(&engine.doc, None, redo.selection_bookmark.as_ref().unwrap()).unwrap(),
        selection("empty", 4)
    );
    drop(engine);
    let (reopened, _) = CollabEngine::open(
        "draft".into(),
        directory
            .path()
            .join("draft.sqlite")
            .to_string_lossy()
            .into_owned(),
    )
    .unwrap();
    assert_eq!(reopened.blocks()[0].text, "你好😀");
}

#[test]
fn appended_empty_legacy_paragraph_captures_its_first_typing_separately() {
    let (_directory, mut engine) = legacy_setup();
    let first = legacy_block("first", "first");
    record_local_snapshot(
        &mut engine,
        vec![first.clone()],
        None,
        selection("first", 5),
    )
    .unwrap();
    record_local_snapshot(
        &mut engine,
        vec![first.clone(), legacy_block("second", "")],
        selection("first", 5),
        selection("second", 0),
    )
    .unwrap();
    record_local_snapshot(
        &mut engine,
        vec![first.clone(), legacy_block("second", "new")],
        selection("second", 0),
        selection("second", 3),
    )
    .unwrap();
    assert_eq!(engine.history_state().undo_depth, 3);
    engine.replay_history(true, selection("second", 3)).unwrap();
    assert_eq!(
        engine.blocks(),
        vec![first.clone(), legacy_block("second", "")]
    );
    engine.replay_history(true, selection("second", 0)).unwrap();
    assert_eq!(engine.blocks(), vec![first]);
    engine.replay_history(false, selection("first", 5)).unwrap();
    engine
        .replay_history(false, selection("second", 0))
        .unwrap();
    assert_eq!(engine.blocks()[1].text, "new");
}

#[test]
fn first_legacy_typing_write_and_commit_failures_leave_content_and_history_unchanged() {
    for commit in [false, true] {
        let (_directory, mut engine) = legacy_setup();
        engine
            .apply_block_snapshot(vec![legacy_block("empty", "")])
            .unwrap();
        if commit {
            engine.connection.execute_batch("CREATE TABLE guard_parent(id INTEGER PRIMARY KEY); CREATE TABLE guard_child(parent INTEGER REFERENCES guard_parent(id) DEFERRABLE INITIALLY DEFERRED); CREATE TRIGGER fail_history AFTER INSERT ON document_updates BEGIN INSERT INTO guard_child VALUES(1); END;").unwrap();
        } else {
            engine.connection.execute_batch("CREATE TRIGGER fail_history BEFORE INSERT ON document_updates BEGIN SELECT RAISE(ABORT,'history write failure'); END;").unwrap();
        }
        let before = snapshot(&engine);
        let attempt = record_local_snapshot(
            &mut engine,
            vec![legacy_block("empty", "😀")],
            selection("empty", 0),
            selection("empty", 2),
        );
        assert!(attempt
            .unwrap_err()
            .starts_with("cannot persist Yjs update"));
        assert_eq!(snapshot(&engine), before);
        engine
            .connection
            .execute_batch("DROP TRIGGER fail_history;")
            .unwrap();
        record_local_snapshot(
            &mut engine,
            vec![legacy_block("empty", "😀")],
            selection("empty", 0),
            selection("empty", 2),
        )
        .unwrap();
        assert_eq!(engine.blocks()[0].text, "😀");
        assert_eq!(engine.history_state().undo_depth, 1);
    }
}

#[test]
fn uncaptured_native_document_change_is_rejected_instead_of_returning_uncommitted_update() {
    let (_directory, mut engine) = legacy_setup();
    let before = snapshot(&engine);
    engine.history_input = Some(HistoryInput {
        before: None,
        after: None,
    });
    let (candidate, recording) = engine.stage_local_history(&[]).unwrap();
    candidate
        .get_or_insert_text("deliberately-unregistered-root")
        .insert(&mut candidate.transact_mut(), 0, "untracked");
    let update = candidate
        .transact()
        .encode_state_as_update_v1(&engine.doc.transact().state_vector());
    assert!(engine
        .commit_local_history(candidate, recording, &update)
        .unwrap_err()
        .starts_with("HISTORY_CAPTURE_INCOMPLETE"));
    engine.history_input = None;
    assert_eq!(snapshot(&engine), before);
}

/// Open the independent Yjs table fixture with active native history and peer.
fn table_setup() -> (TempDir, CollabEngine, Doc) {
    let directory = TempDir::new().unwrap();
    let (mut engine, _) = CollabEngine::open(
        "fixture-doc".into(),
        directory
            .path()
            .join("table.sqlite")
            .to_string_lossy()
            .into_owned(),
    )
    .unwrap();
    let fixture = include_bytes!("../../tests/fixtures/blockcraft-table.update");
    engine.blockcraft_root_id = Some("fixture-doc".into());
    engine.apply_cses_update(fixture.to_vec()).unwrap();
    engine.history = Some(NativeHistory {
        manager: manager(&engine.doc, vec![], vec![]),
        writable: true,
    });
    let peer = create_compatible_doc();
    integrate(&peer, fixture);
    (directory, engine, peer)
}

/// Delete fixture row zero and its descendants as one user command.
fn delete_first_table_row(engine: &mut CollabEngine) -> BlockChangeResult {
    let desired = engine
        .blocks()
        .into_iter()
        .filter(|b| b.id != "row-0" && !b.id.starts_with("cell-0-") && !b.id.starts_with("body-0-"))
        .collect();
    record_local_snapshot(engine, desired, None, None).unwrap()
}

#[test]
fn table_row_deletion_repeated_undo_redo_accepts_its_own_archive_markers() {
    let (_directory, mut engine, peer) = table_setup();
    let original = engine.blocks();
    integrate(&peer, &delete_first_table_row(&mut engine).v1_update);
    let deleted = engine.blocks();
    assert!(deleted.len() < original.len());
    for _ in 0..5 {
        let undo = engine.replay_history(true, None).unwrap();
        integrate(&peer, &undo.v1_update);
        assert_eq!(engine.blocks(), original);
        let redo = engine.replay_history(false, None).unwrap();
        integrate(&peer, &redo.v1_update);
        assert_eq!(engine.blocks(), deleted);
        assert_eq!(engine.doc.transact().snapshot(), peer.transact().snapshot());
    }
}

#[test]
fn table_column_deletion_repeated_undo_redo_restores_grid_and_widths() {
    let (_directory, mut engine, _peer) = table_setup();
    let original = engine.blocks();
    let mut desired: Vec<_> = original
        .iter()
        .filter(|b| {
            !matches!(
                b.id.as_str(),
                "cell-0-0" | "body-0-0" | "cell-1-0" | "body-1-0"
            )
        })
        .cloned()
        .collect();
    let table = desired.iter_mut().find(|b| b.id == "table-1").unwrap();
    let layout = table.resource.as_mut().unwrap();
    layout.properties = r#"{"colWidths":[160,200]}"#.into();
    layout.property_edits = Some(r#"{"colWidths":{"value":[160,200]}}"#.into());
    record_local_snapshot(&mut engine, desired, None, None).unwrap();
    let deleted = engine.blocks();
    for _ in 0..3 {
        engine.replay_history(true, None).unwrap();
        assert_eq!(engine.blocks(), original);
        engine.replay_history(false, None).unwrap();
        assert_eq!(engine.blocks(), deleted);
    }
}

#[test]
fn whole_table_deletion_repeated_undo_redo_restores_all_archived_descendants() {
    let (_directory, mut engine, _peer) = table_setup();
    let original = engine.blocks();
    let mut descendants = HashSet::from(["table-1".to_owned()]);
    loop {
        let previous = descendants.len();
        for block in &original {
            if block
                .parent_id
                .as_ref()
                .is_some_and(|parent| descendants.contains(parent))
            {
                descendants.insert(block.id.clone());
            }
        }
        if descendants.len() == previous {
            break;
        }
    }
    let desired = original
        .iter()
        .filter(|block| !descendants.contains(&block.id))
        .cloned()
        .collect();
    record_local_snapshot(&mut engine, desired, None, None).unwrap();
    let deleted = engine.blocks();
    for _ in 0..3 {
        engine.replay_history(true, None).unwrap();
        assert_eq!(engine.blocks(), original);
        engine.replay_history(false, None).unwrap();
        assert_eq!(engine.blocks(), deleted);
    }
}

#[test]
fn table_row_redo_preserves_remote_edits_in_surviving_rows() {
    let (_directory, mut engine, peer) = table_setup();
    integrate(&peer, &delete_first_table_row(&mut engine).v1_update);
    integrate(&peer, &engine.replay_history(true, None).unwrap().v1_update);
    let before = peer.transact().state_vector();
    text(&peer, "body-1-0").insert(&mut peer.transact_mut(), 0, "remote ");
    engine
        .apply_cses_update(peer.transact().encode_state_as_update_v1(&before))
        .unwrap();
    let redo = engine.replay_history(false, None).unwrap();
    integrate(&peer, &redo.v1_update);
    assert!(engine
        .blocks()
        .iter()
        .find(|block| block.id == "body-1-0")
        .unwrap()
        .text
        .starts_with("remote "));
    assert!(!engine.blocks().iter().any(|block| block.id == "body-0-0"));
    assert_eq!(engine.doc.transact().snapshot(), peer.transact().snapshot());
}

#[test]
fn table_row_redo_rejects_remote_contributions_restored_from_archived_nodes() {
    for edit_while_archived in [false, true] {
        let (_directory, mut engine, peer) = table_setup();
        integrate(&peer, &delete_first_table_row(&mut engine).v1_update);
        if !edit_while_archived {
            integrate(&peer, &engine.replay_history(true, None).unwrap().v1_update);
        }
        let before = peer.transact().state_vector();
        text(&peer, "body-0-0").insert(&mut peer.transact_mut(), 0, "remote ");
        engine
            .apply_cses_update(peer.transact().encode_state_as_update_v1(&before))
            .unwrap();
        if edit_while_archived {
            integrate(&peer, &engine.replay_history(true, None).unwrap().v1_update);
        }
        assert!(engine
            .blocks()
            .iter()
            .find(|block| block.id == "body-0-0")
            .unwrap()
            .text
            .starts_with("remote "));
        let before = snapshot(&engine);
        assert!(engine
            .replay_history(false, None)
            .unwrap_err()
            .starts_with("HISTORY_STRUCTURE_CONFLICT: remote contributions in body-0-0"));
        assert_eq!(snapshot(&engine), before);
    }
}
