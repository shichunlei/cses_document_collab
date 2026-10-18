import 'package:appflowy_editor/appflowy_editor.dart';

/// 桌面无正文、无子块且仅限 root 直属子级的手动分页符 flavour。
const collabPageDividerType = 'page-divider';

/// 在借用的 [state] 中按保存的 [selection] 插入根级分页符，返回后置空段落光标。
/// 空段落原位替换，其他根级块保留并在其后插入；范围选区和嵌套位置返回 null，
/// 不向上寻找根节点。只读、关闭或位置失效时不写入；焦点由调用方面板退场后恢复。
/// 分页符与后置段落共用独立撤销事务，异常通过 Future 传播。
Future<Selection?> insertCollabPageDivider(
  EditorState state,
  Selection selection,
) async {
  if (state.isDisposed ||
      !state.editable ||
      !selection.isCollapsed ||
      selection.start.path.length != 1) {
    return null;
  }
  final source = state.getNodeAtPath(selection.start.path);
  if (source == null || !identical(source.parent, state.document.root)) {
    return null;
  }
  final divider = Node(type: collabPageDividerType);
  divider.updateAttributes({'cses_collab_block_id': divider.id});
  final paragraph = paragraphNode();
  paragraph.updateAttributes({'cses_collab_block_id': paragraph.id});
  final empty =
      source.type == ParagraphBlockKeys.type &&
      source.delta?.toPlainText().isEmpty == true;
  final path = empty ? source.path : source.path.next;
  final transaction = state.transaction
    ..insertNodes(path, [divider, paragraph], deepCopy: false);
  if (empty) transaction.deleteNode(source);
  if (!state.undoManager.undoStack.isEmpty) {
    state.undoManager.undoStack.last.seal();
  }
  final landing = Selection.single(path: path.next, startOffset: 0);
  transaction.afterSelection = landing;
  await state.apply(transaction, skipHistoryDebounce: true);
  return landing;
}

/// 删除借用 [state] 中稳定身份为 [id] 的根级分页符，返回是否已完成事务。
/// 只读、关闭、远端删除或类型/父级变化时返回 false。末块删除时补稳定身份空段落；
/// 删除与补段落共用独立撤销事务，异常由菜单调用方报告，不主动恢复输入焦点。
Future<bool> deleteCollabPageDivider(EditorState state, String id) async {
  if (state.isDisposed || !state.editable) return false;
  Node? source;
  for (final candidate in state.document.root.children) {
    if ((candidate.attributes['cses_collab_block_id'] ?? candidate.id) == id) {
      source = candidate;
      break;
    }
  }
  if (source == null ||
      source.type != collabPageDividerType ||
      !identical(source.parent, state.document.root)) {
    return false;
  }
  if (!state.undoManager.undoStack.isEmpty) {
    state.undoManager.undoStack.last.seal();
  }
  final transaction = state.transaction..deleteNode(source);
  if (source.parent!.children.length == 1) {
    final paragraph = paragraphNode();
    paragraph.updateAttributes({'cses_collab_block_id': paragraph.id});
    transaction.add(
      InsertOperation(source.path, [paragraph]),
      transform: false,
    );
  }
  transaction.afterSelection = null;
  await state.apply(
    transaction,
    withUpdateSelection: false,
    skipHistoryDebounce: true,
  );
  return true;
}
