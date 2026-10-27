# Native history checkpoint extension

Source: crates.io `yrs` 0.27.4, originally selected by the parent lockfile. `UPSTREAM.json` retains hashes for every original Rust source and the upstream MIT license. The parent production engine now uses this path dependency with `small-client`, `sync`, and `history-checkpoint`; the separate native-only prototype remains opt-in.

Original upstream Rust sources differ only in the feature-gated module declaration in `src/lib.rs`. The source manifest adds `history-checkpoint` and omits unavailable benchmark declarations. New `src/history_checkpoint.rs` contains:

- `Doc::fork_for_history`: an independent V1 copy plus private native `Item.redone` links. It rejects GC-enabled/non-UTF-16/subdocument states. The engine owns every candidate and its manager subscriptions; only the SQLite-committed candidate becomes authoritative, preserving the existing actor, GUID and Awareness state.
- `StickyIndex::get_history_offset`: read-only bookmark resolution that preserves an interior UTF-16 offset at every redone link. Upstream 0.27.4 follows a restored item's start and can lose the interior offset after undo/redo. This helper changes neither `Store::follow_redone` nor the native undo implementation; ordinary non-relative positions use the upstream resolver.
- Three isolated extension regressions covering copied map/text redone state, rejected options, and repeated Chinese/Emoji selection resolution across redo/checkpoint cycles.

No wire fields, encoding, merge, GC, or native undo algorithms are changed. Selection tokens are local-only and never encoded into document updates. The production engine installs fresh manager subscriptions and typed root handles on each accepted copy; it keeps personal metadata on native stack items rather than replaying prior commands.

When upgrading, compare every original hash and reapply only this extension. Run checkpoint, formal/legacy history, independent Yjs interoperability, locks, structures, formatting, SQLite write/COMMIT failures, Flutter entry/selection/lifecycle regressions and affected platform builds. Copying a whole Doc per intent is deliberately conservative; large-document latency and memory still need measurement before performance claims.

Upstream has existing formatting differences in `src/observer.rs` and `src/sync/protocol.rs`, plus compiler warnings; preserve those sources and record the baseline rather than reformatting the fork wholesale. See the parent repository's `docs/verification/selective-undo-prototype-20261022/frb-editor-history.md` for integration evidence and limitations.
