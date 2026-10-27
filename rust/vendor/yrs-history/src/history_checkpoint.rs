//! Local-only checkpoint extension. No runtime links are added to the wire format.

use crate::updates::decoder::Decode;
use crate::{Doc, OffsetKind, ReadTxn, StateVector, Transact, Update};

impl crate::StickyIndex {
    /// Resolve this bookmark against `txn`, preserving its UTF-16 offset inside
    /// a restored chunk at every native redone link. The ordinary resolver in
    /// upstream 0.27.4 follows the restored item start and loses that offset.
    /// This read-only extension returns None for missing or excessively deep
    /// histories; it does not change the wire format or native undo algorithm.
    pub fn get_history_offset<T: ReadTxn>(&self, txn: &T) -> Option<crate::sticky_index::Offset> {
        if let crate::IndexScope::Relative(id) = self.scope() {
            let mut id = *id;
            for _ in 0..100_000 {
                let slice = txn.store().blocks.get_item_clean_start(&id)?;
                if let Some(redone) = slice.ptr.redone {
                    id = crate::ID::new(redone.client, redone.clock + slice.start);
                } else {
                    return crate::StickyIndex::from_id(id, self.assoc).get_offset(txn);
                }
            }
            None
        } else {
            self.get_offset(txn)
        }
    }
}

impl Doc {
    /// Copy a UTF-16, GC-disabled document, including native undo restoration links.
    ///
    /// The returned document has independent storage, the same actor and GUID,
    /// and no subscriptions or UndoManager. Only one copy may publish new edits.
    /// The caller must discard an unsuccessful candidate before making another.
    /// Subdocuments and GC-enabled documents are rejected. Source storage is
    /// borrowed read-only; any error discards only the new candidate.
    ///
    /// ```no_run
    /// use yrs::{Doc, Options, OffsetKind};
    /// let source = Doc::with_options(Options {
    ///     skip_gc: true, offset_kind: OffsetKind::Utf16, ..Default::default()
    /// });
    /// let candidate = source.fork_for_history()?;
    /// drop(candidate);
    /// # Ok::<(), String>(())
    /// ```
    pub fn fork_for_history(&self) -> Result<Doc, String> {
        let source = self.transact();
        if !source.store().skip_gc
            || source.store().offset_kind != OffsetKind::Utf16
            || !source.store().subdocs.is_empty()
        {
            return Err("HISTORY_CHECKPOINT_UNSUPPORTED_OPTIONS".into());
        }
        let candidate = Doc::with_options(self.store.options().as_ref().clone());
        let bytes = source.encode_state_as_update_v1(&StateVector::default());
        {
            let mut target = candidate.transact_mut();
            target
                .apply_update(Update::decode_v1(&bytes).map_err(|e| e.to_string())?)
                .map_err(|e| e.to_string())?;
            for (_, blocks) in source.store().blocks.iter() {
                for block in blocks.iter() {
                    let Some(item) = block.as_item() else {
                        continue;
                    };
                    let Some(redone) = item.redone else { continue };
                    let mut clock = 0;
                    while clock < item.len() {
                        let mut id = item.id;
                        id.clock += clock;
                        let mut slice = target
                            .store
                            .blocks
                            .get_item_clean_start(&id)
                            .ok_or("HISTORY_CHECKPOINT_MISSING_ITEM")?;
                        let length = slice.len().min(item.len() - clock);
                        slice.end = slice.start + length - 1;
                        let mut restored = target.store.materialize(slice);
                        restored.redone = Some(crate::ID::new(redone.client, redone.clock + clock));
                        clock += length;
                    }
                }
            }
        }
        Ok(candidate)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{GetString, Map, MapPrelim, Options, Text, TextPrelim, UndoManager};

    #[test]
    fn bookmark_retains_inner_utf16_offset_through_repeated_redo_and_forks() {
        let mut doc = Doc::with_options(Options {
            skip_gc: true,
            offset_kind: OffsetKind::Utf16,
            ..Default::default()
        });
        let text = doc.get_or_insert_text("body");
        let mut manager = UndoManager::with_options(crate::undo::Options {
            capture_timeout_millis: 0,
            ..Default::default()
        });
        manager.expand_scope(&doc, &text);
        text.insert(&mut doc.transact_mut(), 0, "你好😀结尾");
        let bookmark = {
            let txn = doc.transact();
            crate::StickyIndex::at(
                &txn,
                crate::branch::BranchPtr::from(
                    <crate::TextRef as AsRef<crate::branch::Branch>>::as_ref(&text),
                ),
                4,
                crate::Assoc::Before,
            )
            .unwrap()
        };
        for _ in 0..4 {
            assert!(manager.undo_blocking());
            assert!(manager.redo_blocking());
            assert_eq!(
                bookmark.get_history_offset(&doc.transact()).unwrap().index,
                4
            );
            let next = doc.fork_for_history().unwrap();
            let mut next_manager = UndoManager::with_options(crate::undo::Options {
                capture_timeout_millis: 0,
                init_undo_stack: manager.undo_stack().to_vec(),
                init_redo_stack: manager.redo_stack().to_vec(),
                ..Default::default()
            });
            next_manager.expand_scope(&next, &next.get_or_insert_text("body"));
            drop(manager);
            doc = next;
            manager = next_manager;
            assert_eq!(
                bookmark.get_history_offset(&doc.transact()).unwrap().index,
                4
            );
        }
    }

    #[test]
    fn checkpoint_copies_map_and_text_redone_without_mutating_source() {
        let doc = Doc::with_options(Options {
            skip_gc: true,
            offset_kind: OffsetKind::Utf16,
            ..Default::default()
        });
        let root = doc.get_or_insert_map("blocks");
        let text = {
            let mut txn = doc.transact_mut();
            let paragraph = root.insert(&mut txn, "p", MapPrelim::default());
            paragraph.insert(&mut txn, "text", TextPrelim::new("a"))
        };
        let mut manager = UndoManager::with_options(crate::undo::Options {
            capture_timeout_millis: 0,
            ..Default::default()
        });
        manager.expand_scope(&doc, &root);
        root.insert(&mut doc.transact_mut(), "heading", 1_i64);
        root.insert(&mut doc.transact_mut(), "heading", 2_i64);
        manager.undo_blocking();
        text.insert(&mut doc.transact_mut(), 1, "X");
        text.remove_range(&mut doc.transact_mut(), 1, 1);
        manager.undo_blocking();
        let original = doc
            .transact()
            .encode_state_as_update_v1(&StateVector::default());
        let fork = doc.fork_for_history().unwrap();
        let fork_root = fork.get_or_insert_map("blocks");
        let mut fork_manager = UndoManager::with_options(crate::undo::Options {
            init_undo_stack: manager.undo_stack().to_vec(),
            init_redo_stack: manager.redo_stack().to_vec(),
            ..Default::default()
        });
        fork_manager.expand_scope(&fork, &fork_root);
        assert!(fork_manager.undo_blocking());
        let txn = fork.transact();
        let Some(crate::Out::YMap(paragraph)) = fork_root.get(&txn, "p") else {
            panic!()
        };
        let Some(crate::Out::YText(fork_text)) = paragraph.get(&txn, "text") else {
            panic!()
        };
        assert_eq!(fork_text.get_string(&txn), "a");
        drop(txn);
        assert!(fork_manager.undo_blocking());
        assert!(!fork_root.contains_key(&fork.transact(), "heading"));
        assert_eq!(
            doc.transact()
                .encode_state_as_update_v1(&StateVector::default()),
            original
        );
        assert_eq!(text.get_string(&doc.transact()), "aX");
    }

    #[test]
    fn checkpoint_requires_supported_non_gc_utf16_options() {
        assert!(Doc::new().fork_for_history().is_err());
        let utf8 = Doc::with_options(Options {
            skip_gc: true,
            offset_kind: OffsetKind::Bytes,
            ..Default::default()
        });
        assert!(utf8.fork_for_history().is_err());
    }
}
