//! Isolated selective-undo/persistence experiment for the next editor migration.
//!
//! This module is not a Flutter API and is disabled in normal library builds.
//! It owns a separate document and SQLite connection. Use a dedicated prototype
//! database, never the database of an active production document engine.
//!
//! Candidates preserve native restoration links through an isolated Yrs checkpoint
//! extension. It is not enabled for the production collaboration engine. Every
//! local command and historical group is checked against live access and locks
//! before persistence; SQLite failure never consumes the authoritative stacks.

use parking_lot::Mutex;
use rusqlite::{params, Connection};
use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;
use std::sync::Arc;
use yrs;
use yrs::undo::{StackItem, UndoManager};
use yrs::updates::decoder::Decode;
use yrs::{
    merge_updates_v1, Doc, GetString, Map, OffsetKind, Options, Out, ReadTxn, StateVector, Text,
    Transact, Update,
};

const LOCAL_ORIGIN: &str = "history-prototype:local";
const REMOTE_ORIGIN: &str = "history-prototype:remote";

/// Availability of the current session's local history, not another peer's.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct HistoryState {
    /// Number of available local undo groups.
    pub undo_depth: usize,
    /// Number of available local redo groups.
    pub redo_depth: usize,
}

/// Result published only after SQLite accepts the operation.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HistoryChange {
    /// Raw V1 delta suitable for the existing collaboration envelope; empty on no-op.
    pub v1_update: Vec<u8>,
    /// Whether this action produced a CRDT change, including deletion-only changes.
    pub changed: bool,
    /// History availability after the accepted action.
    pub history: HistoryState,
}

/// A standalone native command-history prototype with failure-atomic persistence.
///
/// One `replace_text` call is one capture group. Remote updates are excluded from
/// history and do not clear redo. Reopening restores content but starts a new
/// session history. Closing drops the owned connection, Yrs manager and document.
/// Blocks use formal `blocks[id]` maps with Y.Text/Y.Array children. The host
/// must call [Self::set_write_access] before local edits; new/reopened sessions
/// are read-only. Locks (including the current user's own locks) deny content
/// writes; this module does not unlock them. Selection/IME integration and full
/// block-schema coverage remain outside this prototype.
///
/// ```no_run
/// use cses_collab_core::history_prototype::HistoryPrototype;
/// let mut history = HistoryPrototype::open("/tmp/history-only.sqlite", "test-doc")?;
/// // Seed actual BlockCraft data from an independent peer's V1 update first.
/// // history.apply_remote(&peer_update)?;
/// // history.set_write_access("formal-root-id", true)?;
/// // let change = history.replace_text("paragraph-id", 0, 0, "hello")?;
/// // Send change.v1_update only after this call succeeds.
/// drop(history);
/// # Ok::<(), String>(())
/// ```
pub struct HistoryPrototype {
    connection: Connection,
    document_id: String,
    /// Counts accepted state transitions only; failed candidates cannot advance it.
    accepted_actions: usize,
    state: NativeState,
    /// Host-owned access snapshot; remote updates never grant write permission.
    access: Option<(String, bool)>,
}

/// The manager must be dropped before its borrowed document is released.
struct NativeState {
    history: UndoManager<HistoryMeta>,
    doc: Doc,
}

/// Per-group affected stable IDs; stored directly on native StackItems.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
struct HistoryMeta {
    targets: BTreeSet<String>,
    subtrees: BTreeSet<String>,
    /// Exact shared values an inverse may remove. Later remote contributions
    /// cause a conflict instead of disappearing with a locally created block.
    removable: BTreeMap<String, serde_json::Value>,
}

impl HistoryMeta {
    fn target(id: &str) -> Self {
        Self {
            targets: [id.to_owned()].into_iter().collect(),
            ..Default::default()
        }
    }
}

#[path = "history_commands.rs"]
mod commands;
#[path = "history_policy.rs"]
mod policy;

#[derive(Clone)]
enum Action {
    Remote(Vec<u8>),
    Undo,
    Redo,
}

impl NativeState {
    /// Rebuild the same actor/document with cache replay excluded from history.
    fn from_baseline(options: Options, baseline: &[u8]) -> Result<Self, String> {
        let doc = Doc::with_options(options);
        if !baseline.is_empty() {
            doc.transact_mut_with(REMOTE_ORIGIN)
                .apply_update(decode(baseline)?)
                .map_err(|e| format!("HISTORY_BASELINE: {e}"))?;
        }
        let blocks = doc.get_or_insert_map("blocks");
        let mut history = UndoManager::with_options(yrs::undo::Options {
            capture_timeout_millis: 0,
            tracked_origins: [LOCAL_ORIGIN.into()].into_iter().collect(),
            ..Default::default()
        });
        history.expand_scope(&doc, &blocks);
        Ok(Self { history, doc })
    }

    fn history_state(&self) -> HistoryState {
        HistoryState {
            undo_depth: self.history.undo_stack().len(),
            redo_depth: self.history.redo_stack().len(),
        }
    }

    /// Capture transaction updates rather than comparing state vectors: deletions
    /// change a delete set without advancing the deleting client's vector.
    fn capture(
        &mut self,
        action: impl FnOnce(&mut Self) -> Result<(), String>,
    ) -> Result<Vec<u8>, String> {
        let updates = Arc::new(Mutex::new(Vec::new()));
        let sink = updates.clone();
        let subscription = self
            .doc
            .observe_update_v1(move |_, event| sink.lock().push(event.update.clone()))
            .map_err(|e| format!("HISTORY_OBSERVER: {e}"))?;
        action(self)?;
        drop(subscription);
        let values = updates.lock();
        match values.len() {
            0 => Ok(Vec::new()),
            1 => Ok(values[0].clone()),
            _ => merge_updates_v1(values.iter().map(Vec::as_slice))
                .map_err(|e| format!("HISTORY_UPDATE: {e}")),
        }
    }

    fn execute(&mut self, action: &Action) -> Result<Vec<u8>, String> {
        let popped = Arc::new(Mutex::new(None));
        let sink = popped.clone();
        let subscription = self.history.observe_item_popped(move |_, event| {
            *sink.lock() = Some(event.meta().clone());
        });
        let update = self.capture(|state| {
            match action {
                Action::Remote(bytes) => {
                    state
                        .doc
                        .transact_mut_with(REMOTE_ORIGIN)
                        .apply_update(decode(bytes)?)
                        .map_err(|e| format!("HISTORY_REMOTE_REPLAY: {e}"))?;
                }
                Action::Undo => {
                    state.history.undo_blocking();
                }
                Action::Redo => {
                    state.history.redo_blocking();
                }
            }
            Ok(())
        })?;
        drop(subscription);
        if let Some(meta) = popped.lock().clone() {
            self.set_top_metadata(matches!(action, Action::Undo), meta);
        }
        Ok(update)
    }

    /// Rebind public stacks to this same Doc, retaining its private redone links.
    fn set_top_metadata(&mut self, redo: bool, meta: HistoryMeta) {
        let mut undo_items = self.history.undo_stack().to_vec();
        let mut redo_items = self.history.redo_stack().to_vec();
        let items = if redo {
            &mut redo_items
        } else {
            &mut undo_items
        };
        if let Some(item) = items.pop() {
            items.push(StackItem::with_meta(
                self.doc.guid(),
                item.deletions().clone(),
                item.insertions().clone(),
                meta,
            ));
        }
        self.bind_stacks(undo_items, redo_items);
    }

    fn bind_stacks(
        &mut self,
        undo: Vec<StackItem<HistoryMeta>>,
        redo: Vec<StackItem<HistoryMeta>>,
    ) {
        // Detach old observers before registering the new manager on the same Doc.
        let empty = UndoManager::with_options(yrs::undo::Options::<HistoryMeta>::default());
        drop(std::mem::replace(&mut self.history, empty));
        self.history = UndoManager::with_options(yrs::undo::Options {
            capture_timeout_millis: 0,
            tracked_origins: [LOCAL_ORIGIN.into()].into_iter().collect(),
            init_undo_stack: undo,
            init_redo_stack: redo,
            ..Default::default()
        });
        self.history
            .expand_scope(&self.doc, &self.doc.get_or_insert_map("blocks"));
    }
}

impl HistoryPrototype {
    /// Open an owned SQLite connection at `database_path` for `document_id`.
    /// The parent directory must exist. The cache key is independent from block
    /// IDs. Existing V1 updates restore content, never previous users' history.
    /// Any SQLite/decode failure returns an error before returning a session.
    pub fn open(database_path: impl AsRef<Path>, document_id: &str) -> Result<Self, String> {
        if document_id.trim().is_empty() {
            return Err("HISTORY_DOCUMENT_ID_REQUIRED".into());
        }
        let connection =
            Connection::open(database_path).map_err(|e| format!("HISTORY_DATABASE_OPEN: {e}"))?;
        connection
            .execute_batch(
                "PRAGMA foreign_keys = ON;
                 CREATE TABLE IF NOT EXISTS document_updates (
                   sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                   document_id TEXT NOT NULL,
                   payload BLOB NOT NULL
                 );
                 CREATE INDEX IF NOT EXISTS idx_document_updates_document
                   ON document_updates(document_id, sequence);",
            )
            .map_err(|e| format!("HISTORY_DATABASE_INIT: {e}"))?;
        let options = Options {
            guid: document_id.into(),
            offset_kind: OffsetKind::Utf16,
            skip_gc: true,
            ..Default::default()
        };
        let mut state = NativeState::from_baseline(options, &[])?;
        {
            let mut statement = connection
                .prepare(
                    "SELECT payload FROM document_updates WHERE document_id = ?1 ORDER BY sequence",
                )
                .map_err(|e| format!("HISTORY_CACHE_READ: {e}"))?;
            let updates = statement
                .query_map([document_id], |row| row.get::<_, Vec<u8>>(0))
                .map_err(|e| format!("HISTORY_CACHE_READ: {e}"))?;
            for bytes in updates {
                state.execute(&Action::Remote(
                    bytes.map_err(|e| format!("HISTORY_CACHE_READ: {e}"))?,
                ))?;
            }
        }
        Ok(Self {
            connection,
            document_id: document_id.to_owned(),
            accepted_actions: 0,
            state,
            access: None,
        })
    }

    /// Return local history counts; this does not access SQLite or mutate state.
    pub fn history_state(&self) -> HistoryState {
        self.state.history_state()
    }

    /// Read an existing formal text block by stable `block_id`; missing or
    /// non-text targets return an error without creating a shared type.
    pub fn read_text(&self, block_id: &str) -> Result<String, String> {
        let txn = self.state.doc.transact();
        Ok(text_target(&txn, block_id)?.get_string(&txn))
    }

    /// Encode complete V1 content for an independent peer or reopen comparison.
    /// Local undo history and actor origins are not serialized into shared data.
    pub fn encode_full_update(&self) -> Vec<u8> {
        full_update(&self.state.doc)
    }

    /// Encode the current vector. Deletion-only changes require checking the
    /// returned update as well, because vectors alone do not describe deletes.
    pub fn encode_state_vector(&self) -> Vec<u8> {
        use yrs::updates::encoder::Encode;
        self.state.doc.transact().state_vector().encode_v1()
    }

    /// Apply raw V1 `bytes` as remote/cache content, excluded from user history.
    /// SQLite write or COMMIT failure leaves content, redo and undo untouched.
    /// Returns the actually integrated delta; duplicate echoes produce no delta.
    /// Pending dependency updates are still durably retained in their raw form.
    pub fn apply_remote(&mut self, bytes: &[u8]) -> Result<HistoryChange, String> {
        decode(bytes)?;
        let mut candidate = self.fork()?;
        let action = Action::Remote(bytes.to_vec());
        let generated = candidate.execute(&action)?;
        self.commit(candidate, generated, bytes, true)
    }

    /// Replace `delete_length` UTF-16 units at `index` in the existing `block_id`
    /// with `insert_text`, as one atomic local capture group. Surrogate-splitting,
    /// out-of-range and object-bearing text are rejected in this first prototype.
    /// Unchanged text does not create a group or invalidate redo. SQLite failure
    /// leaves the document, both stacks and accepted action count unchanged.
    pub fn replace_text(
        &mut self,
        block_id: &str,
        index: u32,
        delete_length: u32,
        insert_text: &str,
    ) -> Result<HistoryChange, String> {
        self.local_command(HistoryMeta::target(block_id), |state| {
            let mut txn = state.doc.transact_mut_with(LOCAL_ORIGIN);
            let text = text_target(&txn, block_id)?;
            if text
                .diff(&txn, |_| ())
                .iter()
                .any(|run| !matches!(run.insert, Out::Any(yrs::Any::String(_))))
            {
                return Err("HISTORY_INLINE_OBJECT_NOT_SUPPORTED".into());
            }
            let before = text.get_string(&txn);
            let units: Vec<_> = before.encode_utf16().collect();
            let end = index
                .checked_add(delete_length)
                .filter(|end| *end as usize <= units.len())
                .ok_or("HISTORY_INVALID_RANGE")? as usize;
            for boundary in [index as usize, end] {
                if boundary > 0
                    && boundary < units.len()
                    && (0xd800..=0xdbff).contains(&units[boundary - 1])
                    && (0xdc00..=0xdfff).contains(&units[boundary])
                {
                    return Err("HISTORY_SPLIT_SURROGATE".into());
                }
            }
            if String::from_utf16(&units[index as usize..end]).unwrap() == insert_text {
                return Ok(());
            }
            if delete_length > 0 {
                text.remove_range(&mut txn, index, delete_length);
            }
            if !insert_text.is_empty() {
                text.insert(&mut txn, index, insert_text);
            }
            Ok(())
        })
    }

    /// Selectively undo this session's latest applicable local group. Remote
    /// changes are not added to history. Obsolete groups may be skipped by Yrs;
    /// an empty undo stack is a successful no-op without a database write.
    pub fn undo(&mut self) -> Result<HistoryChange, String> {
        self.history_action(Action::Undo)
    }

    /// Selectively redo this session's latest undone local group. Remote updates
    /// preserve redo; an accepted new local edit invalidates its redo branch.
    pub fn redo(&mut self) -> Result<HistoryChange, String> {
        self.history_action(Action::Redo)
    }

    fn history_action(&mut self, action: Action) -> Result<HistoryChange, String> {
        self.ensure_write_access()?;
        let items = if matches!(action, Action::Undo) {
            self.state.history.undo_stack()
        } else {
            self.state.history.redo_stack()
        };
        if let Some(item) = items.last() {
            self.preflight(item.meta(), &self.state.doc)?;
        }
        let mut candidate = self.fork()?;
        let generated = candidate.execute(&action)?;
        let remaining = if matches!(action, Action::Undo) {
            candidate.history.undo_stack().len()
        } else {
            candidate.history.redo_stack().len()
        };
        // Yrs can skip obsolete items. Validate every consumed group before
        // committing, so skipping cannot bypass an older group's current locks.
        for item in &items[remaining..] {
            self.preflight(item.meta(), &self.state.doc)?;
            self.preflight(item.meta(), &candidate.doc)?;
        }
        policy::validate_candidate(&candidate.doc, self.root_id()?)?;
        policy::check_removals(
            &self.state.doc,
            &candidate.doc,
            self.root_id()?,
            items[remaining..].iter().map(|item| item.meta()),
        )?;
        self.commit(candidate, generated.clone(), &generated, false)
    }

    /// Stage one native local command and attach its affected IDs to its group.
    fn local_command(
        &mut self,
        mut meta: HistoryMeta,
        command: impl FnOnce(&mut NativeState) -> Result<(), String>,
    ) -> Result<HistoryChange, String> {
        self.ensure_write_access()?;
        let graph = policy::Graph::read(&self.state.doc, self.root_id()?)?;
        if meta.targets.iter().any(|id| !graph.nodes.contains_key(id)) {
            return Err("HISTORY_TARGET_NOT_REACHABLE".into());
        }
        self.preflight(&meta, &self.state.doc)?;
        let mut candidate = self.fork()?;
        let generated = candidate.capture(command)?;
        if !generated.is_empty() {
            policy::capture_removal_guards(
                &mut meta,
                &self.state.doc,
                &candidate.doc,
                self.root_id()?,
            )?;
            candidate.set_top_metadata(false, meta.clone());
        }
        self.preflight(&meta, &candidate.doc)?;
        policy::validate_candidate(&candidate.doc, self.root_id()?)?;
        self.commit(candidate, generated.clone(), &generated, false)
    }

    /// Copy exact CRDT identities plus native restoration links. Public stacks
    /// retain their metadata without remapping or re-executing past actions.
    fn fork(&self) -> Result<NativeState, String> {
        let doc = self.state.doc.fork_for_history()?;
        let mut candidate = NativeState {
            history: UndoManager::with_options(yrs::undo::Options::default()),
            doc,
        };
        candidate.bind_stacks(
            self.state.history.undo_stack().to_vec(),
            self.state.history.redo_stack().to_vec(),
        );
        Ok(candidate)
    }

    /// Commit the exact update before swapping the complete candidate. No borrowed
    /// transaction or native handle escapes this boundary, and no network callback
    /// is fired. Failed SQLite statements/COMMIT roll back before candidate drop.
    fn commit(
        &mut self,
        candidate: NativeState,
        generated: Vec<u8>,
        persisted: &[u8],
        retain_remote: bool,
    ) -> Result<HistoryChange, String> {
        let history = candidate.history_state();
        if !persisted.is_empty() {
            let transaction = self
                .connection
                .transaction()
                .map_err(|e| format!("HISTORY_PERSIST_BEGIN: {e}"))?;
            transaction
                .execute(
                    "INSERT INTO document_updates(document_id, payload) VALUES (?1, ?2)",
                    params![self.document_id, persisted],
                )
                .map_err(|e| format!("HISTORY_PERSIST_WRITE: {e}"))?;
            transaction
                .commit()
                .map_err(|e| format!("HISTORY_PERSIST_COMMIT: {e}"))?;
        }
        let changed = !generated.is_empty();
        if changed || history != self.history_state() || retain_remote {
            self.accepted_actions += 1;
            self.state = candidate;
        }
        Ok(HistoryChange {
            v1_update: generated,
            changed,
            history,
        })
    }
}

fn text_target(txn: &impl ReadTxn, block_id: &str) -> Result<yrs::TextRef, String> {
    let blocks = txn.get_map("blocks").ok_or("HISTORY_BLOCKS_MISSING")?;
    let block = match blocks.get(txn, block_id) {
        Some(Out::YMap(block)) => block,
        _ => return Err("HISTORY_TARGET_MISSING".into()),
    };
    match block.get(txn, "children") {
        Some(Out::YText(text)) => Ok(text),
        _ => Err("HISTORY_TARGET_NOT_TEXT".into()),
    }
}

fn decode(bytes: &[u8]) -> Result<Update, String> {
    Update::decode_v1(bytes).map_err(|e| format!("HISTORY_INVALID_UPDATE: {e}"))
}

fn full_update(doc: &Doc) -> Vec<u8> {
    doc.transact()
        .encode_state_as_update_v1(&StateVector::default())
}

#[cfg(test)]
#[path = "history_prototype_tests.rs"]
mod tests;
