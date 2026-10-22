//! Current host access and full reachable-graph lock checks for staged commands.

use super::yrs;
use super::*;
use std::collections::BTreeMap;
use yrs::{types::ToJson, Any, Array, MapRef};

/// Reachable stable identities and child-list ownership, including opaque nodes.
pub(super) struct Graph {
    pub nodes: BTreeMap<String, Node>,
}

pub(super) struct Node {
    pub parent: Option<String>,
    pub children: Vec<String>,
    locked: bool,
}

impl Graph {
    /// Scan every reachable child, rejecting cycles, aliases and missing nodes.
    pub fn read(doc: &Doc, root: &str) -> Result<Self, String> {
        let txn = doc.transact();
        let blocks = txn.get_map("blocks").ok_or("HISTORY_BLOCKS_MISSING")?;
        let mut nodes = BTreeMap::new();
        let mut pending = vec![(root.to_owned(), None, 0)];
        while let Some((id, parent, depth)) = pending.pop() {
            if depth > 256 || nodes.len() >= 100_000 || nodes.contains_key(&id) {
                return Err("HISTORY_STRUCTURE_CONFLICT: cycle, duplicate or graph limit".into());
            }
            let block = block_map(&blocks, &txn, &id)?;
            if id == root
                && (block.get(&txn, "flavour") != Some(Out::Any(Any::from("root")))
                    || block.get(&txn, "nodeType") != Some(Out::Any(Any::from("root"))))
            {
                return Err("HISTORY_INVALID_ROOT".into());
            }
            if block.get(&txn, "id") != Some(Out::Any(Any::from(id.clone()))) {
                return Err("HISTORY_STRUCTURE_CONFLICT: invalid stable identity".into());
            }
            let children = match block.get(&txn, "children") {
                Some(Out::YArray(array)) => array
                    .iter(&txn)
                    .map(|v| {
                        if let Out::Any(Any::String(id)) = v {
                            Ok(id.to_string())
                        } else {
                            Err("HISTORY_STRUCTURE_CONFLICT: non-ID child".to_owned())
                        }
                    })
                    .collect::<Result<Vec<_>, _>>()?,
                Some(Out::YText(_)) | None => Vec::new(),
                _ => return Err("HISTORY_STRUCTURE_CONFLICT: invalid children".into()),
            };
            let locked = if id == root {
                false
            } else {
                match block.get(&txn, "meta") {
                    Some(Out::YMap(meta)) => {
                        matches!(meta.get(&txn, "lock"), Some(Out::Any(Any::String(owner))) if !owner.trim().is_empty())
                    }
                    _ => false,
                }
            };
            for child in children.iter().rev() {
                pending.push((child.clone(), Some(id.clone()), depth + 1));
            }
            nodes.insert(
                id,
                Node {
                    parent,
                    children,
                    locked,
                },
            );
        }
        Ok(Self { nodes })
    }

    pub fn subtree(&self, id: &str) -> Vec<String> {
        let mut result = Vec::new();
        let mut pending = vec![id.to_owned()];
        while let Some(id) = pending.pop() {
            if let Some(node) = self.nodes.get(&id) {
                pending.extend(node.children.iter().cloned());
                result.push(id);
            }
        }
        result
    }

    fn inherited_lock(&self, id: &str) -> bool {
        let mut current = self.nodes.get(id);
        while let Some(node) = current {
            if node.locked {
                return true;
            }
            current = node.parent.as_ref().and_then(|id| self.nodes.get(id));
        }
        false
    }
}

/// Look up an existing map without creating or replacing shared data.
pub(super) fn block_map(parent: &MapRef, txn: &impl ReadTxn, id: &str) -> Result<MapRef, String> {
    match parent.get(txn, id) {
        Some(Out::YMap(map)) => Ok(map),
        _ => Err(format!("HISTORY_TARGET_MISSING: {id}")),
    }
}

pub(super) fn validate_candidate(doc: &Doc, root: &str) -> Result<(), String> {
    Graph::read(doc, root).map(|_| ())
}

fn shared_value(doc: &Doc, id: &str) -> Result<serde_json::Value, String> {
    let txn = doc.transact();
    let blocks = txn.get_map("blocks").ok_or("HISTORY_BLOCKS_MISSING")?;
    serde_json::to_value(block_map(&blocks, &txn, id)?.to_json(&txn))
        .map_err(|e| format!("HISTORY_GUARD_ENCODING: {e}"))
}

/// Record the full native values of nodes created/deleted by a command.
pub(super) fn capture_removal_guards(
    meta: &mut HistoryMeta,
    before: &Doc,
    after: &Doc,
    root: &str,
) -> Result<(), String> {
    let previous = Graph::read(before, root)?;
    let next = Graph::read(after, root)?;
    for id in previous
        .nodes
        .keys()
        .filter(|id| !next.nodes.contains_key(*id))
    {
        meta.removable.insert(id.clone(), shared_value(before, id)?);
    }
    for id in next
        .nodes
        .keys()
        .filter(|id| !previous.nodes.contains_key(*id))
    {
        meta.removable.insert(id.clone(), shared_value(after, id)?);
    }
    Ok(())
}

/// Do not hide remote text, properties or children by undoing a local insertion
/// (or redoing a deletion) after collaborators have contributed to that subtree.
pub(super) fn check_removals<'a>(
    before: &Doc,
    after: &Doc,
    root: &str,
    items: impl Iterator<Item = &'a HistoryMeta>,
) -> Result<(), String> {
    let previous = Graph::read(before, root)?;
    let next = Graph::read(after, root)?;
    let guards: BTreeMap<_, _> = items.flat_map(|meta| meta.removable.iter()).collect();
    for id in previous
        .nodes
        .keys()
        .filter(|id| !next.nodes.contains_key(*id))
    {
        if guards.get(id).copied() != Some(&shared_value(before, id)?) {
            return Err(format!(
                "HISTORY_STRUCTURE_CONFLICT: remote contributions in {id}"
            ));
        }
    }
    Ok(())
}

impl HistoryPrototype {
    /// Install the trusted host's current document access snapshot.
    ///
    /// `root_id` is the formal root block ID (not the SQLite cache key).
    /// `can_write` controls local commands and undo/redo, never remote delivery.
    /// Sessions start read-only; the root cannot be rebound once installed.
    /// Revocation succeeds even if remote data has made the graph invalid.
    /// This does not mutate shared data, grant unlock authority or clear history.
    pub fn set_write_access(&mut self, root_id: &str, can_write: bool) -> Result<(), String> {
        if root_id.trim().is_empty() {
            return Err("HISTORY_ROOT_REQUIRED".into());
        }
        if self
            .access
            .as_ref()
            .is_some_and(|(root, _)| root != root_id)
        {
            return Err("HISTORY_ROOT_MISMATCH".into());
        }
        if can_write {
            validate_candidate(&self.state.doc, root_id)?;
        }
        self.access = Some((root_id.to_owned(), can_write));
        Ok(())
    }

    pub(super) fn root_id(&self) -> Result<&str, String> {
        self.access
            .as_ref()
            .map(|(id, _)| id.as_str())
            .ok_or("HISTORY_ACCESS_REQUIRED".into())
    }

    pub(super) fn ensure_write_access(&self) -> Result<(), String> {
        if !self.access.as_ref().is_some_and(|(_, writable)| *writable) {
            return Err("HISTORY_READ_ONLY".into());
        }
        let txn = self.state.doc.transact();
        if txn
            .get_map("bc:revisions")
            .is_some_and(|revisions| revisions.len(&txn) > 0)
        {
            return Err("HISTORY_UNSUPPORTED_REVISIONS".into());
        }
        Ok(())
    }

    /// Validate affected IDs against the latest full graph, including unprojected
    /// descendants. Deleted history targets are absent; surviving ancestors and
    /// the restored candidate are checked separately before any database write.
    pub(super) fn preflight(&self, meta: &HistoryMeta, doc: &Doc) -> Result<(), String> {
        let graph = Graph::read(doc, self.root_id()?)?;
        for id in &meta.targets {
            if graph.inherited_lock(id) {
                return Err(format!("HISTORY_LOCKED: {id}"));
            }
        }
        for id in &meta.subtrees {
            if graph
                .subtree(id)
                .iter()
                .any(|child| graph.inherited_lock(child))
            {
                return Err(format!("HISTORY_LOCKED_SUBTREE: {id}"));
            }
        }
        Ok(())
    }
}
