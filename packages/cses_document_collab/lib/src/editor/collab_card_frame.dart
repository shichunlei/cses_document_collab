import 'package:cses_document_collab/src/editor/collab_block_lock_scope.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// 编辑器卡片的公共外框；只借用内容，不创建控制器或处理文档事务。
///
/// ```dart
/// import 'package:lucide_icons_flutter/lucide_icons.dart';
/// import 'package:flutter/material.dart';
/// import 'package:cses_document_collab/src/editor/collab_card_frame.dart';
/// const card = CollabCardFrame(
///   header: CollabCardHeader(
///     leading: Icon(LucideIcons.users),
///     title: Text('会议'),
///   ),
///   child: Padding(padding: EdgeInsets.all(12), child: Text('会议内容')),
/// );
/// ```
class CollabCardFrame extends StatelessWidget {
  /// [key]控制组件身份与状态复用，[surfaceKey]标记外框的实际渲染边界。
  /// [header]和[child]分别为借用的标题栏与内容，不转移其资源所有权。
  /// [margin]默认为零，由调用方维持块间距；[showDivider]默认显示分隔线，
  /// 收起代码时可设为false，仅保留标题栏。
  const CollabCardFrame({
    super.key,
    this.surfaceKey,
    required this.header,
    required this.child,
    this.margin = EdgeInsets.zero,
    this.showDivider = true,
  });

  /// 可选实际外框标记，用于选区定位及测试。
  final Key? surfaceKey;

  /// 必填标题栏；调用方提供类型身份、权限和操作。
  final Widget header;

  /// 必填原有内容；播放器和平台视图继续由其创建者释放。
  final Widget child;

  /// 外框外侧间距，默认零。
  final EdgeInsetsGeometry margin;

  /// 是否显示标题栏与正文间的细线，默认true。
  final bool showDivider;

  /// 在借用的[context]中绘制圆角卡片；正文继续裁切，锁标独立覆盖在外框右上角。
  /// [margin]位于整层外侧，使标记始终跟随实际卡片边缘，不受标题高度或外边距影响。
  @override
  Widget build(BuildContext context) {
    final lock = CollabBlockLockScope.maybeOf(context);
    return Padding(
      padding: margin,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            key: surfaceKey,
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: const Color(0xFFE5E7EB)),
              borderRadius: BorderRadius.circular(12),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                header,
                if (showDivider) const Divider(height: 1, thickness: 1, color: Color(0xFFE5E7EB)),
                child,
              ],
            ),
          ),
          if (lock?.showBadge == true)
            Positioned(
              top: -5,
              right: -5,
              child: IgnorePointer(
                child: Tooltip(
                  key: ValueKey('block-lock-badge-${lock!.blockId}'),
                  message: '内容已锁定',
                  child: const Icon(LucideIcons.lockKeyhole, size: 14, color: Color(0xFF87909E)),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 固定操作区的公共标题栏，长标题或网址不会挤压右侧按钮。
///
/// ```dart
/// import 'package:lucide_icons_flutter/lucide_icons.dart';
/// import 'package:flutter/material.dart';
/// import 'package:cses_document_collab/src/editor/collab_card_frame.dart';
/// const header = CollabCardHeader(
///   leading: Icon(LucideIcons.globe),
///   title: Text('网页卡片'),
///   subtitle: 'https://example.com',
///   readOnly: true,
/// );
/// ```
class CollabCardHeader extends StatelessWidget {
  /// [key]控制组件身份与状态复用；[leading]为必填图标或收起按钮，
  /// [title]为必填标题，允许调用方提供已有重命名交互。
  /// [subtitle]为可选网址或来源，null不占第二行；长文本使用省略号。
  /// [actions]为更多左侧的快捷操作，默认空，调用方决定其只读展示方式。
  /// [more]为可选的借用菜单控件；[readOnly]默认false，true时完全移除更多占位。
  /// [tinted]默认true，设为false使用白底，适用于网页类标题栏。
  /// [padding]可覆盖默认边距；null时单行最小52、双行最小64像素。
  const CollabCardHeader({
    super.key,
    required this.leading,
    required this.title,
    this.subtitle,
    this.actions = const [],
    this.more,
    this.readOnly = false,
    this.tinted = true,
    this.padding,
  });

  /// 必填类型图标或展开控件；交互控件应自行提供至少44像素点击区域。
  final Widget leading;

  /// 必填标题，保留主题字体并使用14像素字重500，单行省略。
  final Widget title;

  /// 可选第二行来源；null只显示标题，空字符串仍保留第二行布局。
  final String? subtitle;

  /// 借用的快捷操作，始终位于更多左侧；默认空列表。
  final List<Widget> actions;

  /// 借用的更多控件，事务与权限复核仍由调用方负责；null无占位。
  final Widget? more;

  /// 是否隐藏更多按钮和其占位，默认false；不改变正文的查看交互。
  final bool readOnly;

  /// 是否使用浅灰标题背景，默认true。
  final bool tinted;

  /// 可选标题栏边距；null使用左右12/4、上下4像素。
  final EdgeInsetsGeometry? padding;

  /// 在借用[context]中为右侧操作预留宽度并省略长标题；锁标由卡片外框独立绘制。
  @override
  Widget build(BuildContext context) => ColoredBox(
    color: tinted ? const Color(0xFFF6F8FA) : Colors.white,
    child: ConstrainedBox(
      constraints: BoxConstraints(minHeight: subtitle == null ? 52 : 64),
      child: Padding(
        padding: padding ?? const EdgeInsets.fromLTRB(12, 4, 4, 4),
        child: Row(
          children: [
            IconTheme(
              data: const IconThemeData(size: 22, color: Color(0xFF64748B)),
              child: leading,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  DefaultTextStyle.merge(
                    style: const TextStyle(color: Color(0xFF1F2329), fontSize: 14, fontWeight: FontWeight.w500),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    child: title,
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11, color: Color(0xFF87909E)),
                    ),
                  ],
                ],
              ),
            ),
            ...actions,
            if (!readOnly && more != null) SizedBox(width: 44, height: 44, child: more),
          ],
        ),
      ),
    ),
  );
}
