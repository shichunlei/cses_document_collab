import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:appflowy_editor/src/editor/util/platform_extension.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Apply IME cursor/composing [nonTextUpdate] to borrowed [editorState].
/// [characterShortcutEvents] are retained for shortcut integration. A local
/// permission or pause transition invalidates pending cursor updates.
/// Optional [isInputCurrent] rejects a closed/replaced input connection after
/// asynchronous work; null retains direct editor-command behavior.
Future<void> onNonTextUpdate(
  TextEditingDeltaNonTextUpdate nonTextUpdate,
  EditorState editorState,
  List<CharacterShortcutEvent> characterShortcutEvents, {
  bool Function()? isInputCurrent,
}) async {
  final epoch = editorState.localTransactionEpoch;
  if (!editorState.canAcceptLocalTransactions ||
      !(isInputCurrent?.call() ?? true)) {
    return;
  }
  AppFlowyEditorLog.input.debug('onNonTextUpdate: $nonTextUpdate');

  // update the selection on Windows
  //
  // when typing characters with CJK IME on Windows, a non-text update is sent
  // with the selection range.
  final selection = editorState.selection;

  if (await _checkIfBacktickPressed(
    editorState,
    nonTextUpdate,
    isInputCurrent: isInputCurrent,
  )) {
    return;
  }
  if (!editorState.canAcceptLocalTransactions ||
      editorState.localTransactionEpoch != epoch ||
      !(isInputCurrent?.call() ?? true)) {
    return;
  }

  if (PlatformExtension.isWindows) {
    if (selection != null &&
        nonTextUpdate.composing == TextRange.empty &&
        nonTextUpdate.selection.isCollapsed) {
      editorState.selection = Selection.collapsed(
        Position(
          path: selection.start.path,
          offset: nonTextUpdate.selection.start,
        ),
      );
    }
  } else if (PlatformExtension.isLinux) {
    if (selection != null) {
      editorState.updateSelectionWithReason(
        Selection.collapsed(
          Position(
            path: selection.start.path,
            offset: nonTextUpdate.selection.start,
          ),
        ),
      );
    }
  } else if (PlatformExtension.isMacOS) {
    if (selection != null) {
      editorState.updateSelectionWithReason(
        Selection.collapsed(
          Position(
            path: selection.start.path,
            offset: nonTextUpdate.selection.start,
          ),
        ),
      );
    }
  } else if (PlatformExtension.isAndroid) {
    // on some Android keyboards (e.g. Gboard), they use non-text update to update the selection when moving cursor
    // by space bar.
    // for the another keyboards (e.g. system keyboard), they will trigger the
    // `onFloatingCursor` event instead.
    AppFlowyEditorLog.input.debug('[Android] onNonTextUpdate: $nonTextUpdate');
    if (selection != null) {
      final nonTextUpdateStart = nonTextUpdate.selection.start;
      final selectionStart = selection.start.offset;
      if (nonTextUpdateStart != selectionStart) {
        editorState.updateSelectionWithReason(
          Selection.collapsed(
            Position(path: selection.start.path, offset: nonTextUpdateStart),
          ),
          reason: SelectionUpdateReason.uiEvent,
        );
      }
    }
  } else if (PlatformExtension.isIOS) {
    // on iOS, the cursor movement will trigger the `onFloatingCursor` event.
    // so we don't need to handle the non-text update here.
    AppFlowyEditorLog.input.debug('[iOS] onNonTextUpdate: $nonTextUpdate');
  }
}

/// Interpret a completed backtick composition in [nonTextUpdate] for borrowed
/// [editorState]; a changed input epoch or false [isInputCurrent] prevents a
/// subsequent formatting step.
Future<bool> _checkIfBacktickPressed(
  EditorState editorState,
  TextEditingDeltaNonTextUpdate nonTextUpdate, {
  bool Function()? isInputCurrent,
}) async {
  final epoch = editorState.localTransactionEpoch;
  // if the composing range is not empty, it means the user is typing a text,
  // so we don't need to handle the backtick pressed event
  if (!nonTextUpdate.composing.isCollapsed) {
    return false;
  }

  // if the selection is not collapsed, it means the user is not typing a text,
  // so we need to handle the backtick pressed event
  if (!nonTextUpdate.selection.isCollapsed) {
    return false;
  }

  final selection = editorState.selection;
  if (selection == null || !selection.isCollapsed) {
    AppFlowyEditorLog.input.debug('selection is null or not collapsed');
    return false;
  }

  final node = editorState.getNodesInSelection(selection).firstOrNull;
  if (node == null) {
    AppFlowyEditorLog.input.debug('node is null');
    return false;
  }

  // get last character of the node
  final lastCharacter = node.delta?.toPlainText().characters.lastOrNull;
  if (lastCharacter != '`') {
    AppFlowyEditorLog.input.debug('last character is not backtick');
    return false;
  }

  // check if the text should be formatted
  final (shouldApplyFormat, _) = checkSingleCharacterFormatShouldBeApplied(
    editorState: editorState,
    // check before the last character
    selection: selection.shift(-1),
    character: '`',
    formatStyle: FormatStyleByWrappingWithSingleChar.code,
  );

  if (!shouldApplyFormat) {
    AppFlowyEditorLog.input.debug('should not apply format');
    return false;
  }

  final transaction = editorState.transaction;
  transaction.deleteText(node, node.delta!.toPlainText().length - 1, 1);
  await editorState.apply(transaction);
  if (!editorState.canAcceptLocalTransactions ||
      editorState.localTransactionEpoch != epoch ||
      !(isInputCurrent?.call() ?? true)) {
    return false;
  }

  // remove the last backtick, and try to format the text to code block
  final isFormatted = handleFormatByWrappingWithSingleCharacter(
    editorState: editorState,
    character: '`',
    formatStyle: FormatStyleByWrappingWithSingleChar.code,
  );

  if (!isFormatted) {
    AppFlowyEditorLog.input.debug('format failed');
    // revert the transaction
    editorState.undoManager.undo();
  } else {
    editorState.sliceUpcomingAttributes = false;
  }

  return true;
}
