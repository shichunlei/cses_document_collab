import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/collab_formula_sheet.dart';
import 'package:cses_document_collab/src/model/collab_formula.dart';
import 'package:cses_document_collab/src/ui/modal/collab_card_frame.dart';
import 'package:cses_document_collab/src/ui/modal/collab_formula_visual.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

/// 为正式 formula 注册可选中的无正文组件；点击打开公式编辑面板。
/// ```dart
/// import 'package:cses_document_collab/src/editor/collab_formula_block.dart';
/// final builder = CollabFormulaBlockComponentBuilder();
/// // 在 AppFlowyEditor 的 blockComponentBuilders 中以 'formula' 注册。
/// ```
class CollabFormulaBlockComponentBuilder extends BlockComponentBuilder {
  /// 创建无资源所有权的公式组件工厂，编辑器由页面持有。
  CollabFormulaBlockComponentBuilder();

  /// 拒绝正文 Delta 与子块，以保持桌面 void 结构。
  @override
  BlockComponentValidate get validate =>
      (node) => node.delta == null && node.children.isEmpty;

  /// 使用借用 [context] 的节点与配置创建组件，不写入共享属性。
  @override
  BlockComponentWidget build(BlockComponentContext context) => _FormulaBlock(
    key: context.node.key,
    node: context.node,
    configuration: configuration,
  );
}

/// 借用 AppFlowy 节点展示公式，无定时器、连接或输入控制器。
class _FormulaBlock extends BlockComponentStatefulWidget {
  /// [key] 控制身份与状态复用，[node] 与 [configuration] 均由编辑器持有。
  const _FormulaBlock({
    super.key,
    required super.node,
    required super.configuration,
  });

  /// 创建整块选区代理，编辑器仍由调用方持有。
  @override
  State<_FormulaBlock> createState() => _FormulaBlockState();
}

/// 为无正文块提供完整矩形选区与远端选中展示。
class _FormulaBlockState extends State<_FormulaBlock> with SelectableMixin {
  /// 内部视觉边界，随本 Widget 释放，不绑定编辑输入。
  final _bodyKey = GlobalKey();

  /// 在借用[context]内居中显示无标题卡片，整卡点击打开统一公式面板，不保留更多按钮占位。
  /// 已锁定块仍可打开查看/授权锁操作；文档预览模式仅展示公式。
  @override
  Widget build(BuildContext context) {
    final editor = context.read<EditorState>();
    final node = widget.node;
    final id = node.attributes['cses_collab_block_id'] as String? ?? node.id;
    final visual = CollabFormulaVisual(
      key: ValueKey('collab-formula-visual-$id'),
      latex: readCollabFormula(node.attributes).string('latex'),
    );
    final child = Semantics(
      label: '公式',
      button: editor.editable,
      readOnly: !editor.editable,
      child: ExcludeFocus(
        child: GestureDetector(
          key: ValueKey('collab-formula-$id'),
          behavior: HitTestBehavior.opaque,
          onTap: editor.editable
              ? () async {
                  await showCollabFormulaEditor(context, editor, id);
                }
              : null,
          child: visual,
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
      child: KeyedSubtree(
        key: _bodyKey,
        child: CollabCardFrame(
          surfaceKey: ValueKey('collab-formula-card-$id'),
          margin: const EdgeInsets.symmetric(vertical: 8),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 52),
            child: child,
          ),
        ),
      ),
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
  Rect? getCursorRectInPosition(
    Position position, {
    bool shiftWithBaseOffset = false,
  }) => getBlockRect();

  /// [selection] 对应完整矩形，[shiftWithBaseOffset] 保持组件内坐标约定。
  @override
  List<Rect> getRectsInSelection(
    Selection selection, {
    bool shiftWithBaseOffset = false,
  }) => [getBlockRect()];

  /// [start]/[end] 的拖动范围总是映射为无正文块的完整选区。
  @override
  Selection getSelectionInRange(Offset start, Offset end) =>
      Selection.single(path: widget.node.path, startOffset: 0, endOffset: 1);

  /// 将 [offset] 转为全局坐标，[shiftWithBaseOffset] 不改变组件原点约定。
  @override
  Offset localToGlobal(Offset offset, {bool shiftWithBaseOffset = false}) =>
      (context.findRenderObject() as RenderBox).localToGlobal(offset);
}
