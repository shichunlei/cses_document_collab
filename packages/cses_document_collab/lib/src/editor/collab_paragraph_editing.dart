import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/collab_list_editing.dart';
import 'package:cses_document_collab/src/editor/core/editor_command_context.dart';
import 'package:cses_document_collab/src/editor/editor_block_conversion.dart';
import 'package:cses_document_collab/src/model/collab_paragraph_style.dart';
import 'package:cses_document_collab/src/model/collab_resource.dart';
import 'package:flutter/services.dart';

/// 段落族共用的软/硬键盘回车入口，应置于标准快捷键之前；不拥有编辑器。
/// ```dart
/// import 'package:appflowy_editor/appflowy_editor.dart';
/// import 'package:cses_document_collab/src/editor/collab_paragraph_editing.dart';
/// final state = EditorState.blank(); // 宿主负责 dispose。
/// final editor = AppFlowyEditor(editorState: state,
///   characterShortcutEvents: [collabParagraphEnter, ...standardCharacterShortcutEvents]);
/// ```
final collabParagraphEnter = CharacterShortcutEvent(
  key: 'cses-paragraph-enter',
  character: '\n',
  handler: handleCollabParagraphEnter,
);

/// 按桌面 0.11.20 在借用 [state] 拆分段落，段中保留、段尾按 same/body 选择下一段。
/// 标题/引用默认 body，正文/列表默认 same；空列表复用逐级退出规则，新待办未勾选。
/// 行首插入空同型段落并留在原正文；空标题默认原位转正文。Shift、代码、特殊块、
/// 非叶块及跨父容器选区交给原输入处理；同父段落范围替换在一次事务中完成。
/// 空标题/引用原位转正文时沿用宿主业务字段、桌面身份/元数据与块背景；段尾新增正文不继承原身份。
/// 成功应用事务返回 true；只读、销毁或不适用返回 false，错误向调用边界传播。
Future<bool> handleCollabParagraphEnter(EditorState state) async {
  final selection = state.selection?.normalized;
  if (state.isDisposed ||
      !state.editable ||
      selection == null ||
      HardwareKeyboard.instance.isShiftPressed) {
    return false;
  }
  final nodes = state.getNodesInSelection(selection);
  if (nodes.isEmpty ||
      nodes.any(
        (n) =>
            !supportsCollabParagraph(n) ||
            n.children.isNotEmpty ||
            n.parent != nodes.first.parent,
      )) {
    return false;
  }
  final node = nodes.first;
  final delta = node.delta!;
  final list = const {
    BulletedListBlockKeys.type,
    NumberedListBlockKeys.type,
    TodoListBlockKeys.type,
  }.contains(node.type);
  if (selection.isCollapsed && delta.isEmpty && list) {
    return outdentCollabListAtStart(state);
  }
  final offset = selection.start.offset;
  final last = nodes.last;
  final tail = last.delta!.slice(selection.end.offset);
  final atEnd = tail.isEmpty;
  final props = readCollabParagraph(node).values;
  final nextStyle = atEnd
      ? (const {'same', 'body'}.contains(props['nextParagraphStyle'])
                ? props['nextParagraphStyle']
                : null) ??
            (node.type == HeadingBlockKeys.type ||
                    (props['heading'] is num && props['heading'] != 0) ||
                    node.type == QuoteBlockKeys.type
                ? 'body'
                : 'same')
      : 'same';
  final continuing = nextStyle != 'body';
  final rawDepth = props['depth'];
  final depth = rawDepth is num
      ? rawDepth.toDouble()
      : rawDepth is String
      ? num.tryParse(rawDepth)?.toDouble()
      : null;
  if (selection.isCollapsed &&
      delta.isEmpty &&
      !list &&
      !(node.type == HeadingBlockKeys.type && !continuing) &&
      depth != null &&
      depth > 0) {
    return outdentEmptyCollabParagraph(state);
  }
  final typing = collabParagraphTypingAttributes(
    node,
    offset,
    pending: state.toggledStyle,
  );
  final defaults = paragraphDefaultsFromAttributes(typing);
  final attributes =
      <String, dynamic>{
          if (continuing) ...node.attributes,
          blockComponentDelta: tail.toJson(),
        }
        ..remove(collabParagraphTargetAttribute)
        ..remove('cses_collab_block_id')
        ..remove('cses_replacement_source')
        ..remove('cses_blockcraft_ordered')
        ..remove('cses_ordered_numbering')
        ..remove('cses_ordered_target')
        ..remove(TodoListBlockKeys.checked);
  final nextProps = continuing ? {...props} : <String, dynamic>{'depth': 0};
  nextProps['textDefaults'] = continuing && defaults.isNotEmpty
      ? defaults
      : null;
  attributes.addAll(
    paragraphNodeAttributes(CollabResource.fromValues(nextProps)),
  );
  if (continuing && node.type == TodoListBlockKeys.type) {
    attributes[TodoListBlockKeys.checked] = false;
  }
  final transaction = state.transaction;
  if (state.undoManager.undoStack.isNonEmpty) {
    state.undoManager.undoStack.last.seal();
  }
  if (selection.isCollapsed &&
      delta.isEmpty &&
      ((node.type == HeadingBlockKeys.type && !continuing) ||
          node.type == QuoteBlockKeys.type)) {
    transaction.add(DeleteOperation(node.path, [node]), transform: false);
    transaction.add(
      InsertOperation(node.path, [
        paragraphNode(
          attributes: {
            ...preservedEditorBlockAttributes(
              node,
              preservedAttributes: EditorCommandContext.of(
                state,
              ).configuration.blockConversionPreservedAttributes,
            ),
            if (continuing)
              ...attributes
            else
              for (final key in collabParagraphKeys)
                paragraphPropertyAttribute(key): key == 'depth'
                    ? '{"value":0}'
                    : '{"value":null}',
          },
        ),
      ]),
      transform: false,
    );
    transaction.afterSelection = selection;
  } else if (selection.isCollapsed && offset == 0 && delta.isNotEmpty) {
    attributes[blockComponentDelta] = Delta().toJson();
    transaction.insertNode(
      node.path,
      _freshParagraphNode(node.type, attributes),
    );
    transaction.afterSelection = Selection.collapsed(
      Position(path: node.path.next),
    );
  } else {
    transaction.deleteText(node, offset, delta.length - offset);
    if (nodes.length > 1) transaction.deleteNodes(nodes.skip(1));
    transaction.add(
      InsertOperation(node.path.next, [
        _freshParagraphNode(
          continuing ? node.type : ParagraphBlockKeys.type,
          attributes,
        ),
      ]),
      transform: false,
    );
    transaction.afterSelection = Selection.collapsed(
      Position(path: node.path.next),
    );
  }
  transaction
    ..selectionExtraInfo = {}
    ..customSelectionType = SelectionType.inline;
  await state.apply(transaction, skipHistoryDebounce: true);
  if (!state.isDisposed && state.selection == transaction.afterSelection) {
    for (final key in {
      ...collabCharacterKeys.values,
      ...collabTypographyKeys,
    }) {
      state.updateToggledStyle(key, continuing ? typing[key] : null);
    }
  }
  return true;
}

/// 创建 [type] 的新段落并复制借用的 [attributes]，显式标记新身份以避免范围删除后复用被删块。
/// 返回节点由文档/历史持有；不拥有编辑器或可释放资源。
Node _freshParagraphNode(String type, Attributes attributes) {
  final node = Node(type: type, attributes: {...attributes});
  node.updateAttributes({
    'cses_collab_block_id': node.id,
    collabParagraphTargetAttribute: node.id,
  });
  return node;
}
