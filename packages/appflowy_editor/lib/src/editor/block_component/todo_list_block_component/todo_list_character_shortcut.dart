import 'package:appflowy_editor/appflowy_editor.dart';

/// Convert '[] ' to unchecked todo list
///
/// - support
///   - desktop
///   - mobile
///   - web
///
CharacterShortcutEvent formatEmptyBracketsToUncheckedBox =
    CharacterShortcutEvent(
  key: 'format empty square brackets to unchecked todo list',
  character: ' ',
  handler: (editorState) async {
    return _formatSymbolToUncheckedBox(
      editorState: editorState,
      symbol: '[]',
    );
  },
);

/// Convert '-[] ' to unchecked todo list
///
/// - support
///   - desktop
///   - mobile
///   - web
///
CharacterShortcutEvent formatHyphenEmptyBracketsToUncheckedBox =
    CharacterShortcutEvent(
  key: 'format hyphen and empty square brackets to unchecked todo list',
  character: ' ',
  handler: (editorState) async {
    return _formatSymbolToUncheckedBox(
      editorState: editorState,
      symbol: '-[]',
    );
  },
);

/// Convert '[x] ' to checked todo list
///
/// - support
///   - desktop
///   - mobile
///   - web
///
CharacterShortcutEvent formatFilledBracketsToCheckedBox =
    CharacterShortcutEvent(
  key: 'format filled square brackets to checked todo list',
  character: ' ',
  handler: (editorState) async {
    return _formatSymbolToCheckedBox(
      editorState: editorState,
      symbol: '[x]',
    );
  },
);

/// Convert '-[x] ' to checked todo list
///
/// - support
///   - desktop
///   - mobile
///   - web
///
CharacterShortcutEvent formatHyphenFilledBracketsToCheckedBox =
    CharacterShortcutEvent(
  key: 'format hyphen and filled square brackets to checked todo list',
  character: ' ',
  handler: (editorState) async {
    return _formatSymbolToCheckedBox(
      editorState: editorState,
      symbol: '-[x]',
    );
  },
);

/// Insert a new block after the todo list block.
///
/// - support
///   - desktop
///   - web
///   - mobile
///
CharacterShortcutEvent insertNewLineAfterTodoList = CharacterShortcutEvent(
  key: 'insert new block after todo list',
  character: '\n',
  handler: (editorState) async => await insertNewLineInType(
    editorState,
    'todo_list',
    attributes: {
      TodoListBlockKeys.checked: false,
    },
  ),
);

/// Converts [symbol], either `[]` or `-[]`, into an unchecked todo item.
///
/// Uses the selection in the borrowed [editorState] and removes [symbol] from
/// the text. Completes after applying the transaction, returning `false` when
/// the selection is absent, expanded, or does not match an eligible text node.
Future<bool> _formatSymbolToUncheckedBox({
  required EditorState editorState,
  required String symbol,
}) async {
  assert(symbol == '[]' || symbol == '-[]');

  return formatMarkdownSymbol(
    editorState,
    (node) => node.type != 'todo_list',
    (_, text, _) => text == symbol,
    (_, node, delta) => [
      node.copyWith(
        type: TodoListBlockKeys.type,
        attributes: {
          TodoListBlockKeys.checked: false,
          TodoListBlockKeys.delta:
              delta.compose(Delta()..delete(symbol.length)).toJson(),
        },
      ),
    ],
  );
}

/// Converts [symbol], either `[x]` or `-[x]`, into a checked todo item.
///
/// Uses the selection in the borrowed [editorState] and removes [symbol] from
/// the text. Completes after applying the transaction, returning `false` when
/// the selection is absent, expanded, or does not match an eligible text node.
Future<bool> _formatSymbolToCheckedBox({
  required EditorState editorState,
  required String symbol,
}) async {
  assert(symbol == '[x]' || symbol == '-[x]');

  return formatMarkdownSymbol(
    editorState,
    (node) => node.type != 'todo_list',
    (_, text, _) => text == symbol,
    (_, node, delta) => [
      node.copyWith(
        type: TodoListBlockKeys.type,
        attributes: {
          TodoListBlockKeys.checked: true,
          TodoListBlockKeys.delta:
              delta.compose(Delta()..delete(symbol.length)).toJson(),
        },
      ),
    ],
  );
}
