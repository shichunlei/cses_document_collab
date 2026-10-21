import 'package:cses_document_collab/src/editor/core/editor_command_context.dart';
import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/collab_block_actions.dart';
import 'package:cses_document_collab/src/editor/collab_mermaid_sheet.dart';
import 'package:cses_document_collab/src/editor/editor_shortcut_toolbar.dart';
import 'package:cses_document_collab/src/model/collab_mermaid.dart';
import 'package:cses_document_collab/src/model/collab_mermaid_options.dart';
import 'package:cses_document_collab/src/ui/modal/collab_card_frame.dart';
import 'package:cses_document_collab/src/ui/modal/collab_card_header.dart';
import 'package:cses_document_collab/src/ui/modal/collab_menu_row.dart';
import 'package:cses_document_collab/src/ui/modal/collab_mermaid_visual.dart';
import 'package:cses_document_collab/src/ui/modal/collab_modal.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

/// 为正式 mermaid 注册可选中的容器组件；点击打开独立源码子块的编辑面板。
/// ```dart
/// import 'package:cses_document_collab/src/editor/collab_mermaid_block.dart';
/// final builder = CollabMermaidBlockComponentBuilder();
/// // 在 AppFlowyEditor 的 blockComponentBuilders 中以 'mermaid' 注册。
/// ```
class CollabMermaidBlockComponentBuilder extends BlockComponentBuilder {
  /// 创建无资源所有权的代码绘图组件工厂，编辑器由页面持有。
  CollabMermaidBlockComponentBuilder();

  /// 校验容器无正文且只有一个正式源码子块。
  @override
  BlockComponentValidate get validate =>
      (node) => node.delta == null && collabMermaidSource(node) != null;

  /// 使用借用 [context] 的节点与配置创建组件，不写入共享属性。
  @override
  BlockComponentWidget build(BlockComponentContext context) => _MermaidBlock(
    key: context.node.key,
    node: context.node,
    configuration: configuration,
  );
}

/// 借用容器节点展示子源码；预览子组件拥有平台视图。
class _MermaidBlock extends BlockComponentStatefulWidget {
  /// [key] 控制身份与状态复用，[node] 与 [configuration] 均由编辑器持有。
  const _MermaidBlock({
    super.key,
    required super.node,
    required super.configuration,
  });

  /// 创建整块选区代理，编辑器仍由调用方持有。
  @override
  createState() => _MermaidBlockState();
}

/// 为无正文块提供完整矩形选区与远端选中展示。
class _MermaidBlockState extends State<_MermaidBlock> with SelectableMixin {
  /// 内部视觉边界，随本 Widget 释放，不绑定编辑输入。
  final _bodyKey = GlobalKey();

  /// 从打开菜单到视图提交结束拒绝重复打开；状态归当前块组件持有。
  bool _viewMenuOpen = false;

  /// 在借用 [anchorContext] 对应按钮下打开220逻辑像素的共用菜单。
  /// [currentView] 为当前选中快照，按稳定 [id] 更新借用 [editor] 的共享视图。
  /// 菜单退场后重新核对权限和目标，关闭输入并等待独立事务，失败提示且不上抛未处理异步错误。
  Future<void> _switchView(
    BuildContext anchorContext,
    EditorState editor,
    String id,
    CollabMermaidView currentView,
  ) async {
    if (_viewMenuOpen || !mounted || editor.isDisposed || !editor.editable) {
      return;
    }
    _viewMenuOpen = true;
    try {
      final view = await showCollabPopover<CollabMermaidView>(
        context: anchorContext,
        title: '切换视图',
        width: 220,
        builder: (menuContext) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final mode in CollabMermaidView.values)
              CollabMenuRow(
                selected: mode == currentView,
                key: ValueKey('mermaid-view-option-${mode.name}'),
                leading: Icon(switch (mode) {
                  CollabMermaidView.text => LucideIcons.code,
                  CollabMermaidView.graph => LucideIcons.panelTop,
                  CollabMermaidView.both => LucideIcons.panelsTopLeft,
                }, size: 19),
                title: Text(mode.label),
                trailing: mode == currentView
                    ? const Icon(LucideIcons.check, size: 16)
                    : null,
                onTap: () => Navigator.pop(menuContext, mode),
              ),
          ],
        ),
      );
      if (view == null || !mounted || editor.isDisposed || !editor.editable) {
        return;
      }
      await runEditorHeaderAction<void>(context, editor, () async {
        await changeCollabMermaidView(editor, id, view);
      });
    } catch (error, stack) {
      EditorCommandContext.report(
        mounted ? context.read<EditorState>() : null,
        '切换绘图视图失败',
        error: error,
        stackTrace: stack,
        tag: 'DocCollab',
      );
      if (mounted) {
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(const SnackBar(content: Text('切换视图失败，请重试')));
      }
    } finally {
      _viewMenuOpen = false;
    }
  }

  /// 在借用 [context] 内按共享 mode 展示源码、图形或两者，监听远端属性和源码更新。
  /// 标题使用与添加入口及操作面板一致的图表网络图标；视图入口使用编号菜单同款浮层、紧凑列表及勾选状态。
  @override
  Widget build(BuildContext context) {
    final editor = context.read<EditorState>();
    final node = widget.node;
    final id = node.attributes['cses_collab_block_id'] as String? ?? node.id;
    final source = collabMermaidSource(node)!;
    final child = ListenableBuilder(
      listenable: Listenable.merge([node, source, editor.editableNotifier]),
      builder: (context, _) {
        final view = collabMermaidView(node);
        return CollabCardFrame(
          header: CollabCardHeader(
            leading: const Icon(
              LucideIcons.chartNetwork,
              color: Color(0xFF5755E7),
            ),
            title: const Text('代码绘图'),
            readOnly: !editor.editable,
            actions: [
              if (editor.editable)
                ExcludeFocus(
                  child: SizedBox(
                    width: 44,
                    height: 44,
                    child: Builder(
                      builder: (anchorContext) => IconButton(
                        key: ValueKey('mermaid-view-$id'),
                        tooltip: '切换视图：${view.label}',
                        onPressed: () async {
                          await _switchView(anchorContext, editor, id, view);
                        },
                        icon: const Icon(LucideIcons.arrowLeftRight, size: 18),
                      ),
                    ),
                  ),
                )
              else
                Text(
                  view.label,
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFF87909E),
                  ),
                ),
            ],
            more: CollabBlockMoreButton(
              key: ValueKey('block-more-$id'),
              editor: editor,
              node: node,
              protectSubtree: true,
              actions: [
                (
                  label: '编辑源码',
                  key: ValueKey('mermaid-edit-$id'),
                  run: () async {
                    await showCollabMermaidEditor(context, editor, id);
                  },
                ),
                (
                  label: '删除代码绘图',
                  key: ValueKey('mermaid-delete-$id'),
                  run: () => deleteCollabMermaid(editor, id),
                ),
              ],
            ),
          ),
          child: Semantics(
            label: '代码绘图',
            button: editor.editable,
            readOnly: !editor.editable,
            child: ExcludeFocus(
              child: GestureDetector(
                key: ValueKey('collab-mermaid-$id'),
                behavior: HitTestBehavior.opaque,
                onTap: editor.editable
                    ? () async {
                        await showCollabMermaidEditor(context, editor, id);
                      }
                    : null,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (view != CollabMermaidView.graph)
                      Container(
                        key: ValueKey('mermaid-source-view-$id'),
                        constraints: const BoxConstraints(maxHeight: 240),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Theme.of(
                            context,
                          ).colorScheme.surfaceContainerLow,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: SingleChildScrollView(
                          child: Text(
                            source.delta!.toPlainText(),
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 14,
                            ),
                          ),
                        ),
                      ),
                    if (view != CollabMermaidView.text)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: CollabMermaidVisual(
                          key: ValueKey('collab-mermaid-visual-$id'),
                          source: source.delta!.toPlainText(),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
    return BlockSelectionContainer(
      node: node,
      delegate: this,
      listenable: editor.selectionNotifier,
      remoteSelection: editor.remoteSelections,
      blockColor: editor.editorStyle.selectionColor,
      supportTypes: const [BlockSelectionType.block],
      selectionAboveBlock: true,
      child: KeyedSubtree(key: _bodyKey, child: child),
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
