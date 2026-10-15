import 'package:appflowy_editor/appflowy_editor.dart';
import 'collab_mention_tap_handler.dart';
import 'package:cses_document_collab/src/model/collab_entity_mention.dart';
import 'package:cses_document_collab/src/native/collab_runtime.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

/// 正文会议/任务/文档单字符对象，显示类型图标及名称；不附加@，不加载人员头像。
/// 点击打开操作面板，打开详情才通知宿主；可切换卡片或删除引用，不修改实体业务数据。
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

  /// 创建局部文档卡片展示状态，不持有业务资源。
  @override
  State<CollabInlineEntityMention> createState() => _EntityMentionState();
}

/// 文档卡片视图仅在当前组件生命周期内保留；会议/任务转换为正式共享块。
class _EntityMentionState extends State<CollabInlineEntityMention> {
  /// 文档的手机局部布局目标，不写Y.Text；正文/身份变化后自动失效。
  CollabEntityMentionTarget? _documentCardTarget;

  /// 在借用[context]中显示链接或文档卡片，点击只打开操作面板。
  @override
  Widget build(BuildContext context) {
    final state = context.read<EditorState>();
    final documentCard = _documentCardTarget?.resolve(state) != null;
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
              key: documentCard
                  ? ValueKey('document-mention-card-$id-$offset')
                  : null,
              width: documentCard ? maxWidth : null,
              padding: documentCard
                  ? const EdgeInsets.all(12)
                  : const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(
                color: const Color(0xFFEFF6FF),
                borderRadius: BorderRadius.circular(documentCard ? 8 : 4),
                border: documentCard
                    ? Border.all(color: const Color(0xFFDBEAFE))
                    : null,
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
                    size: documentCard ? 28 : style.fontSize ?? 16,
                    color: const Color(0xFF2563EB),
                  ),
                  SizedBox(width: documentCard ? 10 : 3),
                  Flexible(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (documentCard)
                          const Text(
                            '文档',
                            style: TextStyle(fontSize: 12, color: Colors.grey),
                          ),
                        Text(
                          title,
                          maxLines: documentCard ? 2 : 1,
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
  /// 只有打开详情调用onMentionTap；文档布局不写共享数据，也不调用宿主。
  Future<void> _showActions(EditorState state) async {
    final target = CollabEntityMentionTarget.capture(
      widget.node,
      widget.offset,
    );
    if (target == null) return;
    await runCollabMentionInteraction(context, state, (services) async {
      final documentCard = _documentCardTarget?.resolve(state) != null;
      final kind = switch (target.entityType) {
        'meeting' => '会议',
        'task' => '任务',
        _ => '文档',
      };
      final route = ModalBottomSheetRoute<_EntityAction>(
        builder: (sheetContext) => SafeArea(
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          target.name.isEmpty ? '未命名$kind' : target.name,
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
                  ListTile(
                    key: const ValueKey('entity-mention-open-detail'),
                    leading: const Icon(Icons.open_in_new),
                    title: Text('打开$kind详情'),
                    enabled: services.onMentionTap != null,
                    onTap: () =>
                        Navigator.of(sheetContext).pop(_EntityAction.detail),
                  ),
                  ListenableBuilder(
                    listenable: state.editableNotifier,
                    builder: (context, _) => Column(
                      children: [
                        ListTile(
                          key: const ValueKey('entity-mention-switch-view'),
                          leading: const Icon(Icons.view_agenda_outlined),
                          title: Text(documentCard ? '切换为链接视图' : '切换为卡片视图'),
                          subtitle: Text(documentCard ? '当前：卡片视图' : '当前：链接视图'),
                          enabled: state.editable,
                          onTap: () => Navigator.of(
                            sheetContext,
                          ).pop(_EntityAction.switchView),
                        ),
                        TextButton.icon(
                          key: const ValueKey('entity-mention-delete'),
                          onPressed: state.editable
                              ? () => Navigator.of(
                                  sheetContext,
                                ).pop(_EntityAction.delete)
                              : null,
                          icon: const Icon(Icons.delete_outline),
                          label: const Text('删除提及'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        isScrollControlled: true,
        useSafeArea: true,
        modalBarrierColor: Colors.black54,
        capturedThemes: InheritedTheme.capture(
          from: context,
          to: Navigator.of(context).context,
        ),
      );
      final action = await Navigator.of(context).push(route);
      await route.completed;
      if (!mounted ||
          state.isDisposed ||
          !identical(CollabRuntime.services, services)) {
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
          if (target.entityType == 'doc') {
            setState(() => _documentCardTarget = documentCard ? null : target);
          } else if (!await convertCollabEntityMentionToCard(state, target) &&
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

  /// 手机文档局部布局，或正式会议/任务块转换。
  switchView,

  /// 仅删除正文中的引用。
  delete,
}
