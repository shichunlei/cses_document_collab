import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:appflowy_editor/src/editor/editor_component/service/ime/character_shortcut_event_helper.dart';
import 'package:appflowy_editor/src/editor/editor_component/service/ime/delta_input_impl.dart';
import 'package:appflowy_editor/src/editor/util/platform_extension.dart';
import 'package:flutter/services.dart';

/// Apply IME [replacement] to borrowed [editorState], trying
/// [characterShortcutEvents] for a single block. Changed local input epochs
/// invalidate continuations before applying offsets from the original delta.
/// Optional [isInputCurrent] rejects a closed/replaced input connection after
/// asynchronous work; null retains direct editor-command behavior.
Future<void> onReplace(
  TextEditingDeltaReplacement replacement,
  EditorState editorState,
  List<CharacterShortcutEvent> characterShortcutEvents, {
  bool Function()? isInputCurrent,
}) async {
  final epoch = editorState.localTransactionEpoch;
  if (!editorState.canAcceptLocalTransactions ||
      !(isInputCurrent?.call() ?? true)) {
    return;
  }
  AppFlowyEditorLog.input.debug('onReplace: $replacement');

  // delete the selection
  final selection = editorState.selection;
  if (selection == null) {
    return;
  }

  if (selection.isSingle) {
    final execution = await executeCharacterShortcutEvent(
      editorState,
      replacement.replacementText,
      characterShortcutEvents,
      isInputCurrent: isInputCurrent,
    );
    if (!editorState.canAcceptLocalTransactions ||
        editorState.localTransactionEpoch != epoch ||
        !(isInputCurrent?.call() ?? true)) {
      return;
    }

    if (execution) {
      return;
    }

    if (PlatformExtension.isIOS) {
      // remove the trailing '\n' when pressing the return key
      if (replacement.replacementText.endsWith('\n')) {
        replacement = TextEditingDeltaReplacement(
          oldText: replacement.oldText,
          replacementText: replacement.replacementText.substring(
            0,
            replacement.replacementText.length - 1,
          ),
          replacedRange: replacement.replacedRange,
          selection: replacement.selection,
          composing: replacement.composing,
        );
      }
    }

    final node = editorState.getNodesInSelection(selection).first;
    final transaction = editorState.transaction;
    final start = replacement.replacedRange.start;
    final length = replacement.replacedRange.end - start;
    final afterSelection = Selection(
      start: Position(
        path: node.path,
        offset: replacement.selection.baseOffset,
      ),
      end: Position(
        path: node.path,
        offset: replacement.selection.extentOffset,
      ),
    );
    transaction
      ..replaceText(node, start, length, replacement.replacementText)
      ..afterSelection = afterSelection;
    await editorState.apply(transaction);
  } else {
    await editorState.deleteSelection(selection);
    if (!editorState.canAcceptLocalTransactions ||
        editorState.localTransactionEpoch != epoch ||
        !(isInputCurrent?.call() ?? true)) {
      return;
    }
    // insert the replacement
    final insertion = replacement.toInsertion();
    await onInsert(
      insertion,
      editorState,
      characterShortcutEvents,
      isInputCurrent: isInputCurrent,
    );
  }
}

extension on TextEditingDeltaReplacement {
  TextEditingDeltaInsertion toInsertion() {
    final text = oldText.replaceRange(
      replacedRange.start,
      replacedRange.end,
      '',
    );
    return TextEditingDeltaInsertion(
      oldText: text,
      textInserted: replacementText,
      insertionOffset: replacedRange.start,
      selection: selection,
      composing: composing,
    );
  }
}
