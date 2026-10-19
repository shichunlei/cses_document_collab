import 'package:flutter/material.dart';

/// 给代码正文添加不参与选区、复制或协同的行号栏；自动折行只在逻辑行首显示编号。
/// 借用正文组件，不持有编辑器资源；行号栏单独隔离重绘，避免光标闪烁重复测量代码。
/// ```dart
/// import 'package:flutter/material.dart';
/// import 'package:cses_document_collab/src/editor/collab_code_line_numbers.dart';
/// const style = TextStyle(fontFamily: 'monospace', fontSize: 13);
/// final body = CollabCodeLineNumbers(
///   source: 'print(1);', style: style,
///   textScaler: TextScaler.noScaling, textHeightBehavior: TextHeightBehavior(),
///   child: RichText(text: const TextSpan(text: 'print(1);', style: style),
///     textScaler: TextScaler.noScaling, textHeightBehavior: const TextHeightBehavior()),
/// );
/// ```
class CollabCodeLineNumbers extends StatelessWidget {
  /// [key]控制组件身份；[source]为完整代码，空代码仍显示第1行。
  /// [style]、[textScaler]、[textHeightBehavior]须与[child]正文一致，以对齐折行和基线。
  /// [child]为借用的代码编辑组件，输入和资源所有权仍由其创建者管理。
  const CollabCodeLineNumbers({
    super.key,
    required this.source,
    required this.style,
    required this.textScaler,
    required this.textHeightBehavior,
    required this.child,
  });

  /// 完整代码原文；每个换行字符增加一个编号，末尾换行保留最后的空行。
  final String source;

  /// 与代码正文一致的等宽字体、字号和行高。
  final TextStyle style;

  /// 与代码正文一致的缩放规则，不单独读取系统字号。
  final TextScaler textScaler;

  /// 正文首尾行高及行间留白分配规则。
  final TextHeightBehavior textHeightBehavior;

  /// 借用的原代码编辑组件，不替换其选区或输入委托。
  final Widget child;

  /// 在[context]提供的宽度与语言环境内布局正文，左侧按最大行号位数预留空间。
  @override
  Widget build(BuildContext context) {
    final count = '\n'.allMatches(source).length + 1;
    final locale = Localizations.maybeLocaleOf(context);
    final measure = TextPainter(
      text: TextSpan(text: '$count', style: style),
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
      locale: locale,
    )..layout();
    final gutter = measure.width.ceilToDouble() + 18;
    measure.dispose();
    return Stack(
      children: [
        Padding(
          padding: EdgeInsets.only(left: gutter),
          child: child,
        ),
        Positioned.fill(
          child: IgnorePointer(
            child: ExcludeSemantics(
              child: RepaintBoundary(
                key: const ValueKey('collab-code-line-numbers'),
                child: CustomPaint(
                  painter: _LineNumberPainter(
                    source: source,
                    style: style,
                    textScaler: textScaler,
                    textHeightBehavior: textHeightBehavior,
                    locale: locale,
                    gutter: gutter,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 仅绘制左侧编号，按与正文相同的布局宽度测量软折行；每次绘制后释放本地文字资源。
class _LineNumberPainter extends CustomPainter {
  /// [source]为原文；[style]、[textScaler]、[textHeightBehavior]与正文一致。
  /// [locale]为当前字体区域设置，null使用引擎默认；[gutter]为含间隔的左侧预留宽度。
  const _LineNumberPainter({
    required this.source,
    required this.style,
    required this.textScaler,
    required this.textHeightBehavior,
    required this.locale,
    required this.gutter,
  });

  /// 用于计算逻辑行与软折行的原文。
  final String source;

  /// 与代码正文一致的字体与行高。
  final TextStyle style;

  /// 正文采用的字号缩放。
  final TextScaler textScaler;

  /// 正文首尾行高与留白分配方式。
  final TextHeightBehavior textHeightBehavior;

  /// 正文的字体区域设置，null采用引擎默认值。
  final Locale? locale;

  /// 正文左侧预留的总宽度，含数字、分隔线及间隙。
  final double gutter;

  /// 在[canvas]的[size]区域绘制逻辑行号；基线沿用完整代码的行度量，软折行不递增。
  @override
  void paint(Canvas canvas, Size size) {
    final width = size.width - gutter;
    if (width <= 0) return;
    final code = TextPainter(
      text: TextSpan(text: source.isEmpty ? ' ' : source, style: style),
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
      textHeightBehavior: textHeightBehavior,
      locale: locale,
    )..layout(maxWidth: width);
    final label = TextPainter(
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
      locale: locale,
    );
    try {
      canvas.drawLine(
        Offset(gutter - 9, 0),
        Offset(gutter - 9, size.height),
        Paint()..color = const Color(0xFFE5E7EB),
      );
      var number = 1;
      var firstVisualLine = true;
      for (final line in code.computeLineMetrics()) {
        if (firstVisualLine) {
          label.text = TextSpan(
            text: '$number',
            style: style.copyWith(color: const Color(0xFF9CA3AF), height: 1),
          );
          label.layout();
          final baseline = label.computeDistanceToActualBaseline(
            TextBaseline.alphabetic,
          );
          label.paint(
            canvas,
            Offset(gutter - 18 - label.width, line.baseline - baseline),
          );
        }
        firstVisualLine = line.hardBreak;
        if (line.hardBreak) number++;
      }
    } finally {
      code.dispose();
      label.dispose();
    }
  }

  /// 正文、宽度、字体或行高环境变化时重绘；[oldDelegate]为上一帧借用的绘制配置。
  @override
  bool shouldRepaint(covariant _LineNumberPainter oldDelegate) =>
      source != oldDelegate.source ||
      style != oldDelegate.style ||
      textScaler != oldDelegate.textScaler ||
      textHeightBehavior != oldDelegate.textHeightBehavior ||
      locale != oldDelegate.locale ||
      gutter != oldDelegate.gutter;
}
