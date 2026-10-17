import 'package:cses_document_collab/src/editor/collab_card_frame.dart';
import 'package:cses_document_collab/src/editor/collab_host_mention_ui.dart';
import 'package:cses_document_collab/src/model/collab_task_card_data.dart';
import 'package:cses_document_collab/src/native/collab_runtime.dart';
import 'package:cses_document_collab/src/ui/modal/collab_modal.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// 桌面同款任务引用外观，借用数据与事件，不发请求或写正文。
/// ```dart
/// import 'package:flutter/material.dart';
/// import 'package:cses_document_collab/src/editor/collab_task_card_view.dart';
/// const card = CollabTaskCardView(blockId: 'b1', title: '任务');
/// ```
class CollabTaskCardView extends StatelessWidget {
  /// [key]控制身份复用，[blockId]生成稳定测试/操作标记，[title]为共享标题。
  /// [data]可选本地详情，null只展示引用；[loading]/[failed]/[missing]控制反馈，不推断业务状态。
  /// [busy]表示宿主导航或删除尚未结束，默认false；[onOpen]仅内容区详情图标调用。
  /// [onDelete]存在且非只读时显示更多菜单，删除只影响文档引用；[onRetry]用于失败后手动重试。
  /// [moreActions]可替换默认删除菜单，null保留默认行为，控件由编辑器提供。
  /// [readOnly]默认false，为true隐藏更多菜单而保留详情入口。
  const CollabTaskCardView({
    super.key,
    required this.blockId,
    required this.title,
    this.data,
    this.loading = false,
    this.failed = false,
    this.missing = false,
    this.busy = false,
    this.onOpen,
    this.onDelete,
    this.onRetry,
    this.moreActions,
    this.readOnly = false,
  });

  /// 必填稳定块身份，不用任务ID代替，允许同一任务多次引用。
  final String blockId;

  /// 必填共享标题，详情标题为空时按实际空名称展示占位。
  final String title;

  /// 可选只读业务快照，不进入共享数据。
  final CollabTaskCardData? data;

  /// 默认false，加载时展示固定占位，避免伪造状态和计数。
  final bool loading;

  /// 默认false，失败时显示重试反馈。
  final bool failed;

  /// 默认false，明确不存在时显示提示，不改变文档引用。
  final bool missing;

  /// 默认false，等待宿主操作时禁用卡片事件。
  final bool busy;

  /// 可选详情事件；null禁用内容区首行右对齐的详情图标，其他区域不派发。
  final Future<void> Function()? onOpen;

  /// 可选删除事件；null隐藏更多菜单，由编辑器持有权限和事务。
  final Future<void> Function()? onDelete;

  /// 可选更多操作控件；null保留仅含删除的独立视图菜单，不拥有资源。
  final Widget? moreActions;

  /// 是否只读，默认false；只影响更多菜单，不禁用详情回调。
  final bool readOnly;

  /// 可选失败重试，由调用方管理请求代次。
  final VoidCallback? onRetry;

  /// 在借用[context]中绘制统一卡片；首行详情图标贴齐内容右边界，44像素热区不额外留白。
  /// 卡片宽度最多400，窄屏和大字号自动换行。
  /// 未提供自定义菜单时，默认删除入口使用共用危险操作红色。
  @override
  Widget build(BuildContext context) {
    final detail = data;
    final displayTitle = detail?.title ?? title;
    final priority = detail?.priority;
    final status = detail?.status;
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: CollabCardFrame(
          surfaceKey: ValueKey('task-card-surface-$blockId'),
          margin: const EdgeInsets.symmetric(vertical: 8),
          header: CollabCardHeader(
            leading: const Icon(LucideIcons.listTodo, color: Color(0xFF5755E7)),
            title: const Text('任务'),
            readOnly: readOnly,
            more:
                moreActions ??
                (onDelete == null
                    ? null
                    : PopupMenuButton<Future<void> Function()>(
                        key: ValueKey('task-card-more-$blockId'),
                        tooltip: '更多操作',
                        enabled: !busy,
                        icon: const Icon(LucideIcons.ellipsis, size: 18, color: Color(0xFF9CA3AF)),
                        onSelected: (action) async {
                          await action();
                        },
                        itemBuilder: (_) => [
                          PopupMenuItem(
                            value: onDelete!,
                            key: ValueKey('task-card-delete-$blockId'),
                            child: Text('删除卡片', style: TextStyle(color: CollabModalColors.of(context).danger)),
                          ),
                        ],
                      )),
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: priority != null && priority.name.isNotEmpty
                            ? _TaskTag(tag: priority)
                            : const Text('任务卡片', style: TextStyle(color: Color(0xFF9CA3AF), fontSize: 12)),
                      ),
                    ),
                    if (loading)
                      const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                    if (!loading && detail != null) _TaskLeaders(data: detail),
                    IconButton(
                      key: ValueKey('task-card-open-$blockId'),
                      tooltip: '打开任务详情',
                      constraints: const BoxConstraints.tightFor(width: 44, height: 44),
                      style: const ButtonStyle(tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                      padding: EdgeInsets.zero,
                      alignment: Alignment.centerRight,
                      icon: const Icon(LucideIcons.maximize2, size: 16, color: Color(0xFF9CA3AF)),
                      onPressed: busy || onOpen == null
                          ? null
                          : () async {
                              await onOpen!();
                            },
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        displayTitle.isEmpty ? '未命名任务' : displayTitle,
                        key: ValueKey('task-card-title-$blockId'),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF1D2129),
                          height: 1.35,
                        ),
                      ),
                    ),
                    if (!loading && status != null && status.name.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 112),
                        child: _TaskTag(tag: status),
                      ),
                    ],
                  ],
                ),
                if (detail?.startTime != null || detail?.endTime != null) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (detail?.startTime != null)
                        _TaskTime(icon: LucideIcons.calendarDays, time: detail!.startTime!),
                      if (detail?.startTime != null && detail?.endTime != null)
                        const Text('-', style: TextStyle(color: Color(0xFF86909C), fontSize: 12)),
                      if (detail?.endTime != null) _TaskTime(icon: LucideIcons.calendarCheck, time: detail!.endTime!),
                    ],
                  ),
                ],
                const SizedBox(height: 8),
                _TaskProgress(blockId: blockId, progress: detail?.progress),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(child: _TaskPath(nodes: detail?.path ?? const [])),
                    if (detail?.fileCount != null)
                      _TaskCount(icon: LucideIcons.paperclip, label: '附件', count: detail!.fileCount!),
                    if (detail?.subTaskCount != null) ...[
                      const SizedBox(width: 8),
                      _TaskCount(icon: LucideIcons.network, label: '子任务', count: detail!.subTaskCount!),
                    ],
                  ],
                ),
                if (failed || missing || detail?.deleted == true) ...[
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          failed ? '任务加载失败' : '任务不存在或已删除',
                          style: const TextStyle(fontSize: 12, color: Color(0xFF86909C)),
                        ),
                      ),
                      if (failed)
                        TextButton(
                          key: ValueKey('task-card-retry-$blockId'),
                          onPressed: onRetry,
                          child: const Text('重试'),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 根据桌面色板显示优先级或状态，不响应业务修改。
class _TaskTag extends StatelessWidget {
  /// [tag]是宿主冻结的标签快照。
  const _TaskTag({required this.tag});

  /// 借用标签。
  final CollabTaskCardTag tag;

  /// 在借用[context]中使用桌面映射的背景/文字色，长标签截断为单行。
  @override
  Widget build(BuildContext context) {
    final (background, foreground) = _tagColors(tag.color);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(4)),
      child: Text(
        tag.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 12, height: 1.3, color: foreground),
      ),
    );
  }
}

/// 映射桌面标签色[value]；未知合法#RRGGBB保留背景色，非法/空值回落中性灰。
(Color, Color) _tagColors(String? value) {
  final normalized = value?.replaceFirst('#', '').toUpperCase();
  return switch (normalized) {
    'CED3FF' => (const Color(0xFFCED3FF), const Color(0xFF4857E2)),
    'E1FFEE' => (const Color(0xFFE1FFEE), const Color(0xFF167D3C)),
    'FFE2E2' => (const Color(0xFFFFE2E2), const Color(0xFFF53F3F)),
    '59B463' => (const Color(0x1A59B463), const Color(0xFF59B463)),
    'F6B464' => (const Color(0x21F6B464), const Color(0xFFF6B464)),
    'ED8781' => (const Color(0x21ED8781), const Color(0xFFED8781)),
    _ => (
      normalized != null && RegExp(r'^[0-9A-F]{6}$').hasMatch(normalized)
          ? Color(0xFF000000 | int.parse(normalized, radix: 16))
          : const Color(0xFFE6E6E6),
      const Color(0xFF333333),
    ),
  };
}

/// 负责人使用宿主头像组件，最多三位，其余人数显示计数；不创建默认头像或发图片请求。
class _TaskLeaders extends StatelessWidget {
  /// [data]为当前本地详情快照。
  const _TaskLeaders({required this.data});

  /// 借用详情。
  final CollabTaskCardData data;

  /// 在借用[context]中构建固定尺寸头像组；未注入宿主头像时隐藏。
  @override
  Widget build(BuildContext context) {
    if (CollabRuntime.services.mentionAvatarBuilder == null || data.leaders.isEmpty) {
      return const SizedBox.shrink();
    }
    final visible = data.leaders.take(3).toList();
    return Semantics(
      label: '负责人 ${data.leaders.map((u) => u.name).join('、')}',
      child: SizedBox(
        width: visible.length * 16.0 + 8 + (data.leaders.length > 3 ? 24 : 0),
        height: 24,
        child: Stack(
          children: [
            for (var i = 0; i < visible.length; i++)
              Positioned(
                left: i * 16.0,
                child: buildHostMentionAvatarSlot(
                  context,
                  userId: visible[i].id,
                  name: visible[i].name,
                  avatarUrl: visible[i].avatarUrl,
                  size: 24,
                )!,
              ),
            if (data.leaders.length > 3)
              Positioned(
                right: 0,
                child: Container(
                  width: 24,
                  height: 24,
                  alignment: Alignment.center,
                  decoration: const BoxDecoration(color: Color(0xFFF3F4F6), shape: BoxShape.circle),
                  child: Text(
                    '+${data.leaders.length - 3}',
                    style: const TextStyle(fontSize: 10, color: Color(0xFF86909C)),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 起止时间的轻量图标和本地日期。
class _TaskTime extends StatelessWidget {
  /// [icon]表示开始或截止，[time]为绝对时间，按设备本地时区展示。
  const _TaskTime({required this.icon, required this.time});

  /// 图标不单独响应点击。
  final IconData icon;

  /// 借用时间。
  final DateTime time;

  /// 在借用[context]中显示MM-dd HH:mm，完整日期保留于语义标签。
  @override
  Widget build(BuildContext context) {
    final local = time.toLocal();
    final date =
        '${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')} ${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
    return Semantics(
      label: local.toIso8601String(),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: const Color(0xFF86909C)),
          const SizedBox(width: 3),
          Text(date, style: const TextStyle(fontSize: 12, color: Color(0xFF86909C))),
        ],
      ),
    );
  }
}

/// 中间分割线同时作为进度条；已知0%仍在起点显示圆点，未知不显示圆点。
class _TaskProgress extends StatelessWidget {
  /// [blockId]提供稳定标记，[progress]为可选0～100百分数。
  const _TaskProgress({required this.blockId, required this.progress});

  /// 借用块身份。
  final String blockId;

  /// 可选已校验进度。
  final double? progress;

  /// 在借用[context]中按可用宽度绘制两像素轨道与六像素圆点。
  @override
  Widget build(BuildContext context) => Semantics(
    label: '任务进度',
    value: progress == null ? '未知' : '${progress!.toStringAsFixed(progress! % 1 == 0 ? 0 : 2)}%',
    child: SizedBox(
      key: ValueKey('task-card-progress-$blockId'),
      height: 8,
      child: LayoutBuilder(
        builder: (context, constraints) => Stack(
          children: [
            const Positioned(left: 0, right: 0, top: 3, height: 2, child: ColoredBox(color: Color(0xFFE5E6EB))),
            if (progress != null) ...[
              Positioned(
                left: 0,
                top: 3,
                height: 2,
                width: constraints.maxWidth * progress! / 100,
                child: const ColoredBox(color: Color(0xFF5755E7)),
              ),
              Positioned(
                key: ValueKey('task-card-progress-dot-$blockId'),
                left: (constraints.maxWidth * progress! / 100 - 3).clamp(
                  0.0,
                  (constraints.maxWidth - 6).clamp(0.0, double.infinity),
                ),
                top: 1,
                width: 6,
                height: 6,
                child: const DecoratedBox(
                  decoration: BoxDecoration(color: Color(0xFF5755E7), shape: BoxShape.circle),
                ),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}

/// 截断显示任务路径，保留完整路径语义。
class _TaskPath extends StatelessWidget {
  /// [nodes]按空间/项目/工作项顺序借用。
  const _TaskPath({required this.nodes});

  /// 路径由宿主持有。
  final List<CollabTaskCardPath> nodes;

  /// 在借用[context]中显示路径图标与名称，不提供导航事件。
  @override
  Widget build(BuildContext context) => Text.rich(
    TextSpan(
      children: [
        for (var i = 0; i < nodes.length; i++) ...[
          if (i > 0) const TextSpan(text: ' / '),
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Icon(
              switch (nodes[i].type) {
                'space' => LucideIcons.archive,
                'workItem' => LucideIcons.briefcaseBusiness,
                _ => LucideIcons.folder,
              },
              size: 12,
              color: const Color(0xFF9CA3AF),
            ),
          ),
          TextSpan(text: ' ${nodes[i].name}'),
        ],
      ],
    ),
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: const TextStyle(fontSize: 11, color: Color(0xFF9CA3AF)),
  );
}

/// 只读附件或子任务计数，不响应点击。
class _TaskCount extends StatelessWidget {
  /// [icon]为统计图标，[label]为语义名，[count]为已知非负计数。
  const _TaskCount({required this.icon, required this.label, required this.count});

  /// 图标。
  final IconData icon;

  /// 可读统计类型。
  final String label;

  /// 借用计数。
  final int count;

  /// 在借用[context]中展示图标和原始计数。
  @override
  Widget build(BuildContext context) => Semantics(
    label: '$label $count',
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: const Color(0xFF9CA3AF)),
        const SizedBox(width: 3),
        Text(count > 999 ? '999+' : '$count', style: const TextStyle(fontSize: 11, color: Color(0xFF9CA3AF))),
      ],
    ),
  );
}
