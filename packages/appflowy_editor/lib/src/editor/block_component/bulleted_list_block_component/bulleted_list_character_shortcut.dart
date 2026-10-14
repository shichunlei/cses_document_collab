import 'package:appflowy_editor/appflowy_editor.dart';

/// Convert '* ' to bulleted list
///
/// - support
///   - desktop
///   - mobile
///   - web
///
CharacterShortcutEvent formatAsteriskToBulletedList = CharacterShortcutEvent(
  key: 'format asterisk to bulleted list',
  character: ' ',
  handler: (editorState) async =>
      await _formatSymbolToBulletedList(editorState, '*'),
);

/// Convert '- ' to bulleted list
///
/// - support
///   - desktop
///   - mobile
///   - web
///
CharacterShortcutEvent formatMinusToBulletedList = CharacterShortcutEvent(
  key: 'format minus to bulleted list',
  character: ' ',
  handler: (editorState) async =>
      await _formatSymbolToBulletedList(editorState, '-'),
);

/// Insert a new block after the bulleted list block.
///
/// - support
///   - desktop
///   - web
///   - mobile
///
CharacterShortcutEvent insertNewLineAfterBulletedList = CharacterShortcutEvent(
  key: 'insert new block after bulleted list',
  character: '\n',
  handler: (editorState) async => await insertNewLineInType(
    editorState,
    'bulleted_list',
  ),
);

/// Converts a matching single-character [symbol] into a bulleted list.
///
/// Uses the selection in the borrowed [editorState] and removes [symbol] from
/// the text. Completes after applying the transaction, returning `false` when
/// the selection is absent, expanded, or does not match an eligible text node.
Future<bool> _formatSymbolToBulletedList(
  EditorState editorState,
  String symbol,
) async {
  assert(symbol.length == 1);

  return formatMarkdownSymbol(
    editorState,
    (node) => node.type != BulletedListBlockKeys.type,
    (_, text, _) => text == symbol,
    (_, node, delta) => [
      node.copyWith(
        type: BulletedListBlockKeys.type,
        attributes: {
          BulletedListBlockKeys.delta:
              delta.compose(Delta()..delete(symbol.length)).toJson(),
        },
      ),
    ],
  );
}
