import 'dart:collection';
import 'dart:async';

import 'package:appflowy_editor/src/core/location/selection.dart';
import 'package:appflowy_editor/src/core/transform/operation.dart';
import 'package:appflowy_editor/src/core/transform/transaction.dart';
import 'package:appflowy_editor/src/editor_state.dart';
import 'package:appflowy_editor/src/infra/log.dart';

/// Borrowed history commands for a host that owns durable collaboration history.
/// The host handles asynchronous failures and releases its own resources. Local
/// editors omit this delegate and retain the built-in path history.
///
/// ```dart
/// import 'package:appflowy_editor/appflowy_editor.dart';
/// final editor = EditorState.blank();
/// editor.undoManager.externalHistory = EditorHistoryDelegate(
///   undo: () {}, redo: () {}, canUndo: () => false, canRedo: () => false,
/// );
/// editor.undoManager.externalHistory = null;
/// editor.dispose();
/// ```
class EditorHistoryDelegate {
  /// [undo] and [redo] dispatch commands; [canUndo] and [canRedo] read the
  /// host's latest availability and permissions at invocation time.
  const EditorHistoryDelegate({
    required this.undo,
    required this.redo,
    required this.canUndo,
    required this.canRedo,
  });

  /// Dispatch one undo; the owner handles completion and failure reporting.
  final void Function() undo;

  /// Dispatch one redo; the owner handles completion and failure reporting.
  final void Function() redo;

  /// Whether undo is currently permitted and available.
  final bool Function() canUndo;

  /// Whether redo is currently permitted and available.
  final bool Function() canRedo;
}

/// A [HistoryItem] contains list of operations committed by users.
/// If a [HistoryItem] is not sealed, operations can be added sequentially.
/// Otherwise, the operations should be added to a new [HistoryItem].
final class HistoryItem extends LinkedListEntry<HistoryItem> {
  final List<Operation> operations = [];
  Selection? beforeSelection;
  Selection? afterSelection;
  bool _sealed = false;

  HistoryItem();

  /// Seal the history item.
  /// When an item is sealed, no more operations can be added
  /// to the item.
  ///
  /// The caller should create a new [HistoryItem].
  void seal() {
    _sealed = true;
  }

  bool get sealed => _sealed;

  void add(Operation op) {
    operations.add(op);
  }

  void addAll(Iterable<Operation> iterable) {
    operations.addAll(iterable);
  }

  /// Create a new [Transaction] by inverting the operations.
  Transaction toTransaction(EditorState state) {
    final builder = Transaction(document: state.document);
    for (var i = operations.length - 1; i >= 0; i--) {
      final operation = operations[i];
      final inverted = operation.invert();
      builder.add(inverted, transform: false);
    }
    builder.afterSelection = beforeSelection;
    builder.beforeSelection = afterSelection;
    return builder;
  }
}

class FixedSizeStack {
  final _list = LinkedList<HistoryItem>();
  final int maxSize;

  FixedSizeStack(this.maxSize);

  void push(HistoryItem stackItem) {
    if (_list.length >= maxSize) {
      _list.remove(_list.first);
    }
    _list.add(stackItem);
  }

  HistoryItem? pop() {
    if (_list.isEmpty) {
      return null;
    }
    final last = _list.last;

    _list.remove(last);

    return last;
  }

  void clear() {
    _list.clear();
  }

  HistoryItem get last => _list.last;

  bool get isEmpty => _list.isEmpty;

  bool get isNonEmpty => _list.isNotEmpty;
}

/// Editor-owned undo/redo stacks, or borrowed commands when [externalHistory]
/// is attached. A rejected host write policy never pops a local item.
///
/// ```dart
/// import 'package:appflowy_editor/appflowy_editor.dart';
/// final editor = EditorState.blank();
/// editor.undoManager.undo();
/// editor.dispose();
/// ```
class UndoManager {
  final FixedSizeStack undoStack;
  final FixedSizeStack redoStack;
  EditorState? state;
  EditorHistoryDelegate? _externalHistory;

  /// Borrowed durable history owner; null retains built-in local history.
  /// Replacing the owner clears path stacks so detached collaboration commands
  /// can never later fall back to stale local replay. This does not dispose it.
  EditorHistoryDelegate? get externalHistory => _externalHistory;

  /// Bind borrowed [value], clearing stale local stacks when ownership changes.
  set externalHistory(EditorHistoryDelegate? value) {
    if (identical(value, _externalHistory)) return;
    undoStack.clear();
    redoStack.clear();
    _externalHistory = value;
  }

  /// Current availability from the host or the built-in local undo stack.
  bool get canUndo => _externalHistory?.canUndo() ?? undoStack.isNonEmpty;

  /// Current availability from the host or the built-in local redo stack.
  bool get canRedo => _externalHistory?.canRedo() ?? redoStack.isNonEmpty;

  UndoManager([int stackSize = 20])
    : undoStack = FixedSizeStack(stackSize),
      redoStack = FixedSizeStack(stackSize);

  /// Returns the history entry for a local transaction, owned by this manager.
  /// [isRedo] defaults to false for new edits. Redo restores one command as a
  /// separate sealed undo entry and preserves the remaining redo stack; new
  /// edits keep the existing debounce grouping and invalidate redo as usual.
  HistoryItem getUndoHistoryItem({bool isRedo = false}) {
    if (isRedo) {
      final item = HistoryItem()..seal();
      undoStack.push(item);
      return item;
    }
    redoStack.clear();
    if (undoStack.isEmpty) {
      final item = HistoryItem();
      undoStack.push(item);
      return item;
    }
    final last = undoStack.last;
    if (last.sealed) {
      final item = HistoryItem();
      undoStack.push(item);
      return item;
    }
    return last;
  }

  /// Dispatch to the external owner or replay the latest local change after the
  /// borrowed editor authorizes it. A paused, readonly or disposed target is ignored;
  /// rejected local transactions leave both path stacks untouched.
  void undo() {
    final external = _externalHistory;
    if (external != null) {
      if (state?.canAcceptLocalTransactions == true &&
          state?.isDisposed == false &&
          external.canUndo()) {
        external.undo();
      }
      return;
    }
    final s = state;
    if (s == null || undoStack.isEmpty) return;
    final transaction = undoStack.last.toTransaction(s);
    if (!s.canApplyTransaction(transaction)) return;
    undoStack.pop();
    unawaited(
      s
          .apply(
            transaction,
            options: const ApplyOptions(recordUndo: false, recordRedo: true),
          )
          .catchError((Object error, StackTrace stack) {
            Zone.current.handleUncaughtError(error, stack);
          }),
    );
  }

  /// Replays the latest undone command through the attached editor state.
  /// With [externalHistory], dispatches only to that owner when writable and
  /// available and local transactions are not paused; the owner handles
  /// completion and asynchronous failures.
  /// Preserves other redo entries and records this command separately so a
  /// subsequent undo reverses only this replay. Host policy rejection keeps the
  /// item on its original stack. No attached state or no redo
  /// entry is a no-op; transaction failures follow EditorState.apply semantics.
  void redo() {
    final external = _externalHistory;
    if (external != null) {
      if (state?.canAcceptLocalTransactions == true &&
          state?.isDisposed == false &&
          external.canRedo()) {
        external.redo();
      }
      return;
    }
    final s = state;
    if (s == null || redoStack.isEmpty) return;
    final transaction = redoStack.last.toTransaction(s);
    if (!s.canApplyTransaction(transaction)) return;
    redoStack.pop();
    unawaited(
      s
          .apply(
            transaction,
            options: const ApplyOptions(
              recordUndo: true,
              recordRedo: false,
              isRedo: true,
            ),
          )
          .catchError((Object error, StackTrace stack) {
            Zone.current.handleUncaughtError(error, stack);
          }),
    );
  }

  void forgetRecentUndo() {
    AppFlowyEditorLog.editor.debug('forgetRecentUndo');
    if (state != null) {
      undoStack.pop();
    }
  }
}
