import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// 弹窗设计稿的亮/暗配色；只读取宿主亮度，不修改宿主主题。
///
/// ```dart
/// import 'package:flutter/material.dart';
/// import 'package:cses_document_collab/src/ui/modal/collab_modal.dart';
/// Widget label(BuildContext context) =>
///   Text('说明', style: TextStyle(color: CollabModalColors.of(context).muted));
/// ```
class CollabModalColors {
  /// [dark] 为 true 时使用设计稿的暗色配对。
  const CollabModalColors({required this.dark});

  /// 宿主当前是否使用暗色主题。
  final bool dark;

  /// 从借用的 [context] 读取当前亮度，不持有上下文。
  static CollabModalColors of(BuildContext context) =>
      CollabModalColors(dark: Theme.of(context).brightness == Brightness.dark);

  /// 主操作及选中项的紫色。
  Color get accent => Color(dark ? 0xFFB0A5FF : 0xFF6558D9);

  /// 主操作按钮上的文字色。
  Color get onAccent => Color(dark ? 0xFF231751 : 0xFFFFFFFF);

  /// 图标底色、选中背景及提示区域。
  Color get soft => Color(dark ? 0xFF302947 : 0xFFF0EDFF);

  /// 不透明的弹窗表面。
  Color get surface => Color(dark ? 0xFF202126 : 0xFFFFFFFF);

  /// 标题及正文文字。
  Color get text => Color(dark ? 0xFFEEEEF5 : 0xFF242633);

  /// 说明、占位及未选中图标。
  Color get muted => Color(dark ? 0xFFA9AAB9 : 0xFF757888);

  /// 分隔线、输入框边线及拖动条。
  Color get line => Color(dark ? 0xFF383941 : 0xFFECECF2);

  /// 输入框及次要操作背景。
  Color get field => Color(dark ? 0xFF292A32 : 0xFFF8F8FB);

  /// 删除及错误提示。
  Color get danger => Color(dark ? 0xFFFF94A4 : 0xFFCC4E62);

  /// 模态遮罩，锚点菜单不使用它。
  Color get barrier => Color(dark ? 0x94090B12 : 0x63222437);
}

/// 展示共用底部路由；取消返回 null，等待退场及子组件释放后返回结果。
/// [context] 提供导航和主题；[builder] 创建业务内容，不负责正文焦点恢复。
/// [requestFocus] 默认为 true；[useRootNavigator] 默认为 false，沿用编辑器所在导航器。
/// [isDismissible] 与 [enableDrag] 分别控制遮罩和下拉关闭，默认为 true。
/// 路由错误透传，业务控制器和服务始终由调用方持有。
Future<T?> showCollabBottomSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool requestFocus = true,
  bool useRootNavigator = false,
  bool isDismissible = true,
  bool enableDrag = true,
}) async {
  final navigator = Navigator.of(context, rootNavigator: useRootNavigator);
  final route = ModalBottomSheetRoute<T>(
    builder: (context) => CollabModalTheme(child: builder(context)),
    capturedThemes: InheritedTheme.capture(from: context, to: navigator.context),
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    modalBarrierColor: CollabModalColors.of(context).barrier,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    isDismissible: isDismissible,
    enableDrag: enableDrag,
    showDragHandle: false,
    requestFocus: requestFocus,
  );
  final result = await navigator.push(route);
  await route.completed;
  return result;
}

/// 展示共用居中路由并等待完整退场；取消返回 null，导航异常透传。
/// [context] 提供主题和导航；[builder] 创建业务弹窗。
/// [useRootNavigator] 默认 true，保持既有 showDialog 的导航层级；
/// [requestFocus] 默认 true；[barrierDismissible] 默认 true。
/// 调用方负责编辑器操作会话，不能在 builder 内释放借用的业务资源。
Future<T?> showCollabDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool useRootNavigator = true,
  bool requestFocus = true,
  bool barrierDismissible = true,
}) async {
  final navigator = Navigator.of(context, rootNavigator: useRootNavigator);
  final route = DialogRoute<T>(
    context: context,
    builder: (context) => CollabModalTheme(child: builder(context)),
    themes: InheritedTheme.capture(from: context, to: navigator.context),
    barrierColor: CollabModalColors.of(context).barrier,
    barrierDismissible: barrierDismissible,
    requestFocus: requestFocus,
  );
  final result = await navigator.push(route);
  await route.completed;
  return result;
}

/// 仅在弹窗子树应用设计稿主题，宿主主题和业务状态不受影响。
///
/// ```dart
/// import 'package:flutter/material.dart';
/// import 'package:cses_document_collab/src/ui/modal/collab_modal.dart';
/// const content = CollabModalTheme(child: TextField());
/// ```
class CollabModalTheme extends StatelessWidget {
  /// [key] 控制组件身份与状态复用；[child] 为借用的弹窗内容。
  /// [compactList] 默认false，锚点菜单设为true使用42像素行高。
  const CollabModalTheme({super.key, required this.child, this.compactList = false});

  /// 应用局部主题的必需子树，不接管其业务资源。
  final Widget child;

  /// 是否使用锚点菜单的紧凑列表间距，默认false。
  final bool compactList;

  /// 为 [context] 中的子树设置统一输入框、按钮、列表与分段控件样式。
  @override
  Widget build(BuildContext context) {
    final c = CollabModalColors.of(context);
    final base = Theme.of(context);
    final rounded = RoundedRectangleBorder(borderRadius: BorderRadius.circular(11));
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: BorderSide(color: c.line),
    );
    final text = base.textTheme.apply(bodyColor: c.text, displayColor: c.text);
    return Theme(
      data: base.copyWith(
        colorScheme: base.colorScheme.copyWith(
          primary: c.accent,
          onPrimary: c.onAccent,
          surface: c.surface,
          onSurface: c.text,
          onSurfaceVariant: c.muted,
          outline: c.line,
          error: c.danger,
        ),
        textTheme: text.copyWith(
          bodyMedium: (text.bodyMedium ?? const TextStyle()).copyWith(
            fontSize: 14,
            height: 1.55,
            color: c.text,
          ),
          bodySmall: (text.bodySmall ?? const TextStyle()).copyWith(
            fontSize: 11,
            height: 1.55,
            color: c.muted,
          ),
          titleSmall: (text.titleSmall ?? const TextStyle()).copyWith(
            fontSize: 12,
            height: 1.55,
            fontWeight: FontWeight.w500,
            color: c.text,
          ),
        ),
        iconTheme: IconThemeData(size: 19, color: c.muted),
        dividerColor: c.line,
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: c.field,
          isDense: true,
          contentPadding: const EdgeInsets.all(12),
          border: border,
          enabledBorder: border,
          focusedBorder: border.copyWith(borderSide: BorderSide(color: c.accent)),
          hintStyle: TextStyle(fontSize: 14, color: c.muted),
          labelStyle: TextStyle(fontSize: 12, color: c.muted),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: c.accent,
            foregroundColor: c.onAccent,
            minimumSize: const Size(0, 42),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            padding: const EdgeInsets.symmetric(horizontal: 19, vertical: 10),
            textStyle: TextStyle(
              fontFamily: text.labelLarge?.fontFamily,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
            shape: rounded,
            elevation: 0,
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            foregroundColor: c.muted,
            minimumSize: const Size(0, 42),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            padding: const EdgeInsets.symmetric(horizontal: 19, vertical: 10),
            textStyle: TextStyle(
              fontFamily: text.labelLarge?.fontFamily,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
            shape: rounded,
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: c.text,
            backgroundColor: c.field,
            side: BorderSide(color: c.line),
            minimumSize: const Size(0, 42),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            shape: rounded,
            textStyle: TextStyle(
              fontFamily: text.labelLarge?.fontFamily,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        listTileTheme: ListTileThemeData(
          contentPadding: EdgeInsets.symmetric(horizontal: compactList ? 10 : 12),
          minTileHeight: compactList ? 42 : 51,
          minVerticalPadding: compactList ? 9 : 4,
          minLeadingWidth: 19,
          horizontalTitleGap: 12,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          iconColor: c.muted,
          textColor: c.text,
          titleTextStyle: (text.bodyMedium ?? const TextStyle()).copyWith(
            fontSize: 13,
            height: 1.55,
            color: c.text,
          ),
          subtitleTextStyle: (text.bodySmall ?? const TextStyle()).copyWith(
            fontSize: 11,
            height: 1.55,
            color: c.muted,
          ),
        ),
        sliderTheme: base.sliderTheme.copyWith(activeTrackColor: c.accent, thumbColor: c.accent),
      ),
      child: DefaultTextStyle(
        style: TextStyle(
          fontFamily: base.textTheme.bodyMedium?.fontFamily,
          fontFamilyFallback: base.textTheme.bodyMedium?.fontFamilyFallback,
          fontSize: 14,
          height: 1.55,
          color: c.text,
        ),
        child: child,
      ),
    );
  }
}

/// 带图标、标题、说明和关闭入口的共用面板头；不拥有资源。
///
/// ```dart
/// import 'package:flutter/material.dart';
/// import 'package:cses_document_collab/src/ui/modal/collab_modal.dart';
/// const heading = CollabModalHeader(title: Text('修改标题'), icon: Icons.title);
/// ```
class CollabModalHeader extends StatelessWidget {
  /// [key] 控制身份；[title] 必填；[icon] 为紫色图标槽中的图标。
  /// [subtitle] 为可选单行说明，超长省略；[canClose] 默认 true；[closeKey] 保留业务关闭入口标识。
  /// [compact] 默认 false，键盘遮挡较多时压缩头部；[titleSize] 默认为18逻辑像素。
  const CollabModalHeader({
    super.key,
    required this.title,
    required this.icon,
    this.subtitle,
    this.canClose = true,
    this.closeKey,
    this.compact = false,
    this.titleSize = 18,
  });

  /// 必需标题，使用设计稿的半粗体及配置字号。
  final Widget title;

  /// 必需装饰图标，不产生独立无障碍描述。
  final IconData icon;

  /// 可选的11像素单行说明文字，超出可用宽度时显示省略号。
  final String? subtitle;

  /// 是否允许点击关闭，保存期间可设为 false。
  final bool canClose;

  /// 可选的关闭按钮身份，便于消费者定位原有入口。
  final Key? closeKey;

  /// 键盘挤压空间时压缩头部留白并隐藏副标题，默认 false。
  final bool compact;

  /// 标题基础字号，默认18，居中弹窗使用17；仍遵循系统文字缩放。
  final double titleSize;

  /// 按 [context] 构建固定头部；标题允许换行以适配大字和窄屏。
  /// 说明文字始终单行省略，避免长链接挤占操作内容的可用高度。
  @override
  Widget build(BuildContext context) {
    final c = CollabModalColors.of(context);
    return Padding(
      padding: compact
          ? const EdgeInsets.fromLTRB(16, 4, 16, 6)
          : const EdgeInsets.fromLTRB(20, 14, 20, 16),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: c.soft, borderRadius: BorderRadius.circular(12)),
            child: Icon(icon, color: c.accent, size: 19),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DefaultTextStyle.merge(
                  style: TextStyle(
                    fontSize: titleSize,
                    height: 1.55,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -.3,
                    color: c.text,
                  ),
                  child: title,
                ),
                if (subtitle != null && !compact)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(
                      subtitle!,
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, height: 1.55, color: c.muted),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            key: closeKey,
            tooltip: '关闭',
            constraints: const BoxConstraints.tightFor(width: 36, height: 36),
            padding: EdgeInsets.zero,
            onPressed: canClose ? () => Navigator.pop(context) : null,
            icon: const Icon(LucideIcons.x, size: 19),
          ),
        ],
      ),
    );
  }
}

/// 固定标题/操作区、中部独立滚动的共用底部弹窗，负责键盘和底部安全区。
///
/// ```dart
/// import 'package:flutter/material.dart';
/// import 'package:cses_document_collab/src/ui/modal/collab_modal.dart';
/// Future<void> open(BuildContext context) => showCollabBottomSheet<void>(
///   context: context, builder: (_) => const CollabBottomSheet(
///     title: Text('修改标题'), icon: Icons.title, child: TextField()));
/// ```
class CollabBottomSheet extends StatelessWidget {
  /// [key] 控制身份；[title]/[icon] 为标题及装饰；[child] 为内容，不要重复避让键盘。
  /// [subtitle] 为可选单行省略说明，[header] 为固定的附加控件，如分类切换。
  /// [leadingAction] 为可选左侧次要操作，默认不显示。
  /// [actions] 默认为空；[canClose] 默认 true，false 阻止系统返回和关闭按钮。
  /// [closeKey] 保留关闭入口；[scrollController] 为借用滚动控制器，不会被释放。
  /// [scrollKey] 是可选的滚动视口标识。
  /// [contentPadding] 默认左右20、下18；[expand] 默认 false，true 时正文填满剩余高度、操作区贴底。
  const CollabBottomSheet({
    super.key,
    required this.title,
    required this.icon,
    required this.child,
    this.subtitle,
    this.header,
    this.actions = const [],
    this.leadingAction,
    this.canClose = true,
    this.closeKey,
    this.scrollController,
    this.scrollKey,
    this.contentPadding = const EdgeInsets.fromLTRB(20, 0, 20, 18),
    this.expand = false,
  });

  /// 必需标题。
  final Widget title;

  /// 必需装饰图标。
  final IconData icon;

  /// 可选标题说明，最多一行，超出显示省略号。
  final String? subtitle;

  /// 内容区域，由外壳提供滚动；不得传入无界 Expanded。
  final Widget child;

  /// 可选固定附加头部，内容自行管理分类状态。
  final Widget? header;

  /// 固定操作区，空列表隐藏底部分隔线。
  final List<Widget> actions;

  /// 可选的左侧次要操作，如删除；窄屏时右侧按钮独立换行。
  final Widget? leadingAction;

  /// 是否允许关闭；false 同时阻止系统返回。
  final bool canClose;

  /// 业务关闭按钮标识。
  final Key? closeKey;

  /// 借用的滚动控制器，由创建方释放。
  final ScrollController? scrollController;

  /// 可选的内容滚动视口标识，用于恢复既有操作入口。
  final Key? scrollKey;

  /// 滚动内容内边距。
  final EdgeInsetsGeometry contentPadding;

  /// 是否由滚动正文填满可用高度，适用于图库和添加内容面板；操作区保持在安全区上方。
  final bool expand;

  /// 基于 [context] 的实际约束限制高度，键盘留白只在本层计算一次。
  /// 展开模式让正文占满剩余空间，底部操作区不随内容长短浮动。
  @override
  Widget build(BuildContext context) {
    final c = CollabModalColors.of(context);
    final media = MediaQuery.of(context);
    return CollabModalTheme(
      child: PopScope(
        canPop: canClose,
        child: AnimatedPadding(
          duration: const Duration(milliseconds: 120),
          padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final height = math.max(
                0.0,
                math.min(
                  637.0,
                  math.min(constraints.maxHeight, media.size.height * .9 - media.viewInsets.bottom),
                ),
              );
              final compact = height < 360;
              return ConstrainedBox(
                constraints: BoxConstraints(maxHeight: height),
                child: Material(
                  color: c.surface,
                  clipBehavior: Clip.antiAlias,
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
                  child: Padding(
                    padding: EdgeInsets.only(
                      bottom: math.max(compact ? 12 : 22, media.padding.bottom),
                    ),
                    child: Column(
                      mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (!compact)
                          Center(
                            child: Container(
                              width: 34,
                              height: 4,
                              margin: const EdgeInsets.only(top: 10, bottom: 5),
                              decoration: BoxDecoration(
                                color: c.line,
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                          ),
                        CollabModalHeader(
                          title: title,
                          icon: icon,
                          subtitle: subtitle,
                          canClose: canClose,
                          compact: compact,
                          closeKey: closeKey,
                        ),
                        ?header,
                        Flexible(
                          fit: expand ? FlexFit.tight : FlexFit.loose,
                          child: SingleChildScrollView(
                            key: scrollKey,
                            controller: scrollController,
                            padding: contentPadding,
                            child: child,
                          ),
                        ),
                        if (actions.isNotEmpty || leadingAction != null)
                          CollabModalActions(leading: leadingAction, children: actions),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// 共用居中弹窗，与底部面板共享标题、输入及操作区样式。
///
/// ```dart
/// import 'package:flutter/material.dart';
/// import 'package:cses_document_collab/src/ui/modal/collab_modal.dart';
/// Future<void> open(BuildContext context) => showCollabDialog<void>(
///   context: context, builder: (_) => const CollabDialog(
///     title: Text('提示'), content: Text('操作已完成')));
/// ```
class CollabDialog extends StatelessWidget {
  /// [key] 控制身份；[title] 必填；[content] 为可选内容，不要重复套滚动区域。
  /// [leadingAction] 为可选左侧次要操作，默认不显示。
  /// [icon] 默认为信息图标；[actions] 默认为空；[canClose] 默认 true。
  const CollabDialog({
    super.key,
    required this.title,
    this.content,
    this.icon = LucideIcons.info,
    this.actions = const [],
    this.leadingAction,
    this.canClose = true,
  });

  /// 必需标题。
  final Widget title;

  /// 可选滚动正文。
  final Widget? content;

  /// 标题图标，默认信息符号。
  final IconData icon;

  /// 可换行的固定操作区。
  final List<Widget> actions;

  /// 可选的左侧次要操作，如删除；窄屏时右侧按钮独立换行。
  final Widget? leadingAction;

  /// 是否允许关闭，保存时可阻止按钮及系统返回。
  final bool canClose;

  /// 在 [context] 中按24像素外间距、20像素圆角渲染，保留系统键盘避让。
  @override
  Widget build(BuildContext context) {
    final c = CollabModalColors.of(context);
    return CollabModalTheme(
      child: PopScope(
        canPop: canClose,
        child: Dialog(
          insetPadding: const EdgeInsets.all(24),
          backgroundColor: c.surface,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 420,
              maxHeight: math.min(
                630,
                math.max(
                  0,
                  MediaQuery.sizeOf(context).height - MediaQuery.viewInsetsOf(context).bottom - 72,
                ),
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: CollabModalHeader(
                    title: title,
                    icon: icon,
                    canClose: canClose,
                    titleSize: 17,
                  ),
                ),
                if (content != null)
                  Flexible(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                      child: content,
                    ),
                  ),
                if (actions.isNotEmpty || leadingAction != null)
                  CollabModalActions(leading: leadingAction, bottom: 20, children: actions),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 可换行的固定操作区；不接管按钮的回调或加载状态。
///
/// ```dart
/// import 'package:flutter/material.dart';
/// import 'package:cses_document_collab/src/ui/modal/collab_modal.dart';
/// const actions = CollabModalActions(children: [Text('完成')]);
/// ```
class CollabModalActions extends StatelessWidget {
  /// [key] 控制身份；[children] 为右侧按钮；[bottom] 默认为2逻辑像素。
  /// [leading] 为可选左侧次要操作，其资源和回调由调用方持有。
  const CollabModalActions({super.key, required this.children, this.bottom = 2, this.leading});

  /// 按原始顺序向右排列的按钮，窄屏或大字时换行。
  final List<Widget> children;

  /// 底部留白，外壳另外负责安全区。
  final double bottom;

  /// 可选左侧次要操作，不加入右侧按钮组。
  final Widget? leading;

  /// 在 [context] 中构建细分隔线及10像素间距的操作区。
  /// 左侧操作按自然宽度布局且不超过可用宽度一半，右侧使用剩余空间并贴右排列。
  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      border: Border(top: BorderSide(color: CollabModalColors.of(context).line)),
    ),
    child: Padding(
      padding: EdgeInsets.fromLTRB(20, 14, 20, bottom),
      child: leading == null
          ? OverflowBar(
              alignment: MainAxisAlignment.end,
              overflowAlignment: OverflowBarAlignment.end,
              spacing: 10,
              overflowSpacing: 8,
              children: children,
            )
          : LayoutBuilder(
              builder: (context, constraints) => Row(
                children: [
                  ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: constraints.maxWidth / 2),
                    child: leading!,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OverflowBar(
                      alignment: MainAxisAlignment.end,
                      overflowAlignment: OverflowBarAlignment.end,
                      spacing: 10,
                      overflowSpacing: 8,
                      children: children,
                    ),
                  ),
                ],
              ),
            ),
    ),
  );
}

/// 外置标签的设计稿字段，不持有输入控制器。
///
/// ```dart
/// import 'package:flutter/material.dart';
/// import 'package:cses_document_collab/src/ui/modal/collab_modal.dart';
/// const field = CollabModalField(label: '链接地址', child: TextField());
/// ```
class CollabModalField extends StatelessWidget {
  /// [key] 控制身份；[label] 为必需标签；[child] 为借用的输入控件。
  const CollabModalField({super.key, required this.label, required this.child});

  /// 字段上方12像素标签。
  final String label;

  /// 输入控件，不应再次提供浮动 labelText。
  final Widget child;

  /// 在借用 [context] 中按标签8像素间距、字段底部15像素间距排布。
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 15),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: CollabModalColors.of(context).text,
          ),
        ),
        const SizedBox(height: 8),
        child,
      ],
    ),
  );
}

/// 共用的低矮分段选择器；选中状态及回调由业务持有。
///
/// ```dart
/// import 'package:flutter/material.dart';
/// import 'package:cses_document_collab/src/ui/modal/collab_modal.dart';
/// Widget tabs(int value, ValueChanged<int> select) => CollabModalSegments<int>(
///   values: const {0: '链接', 1: '上传'}, selected: value, onSelected: select);
/// ```
class CollabModalSegments<T> extends StatelessWidget {
  /// [key] 控制身份；[values] 按插入顺序显示；[selected] 为当前值。
  /// [onSelected] 为 null 时禁用；[itemKeys] 可保留各业务入口标识。
  const CollabModalSegments({
    super.key,
    required this.values,
    required this.selected,
    required this.onSelected,
    this.itemKeys = const {},
  });

  /// 各选项的稳定值与显示标签。
  final Map<T, String> values;

  /// 当前选中值，由调用方持有。
  final T selected;

  /// 点击选项时同步回调，null 禁用。
  final ValueChanged<T>? onSelected;

  /// 可选的各选项身份。
  final Map<T, Key> itemKeys;

  /// 在 [context] 中构建4像素内边距、白底紫字的选中态。
  @override
  Widget build(BuildContext context) {
    final c = CollabModalColors.of(context);
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: c.field, borderRadius: BorderRadius.circular(11)),
      child: Row(
        children: [
          for (final entry in values.entries)
            Expanded(
              child: Semantics(
                selected: selected == entry.key,
                button: true,
                child: InkWell(
                  key: itemKeys[entry.key],
                  borderRadius: BorderRadius.circular(8),
                  onTap: onSelected == null ? null : () => onSelected!(entry.key),
                  child: Container(
                    constraints: const BoxConstraints(minHeight: 35),
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 7),
                    decoration: selected == entry.key
                        ? BoxDecoration(
                            color: c.surface,
                            borderRadius: BorderRadius.circular(8),
                            boxShadow: const [
                              BoxShadow(
                                color: Color(0x1F1C1834),
                                blurRadius: 7,
                                offset: Offset(0, 2),
                              ),
                            ],
                          )
                        : null,
                    child: Text(
                      entry.value,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.55,
                        color: selected == entry.key ? c.accent : c.muted,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 锚点菜单共用表面，定位仍由业务负责。
///
/// ```dart
/// import 'package:flutter/material.dart';
/// import 'package:cses_document_collab/src/ui/modal/collab_modal.dart';
/// const menu = CollabPopover(title: '列操作', child: Text('插入列'));
/// ```
class CollabPopover extends StatelessWidget {
  /// [key] 控制身份；[title] 为菜单标题；[child] 为菜单内容；[width] 默认265逻辑像素。
  const CollabPopover({super.key, required this.title, required this.child, this.width = 265});

  /// 菜单标题。
  final String title;

  /// 菜单内容，拥有自身选择逻辑。
  final Widget child;

  /// 首选宽度，仍受外层定位约束限制。
  final double width;

  /// 按 [context] 的亮度应用13像素圆角、7像素内边距及阴影。
  @override
  Widget build(BuildContext context) {
    final c = CollabModalColors.of(context);
    return CollabModalTheme(
      compactList: true,
      child: Material(
        color: c.surface,
        elevation: 8,
        shadowColor: const Color(0x331C1834),
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(13),
          side: BorderSide(color: c.line),
        ),
        child: SizedBox(
          width: width,
          child: Padding(
            padding: const EdgeInsets.all(7),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        title,
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
                      ),
                    ),
                    IconButton(
                      tooltip: '关闭',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(LucideIcons.x, size: 16),
                      constraints: const BoxConstraints.tightFor(width: 32, height: 32),
                      padding: EdgeInsets.zero,
                    ),
                  ],
                ),
                Flexible(child: child),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 在 [context] 对应组件下方打开锚点菜单，空间不足时翻到上方。
/// [title] 是菜单标题；[builder] 创建业务内容；[requestFocus] 默认 false。
/// [width] 为首选宽度，默认265逻辑像素，实际宽度受屏幕安全区与键盘约束。
/// 使用最近 Navigator，捕获原主题；取消返回 null，退场后返回结果。
/// 找不到有效的锚点时直接返回 null，不修改正文输入或业务状态。
Future<T?> showCollabPopover<T>({
  required BuildContext context,
  required String title,
  required WidgetBuilder builder,
  bool requestFocus = false,
  double width = 265,
}) async {
  final navigator = Navigator.of(context);
  final box = context.findRenderObject() as RenderBox?;
  final overlay = navigator.overlay?.context.findRenderObject() as RenderBox?;
  if (box == null || overlay == null || !box.attached) return null;
  final anchor = box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;
  final themes = InheritedTheme.capture(from: context, to: navigator.context);
  final direction = Directionality.of(context);
  final route = RawDialogRoute<T>(
    barrierDismissible: true,
    barrierColor: Colors.transparent,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    transitionDuration: const Duration(milliseconds: 100),
    requestFocus: requestFocus,
    pageBuilder: (context, _, _) {
      final media = MediaQuery.of(context);
      return themes.wrap(
        CustomSingleChildLayout(
          delegate: _CollabPopoverLayout(
            anchor,
            direction,
            EdgeInsets.fromLTRB(
              media.padding.left + 8,
              media.padding.top + 8,
              media.padding.right + 8,
              math.max(media.viewInsets.bottom, media.padding.bottom) + 8,
            ),
          ),
          child: CollabPopover(title: title, width: width, child: builder(context)),
        ),
      );
    },
  );
  final result = await navigator.push(route);
  await route.completed;
  return result;
}

/// 保持菜单在安全区域和键盘之外的锚点布局，不拥有渲染对象。
class _CollabPopoverLayout extends SingleChildLayoutDelegate {
  /// [anchor] 为导航覆盖层坐标；[direction] 为文字方向；[insets] 为有效边缘留白。
  const _CollabPopoverLayout(this.anchor, this.direction, this.insets);

  /// 借用组件在导航覆盖层中的逻辑像素范围。
  final Rect anchor;

  /// 打开时的文字方向，决定菜单左右对齐。
  final TextDirection direction;

  /// 当前安全区和键盘之外的有效留白。
  final EdgeInsets insets;

  /// 按借用的父 [constraints] 给出不超过可视区域的松约束。
  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) => BoxConstraints.loose(
    Size(
      math.max(0, constraints.maxWidth - insets.horizontal),
      math.max(0, constraints.maxHeight - insets.vertical),
    ),
  );

  /// 根据父 [size] 与实际 [childSize] 翻转和限幅，不缓存过期布局。
  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final right = math.max(insets.left, size.width - insets.right - childSize.width);
    final bottom = math.max(insets.top, size.height - insets.bottom - childSize.height);
    final left = direction == TextDirection.rtl ? anchor.right - childSize.width : anchor.left;
    final below = anchor.bottom + 8;
    return Offset(
      left.clamp(insets.left, right),
      (below <= bottom ? below : anchor.top - childSize.height - 8).clamp(insets.top, bottom),
    );
  }

  /// 比较借用的 [oldDelegate]，锚点、方向或安全区域变化时重新定位。
  @override
  bool shouldRelayout(_CollabPopoverLayout oldDelegate) =>
      anchor != oldDelegate.anchor ||
      direction != oldDelegate.direction ||
      insets != oldDelegate.insets;
}
