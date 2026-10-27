import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/collab_block_actions.dart';
import 'package:cses_document_collab/src/editor/collab_block_locks.dart';
import 'package:cses_document_collab/src/model/collab_page_divider.dart';
import 'package:cses_document_collab/src/ui/modal/collab_card_frame.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

/// 为正式 page-divider 注册可选中的无正文组件；点击整条标记打开公共操作菜单。
/// ```dart
/// import 'package:appflowy_editor/appflowy_editor.dart';
/// import 'package:cses_document_collab/src/editor/collab_page_divider_block.dart';
/// final state = EditorState.blank(); // 页面关闭时由创建方 dispose。
/// final editor = AppFlowyEditor(editorState: state, blockComponentBuilders: {
///   ...standardBlockComponentBuilderMap,
///   'page-divider': CollabPageDividerBlockComponentBuilder(),
/// });
/// ```
class CollabPageDividerBlockComponentBuilder extends BlockComponentBuilder {
  /// 创建无资源所有权的分页符组件工厂，编辑器由页面持有。
  CollabPageDividerBlockComponentBuilder();

  /// 拒绝正文 Delta 与子块，以保持桌面 void 结构。
  @override
  BlockComponentValidate get validate =>
      (node) => node.delta == null && node.children.isEmpty;

  /// 使用借用 [context] 的节点与配置创建组件，不写入共享属性。
  @override
  BlockComponentWidget build(BlockComponentContext context) =>
      _PageDividerBlock(
        key: context.node.key,
        node: context.node,
        configuration: configuration,
      );
}

/// 借用 AppFlowy 节点展示分页符，无定时器、连接或输入控制器。
class _PageDividerBlock extends BlockComponentStatefulWidget {
  /// [key] 控制身份与状态复用，[node] 与 [configuration] 均由编辑器持有。
  const _PageDividerBlock({
    super.key,
    required super.node,
    required super.configuration,
  });

  /// 创建整块选区代理，编辑器仍由调用方持有。
  @override
  State<_PageDividerBlock> createState() => _PageDividerBlockState();
}

/// 为无正文块提供完整矩形选区与远端选中展示。
class _PageDividerBlockState extends State<_PageDividerBlock>
    with SelectableMixin {
  /// 内部视觉边界，随本 Widget 释放，不绑定编辑输入。
  final _bodyKey = GlobalKey();

  /// 在借用 [context] 内构建整条可点击的分页符，标记及菜单共用横向分页分隔图标。
  /// 整条点击沿用公共菜单及当前文档权限，锁定时保留查看和允许的解锁操作。
  /// 有效块锁生效时使用无标题卡片外框，保留整条菜单入口，不添加右侧更多按钮。
  @override
  Widget build(BuildContext context) {
    final editor = context.read<EditorState>();
    final node = widget.node;
    final id = node.attributes['cses_collab_block_id'] as String? ?? node.id;
    final locked = CollabBlockLocks.of(editor)?.state(id).locked ?? false;
    final child = CollabBlockMoreButton(
      editor: editor,
      node: node,
      menuTitle: '分页符操作',
      menuIcon: LucideIcons.separatorHorizontal,
      actions: [
        (
          label: '删除分页符',
          key: const ValueKey('page-divider-delete'),
          run: () async {
            await deleteCollabPageDivider(editor, id);
          },
        ),
      ],
      triggerBuilder: (context, onPressed) => Semantics(
        label: '分页符，分页布局中从下一页开始',
        button: onPressed != null,
        readOnly: locked || !editor.editable,
        child: GestureDetector(
          key: ValueKey('collab-page-divider-$id'),
          behavior: HitTestBehavior.opaque,
          onTap: onPressed,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  Expanded(child: _PageDividerSegment()),
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(LucideIcons.separatorHorizontal, size: 14),
                        SizedBox(width: 4),
                        Text('分页符', style: TextStyle(fontSize: 12)),
                      ],
                    ),
                  ),
                  Expanded(child: _PageDividerSegment()),
                ],
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
      child: KeyedSubtree(
        key: _bodyKey,
        child: locked
            ? CollabCardFrame(
                surfaceKey: ValueKey('line-lock-card-$id'),
                margin: const EdgeInsets.symmetric(vertical: 6),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: child,
                ),
              )
            : child,
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

/// 自适应可用宽度的虚线段，无共享属性或选区偏移。
class _PageDividerSegment extends StatelessWidget {
  /// 创建由父布局决定宽度的装饰段。
  const _PageDividerSegment();

  /// 在借用 [context] 中按主题边线色绘制，不影响分页符的数据语义。
  @override
  Widget build(BuildContext context) => SizedBox(
    height: 1,
    child: CustomPaint(
      painter: _PageDividerPainter(Theme.of(context).dividerColor),
    ),
  );
}

/// 将连续流中的分页标记绘制为紧凑虚线，不模拟纸张高度。
class _PageDividerPainter extends CustomPainter {
  /// [color] 为当前主题的边线色。
  const _PageDividerPainter(this.color);

  /// 当前主题解析的虚线颜色。
  final Color color;

  /// 使用借用的 [canvas] 在 [size] 限定的逻辑像素区域绘制水平虚线。
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    for (var x = 0.0; x < size.width; x += 7) {
      canvas.drawLine(
        Offset(x, 0),
        Offset((x + 4).clamp(0, size.width), 0),
        paint,
      );
    }
  }

  /// [oldDelegate] 颜色变化时重绘。
  @override
  bool shouldRepaint(covariant _PageDividerPainter oldDelegate) =>
      oldDelegate.color != color;
}
