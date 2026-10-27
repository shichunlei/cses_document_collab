import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/core/editor_command_context.dart';
import 'package:cses_document_collab/src/model/collab_entity_mention.dart';
import 'package:cses_document_collab/src/ui/modal/collab_bottom_sheet.dart';
import 'package:cses_document_collab/src/ui/modal/collab_menu_row.dart';
import 'package:cses_document_collab/src/ui/modal/collab_modal.dart';
import 'package:cses_document_collab/src/ui/modal/collab_modal_colors.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import 'collab_mention_tap_handler.dart';

/// 正文会议/任务/文档单字符对象，显示类型图标及名称；不附加@，不加载人员头像。
/// 点击打开操作面板，打开详情才通知宿主；会议/任务可转卡片，三类均可删除引用，不修改实体业务数据。
/// ```dart
/// import 'package:flutter/material.dart';
/// import 'package:appflowy_editor/appflowy_editor.dart';
/// import 'package:cses_document_collab/src/editor/collab_inline_entity_mention.dart';
/// final chip = CollabInlineEntityMention(node: paragraphNode(), offset: 0,
///   name: '周会', entityType: 'meeting', style: const TextStyle(fontSize: 16));
/// // 将chip放入提供EditorState的WidgetSpan。
/// ```
class CollabInlineEntityMention extends StatefulWidget {
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

  /// 创建操作面板生命周期状态，不持有业务资源。
  @override
  State<CollabInlineEntityMention> createState() => _EntityMentionState();
}

/// 管理提及操作面板；仅会议/任务允许转换为正式共享卡片块。
class _EntityMentionState extends State<CollabInlineEntityMention> {
  /// 在借用[context]中显示行内实体名称，点击只打开操作面板。
  @override
  Widget build(BuildContext context) {
    final state = context.read<EditorState>();
    final node = widget.node;
    final offset = widget.offset;
    final entityType = widget.entityType;
    final name = widget.name;
    final style = widget.style;
    final id = node.attributes['cses_collab_block_id'] as String? ?? node.id;
    final kind = switch (entityType) {
      'meeting' => '会议',
      'task' => '任务',
      _ => '文档',
    };
    final title = name.isEmpty ? '未命名$kind' : name;
    final maxWidth = (MediaQuery.sizeOf(context).width - 40).clamp(
      40.0,
      double.infinity,
    );
    return Semantics(
      label: '$kind $title',
      button: true,
      child: ExcludeFocus(
        child: GestureDetector(
          key: ValueKey('collab-inline-entity-$id-$offset'),
          onTap: () => _showActions(state),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth),
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
                      'meeting' => LucideIcons.users,
                      'task' => LucideIcons.squareCheck,
                      _ => LucideIcons.fileText,
                    },
                    size: style.fontSize ?? 16,
                    color: const Color(0xFF2563EB),
                  ),
                  const SizedBox(width: 3),
                  Flexible(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: style.copyWith(
                            color: style.color ?? const Color(0xFF2563EB),
                            height: 1.2,
                          ),
                        ),
                      ],
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

  /// 为借用[state]中的原子展示详情/视图/删除操作，退场后复核目标与会话。
  /// 只有打开详情调用onMentionTap；文档不提供视图切换，会议/任务转换及删除不调用宿主。
  /// 删除使用与块菜单一致的红色整行操作；预览/只读时保持禁用，不修改实体业务数据。
  Future<void> _showActions(EditorState state) async {
    final target = CollabEntityMentionTarget.capture(
      widget.node,
      widget.offset,
    );
    if (target == null) return;
    await runCollabMentionInteraction(context, state, (services) async {
      final kind = switch (target.entityType) {
        'meeting' => '会议',
        'task' => '任务',
        _ => '文档',
      };
      final action = await showCollabBottomSheet<_EntityAction>(
        context: context,
        builder: (sheetContext) => CollabBottomSheet(
          title: Text(target.name.isEmpty ? '未命名$kind' : target.name),
          icon: switch (target.entityType) {
            'meeting' => LucideIcons.video,
            'task' => LucideIcons.squareCheck,
            _ => LucideIcons.fileText,
          },
          subtitle: '$kind引用 · 当前为链接视图',
          contentPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CollabMenuRow(
                key: const ValueKey('entity-mention-open-detail'),
                leading: const Icon(LucideIcons.externalLink),
                title: Text('打开$kind详情'),
                enabled: services.onMentionTap != null,
                onTap: () =>
                    Navigator.of(sheetContext).pop(_EntityAction.detail),
              ),
              ListenableBuilder(
                listenable: state.editableNotifier,
                builder: (context, _) => Column(
                  children: [
                    if (const {'meeting', 'task'}.contains(target.entityType))
                      CollabMenuRow(
                        key: const ValueKey('entity-mention-switch-view'),
                        leading: const Icon(LucideIcons.panelTop),
                        title: const Text('切换为卡片视图'),
                        subtitle: const Text('当前：链接视图'),
                        enabled: state.editable,
                        onTap: () => Navigator.of(
                          sheetContext,
                        ).pop(_EntityAction.switchView),
                      ),
                    CollabMenuRow(
                      key: const ValueKey('entity-mention-delete'),
                      enabled: state.editable,
                      leading: Icon(
                        LucideIcons.trash2,
                        color: state.editable
                            ? CollabModalColors.of(context).danger
                            : null,
                      ),
                      title: Text(
                        '删除提及',
                        style: state.editable
                            ? TextStyle(
                                color: CollabModalColors.of(context).danger,
                              )
                            : null,
                      ),
                      onTap: () =>
                          Navigator.of(sheetContext).pop(_EntityAction.delete),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );

      if (!mounted ||
          state.isDisposed ||
          !identical(EditorCommandContext.of(state).services, services)) {
        return;
      }
      final current = target.resolve(state);
      if (current == null || action == null) return;
      switch (action) {
        case _EntityAction.detail:
          final event = collabMentionTapAt(current, target.offset);
          if (event != null) await services.onMentionTap?.call(event);
        case _EntityAction.switchView:
          if (!state.editable) return;
          if (!const {'meeting', 'task'}.contains(target.entityType)) return;
          if (!await convertCollabEntityMentionToCard(state, target) &&
              mounted) {
            ScaffoldMessenger.maybeOf(
              context,
            )?.showSnackBar(const SnackBar(content: Text('无法转换此提及，请重新打开')));
          }
        case _EntityAction.delete:
          if (!await deleteCollabEntityMention(state, target) && mounted) {
            ScaffoldMessenger.maybeOf(
              context,
            )?.showSnackBar(const SnackBar(content: Text('提及已变化，请重新打开')));
          }
      }
    });
  }
}

/// 面板选择在路由完全退场后执行，不在面板内发起业务导航或正文写入。
enum _EntityAction {
  /// 只通知宿主打开详情。
  detail,

  /// 仅转换为正式会议/任务块。
  switchView,

  /// 仅删除正文中的引用。
  delete,
}
