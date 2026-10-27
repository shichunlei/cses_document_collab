//! One-time formal initialization. The receipt is local infrastructure, never shared
//! through Yjs. Reopening restores the original CRDT identities rather than recreating them.
use super::*;
use rusqlite::OptionalExtension;
use serde_json::{json, Value};
use yrs::{ArrayPrelim, MapPrelim, TextPrelim};

/// Validate identifiers before opening storage; zero timestamps and aliased IDs are invalid.
fn validate_request(
    root: &str,
    cache: &str,
    operation: &str,
    paragraph: &str,
    time: f64,
) -> Result<(), String> {
    if [root, cache, operation, paragraph]
        .iter()
        .any(|v| v.trim().is_empty() || v.len() > 256)
        || root == paragraph
        || !time.is_finite()
        || time <= 0.0
        || time.fract() != 0.0
        || time > 8_640_000_000_000_000.0
    {
        return Err("INVALID_DOCUMENT_BOOTSTRAP".into());
    }
    Ok(())
}

/// Create local receipt storage independently of the document's shared types.
fn ensure_table(connection: &Connection) -> Result<(), String> {
    connection
        .execute_batch(
            "CREATE TABLE IF NOT EXISTS document_bootstraps (
        cache_id TEXT PRIMARY KEY, root_id TEXT NOT NULL, operation_id TEXT NOT NULL,
        paragraph_id TEXT NOT NULL, created_time REAL NOT NULL,
        snapshot TEXT NOT NULL, initial_vector BLOB NOT NULL
    );",
        )
        .map_err(|e| format!("cannot initialize bootstrap receipts: {e}"))
}

/// Return the desktop snapshot used by both the persisted update and host HTTP projection.
fn snapshot(root: &str, paragraph: &str, time: f64) -> Value {
    json!({"id": root, "flavour": "root", "nodeType": "root", "props": {},
        "meta": {"createdTime": time, "lastModified": {"time": time, "user": null}},
        "children": [{"id": paragraph, "flavour": "paragraph", "nodeType": "editable",
            "props": {"depth": 0}, "meta": {}, "children": []}]})
}

/// Write only the two newly allocated blocks using desktop-compatible nested types.
fn populate(doc: &Doc, root: &str, paragraph: &str, time: f64) {
    let blocks = doc.get_or_insert_map(blockcraft::ROOT_NAME);
    let mut txn = doc.transact_mut();
    let r = blocks.insert(&mut txn, root, MapPrelim::default());
    r.insert(&mut txn, "id", root);
    r.insert(&mut txn, "flavour", "root");
    r.insert(&mut txn, "nodeType", "root");
    r.insert(&mut txn, "props", MapPrelim::default());
    let meta = r.insert(&mut txn, "meta", MapPrelim::default());
    meta.insert(&mut txn, "createdTime", time);
    meta.insert(
        &mut txn,
        "lastModified",
        Any::from_json(&json!({"time":time,"user":null}).to_string()).unwrap(),
    );
    r.insert(
        &mut txn,
        "children",
        ArrayPrelim::from(vec![paragraph.to_owned()]),
    );
    let p = blocks.insert(&mut txn, paragraph, MapPrelim::default());
    p.insert(&mut txn, "id", paragraph);
    p.insert(&mut txn, "flavour", "paragraph");
    p.insert(&mut txn, "nodeType", "editable");
    let props = p.insert(&mut txn, "props", MapPrelim::default());
    props.insert(&mut txn, "depth", 0);
    p.insert(&mut txn, "meta", MapPrelim::default());
    p.insert(&mut txn, "children", TextPrelim::new(""));
}

/// Prepare under the caller's engine reservation. The fresh initial transaction has
/// no deletions. Retry requires the same receipt, vector and empty delete set; this
/// also validates receipts written before deletion checks without a database migration.
/// Any mutation preserves the existing data and fails closed.
pub(super) fn prepare(
    root: String,
    cache: String,
    path: String,
    operation: String,
    paragraph: String,
    time: f64,
) -> Result<String, String> {
    validate_request(&root, &cache, &operation, &paragraph, time)?;
    let (mut engine, count) = CollabEngine::open(cache.clone(), path)?;
    ensure_table(&engine.connection)?;
    let stored: Option<(String, String, String, f64, String, Vec<u8>)> = engine.connection.query_row(
        "SELECT root_id,operation_id,paragraph_id,created_time,snapshot,initial_vector FROM document_bootstraps WHERE cache_id=?1",
        [&cache], |r| Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?,r.get(4)?,r.get(5)?))
    ).optional().map_err(|e| format!("cannot read bootstrap receipt: {e}"))?;
    if let Some((stored_root, stored_operation, stored_paragraph, stored_time, snapshot, vector)) =
        stored
    {
        if (
            stored_root.as_str(),
            stored_operation.as_str(),
            stored_paragraph.as_str(),
            stored_time,
        ) != (root.as_str(), operation.as_str(), paragraph.as_str(), time)
        {
            return Err("DOCUMENT_BOOTSTRAP_CONFLICT: 初始化身份不匹配".into());
        }
        let initial_vector = StateVector::decode_v1(&vector)
            .map_err(|e| format!("cannot decode bootstrap vector: {e}"))?;
        let current = engine.doc.transact().snapshot();
        if current.state_map != initial_vector || !current.delete_set.is_empty() {
            return Err("DOCUMENT_BOOTSTRAP_CHANGED: 正文已变化，请恢复文档".into());
        }
        blockcraft::validate(&engine.doc, &root)?;
        return Ok(snapshot);
    }
    if count != 0
        || engine
            .doc
            .transact()
            .get_map(blockcraft::ROOT_NAME)
            .is_some_and(|m| m.len(&engine.doc.transact()) > 0)
    {
        return Err("DOCUMENT_BOOTSTRAP_CONFLICT: 已有正文不能初始化".into());
    }
    let doc = create_compatible_doc();
    populate(&doc, &root, &paragraph, time);
    blockcraft::validate(&doc, &root)?;
    let payload = doc
        .transact()
        .encode_state_as_update_v1(&StateVector::default());
    let vector = doc.transact().state_vector().encode_v1();
    let snapshot = snapshot(&root, &paragraph, time).to_string();
    let transaction = engine.connection.transaction().map_err(|e| e.to_string())?;
    transaction
        .execute(
            "INSERT INTO document_updates(document_id,payload) VALUES (?1,?2)",
            params![cache, payload],
        )
        .map_err(|e| e.to_string())?;
    transaction.execute("INSERT INTO document_bootstraps(cache_id,root_id,operation_id,paragraph_id,created_time,snapshot,initial_vector) VALUES (?1,?2,?3,?4,?5,?6,?7)", params![cache,root,operation,paragraph,time,snapshot,vector]).map_err(|e| e.to_string())?;
    transaction.commit().map_err(|e| e.to_string())?;
    Ok(snapshot)
}

/// Reject a competing CRDT root even when it has the same logical IDs and content.
/// Incremental edits referencing the existing root pass through unchanged. Missing
/// local roots (e.g. an explicit cache reset) can still recover from the server.
pub(super) fn guard_remote(engine: &CollabEngine, payload: &[u8]) -> Result<(), String> {
    let Some(root_id) = engine.blockcraft_root_id.as_deref() else {
        return Ok(());
    };
    if engine.bootstrap_root_id.as_deref() != Some(root_id) {
        return Ok(());
    }
    let txn = engine.doc.transact();
    let Some(Out::YMap(local)) = txn
        .get_map(blockcraft::ROOT_NAME)
        .and_then(|m| m.get(&txn, root_id))
    else {
        return Ok(());
    };
    let remote = create_compatible_doc();
    remote
        .transact_mut()
        .apply_update(Update::decode_v1(payload).map_err(|e| e.to_string())?)
        .map_err(|e| e.to_string())?;
    let remote_txn = remote.transact();
    if let Some(Out::YMap(incoming)) = remote_txn
        .get_map(blockcraft::ROOT_NAME)
        .and_then(|m| m.get(&remote_txn, root_id))
    {
        if incoming.as_ref().id() != local.as_ref().id() {
            return Err("DOCUMENT_BOOTSTRAP_CONFLICT: 远端已有不同来源的正文，请恢复文档".into());
        }
    }
    Ok(())
}

/// Read the cached initialization root once when opening an engine. Old databases
/// without receipt storage remain unchanged and require no shared-data migration.
pub(super) fn protected_root(
    connection: &Connection,
    cache: &str,
) -> Result<Option<String>, String> {
    let has_table: bool = connection.query_row("SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='document_bootstraps')", [], |r| r.get(0)).map_err(|e| e.to_string())?;
    if !has_table {
        return Ok(None);
    }
    connection
        .query_row(
            "SELECT root_id FROM document_bootstraps WHERE cache_id=?1",
            [cache],
            |r| r.get(0),
        )
        .optional()
        .map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    fn prepare_at(path: &str) -> Result<String, String> {
        prepare(
            "new-doc".into(),
            "cache".into(),
            path.into(),
            "op".into(),
            "p1".into(),
            1_792_584_000_000.0,
        )
    }

    #[test]
    fn retry_reuses_update_and_reopens_as_formal() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("updates.sqlite");
        let path = path.to_str().unwrap();
        let first = prepare_at(path).unwrap();
        let (mut engine, count) = CollabEngine::open("cache".into(), path.into()).unwrap();
        assert_eq!(count, 1);
        engine.blockcraft_root_id = Some("new-doc".into());
        assert_eq!(engine.blocks().len(), 1);
        assert_eq!(engine.blocks()[0].id, "p1");
        assert_eq!(engine.blocks()[0].text, "");
        let vector = engine.doc.transact().state_vector().encode_v1();
        assert!(engine.doc.transact().snapshot().delete_set.is_empty());
        drop(engine);
        assert_eq!(first, prepare_at(path).unwrap());
        let (engine, count) = CollabEngine::open("cache".into(), path.into()).unwrap();
        assert_eq!(count, 1);
        assert_eq!(vector, engine.doc.transact().state_vector().encode_v1());
        let parsed: Value = serde_json::from_str(&first).unwrap();
        assert_eq!(parsed["children"][0]["props"], json!({"depth":0}));
    }

    #[test]
    fn wrong_receipt_and_existing_content_do_not_mutate() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("db");
        let path = path.to_str().unwrap();
        prepare_at(path).unwrap();
        assert!(prepare(
            "new-doc".into(),
            "cache".into(),
            path.into(),
            "other".into(),
            "p1".into(),
            1_792_584_000_000.0
        )
        .unwrap_err()
        .contains("CONFLICT"));
        let (mut engine, _) = CollabEngine::open("cache".into(), path.into()).unwrap();
        engine.blockcraft_root_id = Some("new-doc".into());
        let mut blocks = engine.blocks();
        blocks[0].text = "用户正文".into();
        engine.apply_block_snapshot(blocks).unwrap();
        drop(engine);
        assert!(prepare_at(path).unwrap_err().contains("CHANGED"));
        let (engine, _) = CollabEngine::open("cache".into(), path.into()).unwrap();
        engine
            .connection
            .execute("DELETE FROM document_bootstraps", [])
            .unwrap();
        drop(engine);
        assert!(prepare_at(path).unwrap_err().contains("已有正文"));
    }

    #[test]
    fn receipt_failure_rolls_back_update_and_can_retry() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("db");
        let path = path.to_str().unwrap();
        let (engine, _) = CollabEngine::open("cache".into(), path.into()).unwrap();
        ensure_table(&engine.connection).unwrap();
        engine.connection.execute_batch("CREATE TRIGGER fail_bootstrap BEFORE INSERT ON document_bootstraps BEGIN SELECT RAISE(ABORT,'disk failure'); END;").unwrap();
        drop(engine);
        assert!(prepare_at(path).is_err());
        let (engine, count) = CollabEngine::open("cache".into(), path.into()).unwrap();
        assert_eq!(count, 0);
        engine
            .connection
            .execute_batch("DROP TRIGGER fail_bootstrap;")
            .unwrap();
        drop(engine);
        prepare_at(path).unwrap();
    }

    /// Delete-only updates keep the vector but must invalidate the initial receipt.
    #[test]
    fn delete_only_changes_reject_reprepare_without_mutation() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("delete.sqlite");
        let path = path.to_str().unwrap();
        prepare_at(path).unwrap();
        let (mut engine, _) = CollabEngine::open("cache".into(), path.into()).unwrap();
        engine.blockcraft_root_id = Some("new-doc".into());
        let before = engine.doc.transact().state_vector();
        let staged = engine.staged_document().unwrap();
        {
            let mut txn = staged.transact_mut();
            let blocks = txn.get_map(blockcraft::ROOT_NAME).unwrap();
            let Out::YMap(root) = blocks.get(&txn, "new-doc").unwrap() else {
                panic!("missing root");
            };
            let Out::YArray(children) = root.get(&txn, "children").unwrap() else {
                panic!("missing children");
            };
            children.remove_range(&mut txn, 0, 1);
        }
        let delta = staged.transact().encode_state_as_update_v1(&before);
        engine.persist_and_apply_update(&delta).unwrap();
        assert_eq!(before, engine.doc.transact().state_vector());
        blockcraft::validate(&engine.doc, "new-doc").unwrap();
        assert!(engine.blocks().is_empty());
        let changed = engine.doc.transact().snapshot();
        drop(engine);
        assert!(prepare_at(path).unwrap_err().contains("CHANGED"));
        let (engine, count) = CollabEngine::open("cache".into(), path.into()).unwrap();
        assert_eq!(count, 2);
        assert_eq!(engine.doc.transact().snapshot(), changed);
    }

    #[test]
    fn different_remote_root_is_rejected_without_advancing_vector() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("db");
        let path = path.to_str().unwrap();
        prepare_at(path).unwrap();
        let (mut engine, _) = CollabEngine::open("cache".into(), path.into()).unwrap();
        engine.blockcraft_root_id = Some("new-doc".into());
        let before = engine.doc.transact().state_vector();
        let remote = create_compatible_doc();
        populate(&remote, "new-doc", "p1", 1_792_584_000_000.0);
        let bytes = remote
            .transact()
            .encode_state_as_update_v1(&StateVector::default());
        assert!(engine
            .apply_cses_update(bytes)
            .unwrap_err()
            .contains("CONFLICT"));
        assert_eq!(before, engine.doc.transact().state_vector());
        let bytes = engine
            .doc
            .transact()
            .encode_state_as_update_v1(&StateVector::default());
        engine.apply_cses_update(bytes).unwrap();
    }
}
