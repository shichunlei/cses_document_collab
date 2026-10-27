import 'package:cses_document_collab/src/ui/modal/collab_menu_density.dart';
import 'package:cses_document_collab/src/ui/modal/collab_modal_colors.dart';
import 'package:flutter/material.dart';

/// 仅在弹窗子树应用设计稿主题，宿主主题和业务状态不受影响。
///
/// ```dart
/// import 'package:cses_document_collab/src/ui/modal/collab_modal_theme.dart';
/// import 'package:flutter/material.dart';
/// const content = CollabModalTheme(child: TextField());
/// ```
class CollabModalTheme extends StatelessWidget {
  /// [key] 控制组件身份与状态复用；[child] 为借用的弹窗内容。
  /// [compactList] 默认false，锚点菜单设为true使用42逻辑像素最小行高，内容可随文字增长。
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
          bodyMedium: (text.bodyMedium ?? const TextStyle()).copyWith(fontSize: 14, height: 1.55, color: c.text),
          bodySmall: (text.bodySmall ?? const TextStyle()).copyWith(fontSize: 11, height: 1.55, color: c.muted),
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
            textStyle: TextStyle(fontFamily: text.labelLarge?.fontFamily, fontSize: 13, fontWeight: FontWeight.w500),
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
            textStyle: TextStyle(fontFamily: text.labelLarge?.fontFamily, fontSize: 13, fontWeight: FontWeight.w500),
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
            textStyle: TextStyle(fontFamily: text.labelLarge?.fontFamily, fontSize: 13, fontWeight: FontWeight.w500),
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
        child: CollabMenuDensity(compact: compactList, child: child),
      ),
    );
  }
}
