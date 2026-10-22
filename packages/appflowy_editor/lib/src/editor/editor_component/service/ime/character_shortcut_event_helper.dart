import 'package:appflowy_editor/appflowy_editor.dart';

/// Try [characterShortcutEvents] for [character] against borrowed [editorState].
/// Null or multi-character input does not match. Permission and pause changes
/// across an asynchronous handler stop the remaining shortcut chain.
/// Optional [isInputCurrent] rejects a closed/replaced input connection after
/// asynchronous work; null retains direct editor-command behavior.
Future<bool> executeCharacterShortcutEvent(
  EditorState editorState,
  String? character,
  List<CharacterShortcutEvent> characterShortcutEvents, {
  bool Function()? isInputCurrent,
}) async {
  final epoch = editorState.localTransactionEpoch;
  if (!editorState.canAcceptLocalTransactions ||
      !(isInputCurrent?.call() ?? true)) {
    return false;
  }
  // if the character is a space + enter, we should execute the enter event
  if (character == ' \n') {
    character = '\n';
  }

  if (character?.length != 1) {
    return false;
  }

  for (final shortcutEvent in characterShortcutEvents) {
    if (!editorState.canAcceptLocalTransactions ||
        editorState.localTransactionEpoch != epoch ||
        !(isInputCurrent?.call() ?? true)) {
      return false;
    }
    bool hasMatchRegExp = false;
    final regExp = shortcutEvent.regExp;
    if (regExp != null && character != null) {
      hasMatchRegExp = regExp.hasMatch(character);
      if (hasMatchRegExp && shortcutEvent.handlerWithCharacter != null) {
        final handled = await shortcutEvent.executeWithCharacter(
          editorState,
          character,
        );
        if (!editorState.canAcceptLocalTransactions ||
            editorState.localTransactionEpoch != epoch ||
            !(isInputCurrent?.call() ?? true)) {
          return false;
        }
        if (handled) {
          AppFlowyEditorLog.input.debug(
            'keyboard service - handled by character shortcut event: $shortcutEvent',
          );
          return true;
        }
      }
    }
    if (shortcutEvent.character == character || hasMatchRegExp) {
      final handled = await shortcutEvent.handler(editorState);
      if (!editorState.canAcceptLocalTransactions ||
          editorState.localTransactionEpoch != epoch ||
          !(isInputCurrent?.call() ?? true)) {
        return false;
      }
      if (handled) {
        AppFlowyEditorLog.input.debug(
          'keyboard service - handled by character shortcut event: $shortcutEvent',
        );
        return true;
      }
    }
  }

  return false;
}
