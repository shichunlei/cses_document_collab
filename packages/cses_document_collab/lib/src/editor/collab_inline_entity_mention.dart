import 'package:appflowy_editor/appflowy_editor.dart';
import 'collab_mention_tap_handler.dart';
import 'package:cses_document_collab/src/model/collab_entity_mention.dart';
import 'package:cses_document_collab/src/native/collab_runtime.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

/// 正文会议/任务/文档单字符对象，显示类型图标及名称；不附加@，不加载人员头像。
/// 点击优先交给宿主统一回调，未配置时查看原始名称/ID并按权限删除提及；不持有连接，不修改实体业务数据。
/// ```dart
/// import 'package:flutter/material.dart';
/// import 'package:appflowy_editor/appflowy_editor.dart';
/// import 'package:cses_document_collab/src/editor/collab_inline_entity_mention.dart';
/// final chip = CollabInlineEntityMention(node: paragraphNode(), offset: 0,
///   name: '周会', entityType: 'meeting', style: const TextStyle(fontSize: 16));
/// // 将chip放入提供EditorState的WidgetSpan。
/// ```
class CollabInlineEntityMention extends StatelessWidget {
  /// [key] 控制组件身份与复用；[node] 是借用正文节点，[offset] 是UTF-16对象位置；
  /// [name] 为共享正文中的实体名称，[entityType] 为meeting/task/doc类型，[style] 为段落格式，空名称显示“未命名实体”。
  const CollabInlineEntityMention({
    super.key,
    required this.node,
    required this.offset,
    required this.name,
    required this.entityType,
    required this.style,
  });

  /// 编辑器拥有的正文节点，必填，不释放。
  final Node node;

  /// 必填UTF-16对象位置，点击时重新捕获身份及属性。
  final int offset;

  /// 必填原始实体名称，不自动写回业务实体最新标题。
  final String name;

  /// 必填实体类型，meeting/task/doc分别显示会议、任务和文档图标。
  final String entityType;

  /// 必填正文格式；未指定颜色时使用蓝色。
  final TextStyle style;

  /// 在借用 [context] 中显示限宽单行实体名称，点击期间隔离正文输入并恢复焦点。
  @override
  Widget build(BuildContext context) {
    final state = context.read<EditorState>();
    final id = node.attributes['cses_collab_block_id'] as String? ?? node.id;
    final kind = switch (entityType) {
      'meeting' => '会议',
      'task' => '任务',
      _ => '文档',
    };
    final title = name.isEmpty ? '未命名$kind' : name;
    return Semantics(
      label: '$kind $title',
      button: true,
      child: ExcludeFocus(
        child: GestureDetector(
          key: ValueKey('collab-inline-entity-$id-$offset'),
          onTap: () async {
            final target = CollabEntityMentionTarget.capture(node, offset);
            if (target == null) return;
            await handleCollabMentionTap(
              context,
              state,
              node,
              offset,
              defaultAction: () => _showEntity(context, state, target),
            );
          },
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: (MediaQuery.sizeOf(context).width - 40).clamp(
                40,
                double.infinity,
              ),
            ),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(
                color: const Color(0xFFEFF6FF),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    switch (entityType) {
                      'meeting' => Icons.groups_outlined,
                      'task' => Icons.task_alt,
                      _ => Icons.description_outlined,
                    },
                    size: style.fontSize ?? 16,
                    color: const Color(0xFF2563EB),
                  ),
                  const SizedBox(width: 3),
                  Flexible(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: style.copyWith(
                        color: style.color ?? const Color(0xFF2563EB),
                        height: 1.2,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 用借用 [context]/[state] 展示稳定 [target]；删除前再次核对权限、位置和完整属性。
/// 面板关闭后由调用方恢复正文输入；不会请求业务实体接口或修改业务实体。
Future<void> _showEntity(
  BuildContext context,
  EditorState state,
  CollabEntityMentionTarget target,
) async {
  await showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (sheetContext) => Padding(
      padding: const EdgeInsets.all(16),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    target.name.isEmpty ? '未命名实体' : target.name,
                    style: Theme.of(sheetContext).textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  tooltip: '关闭',
                  onPressed: () => Navigator.of(sheetContext).pop(),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            Text('引用ID：${target.entityId}'),
            const SizedBox(height: 12),
            TextButton.icon(
              key: const ValueKey('entity-mention-delete'),
              onPressed: state.editable
                  ? () async {
                      try {
                        final deleted = await deleteCollabEntityMention(
                          state,
                          target,
                        );
                        if (!sheetContext.mounted) return;
                        if (deleted) {
                          Navigator.of(sheetContext).pop();
                        } else {
                          ScaffoldMessenger.maybeOf(sheetContext)?.showSnackBar(
                            const SnackBar(content: Text('实体提及已变化，请重新打开')),
                          );
                        }
                      } catch (error, stack) {
                        CollabDiagnostics.report(
                          '删除实体提及失败',
                          error: error,
                          stackTrace: stack,
                          tag: 'DocCollab',
                        );
                        if (sheetContext.mounted) {
                          ScaffoldMessenger.maybeOf(sheetContext)?.showSnackBar(
                            const SnackBar(content: Text('删除失败，请重试')),
                          );
                        }
                      }
                    }
                  : null,
              icon: const Icon(Icons.delete_outline),
              label: const Text('删除提及'),
            ),
          ],
        ),
      ),
    ),
  );
}
