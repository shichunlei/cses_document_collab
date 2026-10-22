//! Native command boundaries; shared maps and arrays are edited in one transaction.

use super::yrs;
use super::*;
use yrs::types::Attrs;
use yrs::{Any, Array, ArrayPrelim, MapPrelim, TextPrelim, TransactionMut};

/// Validate UTF-16 range boundaries without splitting a surrogate pair.
fn text_range(
    text: &yrs::TextRef,
    txn: &impl ReadTxn,
    index: u32,
    length: u32,
) -> Result<(), String> {
    if text
        .diff(txn, |_| ())
        .iter()
        .any(|run| !matches!(run.insert, Out::Any(Any::String(_))))
    {
        return Err("HISTORY_INLINE_OBJECT_NOT_SUPPORTED".into());
    }
    let units: Vec<_> = text.get_string(txn).encode_utf16().collect();
    let end = index
        .checked_add(length)
        .filter(|end| *end as usize <= units.len())
        .ok_or("HISTORY_INVALID_RANGE")?;
    for boundary in [index as usize, end as usize] {
        if boundary > 0
            && boundary < units.len()
            && (0xd800..=0xdbff).contains(&units[boundary - 1])
            && (0xdc00..=0xdfff).contains(&units[boundary])
        {
            return Err("HISTORY_SPLIT_SURROGATE".into());
        }
    }
    Ok(())
}

fn array_target(txn: &impl ReadTxn, id: &str) -> Result<yrs::ArrayRef, String> {
    let blocks = txn.get_map("blocks").ok_or("HISTORY_BLOCKS_MISSING")?;
    let block = policy::block_map(&blocks, txn, id)?;
    match block.get(txn, "children") {
        Some(Out::YArray(array)) => Ok(array),
        _ => Err("HISTORY_TARGET_NOT_CONTAINER".into()),
    }
}

fn metadata_for_structure(
    graph: &policy::Graph,
    id: &str,
    destination: Option<&str>,
) -> Result<HistoryMeta, String> {
    let node = graph.nodes.get(id).ok_or("HISTORY_TARGET_NOT_REACHABLE")?;
    let parent = node.parent.as_ref().ok_or("HISTORY_ROOT_PROTECTED")?;
    let mut meta = HistoryMeta::target(id);
    meta.targets.insert(parent.clone());
    if let Some(destination) = destination {
        meta.targets.insert(destination.to_owned());
    }
    meta.subtrees.insert(id.to_owned());
    Ok(meta)
}

impl HistoryPrototype {
    /// Apply inline `attributes` to `length` UTF-16 units starting at `index`
    /// in `block_id`. Null removes the given mark. Common `a:*` toggles and
    /// `s:*` visual string attributes are supported; unknown keys are rejected.
    /// Unspecified marks and remote formatting are preserved. One call is one
    /// group; invalid ranges, locks, access or SQLite failure leave state intact.
    pub fn format_text(
        &mut self,
        block_id: &str,
        index: u32,
        length: u32,
        attributes: Attrs,
    ) -> Result<HistoryChange, String> {
        if attributes
            .iter()
            .any(|(key, value)| !valid_inline_property(key, value))
        {
            return Err("HISTORY_INVALID_FORMAT".into());
        }
        self.local_command(HistoryMeta::target(block_id), move |state| {
            let mut txn = state.doc.transact_mut_with(LOCAL_ORIGIN);
            let text = text_target(&txn, block_id)?;
            text_range(&text, &txn, index, length)?;
            if length > 0 && !attributes.is_empty() {
                text.format(&mut txn, index, length, attributes);
            }
            Ok(())
        })
    }

    /// Patch individual paragraph `properties` on `block_id`, without replacing
    /// its props map. None removes a key; Some(Null) preserves explicit null.
    /// Supports heading 0..6, depth 0..6, textAlign and desktop paragraph style
    /// fields (textDefaults, nextParagraphStyle, fs/pfs/lh/psb/psa/decoration).
    /// Unknown props remain untouched; lock/meta keys cannot
    /// be patched through this API. The whole patch is a single undo group.
    pub fn patch_paragraph_properties(
        &mut self,
        block_id: &str,
        properties: std::collections::BTreeMap<String, Option<Any>>,
    ) -> Result<HistoryChange, String> {
        for (key, value) in &properties {
            let allowed = [
                "heading",
                "depth",
                "textAlign",
                "fs",
                "pfs",
                "lh",
                "psb",
                "psa",
                "decoration",
                "textDefaults",
                "nextParagraphStyle",
            ]
            .contains(&key.as_str());
            let valid = match (key.as_str(), value) {
                (_, None | Some(Any::Null)) => allowed,
                ("heading" | "depth", Some(Any::Number(v))) => {
                    v.is_finite() && v.fract() == 0.0 && (0.0..=6.0).contains(v)
                }
                ("textAlign", Some(Any::String(v))) => {
                    ["left", "right", "center", "justify"].contains(&v.as_ref())
                }
                ("fs" | "pfs" | "lh" | "psb" | "psa", Some(Any::Number(v))) => v.is_finite(),
                ("fs" | "pfs" | "lh" | "psb" | "psa", Some(Any::String(_))) => true,
                ("decoration", Some(Any::String(_) | Any::Map(_) | Any::Array(_))) => true,
                ("textDefaults", Some(Any::Map(values))) => values
                    .iter()
                    .all(|(key, value)| key != "a:link" && valid_inline_property(key, value)),
                ("nextParagraphStyle", Some(Any::String(value))) => {
                    ["same", "body"].contains(&value.as_ref())
                }
                _ => false,
            };
            if !valid {
                return Err("HISTORY_INVALID_PARAGRAPH_PROPERTY".into());
            }
        }
        self.local_command(HistoryMeta::target(block_id), move |state| {
            let mut txn = state.doc.transact_mut_with(LOCAL_ORIGIN);
            let blocks = txn.get_map("blocks").ok_or("HISTORY_BLOCKS_MISSING")?;
            let block = policy::block_map(&blocks, &txn, block_id)?;
            if block.get(&txn, "flavour") != Some(Out::Any(Any::from("paragraph"))) {
                return Err("HISTORY_TARGET_NOT_PARAGRAPH".into());
            }
            let props = policy::block_map(&block, &txn, "props")?;
            for (key, value) in properties {
                match value {
                    Some(value) => {
                        props.try_update(&mut txn, key, value);
                    }
                    None => {
                        props.remove(&mut txn, &key);
                    }
                }
            }
            Ok(())
        })
    }

    /// Insert a new editable paragraph `block_id` with plain `text` into
    /// `parent_id` at child `index` (0..=child count), as one undo group.
    /// The caller supplies a globally fresh stable ID and must never reuse IDs
    /// from deleted documents. Existing or session-history IDs are rejected.
    /// Parent must be root/callout; unsupported container schemas are rejected.
    pub fn insert_paragraph(
        &mut self,
        parent_id: &str,
        index: u32,
        block_id: &str,
        text: &str,
    ) -> Result<HistoryChange, String> {
        self.insert_native_block(parent_id, index, block_id, Some(text))
    }

    /// Insert an empty callout container `block_id` into `parent_id` at
    /// child `index`, as one undo group. IDs obey [Self::insert_paragraph]'s
    /// freshness contract. Only root/callout parents are supported initially.
    pub fn insert_callout(
        &mut self,
        parent_id: &str,
        index: u32,
        block_id: &str,
    ) -> Result<HistoryChange, String> {
        self.insert_native_block(parent_id, index, block_id, None)
    }

    fn insert_native_block(
        &mut self,
        parent_id: &str,
        index: u32,
        block_id: &str,
        text: Option<&str>,
    ) -> Result<HistoryChange, String> {
        if block_id.trim().is_empty()
            || self
                .state
                .history
                .undo_stack()
                .iter()
                .chain(self.state.history.redo_stack())
                .any(|item| {
                    item.meta().targets.contains(block_id)
                        || item.meta().subtrees.contains(block_id)
                })
        {
            return Err("HISTORY_ID_NOT_FRESH".into());
        }
        let mut meta = HistoryMeta::target(parent_id);
        meta.subtrees.insert(block_id.to_owned());
        self.local_command(meta, |state| {
            let mut txn = state.doc.transact_mut_with(LOCAL_ORIGIN);
            let blocks = txn.get_map("blocks").ok_or("HISTORY_BLOCKS_MISSING")?;
            if blocks.contains_key(&txn, block_id) {
                return Err("HISTORY_ID_NOT_FRESH".into());
            }
            check_parent(&blocks, &txn, parent_id)?;
            let array = array_target(&txn, parent_id)?;
            if index > array.len(&txn) {
                return Err("HISTORY_INVALID_CHILD_INDEX".into());
            }
            let block = blocks.insert(&mut txn, block_id, MapPrelim::default());
            block.insert(&mut txn, "id", block_id);
            block.insert(
                &mut txn,
                "flavour",
                if text.is_some() {
                    "paragraph"
                } else {
                    "callout"
                },
            );
            block.insert(
                &mut txn,
                "nodeType",
                if text.is_some() { "editable" } else { "block" },
            );
            block.insert(&mut txn, "props", MapPrelim::default());
            block.insert(&mut txn, "meta", MapPrelim::default());
            if let Some(text) = text {
                block.insert(&mut txn, "children", TextPrelim::new(text));
            } else {
                block.insert(&mut txn, "children", ArrayPrelim::default());
            }
            array.insert(&mut txn, index, block_id);
            Ok(())
        })
    }

    /// Delete reachable `block_id` and its complete native subtree in one group.
    /// Root deletion and any locked descendant are rejected. Native undo restores
    /// maps, unknown props/meta and formatting; it never rebuilds a projection.
    /// Only root/callout child lists can be changed by this prototype.
    pub fn delete_block(&mut self, block_id: &str) -> Result<HistoryChange, String> {
        let graph = policy::Graph::read(&self.state.doc, self.root_id()?)?;
        let meta = metadata_for_structure(&graph, block_id, None)?;
        let parent = graph.nodes[block_id].parent.as_ref().unwrap();
        let index = graph.nodes[parent]
            .children
            .iter()
            .position(|id| id == block_id)
            .unwrap() as u32;
        self.local_command(meta, |state| {
            let mut txn = state.doc.transact_mut_with(LOCAL_ORIGIN);
            let blocks = txn.get_map("blocks").ok_or("HISTORY_BLOCKS_MISSING")?;
            check_parent(&blocks, &txn, parent)?;
            array_target(&txn, parent)?.remove_range(&mut txn, index, 1);
            for id in graph.subtree(block_id).into_iter().rev() {
                blocks.remove(&mut txn, &id);
            }
            Ok(())
        })
    }

    /// Move reachable `block_id` into `parent_id` at `index` measured after the
    /// old occurrence is removed. The transaction preserves the block's shared
    /// map/text identity. Root, cycles, unsupported parents and locks are rejected.
    /// Only paragraphs/callouts can move, between root/callout child lists;
    /// specialized table, media and root-only placement rules are not exposed.
    /// Concurrent competing moves that would create duplicate references during
    /// undo return a structure conflict, leaving content and history untouched.
    pub fn move_block(
        &mut self,
        block_id: &str,
        parent_id: &str,
        index: u32,
    ) -> Result<HistoryChange, String> {
        let graph = policy::Graph::read(&self.state.doc, self.root_id()?)?;
        let meta = metadata_for_structure(&graph, block_id, Some(parent_id))?;
        if graph.subtree(block_id).iter().any(|id| id == parent_id) {
            return Err("HISTORY_MOVE_CYCLE".into());
        }
        let parent = graph.nodes[block_id].parent.as_ref().unwrap();
        let old_index = graph.nodes[parent]
            .children
            .iter()
            .position(|id| id == block_id)
            .unwrap() as u32;
        self.local_command(meta, |state| {
            let mut txn = state.doc.transact_mut_with(LOCAL_ORIGIN);
            let blocks = txn.get_map("blocks").ok_or("HISTORY_BLOCKS_MISSING")?;
            check_parent(&blocks, &txn, parent)?;
            check_parent(&blocks, &txn, parent_id)?;
            let block = policy::block_map(&blocks, &txn, block_id)?;
            if !matches!(block.get(&txn, "flavour"), Some(Out::Any(Any::String(kind))) if kind.as_ref() == "paragraph" || kind.as_ref() == "callout") {
                return Err("HISTORY_UNSUPPORTED_MOVE_SCHEMA".into());
            }
            let source = array_target(&txn, parent)?;
            let dest = array_target(&txn, parent_id)?;
            let length = dest.len(&txn) - u32::from(parent == parent_id);
            if index > length {
                return Err("HISTORY_INVALID_CHILD_INDEX".into());
            }
            if parent == parent_id && index == old_index {
                return Ok(());
            }
            source.remove_range(&mut txn, old_index, 1);
            dest.insert(&mut txn, index, block_id);
            Ok(())
        })
    }
}

/// Desktop inline keys accepted by explicit formatting and paragraph defaults.
fn valid_inline_property(key: &str, value: &Any) -> bool {
    match key {
        "a:bold" | "a:italic" | "a:underline" | "a:strike" | "a:code" | "a:sup" | "a:sub" => {
            matches!(value, Any::Bool(_) | Any::Null)
        }
        "s:color" | "s:background" | "s:fontSize" | "s:fontWeight" | "s:fontFamily"
        | "s:letterSpacing" | "a:link" => matches!(value, Any::String(_) | Any::Null),
        "t:ff" | "t:px" | "t:fs" | "t:ls" => match value {
            Any::Number(v) => v.is_finite(),
            Any::String(_) | Any::Null => true,
            _ => false,
        },
        _ => false,
    }
}

/// Restrict new placements to container schemas covered by this prototype.
fn check_parent(blocks: &yrs::MapRef, txn: &TransactionMut<'_>, id: &str) -> Result<(), String> {
    let parent = policy::block_map(blocks, txn, id)?;
    if matches!(parent.get(txn, "flavour"), Some(Out::Any(Any::String(flavour))) if flavour.as_ref() == "root" || flavour.as_ref() == "callout")
    {
        Ok(())
    } else {
        Err("HISTORY_UNSUPPORTED_PARENT_SCHEMA".into())
    }
}
