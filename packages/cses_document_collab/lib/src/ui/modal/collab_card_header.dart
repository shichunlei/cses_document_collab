import 'package:cses_document_collab/src/ui/modal/collab_editor_display_scope.dart';
import 'package:flutter/material.dart';

/// 固定操作区的公共标题栏，长标题或网址不会挤压右侧按钮。
///
/// ```dart
/// import 'package:cses_document_collab/src/ui/modal/collab_card_header.dart';
/// import 'package:lucide_icons_flutter/lucide_icons.dart';
/// import 'package:flutter/material.dart';
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
                    style: const TextStyle(
                      color: Color(0xFF1F2329),
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
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
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xFF87909E),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (CollabEditorDisplayScope.maybeOf(context)?.preview != true)
              ...actions,
            if (!readOnly &&
                CollabEditorDisplayScope.maybeOf(context)?.preview != true &&
                more != null)
              SizedBox(width: 44, height: 44, child: more),
          ],
        ),
      ),
    ),
  );
}
