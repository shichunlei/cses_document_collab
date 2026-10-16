import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/editor/collab_block_actions.dart';
import 'package:cses_document_collab/src/editor/collab_color_picker.dart';
import 'package:cses_document_collab/src/editor/collab_emoji_picker.dart';
import 'package:cses_document_collab/src/model/collab_block_colors.dart';
import 'package:cses_document_collab/src/model/collab_color_palette.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

/// A real container: child paragraphs retain their own input and selection delegates.
class CollabCalloutBlockComponentBuilder extends BlockComponentBuilder {
  @override
  BlockComponentValidate get validate =>
      (node) => node.delta == null;

  @override
  BlockComponentWidget build(BlockComponentContext context) =>
      _CalloutBlock(key: context.node.key, node: context.node, configuration: configuration);
}

class _CalloutBlock extends BlockComponentStatefulWidget {
  const _CalloutBlock({super.key, required super.node, required super.configuration});

  @override
  createState() => _CalloutBlockState();
}

class _CalloutBlockState extends State<_CalloutBlock> with SelectableMixin {
  final _bodyKey = GlobalKey();
  late final _editor = context.read<EditorState>();

  /// 在 [context] 中渲染子块，背景按桌面82%不透明度混合，不改变原始颜色属性。
  /// 保留输入、选区、只读展示和安全容器删除。
  @override
  Widget build(BuildContext context) {
    final node = widget.node;
    final host = collabBlockActionContext(context);
    final prefix = node.attributes[csesCalloutPrefixAttribute] as String? ?? '';
    final color = parseCollabBlockColor(node.attributes[csesBlockTextColorAttribute] as String?);
    final child = Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Container(
        key: _bodyKey,
        decoration: BoxDecoration(
          color: _calloutBackground(node.attributes[csesBlockBackgroundColorAttribute] as String?),
          border: Border.all(
            color:
                parseCollabBlockColor(node.attributes[csesBlockBorderColorAttribute] as String?) ?? Colors.transparent,
          ),
          borderRadius: BorderRadius.circular(4),
        ),
        padding: const EdgeInsets.fromLTRB(12, 12, 8, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (prefix.isNotEmpty || _editor.editable)
              ExcludeFocus(
                child: InkWell(
                  key: const ValueKey('collab-callout-prefix'),
                  onTap: _editor.editable ? () => showCollabCalloutEmojiPicker(context, _editor, node) : null,
                  borderRadius: BorderRadius.circular(4),
                  child: Tooltip(
                    message: _editor.editable ? '更换表情' : prefix,
                    child: Padding(
                      padding: const EdgeInsets.only(right: 12, top: 2, bottom: 2),
                      child: prefix.isEmpty
                          ? const Icon(Icons.add_reaction_outlined, size: 20)
                          : Text(prefix, style: TextStyle(fontSize: 18, height: 1.5, color: color)),
                    ),
                  ),
                ),
              ),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final child in node.children) _editor.renderer.build(context, child),
                  if (node.children.isEmpty && _editor.editable)
                    TextButton(
                      key: const ValueKey('collab-callout-add-body'),
                      onPressed: () async {
                        if (!_editor.editable || _editor.isDisposed) return;
                        final transaction = _editor.transaction
                          ..insertNode(node.path + [0], paragraphNode())
                          ..afterSelection = Selection.single(path: node.path + [0], startOffset: 0);
                        await _editor.apply(transaction);
                      },
                      child: const Text('添加正文'),
                    ),
                ],
              ),
            ),
            CollabBlockMoreButton(
              key: ValueKey('block-more-${node.attributes['cses_collab_block_id'] ?? node.id}'),
              editor: _editor,
              node: node,
              protectSubtree: true,
              actions: [
                (
                  label: '颜色设置',
                  key: const ValueKey('collab-callout-settings'),
                  run: () async {
                    final current = findCollabActionNode(
                      _editor,
                      node.attributes['cses_collab_block_id'] as String? ?? node.id,
                    );
                    if (host.mounted && current != null) {
                      await showCollabCalloutSettings(host, _editor, current);
                    }
                  },
                ),
                if (!_containsUnsupportedCalloutContent(node))
                  (
                    label: '删除高亮块',
                    key: ValueKey('callout-delete-${node.attributes['cses_collab_block_id'] ?? node.id}'),
                    run: () async {
                      await _deleteCallout(_editor, node.attributes['cses_collab_block_id'] as String? ?? node.id);
                    },
                  ),
              ],
            ),
          ],
        ),
      ),
    );
    return BlockSelectionContainer(
      node: node,
      delegate: this,
      listenable: _editor.selectionNotifier,
      remoteSelection: _editor.remoteSelections,
      blockColor: _editor.editorStyle.selectionColor,
      supportTypes: const [BlockSelectionType.block],
      selectionAboveBlock: true,
      child: child,
    );
  }

  @override
  Position start() => Position(path: widget.node.path);

  @override
  Position end() => Position(path: widget.node.path, offset: 1);

  @override
  Position getPositionInOffset(Offset offset) => end();

  @override
  bool get shouldCursorBlink => false;

  @override
  CursorStyle get cursorStyle => CursorStyle.cover;

  @override
  Rect getBlockRect({bool shiftWithBaseOffset = false}) {
    final outer = context.findRenderObject();
    final inner = _bodyKey.currentContext?.findRenderObject();
    if (outer is! RenderBox || inner is! RenderBox) return Rect.zero;
    return inner.localToGlobal(Offset.zero, ancestor: outer) & inner.size;
  }

  @override
  Rect? getCursorRectInPosition(Position position, {bool shiftWithBaseOffset = false}) => getBlockRect();

  @override
  List<Rect> getRectsInSelection(Selection selection, {bool shiftWithBaseOffset = false}) => [getBlockRect()];

  @override
  Selection getSelectionInRange(Offset start, Offset end) =>
      Selection.single(path: widget.node.path, startOffset: 0, endOffset: 1);

  @override
  Offset localToGlobal(Offset offset, {bool shiftWithBaseOffset = false}) =>
      (context.findRenderObject() as RenderBox).localToGlobal(offset);
}

/// 将已有 [value] 仅在渲染时按桌面82%不透明度混合，保留源alpha及原始属性。
Color _calloutBackground(String? value) {
  final color = parseCollabBlockColor(value) ?? Colors.transparent;
  return color.withValues(alpha: color.a * .82);
}

/// Reports whether borrowed [node] contains an opaque unsupported descendant.
/// These subtrees cannot be reconstructed by local history and must not be deleted.
bool _containsUnsupportedCalloutContent(Node node) =>
    node.type == csesUnsupportedBlockType || node.children.any(_containsUnsupportedCalloutContent);

/// Deletes the current callout with stable [id] and its children from borrowed [editor].
/// Root/callout parents are supported; the last sibling is replaced by a fresh empty
/// paragraph. Readonly, disposed, deleted and opaque targets are ignored. Records
/// one undo step without restoring keyboard focus; apply failures propagate to the
/// menu boundary. The editor retains ownership of the document and undo snapshots.
Future<void> _deleteCallout(EditorState editor, String id) async {
  if (editor.isDisposed || !editor.editable) return;
  final node = findCollabActionNode(editor, id);
  if (node == null ||
      node.type != csesCalloutBlockType ||
      !const {'page', 'callout'}.contains(node.parent?.type) ||
      _containsUnsupportedCalloutContent(node)) {
    return;
  }
  final path = node.path;
  final lastSibling = node.parent!.children.length == 1;
  if (editor.undoManager.undoStack.isNonEmpty) {
    editor.undoManager.undoStack.last.seal();
  }
  final transaction = editor.transaction
    ..add(DeleteOperation(path, [node]), transform: false)
    ..afterSelection = null;
  if (lastSibling) {
    final paragraph = paragraphNode();
    paragraph.updateAttributes({AppFlowyBlockEditorAdapter.collabBlockIdAttribute: paragraph.id});
    transaction.add(InsertOperation(path, [paragraph]), transform: false);
  }
  await editor.apply(transaction, withUpdateSelection: false, skipHistoryDebounce: true);
}

Node? _findCallout(EditorState editor, String id) {
  Node? visit(Node node) {
    if (node.type == csesCalloutBlockType &&
        (node.attributes[AppFlowyBlockEditorAdapter.collabBlockIdAttribute] ?? node.id) == id) {
      return node;
    }
    for (final child in node.children) {
      final found = visit(child);
      if (found != null) return found;
    }
    return null;
  }

  return visit(editor.document.root);
}

/// One field per transaction so undo never restores stale body text or other colors.
Future<void> updateCollabCalloutAppearance(EditorState editor, String id, String attribute, String? value) async {
  if (editor.isDisposed ||
      !editor.editable ||
      !const {
        csesCalloutPrefixAttribute,
        csesBlockTextColorAttribute,
        csesBlockBackgroundColorAttribute,
        csesBlockBorderColorAttribute,
      }.contains(attribute)) {
    return;
  }
  final node = _findCallout(editor, id);
  if (node == null || node.attributes[attribute] == value) return;
  if (editor.undoManager.undoStack.isNonEmpty) {
    editor.undoManager.undoStack.last.seal();
  }
  final transaction = editor.transaction
    ..add(
      UpdateOperation(
        node.path,
        {attribute: value, csesCalloutTargetAttribute: id},
        {attribute: node.attributes[attribute], csesCalloutTargetAttribute: id},
      ),
    );
  await editor.apply(transaction, withUpdateSelection: false, skipHistoryDebounce: true);
}

Future<void> showCollabCalloutSettings(BuildContext context, EditorState editor, Node node) =>
    _showCalloutSettings(context, editor, node, _CalloutSettingsKind.colors);

Future<void> showCollabCalloutEmojiPicker(BuildContext context, EditorState editor, Node node) =>
    _showCalloutSettings(context, editor, node, _CalloutSettingsKind.emoji);

enum _CalloutSettingsKind { emoji, colors }

Future<void> _showCalloutSettings(
  BuildContext context,
  EditorState editor,
  Node node,
  _CalloutSettingsKind kind,
) async {
  if (!editor.editable || editor.isDisposed) return;
  final id = node.attributes[AppFlowyBlockEditorAdapter.collabBlockIdAttribute] as String? ?? node.id;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.white,
    builder: (_) => _CalloutSettings(editor: editor, id: id, kind: kind),
  );
}

/// 借用编辑器和稳定块身份的外观面板，不拥有编辑器资源。
class _CalloutSettings extends StatefulWidget {
  /// [editor] 由宿主持有，[id] 为稳定块身份，[kind] 决定颜色或表情面板。
  const _CalloutSettings({required this.editor, required this.id, required this.kind});

  /// 借用的编辑器，保存前检查存活及编辑权限。
  final EditorState editor;

  /// 必填稳定块身份，避免远端重排后写入其他块。
  final String id;

  /// 必填面板类型。
  final _CalloutSettingsKind kind;

  /// 创建仅管理面板回显的状态，不接管文档资源。
  @override
  createState() => _CalloutSettingsState();
}

/// 用字段级事务处理外观，不保存正文或替换已有自定义颜色。
class _CalloutSettingsState extends State<_CalloutSettings> {
  /// 每次保存重新查找稳定目标，不持有可能被远端删除的旧节点。
  Node? get _node => widget.editor.isDisposed ? null : _findCallout(widget.editor, widget.id);

  /// 保存 [attribute] 对应的 [value]；只提交一个字段，空值语义由所属属性决定。
  /// 表情保存后关闭面板，颜色保存后继续选择；失败交由共用选择器提示。
  Future<void> _set(String attribute, String? value) async {
    if (widget.editor.isDisposed || !widget.editor.editable || _node == null) {
      return;
    }
    await updateCollabCalloutAppearance(widget.editor, widget.id, attribute, value);
    if (!mounted) return;
    if (widget.kind == _CalloutSettingsKind.emoji && attribute == csesCalloutPrefixAttribute) {
      if (ModalRoute.of(context)?.isCurrent == true) Navigator.pop(context);
    } else {
      setState(() {});
    }
  }

  /// 为 [label] 与 [attribute] 构建共用色板，使用 [key] 保持入口标识。
  /// 字色使用深色、背景和边框使用浅色，既有自定义值按原文回显。
  Widget _colorRow(String label, String attribute, String key) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
      const SizedBox(height: 8),
      CollabColorPicker(
        keyPrefix: 'callout-$key',
        enabled: !widget.editor.isDisposed && widget.editor.editable && _node != null,
        textColors: attribute == csesBlockTextColorAttribute,
        selection: CollabColorSelection(_node?.attributes[attribute] as String?),
        onSelected: (value) => _set(attribute, value),
      ),
    ],
  );

  /// 按 [context] 约束展示共用表情或三组颜色，保存时重新核对目标和权限。
  @override
  Widget build(BuildContext context) {
    final enabled = !widget.editor.isDisposed && widget.editor.editable && _node != null;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 8, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * .8),
          child: SingleChildScrollView(
            key: ValueKey(
              widget.kind == _CalloutSettingsKind.emoji
                  ? 'callout-emoji-settings-panel'
                  : 'callout-color-settings-panel',
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.kind == _CalloutSettingsKind.emoji ? '设置表情' : '设置颜色',
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                      ),
                    ),
                    IconButton(tooltip: '完成', onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
                  ],
                ),
                if (!enabled) const Text('当前高亮块不可编辑'),
                IgnorePointer(
                  ignoring: !enabled,
                  child: Opacity(
                    opacity: enabled ? 1 : .45,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (widget.kind == _CalloutSettingsKind.emoji)
                          CollabEmojiPicker(
                            keyPrefix: 'callout-emoji',
                            current: _node?.attributes[csesCalloutPrefixAttribute] as String?,
                            enabled: enabled,
                            onSelected: (value) => _set(csesCalloutPrefixAttribute, value),
                            onClear: () => _set(csesCalloutPrefixAttribute, ''),
                          )
                        else ...[
                          const SizedBox(height: 8),
                          _colorRow('文字颜色', csesBlockTextColorAttribute, 'text'),
                          const SizedBox(height: 16),
                          _colorRow('背景色', csesBlockBackgroundColorAttribute, 'background'),
                          const SizedBox(height: 16),
                          _colorRow('边框色', csesBlockBorderColorAttribute, 'border'),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Inserts a desktop-compatible container after the current root block.
Future<Selection?> insertCollabCallout(EditorState editor, Selection? selection) async {
  if (!editor.editable || editor.isDisposed) return null;
  final roots = editor.document.root.children;
  final index = selection == null || selection.start.path.isEmpty
      ? roots.length
      : (selection.start.path.first + 1).clamp(0, roots.length);
  final node = Node(
    type: csesCalloutBlockType,
    attributes: {
      csesCalloutPrefixAttribute: '📢',
      csesBlockTextColorAttribute: '#333',
      csesBlockBackgroundColorAttribute: '#FFE6CD',
      csesBlockBorderColorAttribute: 'transparent',
    },
    children: [paragraphNode()],
  );
  node.updateAttributes({
    AppFlowyBlockEditorAdapter.collabBlockIdAttribute: node.id,
    csesCalloutTargetAttribute: node.id,
  });
  final caret = Selection.single(path: [index, 0], startOffset: 0);
  final transaction = editor.transaction
    ..insertNode([index], node)
    ..afterSelection = caret;
  await editor.apply(transaction);
  return caret;
}
