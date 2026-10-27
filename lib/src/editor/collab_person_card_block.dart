import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/collab_block_actions.dart';
import 'package:cses_document_collab/src/editor/collab_block_locks.dart';
import 'package:cses_document_collab/src/editor/collab_person_card_settings.dart';
import 'package:cses_document_collab/src/model/collab_person_card.dart';
import 'package:cses_document_collab/src/ui/modal/collab_person_card_visual.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

/// 为正式 person-card 注册可选中的无正文组件；点击整卡打开设置、锁定与整块删除操作。
/// ```dart
/// import 'package:appflowy_editor/appflowy_editor.dart';
/// import 'package:cses_document_collab/src/editor/collab_person_card_block.dart';
/// final state = EditorState.blank(); // 页面关闭时由创建方 dispose。
/// final editor = AppFlowyEditor(editorState: state, blockComponentBuilders: {
///   ...standardBlockComponentBuilderMap,
///   'person-card': CollabPersonCardBlockComponentBuilder(),
/// });
/// ```
class CollabPersonCardBlockComponentBuilder extends BlockComponentBuilder {
  /// 创建无资源所有权的人员卡片组件工厂，编辑器由页面持有。
  CollabPersonCardBlockComponentBuilder();

  /// 拒绝正文 Delta 与子块，以保持桌面 void 结构。
  @override
  BlockComponentValidate get validate =>
      (node) => node.type == collabPersonCardType && node.delta == null && node.children.isEmpty;

  /// 使用借用 [context] 的节点与配置创建组件，不写入共享属性。
  @override
  BlockComponentWidget build(BlockComponentContext context) =>
      _PersonCardBlock(key: context.node.key, node: context.node, configuration: configuration);
}

/// 借用 AppFlowy 节点展示人员卡片，无定时器、连接或输入控制器。
class _PersonCardBlock extends BlockComponentStatefulWidget {
  /// [key] 控制身份与状态复用，[node] 与 [configuration] 均由编辑器持有。
  const _PersonCardBlock({super.key, required super.node, required super.configuration});

  /// 创建整块选区代理，编辑器仍由调用方持有。
  @override
  createState() => _PersonCardBlockState();
}

/// 为无正文块提供完整矩形选区与远端选中展示。
class _PersonCardBlockState extends State<_PersonCardBlock> with SelectableMixin {
  /// 内部视觉边界，随本 Widget 释放，不绑定编辑输入。
  final _bodyKey = GlobalKey();

  /// 在借用 [context] 内构建无额外外框的人员卡片，点击整卡打开样式设置、删除及公共锁操作。
  /// 锁定时仅保留公共查看/解锁操作；只读时隐藏修改入口。
  /// 锁标由卡片本体展示层定位，不使用整行宽度作为标记边界。
  @override
  Widget build(BuildContext context) {
    final editor = context.read<EditorState>();
    final node = widget.node;
    final id = node.attributes['cses_collab_block_id'] as String? ?? node.id;
    final child = CollabBlockMoreButton(
      editor: editor,
      node: node,
      actions: [
        (
          label: '人员设置',
          key: const ValueKey('person-card-settings'),
          run: () async => await showCollabPersonCardSettings(context, editor, id),
        ),
        (
          label: '删除人员卡片',
          key: const ValueKey('person-card-delete'),
          run: () async {
            final current = findCollabPersonCard(editor, id);
            if (current == null || !canEditCollabNode(editor, current)) return;
            final transaction = editor.transaction..deleteNode(current);
            if (current.parent!.children.length == 1) {
              transaction.add(InsertOperation(current.path, [paragraphNode()]), transform: false);
            }
            transaction.afterSelection = null;
            if (editor.undoManager.undoStack.isNonEmpty) editor.undoManager.undoStack.last.seal();
            await editor.apply(transaction, withUpdateSelection: false, skipHistoryDebounce: true);
          },
        ),
      ],
      triggerBuilder: (context, onPressed) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Semantics(
          label: '人员卡片操作',
          button: onPressed != null,
          child: GestureDetector(
            key: _bodyKey,
            behavior: HitTestBehavior.opaque,
            onTap: onPressed,
            child: SizedBox(
              width: double.infinity,
              child: CollabPersonCardVisual(
                card: CollabPersonCard(CollabPersonCard.readAttributes(node.attributes).values),
              ),
            ),
          ),
        ),
      ),
    );
    return BlockSelectionContainer(
      node: node,
      delegate: this,
      listenable: editor.selectionNotifier,
      remoteSelection: editor.remoteSelections,
      blockColor: editor.editorStyle.selectionColor,
      supportTypes: const [BlockSelectionType.block],
      selectionAboveBlock: true,
      child: child,
    );
  }

  /// 返回当前节点的整块起点。
  @override
  Position start() => Position(path: widget.node.path);

  /// 返回当前节点的整块终点（虚拟偏移 1）。
  @override
  Position end() => Position(path: widget.node.path, offset: 1);

  /// [offset] 无文本对应关系，任意命中选择整块终点。
  @override
  Position getPositionInOffset(Offset offset) => end();

  /// 无正文光标不闪烁。
  @override
  bool get shouldCursorBlink => false;

  /// 整块选择覆盖视觉区域。
  @override
  CursorStyle get cursorStyle => CursorStyle.cover;

  /// 返回块在组件内的矩形；[shiftWithBaseOffset] 沿用组件局部原点。
  @override
  Rect getBlockRect({bool shiftWithBaseOffset = false}) {
    final outer = context.findRenderObject();
    final inner = _bodyKey.currentContext?.findRenderObject();
    if (outer is! RenderBox || inner is! RenderBox) return Rect.zero;
    return inner.localToGlobal(Offset.zero, ancestor: outer) & inner.size;
  }

  /// [position] 命中整块，[shiftWithBaseOffset] 保持组件内坐标约定。
  @override
  Rect? getCursorRectInPosition(Position position, {bool shiftWithBaseOffset = false}) => getBlockRect();

  /// [selection] 对应完整矩形，[shiftWithBaseOffset] 保持组件内坐标约定。
  @override
  List<Rect> getRectsInSelection(Selection selection, {bool shiftWithBaseOffset = false}) => [getBlockRect()];

  /// [start]/[end] 的拖动范围总是映射为无正文块的完整选区。
  @override
  Selection getSelectionInRange(Offset start, Offset end) =>
      Selection.single(path: widget.node.path, startOffset: 0, endOffset: 1);

  /// 将 [offset] 转为全局坐标，[shiftWithBaseOffset] 不改变组件原点约定。
  @override
  Offset localToGlobal(Offset offset, {bool shiftWithBaseOffset = false}) =>
      (context.findRenderObject() as RenderBox).localToGlobal(offset);
}
