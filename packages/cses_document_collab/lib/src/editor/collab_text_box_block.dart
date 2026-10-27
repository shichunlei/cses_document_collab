import 'dart:math' as math;

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/collab_block_actions.dart';
import 'package:cses_document_collab/src/editor/collab_block_locks.dart';
import 'package:cses_document_collab/src/editor/collab_text_box_settings.dart';
import 'package:cses_document_collab/src/ui/modal/collab_editor_display_scope.dart';
import 'package:cses_document_collab/src/model/collab_block_colors.dart';
import 'package:cses_document_collab/src/model/collab_text_box.dart';
import 'package:cses_document_collab/src/ui/modal/collab_card_lock_overlay.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

/// 正式文本框容器；正文继续使用编辑器的子块输入代理，尺寸仅在显示时限幅。
/// ```dart
/// import 'package:cses_document_collab/src/editor/collab_text_box_block.dart';
/// final builder = CollabTextBoxBlockComponentBuilder();
/// // 注册到AppFlowyEditor的text-box类型，文档由外层编辑器释放。
/// ```
class CollabTextBoxBlockComponentBuilder extends BlockComponentBuilder {
  /// 创建无独占编辑器或网络资源的构建器。
  CollabTextBoxBlockComponentBuilder();

  /// 仅接受普通正文叶子节点，非法旧子树交给错误构建器保护。
  @override
  BlockComponentValidate get validate =>
      (node) =>
          node.delta == null &&
          node.children.every((c) => collabTextBoxChildren.contains(c.type) && c.children.isEmpty);

  /// 在借用[context]下保留节点身份和真实后代渲染器。
  @override
  BlockComponentWidget build(BlockComponentContext context) =>
      _TextBoxBlock(key: context.node.key, node: context.node, configuration: configuration);
}

/// 连续流中的文本框，不在渲染过程中改写桌面几何或测量缓存。
class _TextBoxBlock extends BlockComponentStatelessWidget {
  /// [key]控制身份复用；[node]和[configuration]借自所属编辑器。
  const _TextBoxBlock({super.key, required super.node, required super.configuration});

  /// 在借用[context]中绘制固定框；编辑滚动位置独立保存，纯预览从顶部裁切超出内容。
  @override
  Widget build(BuildContext context) {
    final editor = context.read<EditorState>();
    final preview = CollabEditorDisplayScope.maybeOf(context)?.preview == true;
    final host = collabBlockActionContext(context);
    final id = CollabBlockLocks.idOf(node);
    final props = readCollabTextBox(node.attributes).values;
    final width = _dimension(props['width'], 240, 48);
    final height = _dimension(
      props['textAutoFit'] == 'resize-shape' && props['textDirection'] != 'vertical-rl'
          ? props['textFit'] ?? props['height']
          : props['height'],
      120,
      32,
    );
    final fill = props['fill'] == 'none'
        ? Colors.transparent
        : parseCollabBlockColor(props['fill'] is String ? props['fill'] as String : null) ?? Colors.white;
    final outline = '${props['outline'] ?? '1px solid #000000'}';
    final parts = outline.split(' ');
    final lineWidth = double.tryParse(parts.first.replaceAll('px', '')) ?? 1;
    final border = outline == 'none'
        ? null
        : Border.all(color: parseCollabBlockColor(parts.last) ?? Colors.black, width: lineWidth.clamp(0, 100));
    final padding = '${props['textPadding'] ?? '8 12'}'.split(' ').map(double.tryParse).toList();
    final inset =
        padding.isNotEmpty && padding.length <= 4 && padding.every((v) => v != null && v.isFinite && v >= 0 && v <= 200)
        ? EdgeInsets.fromLTRB(
            padding.length == 4
                ? padding[3]!
                : padding.length > 1
                ? padding[1]!
                : padding[0]!,
            padding[0]!,
            padding.length > 1 ? padding[1]! : padding[0]!,
            padding.length > 2 ? padding[2]! : padding[0]!,
          )
        : const EdgeInsets.symmetric(vertical: 8, horizontal: 12);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Align(
        alignment: Alignment.centerLeft,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final actualWidth = math.min(width, constraints.maxWidth);
            return CollabCardLockOverlay(
              child: SizedBox(
                width: actualWidth,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Align(
                      alignment: Alignment.centerRight,
                      child: CollabBlockMoreButton(
                        editor: editor,
                        node: node,
                        protectSubtree: true,
                        actions: [
                          (
                            label: '文本框设置',
                            key: ValueKey('text-box-settings-$id'),
                            run: () async {
                              if (host.mounted) await showCollabTextBoxSettings(host, editor, id);
                            },
                          ),
                          (
                            label: '删除文本框',
                            key: ValueKey('text-box-delete-$id'),
                            run: () async {
                              await deleteCollabTextBox(editor, id);
                            },
                          ),
                        ],
                      ),
                    ),
                    Container(
                      key: ValueKey('text-box-frame-$id'),
                      height: height,
                      clipBehavior: Clip.hardEdge,
                      decoration: BoxDecoration(
                        color: fill,
                        border: border,
                        borderRadius: props['shape'] == 'rounded-rectangle' ? BorderRadius.circular(12) : null,
                      ),
                      child: SingleChildScrollView(
                        key: PageStorageKey(preview ? 'text-box-preview-$id' : 'text-box-scroll-$id'),
                        physics: preview ? const NeverScrollableScrollPhysics() : null,
                        padding: inset,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (final child in node.children) editor.renderer.build(context, child),
                            if (node.children.isEmpty && canEditCollabNode(editor, node))
                              TextButton(
                                key: ValueKey('text-box-body-$id'),
                                onPressed: () async {
                                  if (!canEditCollabNode(editor, node) ||
                                      !identical(findCollabActionNode(editor, id), node)) {
                                    return;
                                  }
                                  await editor.apply(
                                    editor.transaction
                                      ..insertNode(node.path + [0], paragraphNode())
                                      ..afterSelection = Selection.single(path: node.path + [0], startOffset: 0),
                                    skipHistoryDebounce: true,
                                  );
                                },
                                child: const Text('添加正文'),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// 返回[value]的有效尺寸，缺失/非法使用[fallback]，显示范围为[minimum]～2000逻辑像素。
double _dimension(Object? value, double fallback, double minimum) =>
    value is num && value.isFinite ? value.toDouble().clamp(minimum, 2000) : fallback;
