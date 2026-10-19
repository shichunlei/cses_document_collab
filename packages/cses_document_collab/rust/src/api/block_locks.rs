//! Desktop-compatible persistent locks. The reachable Yrs graph is authoritative;
//! Flutter receives derived state and never supplies writable lock metadata.
use super::collab::*;
use std::collections::{HashMap, HashSet};
use yrs::{Map, MapRef, Out, ReadTxn, Transact};

/// A reachable block's effective lock and subtree protection, including hidden children.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CollabBlockLock {
    /// Stable block identity, including infrastructure/container blocks.
    pub block_id: String,
    /// Nearest self/ancestor lock source; None means this block is writable.
    pub source_id: Option<String>,
    /// Nonempty desktop meta.lock owner, preserved without trimming its identity.
    pub owner_id: Option<String>,
    /// True only for meta.lockKind == template on the effective lock source.
    pub template: bool,
    /// Whether any explicit lock exists in this block's reachable subtree.
    pub contains_lock: bool,
}

/// Return an existing nested map without creating shared data.
fn map<T: ReadTxn>(parent: &MapRef, txn: &T, key: &str) -> Option<MapRef> {
    match parent.get(txn, key) {
        Some(Out::YMap(map)) => Some(map),
        _ => None,
    }
}

/// Read only desktop's nonempty string owner; legacy readonly bits are ignored.
fn owner<T: ReadTxn>(meta: &MapRef, txn: &T) -> Option<String> {
    match meta.get(txn, "lock") {
        Some(Out::Any(yrs::Any::String(value))) if !value.trim().is_empty() => {
            Some(value.to_string())
        }
        _ => None,
    }
}

/// Scan the complete reachable graph, preserving inherited locks in opaque subtrees.
pub(super) fn scan(doc: &yrs::Doc, root_id: &str) -> Vec<CollabBlockLock> {
    use yrs::Array;
    let txn = doc.transact();
    let Some(blocks) = txn.get_map("blocks") else {
        return Vec::new();
    };
    let mut stack = vec![(
        root_id.to_owned(),
        None::<(String, String, bool)>,
        None::<usize>,
    )];
    let mut seen = HashSet::new();
    let mut result: Vec<CollabBlockLock> = Vec::new();
    let mut parents = Vec::new();
    while let Some((id, inherited, parent)) = stack.pop() {
        if !seen.insert(id.clone()) {
            continue;
        }
        let Some(block) = map(&blocks, &txn, &id) else {
            continue;
        };
        let own = if id == root_id {
            None
        } else {
            map(&block, &txn, "meta").and_then(|meta| owner(&meta, &txn).map(|user| {
                let template = matches!(meta.get(&txn, "lockKind"), Some(Out::Any(yrs::Any::String(v))) if &*v == "template");
                (id.clone(), user, template)
            }))
        };
        let effective = own.clone().or(inherited);
        let index = result.len();
        result.push(CollabBlockLock {
            block_id: id,
            source_id: effective.as_ref().map(|v| v.0.clone()),
            owner_id: effective.as_ref().map(|v| v.1.clone()),
            template: effective.as_ref().is_some_and(|v| v.2),
            contains_lock: own.is_some(),
        });
        parents.push(parent);
        if let Some(Out::YArray(children)) = block.get(&txn, "children") {
            for child in children.iter(&txn).collect::<Vec<_>>().into_iter().rev() {
                if let Out::Any(yrs::Any::String(id)) = child {
                    stack.push((id.to_string(), effective.clone(), Some(index)));
                }
            }
        }
    }
    for i in (0..result.len()).rev() {
        if result[i].contains_lock {
            if let Some(parent) = parents[i] {
                result[parent].contains_lock = true;
            }
        }
    }
    result
}

/// Reject protected local changes before the first staged write. Derived numbering
/// may change when writable siblings are inserted, but user props and text may not.
pub(super) fn preflight(
    doc: &yrs::Doc,
    root: &str,
    previous: &[CollabBlock],
    desired: &[CollabBlock],
) -> Result<(), String> {
    let states = scan(doc, root);
    let locks: HashMap<_, _> = states.iter().map(|v| (v.block_id.as_str(), v)).collect();
    let next: HashMap<_, _> = desired.iter().map(|v| (v.id.as_str(), v)).collect();
    let old: HashMap<_, _> = previous.iter().map(|v| (v.id.as_str(), v)).collect();
    let reject = || "READ_ONLY_BLOCK: 内容已锁定，无法修改".to_owned();
    for block in previous {
        let Some(state) = locks.get(block.id.as_str()) else {
            continue;
        };
        if state.source_id.is_none() && !state.contains_lock {
            continue;
        }
        let Some(target) = next.get(block.id.as_str()) else {
            return Err(reject());
        };
        if block.parent_id != target.parent_id
            || block.block_type != target.block_type
            || target.replaces_id.is_some()
        {
            return Err(reject());
        }
        if state.source_id.is_some() {
            let mut normalized = (*target).clone();
            if let (Some(a), Some(b)) = (&mut normalized.ordered, &block.ordered) {
                a.order = b.order;
                a.needs_repair = b.needs_repair;
            }
            if &normalized != block {
                return Err(reject());
            }
            let before: Vec<_> = previous
                .iter()
                .filter(|b| b.parent_id.as_deref() == Some(&block.id))
                .map(|b| &b.id)
                .collect();
            let after: Vec<_> = desired
                .iter()
                .filter(|b| b.parent_id.as_deref() == Some(&block.id))
                .map(|b| &b.id)
                .collect();
            if before != after {
                return Err(reject());
            }
        }
        // Inserts/removals before a protected block are safe. Reordering existing
        // siblings around it is conservatively rejected at the snapshot boundary.
        let before: Vec<_> = previous
            .iter()
            .filter(|b| b.parent_id == block.parent_id && next.contains_key(b.id.as_str()))
            .map(|b| b.id.as_str())
            .collect();
        let after: Vec<_> = desired
            .iter()
            .filter(|b| b.parent_id == block.parent_id && old.contains_key(b.id.as_str()))
            .map(|b| b.id.as_str())
            .collect();
        let split = |ids: Vec<&str>| {
            ids.into_iter()
                .take_while(|id| *id != block.id)
                .map(str::to_owned)
                .collect::<HashSet<_>>()
        };
        if split(before) != split(after) {
            return Err(reject());
        }
        // Captions are projected inside their image rather than as Flutter nodes.
        if let Some(image) = &block.image {
            for caption in &image.captions {
                if locks
                    .get(caption.id.as_str())
                    .is_some_and(|v| v.source_id.is_some())
                    && !target
                        .image
                        .as_ref()
                        .is_some_and(|v| v.captions.contains(caption))
                {
                    return Err(reject());
                }
            }
        }
    }
    for block in desired {
        if !old.contains_key(block.id.as_str())
            && block
                .parent_id
                .as_deref()
                .and_then(|id| locks.get(id))
                .is_some_and(|v| v.source_id.is_some())
        {
            return Err(reject());
        }
    }
    Ok(())
}

/// Change only lock metadata after rechecking the latest owner and source. The
/// trusted host supplies current identity and additional unlock authorization.
pub(super) fn set(
    doc: &yrs::Doc,
    root: &str,
    block_id: &str,
    locked: bool,
    user_id: &str,
    grant: bool,
    expected_owner: Option<&str>,
    expected_template: bool,
) -> Result<(), String> {
    if user_id.trim().is_empty() || block_id == root {
        return Err("BLOCK_LOCK_DENIED: 未识别当前用户或根块不可锁定".into());
    }
    let states = scan(doc, root);
    let state = states
        .iter()
        .find(|v| v.block_id == block_id)
        .ok_or("BLOCK_LOCK_STALE: 内容已删除")?;
    let explicit = state.source_id.as_deref() == Some(block_id);
    let current_owner = if explicit {
        state.owner_id.as_deref()
    } else {
        None
    };
    if current_owner != expected_owner || (explicit && state.template != expected_template) {
        return Err("BLOCK_LOCK_STALE: 锁状态已更新，请重新选择".into());
    }
    if state.source_id.is_some() && !explicit {
        return Err("BLOCK_LOCK_DENIED: 请在上级内容块解除锁定".into());
    }
    if locked && explicit {
        return Ok(());
    }
    if !locked && !explicit {
        return Ok(());
    }
    if !locked && !(grant || (!state.template && current_owner == Some(user_id))) {
        return Err("BLOCK_LOCK_DENIED: 无权解除锁定".into());
    }
    let mut txn = doc.transact_mut();
    let blocks = txn
        .get_map("blocks")
        .ok_or("BLOCK_LOCK_STALE: 文档未初始化")?;
    let block = map(&blocks, &txn, block_id).ok_or("BLOCK_LOCK_STALE: 内容已删除")?;
    let meta = map(&block, &txn, "meta").ok_or("BLOCK_LOCK_STALE: 块元数据无效")?;
    if locked {
        meta.insert(&mut txn, "lock", user_id);
        meta.remove(&mut txn, "lockKind");
    } else {
        meta.remove(&mut txn, "lock");
        meta.remove(&mut txn, "lockKind");
    }
    Ok(())
}
