import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/model/collab_resource.dart';

/// Desktop-compatible link representations; changing view replaces the block.
enum CollabLinkView {
  /// Editable paragraph whose entire text carries one HTTP(S) link.
  inline,

  /// Native metadata preview stored as a desktop bookmark.
  card,

  /// WebView backed by the desktop embed flavour.
  embed;

  /// User-facing label for the representation.
  String get label => switch (this) {
    inline => '链接视图',
    card => '卡片视图',
    embed => '嵌入视图',
  };
}

/// Local transaction marker; never serialized as a shared block property.
const collabLinkViewCommand = 'cses_link_view_command';

/// Returns the original URL represented by borrowed [node], or null.
/// Whole-link paragraphs may contain styled runs but no unrelated text/children;
/// mixed body text is excluded so conversion cannot silently discard it.
String? collabLinkUrl(Node node) {
  if (node.children.isNotEmpty) return null;
  if (const {'bookmark', 'embed', 'figma-embed', 'juejin-embed'}.contains(node.type)) {
    final url = node.attributes['url'];
    return url is String && isCollabResourceUrl(node.type, url) ? url : null;
  }
  if (node.type != 'paragraph' || node.delta?.isEmpty != false) return null;
  String? url;
  for (final op in node.delta!) {
    if (op is! TextInsert || op.text.isEmpty) return null;
    final href = op.attributes?[AppFlowyRichTextKeys.href];
    if (href is! String || !isCollabResourceUrl('bookmark', href) || (url != null && href != url)) {
      return null;
    }
    url = href;
  }
  return url;
}

/// Returns the representation for [node]; callers first validate its URL.
CollabLinkView collabLinkView(Node node) => switch (node.type) {
  'paragraph' => CollabLinkView.inline,
  'bookmark' => CollabLinkView.card,
  _ => CollabLinkView.embed,
};

/// Serializes view-relevant content of [node] for conflict checks.
/// Metadata/size updates remain compatible; URL or linked-text changes invalidate
/// an open action panel or conversion history before any mutation takes place.
String collabLinkFingerprint(Node node) => jsonEncode({
  'type': node.type,
  'url': collabLinkUrl(node),
  if (node.type == 'paragraph') 'delta': node.delta?.toJson(),
});

/// Finds a current node by stable [id] in borrowed [state], including callouts.
/// Returns null after deletion/disposal; this function does not alter selection.
Node? findCollabLinkNode(EditorState state, String id) {
  if (state.isDisposed) return null;
  Node? visit(Node node) {
    if ((node.attributes['cses_collab_block_id'] ?? node.id) == id) return node;
    for (final child in node.children) {
      final found = visit(child);
      if (found != null) return found;
    }
    return null;
  }

  return visit(state.document.root);
}

/// Converts borrowed [source] in [state] to [view] as one undoable transaction.
/// [fingerprint] optionally rejects a stale action-panel snapshot. Only root and
/// callout leaf children convert; readonly/disposed, detached or unchanged targets
/// return false. URL and native extensions survive through the adapter's existing
/// replacement identity chain. Errors propagate after the apply future completes.
Future<bool> changeCollabLinkView(EditorState state, Node source, CollabLinkView view, {String? fingerprint}) async {
  if (state.isDisposed ||
      !state.editable ||
      !const {'page', 'callout'}.contains(source.parent?.type) ||
      (fingerprint != null && collabLinkFingerprint(source) != fingerprint)) {
    return false;
  }
  final url = collabLinkUrl(source);
  if (url == null || collabLinkView(source) == view) return false;
  final id = source.attributes['cses_collab_block_id'] as String? ?? source.id;
  if (!identical(findCollabLinkNode(state, id), source)) return false;
  final attributes = Map<String, dynamic>.from(source.attributes)
    ..remove('delta')
    ..remove('cses_replacement_source')
    ..remove(collabLinkViewCommand);
  final type = switch (view) {
    CollabLinkView.inline => 'paragraph',
    CollabLinkView.card => 'bookmark',
    CollabLinkView.embed => 'embed',
  };
  if (view == CollabLinkView.inline) {
    attributes['delta'] = (Delta()..insert(url, attributes: {AppFlowyRichTextKeys.href: url})).toJson();
  } else {
    attributes['url'] = url;
  }
  final target = source.copyWith(type: type, attributes: attributes);
  final command = {'id': id, 'before': collabLinkFingerprint(source), 'after': collabLinkFingerprint(target)};
  if (state.undoManager.undoStack.isNonEmpty) {
    state.undoManager.undoStack.last.seal();
  }
  final path = source.path;
  final transaction = state.transaction;
  transaction.add(DeleteOperation(path, [source]), transform: false);
  transaction.add(InsertOperation(path, [target]), transform: false);
  transaction.add(
    UpdateOperation(
      path,
      {
        collabLinkViewCommand: jsonEncode({...command, 'forward': true}),
      },
      {
        collabLinkViewCommand: jsonEncode({...command, 'forward': false}),
      },
    ),
    transform: false,
  );
  transaction.afterSelection = Selection.single(
    path: path,
    startOffset: view == CollabLinkView.inline ? url.length : 0,
  );
  await state.apply(transaction, skipHistoryDebounce: true);
  return true;
}

/// Revalidates/rebases a conversion [transaction] in borrowed [state].
/// [resolveId] follows the adapter-owned replacement identity chain. Deleted,
/// modified or readonly targets atomically discard the history operation; remote
/// reorders are resolved by current identity rather than an old document path.
void resolveCollabLinkViewCommand(EditorState state, Transaction transaction, String Function(String id) resolveId) {
  final marker = transaction.operations
      .whereType<UpdateOperation>()
      .where((op) => op.attributes[collabLinkViewCommand] is String)
      .firstOrNull;
  if (marker == null) return;
  final command = jsonDecode(marker.attributes[collabLinkViewCommand] as String) as Map;
  final node = findCollabLinkNode(state, resolveId(command['id'] as String));
  final expected = command[command['forward'] == true ? 'before' : 'after'];
  if (!state.editable ||
      node == null ||
      !const {'page', 'callout'}.contains(node.parent?.type) ||
      collabLinkFingerprint(node) != expected) {
    transaction.operations = [];
    return;
  }
  final id = node.attributes['cses_collab_block_id'] ?? node.id;
  transaction.operations = transaction.operations.map((op) {
    if (op is DeleteOperation) return DeleteOperation(node.path, [node]);
    if (op is InsertOperation) {
      return InsertOperation(node.path, [
        for (final target in op.nodes) target.copyWith(attributes: {...target.attributes, 'cses_collab_block_id': id}),
      ]);
    }
    if (op is UpdateOperation) return op.copyWith(path: node.path);
    return op;
  }).toList();
  transaction.beforeSelection = state.selection;
  transaction.afterSelection = Selection.single(path: node.path, startOffset: 0);
}
