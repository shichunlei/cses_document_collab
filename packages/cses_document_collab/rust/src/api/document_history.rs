//! Durable native history for the active engine. Selection tokens are personal,
//! session-scoped data and are never written into CRDT updates or SQLite.

use super::*;
use std::collections::{BTreeMap, BTreeSet};
use yrs::types::ToJson;
use yrs::undo::{StackItem, UndoManager};
use yrs::{Assoc, StickyIndex};

pub(super) const REMOTE_ORIGIN: &str = "collab:remote-or-system";

/// A directional selection endpoint using stable block identity and UTF-16 units.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HistoryPoint {
    /// Formal or legacy projected block identity, never an AppFlowy path.
    pub block_id: String,
    /// UTF-16 caret offset; non-text blocks use offset zero.
    pub offset: u32,
}

/// Anchor/focus order is preserved, including backwards multi-block ranges.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HistorySelection {
    /// User's original anchor endpoint.
    pub anchor: HistoryPoint,
    /// User's active focus endpoint.
    pub focus: HistoryPoint,
}

/// Availability of the current user's session history, independent of the wire.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DocumentHistoryState {
    /// Number of local groups currently on the undo stack.
    pub undo_depth: u32,
    /// Number of undone local groups currently on the redo stack.
    pub redo_depth: u32,
}

/// Returned only after the native candidate has committed to SQLite.
#[derive(Debug, Clone)]
pub struct DocumentHistoryResult {
    /// Canonical projected body after acceptance.
    pub blocks: Vec<CollabBlock>,
    /// Unframed Yjs V1 update for the existing collaboration session.
    pub v1_update: Vec<u8>,
    /// Personal bookmark resolved again after the Flutter projection is current.
    pub selection_bookmark: Option<String>,
    /// Availability after this accepted transition.
    pub history: DocumentHistoryState,
}

#[flutter_rust_bridge::frb(ignore)]
#[derive(Default, Debug, Clone, PartialEq, Eq)]
struct Meta {
    affected: BTreeSet<String>,
    subtrees: BTreeSet<String>,
    removable: BTreeMap<String, serde_json::Value>,
    restore: Option<String>,
}

#[flutter_rust_bridge::frb(ignore)]
pub(super) struct NativeHistory {
    manager: UndoManager<Meta>,
    writable: bool,
}

#[flutter_rust_bridge::frb(ignore)]
pub(super) struct HistoryInput {
    before: Option<HistorySelection>,
    after: Option<HistorySelection>,
}

#[flutter_rust_bridge::frb(ignore)]
pub(super) struct Recording {
    manager: UndoManager<Meta>,
    previous_depth: usize,
}

/// Enable native history on the active engine and install the host's `editable`
/// permission snapshot. Repeated calls update access without clearing history.
/// Cache replay and system/remote writes never become local undo entries.
#[flutter_rust_bridge::frb(sync)]
pub fn configure_document_history(editable: bool) -> Result<DocumentHistoryState, String> {
    with_engine_mut(|engine| {
        if engine.history.is_none() {
            engine.history = Some(NativeHistory {
                manager: manager(&engine.doc, vec![], vec![]),
                writable: editable,
            });
        } else {
            engine.history.as_mut().unwrap().writable = editable;
        }
        Ok(engine.history_state())
    })
}

/// Read session availability without changing access, content or either stack.
#[flutter_rust_bridge::frb(sync)]
pub fn document_history_state() -> Result<DocumentHistoryState, String> {
    with_engine(|engine| Ok(engine.history_state()))
}

/// Apply editor `blocks` as one native user-intent group. `before_selection` and
/// `after_selection` use stable IDs; missing endpoints are safely omitted.
/// All existing schema/lock validation is retained. Persistence failure does not
/// advance the authoritative document or native history. System callers retain
/// the original apply_block_snapshot API, which deliberately records no history.
#[flutter_rust_bridge::frb(sync)]
pub fn apply_history_snapshot(
    blocks: Vec<CollabBlock>,
    before_selection: Option<HistorySelection>,
    after_selection: Option<HistorySelection>,
) -> Result<DocumentHistoryResult, String> {
    with_engine_mut(|engine| {
        engine.history_access()?;
        engine.history_input = Some(HistoryInput {
            before: before_selection,
            after: after_selection,
        });
        let result = engine.apply_block_snapshot(blocks);
        let input = engine.history_input.take().unwrap();
        let result = result?;
        Ok(DocumentHistoryResult {
            blocks: result.blocks,
            v1_update: result.v1_update,
            selection_bookmark: bookmark(
                &engine.doc,
                engine.blockcraft_root_id.as_deref(),
                input.after.as_ref(),
            )?,
            history: engine.history_state(),
        })
    })
}

/// Undo the latest applicable local group. `selection` is the current personal
/// selection, saved on the inverse group for redo. Rejected permissions, locks,
/// structural conflicts and SQLite failures leave both native stacks untouched.
#[flutter_rust_bridge::frb(sync)]
pub fn undo_document(selection: Option<HistorySelection>) -> Result<DocumentHistoryResult, String> {
    with_engine_mut(|engine| engine.replay_history(true, selection))
}

/// Redo one undone local group, saving current `selection` for the inverse undo.
/// New local writes invalidate redo; remote and system writes preserve it.
#[flutter_rust_bridge::frb(sync)]
pub fn redo_document(selection: Option<HistorySelection>) -> Result<DocumentHistoryResult, String> {
    with_engine_mut(|engine| engine.replay_history(false, selection))
}

/// Encode a personal `selection` against the current native document. Tokens are
/// tied to this open session's GUID; they are not collaborative document data.
#[flutter_rust_bridge::frb(sync)]
pub fn bookmark_document_selection(
    selection: Option<HistorySelection>,
) -> Result<Option<String>, String> {
    with_engine(|engine| {
        bookmark(
            &engine.doc,
            engine.blockcraft_root_id.as_deref(),
            selection.as_ref(),
        )
    })
}

/// Resolve personal `token` using the latest text identities and offsets. A
/// deleted/unreachable endpoint returns None, never another block's old path.
/// Malformed or cross-session tokens return an error without modifying state.
#[flutter_rust_bridge::frb(sync)]
pub fn resolve_document_selection(token: String) -> Result<Option<HistorySelection>, String> {
    with_engine(|engine| {
        resolve_bookmark(&engine.doc, engine.blockcraft_root_id.as_deref(), &token)
    })
}

impl CollabEngine {
    fn history_state(&self) -> DocumentHistoryState {
        DocumentHistoryState {
            undo_depth: self
                .history
                .as_ref()
                .map_or(0, |h| h.manager.undo_stack().len() as u32),
            redo_depth: self
                .history
                .as_ref()
                .map_or(0, |h| h.manager.redo_stack().len() as u32),
        }
    }

    fn history_access(&self) -> Result<(), String> {
        if !self.history.as_ref().is_some_and(|h| h.writable) {
            return Err("HISTORY_READ_ONLY".into());
        }
        if let Some(root) = &self.blockcraft_root_id {
            if let Some(reason) = blockcraft::project(&self.doc, root).reason {
                return Err(format!("READ_ONLY_DOCUMENT: {reason}"));
            }
        }
        Ok(())
    }

    /// Build an isolated native checkpoint for incoming `blocks`. Legacy text
    /// roots, including empty/new paragraphs omitted by V1, are declared before
    /// the recording manager subscribes. Only explicit editor writes capture.
    pub(super) fn stage_local_history(
        &self,
        blocks: &[CollabBlock],
    ) -> Result<(Doc, Option<Recording>), String> {
        let doc = self.staged_document()?;
        if self.blockcraft_root_id.is_none() {
            for block in blocks {
                doc.get_or_insert_text(block_text_name(&block.id));
            }
        }
        let recording = if self.history_input.is_some() {
            self.history_access()?;
            let previous = &self.history.as_ref().unwrap().manager;
            Some(Recording {
                manager: manager(
                    &doc,
                    previous.undo_stack().to_vec(),
                    previous.redo_stack().to_vec(),
                ),
                previous_depth: previous.undo_stack().len(),
            })
        } else {
            None
        };
        Ok((doc, recording))
    }

    /// Persist `update` then atomically install candidate `doc` and its
    /// `recording`. A real document change without a captured group is rejected
    /// before SQLite is touched; no uncommitted update can report success.
    pub(super) fn commit_local_history(
        &mut self,
        doc: Doc,
        recording: Option<Recording>,
        update: &[u8],
    ) -> Result<(), String> {
        let Some(mut recording) = recording else {
            return self.persist_and_apply_update(update);
        };
        scope(&mut recording.manager, &doc);
        let mut items = recording.manager.undo_stack().to_vec();
        let new = items.split_off(recording.previous_depth);
        if new.is_empty() {
            if self.doc.transact().snapshot() != doc.transact().snapshot() {
                return Err("HISTORY_CAPTURE_INCOMPLETE: document change was not recorded".into());
            }
            return Ok(());
        }
        let mut group = new.into_iter();
        let mut item = group.next().unwrap();
        for next in group {
            item.merge(next, |_, _| ());
        }
        let mut meta = footprint(&self.doc, &doc, self.blockcraft_root_id.as_deref())?;
        meta.restore = bookmark(
            &self.doc,
            self.blockcraft_root_id.as_deref(),
            self.history_input.as_ref().and_then(|i| i.before.as_ref()),
        )?;
        items.push(StackItem::with_meta(
            doc.guid(),
            item.deletions().clone(),
            item.insertions().clone(),
            meta,
        ));
        if items.len() > 200 {
            items.drain(..items.len() - 200);
        }
        let redo = recording.manager.redo_stack().to_vec();
        drop(recording.manager);
        let manager = manager(&doc, items, redo);
        // Validate after-selection before persistence: no fallible work is left
        // between COMMIT and the authoritative state swap.
        let _ = bookmark(
            &doc,
            self.blockcraft_root_id.as_deref(),
            self.history_input.as_ref().and_then(|i| i.after.as_ref()),
        )?;
        self.persist_update(update)?;
        self.install_history(doc, manager);
        Ok(())
    }

    /// Rebind every native handle and Awareness's Doc while preserving clients,
    /// clocks and presence; no old branch handle escapes the engine lock.
    fn install_history(&mut self, doc: Doc, manager: UndoManager<Meta>) {
        self.history.as_mut().unwrap().manager = manager;
        self.doc = doc;
        *self.awareness.doc_mut() = self.doc.clone();
        self.block_order = self.doc.get_or_insert_array(BLOCK_ORDER_NAME);
        self.block_meta = self.doc.get_or_insert_map(BLOCK_META_NAME);
        self.block_checked = self.doc.get_or_insert_map(BLOCK_CHECKED_NAME);
        self.block_align = self.doc.get_or_insert_map(BLOCK_ALIGN_NAME);
        self.block_indent = self.doc.get_or_insert_map(BLOCK_INDENT_NAME);
        self.block_colors = self.doc.get_or_insert_map(BLOCK_COLORS_NAME);
    }

    fn replay_history(
        &mut self,
        undo: bool,
        selection: Option<HistorySelection>,
    ) -> Result<DocumentHistoryResult, String> {
        self.history_access()?;
        let history = &self.history.as_ref().unwrap().manager;
        let source = if undo {
            history.undo_stack()
        } else {
            history.redo_stack()
        };
        if let Some(item) = source.last() {
            locks(&self.doc, self.blockcraft_root_id.as_deref(), item.meta())?;
        }
        let doc = self.staged_document()?;
        let mut candidate = manager(
            &doc,
            history.undo_stack().to_vec(),
            history.redo_stack().to_vec(),
        );
        let popped = std::sync::Arc::new(Mutex::new(None));
        let sink = popped.clone();
        let subscription = candidate.observe_item_popped(move |_, event| {
            *sink.lock() = Some(event.meta().clone());
        });
        let update = capture(&doc, || {
            if undo {
                candidate.undo_blocking();
            } else {
                candidate.redo_blocking();
            }
        })?;
        drop(subscription);
        let remaining = if undo {
            candidate.undo_stack().len()
        } else {
            candidate.redo_stack().len()
        };
        let mut guards = BTreeMap::new();
        for item in &source[remaining..] {
            locks(&self.doc, self.blockcraft_root_id.as_deref(), item.meta())?;
            locks(&doc, self.blockcraft_root_id.as_deref(), item.meta())?;
            guards.extend(item.meta().removable.clone());
        }
        if let Some(root) = &self.blockcraft_root_id {
            blockcraft::validate(&doc, root)?;
            let before = blockcraft::project(&self.doc, root);
            let after = blockcraft::project(&doc, root);
            if after.reason.is_some() {
                return Err("HISTORY_STRUCTURE_CONFLICT: unsupported restoration".into());
            }
            block_locks::preflight(&self.doc, root, &before.blocks, &after.blocks)?;
            blockcraft::validate_tables(&after.blocks)?;
            let previous = reachable(&self.doc, root)?;
            let next = reachable(&doc, root)?;
            let raw = raw_blocks(&self.doc)?;
            for id in previous.keys().filter(|id| !next.contains_key(*id)) {
                if raw.get(id) != guards.get(id) {
                    return Err(format!(
                        "HISTORY_STRUCTURE_CONFLICT: remote contributions in {id}"
                    ));
                }
            }
        }
        let popped_meta = popped.lock().clone();
        let restore = popped_meta.as_ref().and_then(|m| m.restore.clone());
        if let Some(mut inverse) = popped_meta {
            inverse.restore = bookmark(
                &self.doc,
                self.blockcraft_root_id.as_deref(),
                selection.as_ref(),
            )?;
            let mut us = candidate.undo_stack().to_vec();
            let mut rs = candidate.redo_stack().to_vec();
            let target = if undo { &mut rs } else { &mut us };
            if let Some(item) = target.pop() {
                target.push(StackItem::with_meta(
                    doc.guid(),
                    item.deletions().clone(),
                    item.insertions().clone(),
                    inverse,
                ));
            }
            drop(candidate);
            candidate = manager(&doc, us, rs);
        }
        self.persist_update(&update)?;
        self.install_history(doc, candidate);
        Ok(DocumentHistoryResult {
            blocks: self.blocks(),
            v1_update: update,
            selection_bookmark: restore,
            history: self.history_state(),
        })
    }
}

fn manager(doc: &Doc, undo: Vec<StackItem<Meta>>, redo: Vec<StackItem<Meta>>) -> UndoManager<Meta> {
    let mut manager = UndoManager::with_options(yrs::undo::Options {
        capture_timeout_millis: 0,
        init_undo_stack: undo,
        init_redo_stack: redo,
        ..Default::default()
    });
    scope(&mut manager, doc);
    manager
}

fn scope(manager: &mut UndoManager<Meta>, doc: &Doc) {
    // Empty root declarations are absent from V1. Establish the existing engine
    // roots before observing a first legacy paragraph insertion.
    manager.expand_scope(doc, &doc.get_or_insert_array(BLOCK_ORDER_NAME));
    for name in [
        BLOCK_META_NAME,
        BLOCK_CHECKED_NAME,
        BLOCK_ALIGN_NAME,
        BLOCK_INDENT_NAME,
        BLOCK_COLORS_NAME,
    ] {
        manager.expand_scope(doc, &doc.get_or_insert_map(name));
    }
    let roots: Vec<_> = doc.transact().root_refs().map(|(_, out)| out).collect();
    if doc.transact().get_map("blocks").is_some() {
        manager.expand_scope(doc, &doc.get_or_insert_map("blocks"));
    }
    let names: Vec<_> = doc
        .transact()
        .root_refs()
        .filter_map(|(name, _)| {
            if name.starts_with(BLOCK_TEXT_PREFIX) {
                Some(name.to_owned())
            } else {
                None
            }
        })
        .collect();
    for name in names {
        manager.expand_scope(doc, &doc.get_or_insert_text(name));
    }
    for root in roots {
        match root {
            Out::YMap(value) => manager.expand_scope(doc, &value),
            Out::YArray(value) => manager.expand_scope(doc, &value),
            Out::YText(value) => manager.expand_scope(doc, &value),
            _ => (),
        }
    }
}

fn capture(doc: &Doc, action: impl FnOnce()) -> Result<Vec<u8>, String> {
    let updates = std::sync::Arc::new(Mutex::new(Vec::new()));
    let sink = updates.clone();
    let subscription = doc
        .observe_update_v1(move |_, event| sink.lock().push(event.update.clone()))
        .map_err(|e| e.to_string())?;
    action();
    drop(subscription);
    let bytes = updates.lock();
    match bytes.len() {
        0 => Ok(vec![]),
        1 => Ok(bytes[0].clone()),
        _ => yrs::merge_updates_v1(bytes.iter().map(Vec::as_slice)).map_err(|e| e.to_string()),
    }
}

fn raw_blocks(doc: &Doc) -> Result<BTreeMap<String, serde_json::Value>, String> {
    let txn = doc.transact();
    let Some(blocks) = txn.get_map("blocks") else {
        return Ok(BTreeMap::new());
    };
    blocks.iter(&txn).map(|(id, out)| {
        let value = serde_json::to_value(out.to_json(&txn)).map_err(|e| e.to_string())?;
        let text = if let Out::YMap(block) = &out { if let Some(Out::YText(text)) = block.get(&txn, "children") {
            Some(text.diff(&txn, |_| ()).into_iter().map(|run| serde_json::json!({"insert": run.insert.to_json(&txn), "attributes": run.attributes})).collect::<Vec<_>>())
        } else { None } } else { None };
        Ok((id.to_owned(), serde_json::json!({"value": value, "text": text})))
    }).collect()
}

/// Include hidden nodes and reject alias/cycle/dangling references in candidates.
fn reachable(doc: &Doc, root: &str) -> Result<BTreeMap<String, Option<String>>, String> {
    let txn = doc.transact();
    let Some(blocks) = txn.get_map("blocks") else {
        return Ok(BTreeMap::new());
    };
    if blocks.len(&txn) == 0 {
        return Ok(BTreeMap::new());
    }
    let mut result = BTreeMap::new();
    let mut pending = vec![(root.to_owned(), None, 0)];
    while let Some((id, parent, depth)) = pending.pop() {
        if depth > 256 || result.len() > 100_000 || result.contains_key(&id) {
            return Err("HISTORY_STRUCTURE_CONFLICT: duplicate or cyclic reference".into());
        }
        let Some(Out::YMap(block)) = blocks.get(&txn, &id) else {
            return Err("HISTORY_STRUCTURE_CONFLICT: dangling reference".into());
        };
        if let Some(Out::YArray(children)) = block.get(&txn, "children") {
            for child in children.iter(&txn) {
                let Some(child) = out_string(Some(child)) else {
                    return Err("HISTORY_STRUCTURE_CONFLICT: non-ID child".into());
                };
                pending.push((child, Some(id.clone()), depth + 1));
            }
        }
        result.insert(id, parent);
    }
    Ok(result)
}

/// Retain the visible-side fingerprint of inserted/removed blocks under `root`.
/// Archived table nodes remain in `after` with a deletion marker, so removal
/// guards must use their reachable `before` content. The same fingerprint is
/// carried through inverse groups to keep later remote contributions protected.
fn footprint(before: &Doc, after: &Doc, root: Option<&str>) -> Result<Meta, String> {
    let mut meta = Meta::default();
    let Some(root) = root else { return Ok(meta) };
    let old = raw_blocks(before)?;
    let next = raw_blocks(after)?;
    let old_graph = reachable(before, root)?;
    let graph = reachable(after, root)?;
    for id in old.keys().chain(next.keys()) {
        if old.get(id) != next.get(id) {
            meta.affected.insert(id.clone());
        }
    }
    for id in old_graph.keys().chain(graph.keys()) {
        if old_graph.get(id) != graph.get(id) {
            meta.affected.insert(id.clone());
            meta.subtrees.insert(id.clone());
        }
        if old_graph.contains_key(id) != graph.contains_key(id) {
            let visible = if old_graph.contains_key(id) {
                old.get(id)
            } else {
                next.get(id)
            };
            if let Some(value) = visible {
                meta.removable.insert(id.clone(), value.clone());
            }
        }
    }
    Ok(meta)
}

fn locks(doc: &Doc, root: Option<&str>, meta: &Meta) -> Result<(), String> {
    if let Some(root) = root {
        if blockcraft::project(doc, root).blocks.iter().any(|block| {
            block.block_type == blockcraft::UNSUPPORTED_BLOCK_TYPE
                && meta.affected.contains(&block.id)
        }) {
            return Err("READ_ONLY_BLOCK: unsupported history target".into());
        }
        for state in block_locks::scan(doc, root) {
            if (meta.affected.contains(&state.block_id) && state.source_id.is_some())
                || (meta.subtrees.contains(&state.block_id)
                    && (state.source_id.is_some() || state.contains_lock))
            {
                return Err(format!("READ_ONLY_BLOCK: {}", state.block_id));
            }
        }
    }
    Ok(())
}

fn selection_text(doc: &Doc, root: Option<&str>, id: &str) -> Option<yrs::TextRef> {
    if root.is_some() {
        let txn = doc.transact();
        let blocks = txn.get_map("blocks")?;
        let Out::YMap(block) = blocks.get(&txn, id)? else {
            return None;
        };
        if let Some(Out::YText(text)) = block.get(&txn, "children") {
            Some(text)
        } else {
            None
        }
    } else {
        doc.transact().get_text(block_text_name(id))
    }
}

fn bookmark(
    doc: &Doc,
    root: Option<&str>,
    selection: Option<&HistorySelection>,
) -> Result<Option<String>, String> {
    let Some(selection) = selection else {
        return Ok(None);
    };
    if selection.anchor.block_id.len() > 1024 || selection.focus.block_id.len() > 1024 {
        return Err("INVALID_HISTORY_SELECTION: identity".into());
    }
    let visible: HashSet<_> = if let Some(root) = root {
        blockcraft::project(doc, root)
            .blocks
            .into_iter()
            .map(|block| block.id)
            .collect()
    } else {
        let txn = doc.transact();
        txn.get_array(BLOCK_ORDER_NAME)
            .map(|array| {
                array
                    .iter(&txn)
                    .filter_map(|v| out_string(Some(v)))
                    .collect()
            })
            .unwrap_or_default()
    };
    if !visible.contains(&selection.anchor.block_id) || !visible.contains(&selection.focus.block_id)
    {
        return Ok(None);
    }
    let point = |point: &HistoryPoint| -> Result<serde_json::Value, String> {
        let text = selection_text(doc, root, &point.block_id);
        let relative = if let Some(text) = text {
            let txn = doc.transact();
            if point.offset > text.len(&txn) {
                return Err("INVALID_HISTORY_SELECTION: offset".into());
            }
            StickyIndex::at(
                &txn,
                yrs::branch::BranchPtr::from(<yrs::TextRef as AsRef<yrs::branch::Branch>>::as_ref(
                    &text,
                )),
                point.offset,
                Assoc::Before,
            )
            .map(|p| p.encode_v1())
        } else {
            None
        };
        Ok(serde_json::json!({"id":point.block_id,"offset":point.offset,"relative":relative}))
    };
    Ok(Some(serde_json::json!({"guid":doc.guid(),"anchor":point(&selection.anchor)?,"focus":point(&selection.focus)?}).to_string()))
}

fn resolve_bookmark(
    doc: &Doc,
    root: Option<&str>,
    token: &str,
) -> Result<Option<HistorySelection>, String> {
    if token.len() > 65536 {
        return Err("INVALID_HISTORY_SELECTION".into());
    }
    let value: serde_json::Value =
        serde_json::from_str(token).map_err(|_| "INVALID_HISTORY_SELECTION")?;
    if value["guid"].as_str() != Some(doc.guid().as_ref()) {
        return Err("HISTORY_SELECTION_STALE".into());
    }
    let visible: HashSet<_> = if let Some(root) = root {
        blockcraft::project(doc, root)
            .blocks
            .into_iter()
            .map(|b| b.id)
            .collect()
    } else {
        let txn = doc.transact();
        txn.get_array(BLOCK_ORDER_NAME)
            .map(|array| {
                array
                    .iter(&txn)
                    .filter_map(|v| out_string(Some(v)))
                    .collect()
            })
            .unwrap_or_default()
    };
    let point = |value: &serde_json::Value| -> Result<Option<HistoryPoint>, String> {
        let id = value["id"].as_str().ok_or("INVALID_HISTORY_SELECTION")?;
        if !visible.contains(id) {
            return Ok(None);
        }
        let offset = if let Some(array) = value["relative"].as_array() {
            let bytes = array
                .iter()
                .map(|n| {
                    n.as_u64()
                        .filter(|n| *n <= 255)
                        .map(|n| n as u8)
                        .ok_or("INVALID_HISTORY_SELECTION")
                })
                .collect::<Result<Vec<_>, _>>()?;
            let relative =
                StickyIndex::decode_v1(&bytes).map_err(|_| "INVALID_HISTORY_SELECTION")?;
            let txn = doc.transact();
            let Some(position) = relative.get_history_offset(&txn) else {
                return Ok(None);
            };
            let Some(text) = selection_text(doc, root, id) else {
                return Ok(None);
            };
            if position.branch
                != yrs::branch::BranchPtr::from(
                    <yrs::TextRef as AsRef<yrs::branch::Branch>>::as_ref(&text),
                )
            {
                return Ok(None);
            }
            position.index.min(text.len(&txn))
        } else {
            0
        };
        Ok(Some(HistoryPoint {
            block_id: id.to_owned(),
            offset,
        }))
    };
    let (Some(anchor), Some(focus)) = (point(&value["anchor"])?, point(&value["focus"])?) else {
        return Ok(None);
    };
    Ok(Some(HistorySelection { anchor, focus }))
}

#[cfg(test)]
#[path = "document_history_tests.rs"]
mod tests;
