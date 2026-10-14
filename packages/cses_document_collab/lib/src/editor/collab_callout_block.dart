import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/model/collab_block_colors.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

/// A real container: child paragraphs retain their own input and selection delegates.
class CollabCalloutBlockComponentBuilder extends BlockComponentBuilder {
  @override
  BlockComponentValidate get validate =>
      (node) => node.delta == null;

  @override
  BlockComponentWidget build(BlockComponentContext context) => _CalloutBlock(
    key: context.node.key,
    node: context.node,
    configuration: configuration,
  );
}

class _CalloutBlock extends BlockComponentStatefulWidget {
  const _CalloutBlock({
    super.key,
    required super.node,
    required super.configuration,
  });

  @override
  State<_CalloutBlock> createState() => _CalloutBlockState();
}

class _CalloutBlockState extends State<_CalloutBlock> with SelectableMixin {
  final _bodyKey = GlobalKey();
  late final _editor = context.read<EditorState>();

  @override
  Widget build(BuildContext context) {
    final node = widget.node;
    final prefix = node.attributes[csesCalloutPrefixAttribute] as String? ?? '';
    final color = parseCollabBlockColor(
      node.attributes[csesBlockTextColorAttribute] as String?,
    );
    final child = Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Container(
        key: _bodyKey,
        decoration: BoxDecoration(
          color:
              parseCollabBlockColor(
                node.attributes[csesBlockBackgroundColorAttribute] as String?,
              ) ??
              Colors.transparent,
          border: Border.all(
            color:
                parseCollabBlockColor(
                  node.attributes[csesBlockBorderColorAttribute] as String?,
                ) ??
                Colors.transparent,
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
                  onTap: _editor.editable
                      ? () =>
                            showCollabCalloutEmojiPicker(context, _editor, node)
                      : null,
                  borderRadius: BorderRadius.circular(4),
                  child: Tooltip(
                    message: _editor.editable ? '更换表情' : prefix,
                    child: Padding(
                      padding: const EdgeInsets.only(
                        right: 12,
                        top: 2,
                        bottom: 2,
                      ),
                      child: prefix.isEmpty
                          ? const Icon(Icons.add_reaction_outlined, size: 20)
                          : Text(
                              prefix,
                              style: TextStyle(
                                fontSize: 18,
                                height: 1.5,
                                color: color,
                              ),
                            ),
                    ),
                  ),
                ),
              ),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final child in node.children)
                    _editor.renderer.build(context, child),
                  if (node.children.isEmpty && _editor.editable)
                    TextButton(
                      key: const ValueKey('collab-callout-add-body'),
                      onPressed: () async {
                        if (!_editor.editable || _editor.isDisposed) return;
                        final transaction = _editor.transaction
                          ..insertNode(node.path + [0], paragraphNode())
                          ..afterSelection = Selection.single(
                            path: node.path + [0],
                            startOffset: 0,
                          );
                        await _editor.apply(transaction);
                      },
                      child: const Text('添加正文'),
                    ),
                ],
              ),
            ),
            if (_editor.editable)
              ExcludeFocus(
                child: SizedBox.square(
                  dimension: 28,
                  child: IconButton(
                    key: const ValueKey('collab-callout-settings'),
                    tooltip: '设置高亮块颜色',
                    padding: EdgeInsets.zero,
                    iconSize: 17,
                    color: const Color(0xFF8A8F98),
                    onPressed: () =>
                        showCollabCalloutSettings(context, _editor, node),
                    icon: const Icon(Icons.tune),
                  ),
                ),
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
  Rect? getCursorRectInPosition(
    Position position, {
    bool shiftWithBaseOffset = false,
  }) => getBlockRect();
  @override
  List<Rect> getRectsInSelection(
    Selection selection, {
    bool shiftWithBaseOffset = false,
  }) => [getBlockRect()];
  @override
  Selection getSelectionInRange(Offset start, Offset end) =>
      Selection.single(path: widget.node.path, startOffset: 0, endOffset: 1);
  @override
  Offset localToGlobal(Offset offset, {bool shiftWithBaseOffset = false}) =>
      (context.findRenderObject() as RenderBox).localToGlobal(offset);
}

Node? _findCallout(EditorState editor, String id) {
  Node? visit(Node node) {
    if (node.type == csesCalloutBlockType &&
        (node.attributes[AppFlowyBlockEditorAdapter.collabBlockIdAttribute] ??
                node.id) ==
            id) {
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
Future<void> updateCollabCalloutAppearance(
  EditorState editor,
  String id,
  String attribute,
  String? value,
) async {
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
  await editor.apply(
    transaction,
    withUpdateSelection: false,
    skipHistoryDebounce: true,
  );
}

Future<void> showCollabCalloutSettings(
  BuildContext context,
  EditorState editor,
  Node node,
) => _showCalloutSettings(context, editor, node, _CalloutSettingsKind.colors);

Future<void> showCollabCalloutEmojiPicker(
  BuildContext context,
  EditorState editor,
  Node node,
) => _showCalloutSettings(context, editor, node, _CalloutSettingsKind.emoji);

enum _CalloutSettingsKind { emoji, colors }

Future<void> _showCalloutSettings(
  BuildContext context,
  EditorState editor,
  Node node,
  _CalloutSettingsKind kind,
) async {
  if (!editor.editable || editor.isDisposed) return;
  final id =
      node.attributes[AppFlowyBlockEditorAdapter.collabBlockIdAttribute]
          as String? ??
      node.id;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.white,
    builder: (_) => _CalloutSettings(editor: editor, id: id, kind: kind),
  );
}

class _CalloutSettings extends StatefulWidget {
  const _CalloutSettings({
    required this.editor,
    required this.id,
    required this.kind,
  });
  final EditorState editor;
  final String id;
  final _CalloutSettingsKind kind;
  @override
  State<_CalloutSettings> createState() => _CalloutSettingsState();
}

class _CalloutSettingsState extends State<_CalloutSettings> {
  TextEditingController? _prefix;
  Node? get _node =>
      widget.editor.isDisposed ? null : _findCallout(widget.editor, widget.id);

  @override
  void initState() {
    super.initState();
    if (widget.kind == _CalloutSettingsKind.emoji) {
      _prefix = TextEditingController(
        text: _node?.attributes[csesCalloutPrefixAttribute] as String? ?? '',
      );
    }
  }

  static const _emoji = [
    '📢',
    '💡',
    '🤪',
    '😀',
    '📝',
    '✅',
    '⚠️',
    '❗',
    '⭐',
    '🎯',
    '🔥',
    '❤️',
    '🚀',
    '📌',
    '💬',
    '🎉',
  ];
  static const _colors = [
    ('orange', '橙色', '#FFE6CD'),
    ('pink', '粉色', '#F6E5F0'),
    ('yellow', '黄色', '#FFF4C2'),
    ('green', '绿色', '#DDF3E4'),
    ('blue', '蓝色', '#DFEAFC'),
    ('purple', '紫色', '#EAE3FA'),
    ('gray', '灰色', '#F0F1F3'),
    ('white', '白色', '#FFFFFF'),
  ];

  Future<void> _set(String attribute, String? value) async {
    if (widget.editor.isDisposed || !widget.editor.editable || _node == null) {
      return;
    }
    await updateCollabCalloutAppearance(
      widget.editor,
      widget.id,
      attribute,
      value,
    );
    if (!mounted) return;
    if (widget.kind == _CalloutSettingsKind.emoji &&
        attribute == csesCalloutPrefixAttribute) {
      if (ModalRoute.of(context)?.isCurrent == true) Navigator.pop(context);
    } else {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _prefix?.dispose();
    super.dispose();
  }

  Widget _colorRow(String label, String attribute, String key) {
    final current = parseCollabBlockColor(
      _node?.attributes[attribute] as String?,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 4,
          runSpacing: 4,
          children: [
            IconButton(
              key: ValueKey('callout-$key-clear'),
              tooltip: '透明',
              onPressed: () => _set(attribute, null),
              icon: const Icon(Icons.format_color_reset),
            ),
            for (final option in _colors)
              IconButton(
                key: ValueKey('callout-$key-${option.$1}'),
                tooltip: option.$2,
                onPressed: () => _set(attribute, option.$3),
                icon: Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    color: parseCollabBlockColor(option.$3),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: const Color(0x22000000)),
                  ),
                  child: current == parseCollabBlockColor(option.$3)
                      ? const Icon(
                          Icons.check,
                          size: 17,
                          color: Color(0xFF333333),
                        )
                      : null,
                ),
              ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final enabled =
        !widget.editor.isDisposed && widget.editor.editable && _node != null;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          8,
          20,
          20 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * .8,
          ),
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
                        widget.kind == _CalloutSettingsKind.emoji
                            ? '设置表情'
                            : '设置颜色',
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '完成',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                    ),
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
                        if (widget.kind == _CalloutSettingsKind.emoji) ...[
                          const Text('表情'),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 2,
                            children: [
                              for (final emoji in _emoji)
                                TextButton(
                                  key: ValueKey('callout-emoji-$emoji'),
                                  onPressed: () {
                                    _prefix!.text = emoji;
                                    _set(csesCalloutPrefixAttribute, emoji);
                                  },
                                  style: TextButton.styleFrom(
                                    minimumSize: const Size(42, 42),
                                    padding: const EdgeInsets.all(4),
                                  ),
                                  child: Text(
                                    emoji,
                                    style: const TextStyle(fontSize: 24),
                                  ),
                                ),
                              TextButton(
                                key: const ValueKey('callout-emoji-clear'),
                                onPressed: () {
                                  _prefix!.clear();
                                  _set(csesCalloutPrefixAttribute, '');
                                },
                                child: const Text('移除'),
                              ),
                            ],
                          ),
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  key: const ValueKey('callout-custom-prefix'),
                                  controller: _prefix,
                                  maxLength: 32,
                                  decoration: const InputDecoration(
                                    hintText: '输入或粘贴其他表情',
                                    counterText: '',
                                  ),
                                  onSubmitted: (value) =>
                                      _set(csesCalloutPrefixAttribute, value),
                                ),
                              ),
                              TextButton(
                                key: const ValueKey('callout-prefix-apply'),
                                onPressed: () => _set(
                                  csesCalloutPrefixAttribute,
                                  _prefix!.text,
                                ),
                                child: const Text('应用'),
                              ),
                            ],
                          ),
                        ] else ...[
                          const SizedBox(height: 8),
                          _colorRow(
                            '背景色',
                            csesBlockBackgroundColorAttribute,
                            'background',
                          ),
                          const SizedBox(height: 16),
                          _colorRow(
                            '边框色',
                            csesBlockBorderColorAttribute,
                            'border',
                          ),
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
Future<Selection?> insertCollabCallout(
  EditorState editor,
  Selection? selection,
) async {
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
