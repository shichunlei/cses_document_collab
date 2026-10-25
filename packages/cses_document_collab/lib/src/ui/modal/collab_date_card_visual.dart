import 'dart:math' as math;

import 'package:cses_document_collab/src/model/collab_date_card.dart';
import 'package:cses_document_collab/src/model/collab_block_colors.dart';
import 'package:flutter/material.dart';

/// 日期卡片的原生展示，编辑、预览和设置草稿共用；不写日期或持有编辑器。
/// ```dart
/// import 'package:cses_document_collab/src/model/collab_date_card.dart';
/// import 'package:cses_document_collab/src/ui/modal/collab_date_card_visual.dart';
/// const card = CollabDateCardVisual(card: CollabDateCard({'date': '2026-10-25T09:00'}));
/// ```
class CollabDateCardVisual extends StatelessWidget {
  /// [key]控制身份；[card]为必需的只读属性，未知外观只回落展示。
  /// [alignment]默认左侧居中；预览可传居中，使缩放后的实际卡片位于可用区域中央。
  const CollabDateCardVisual({super.key, required this.card, this.alignment = Alignment.centerLeft});

  /// 借用日期及样式数据，不修改共享树。
  final CollabDateCard card;

  /// 卡片在可用宽高内的位置，默认左侧居中；不修改保存尺寸或日期。
  final AlignmentGeometry alignment;

  /// 在借用 [context] 中按手机宽度缩小固定设计框；系统大字保持框内可读且不溢出。
  @override
  Widget build(BuildContext context) {
    final style = card.style;
    final date = card.date;
    final props = card.values;
    final spec = collabDateCardDesigns[style]!;
    final green = {'masthead', 'split', 'pill', 'rail'}.contains(style);
    final fg =
        parseCollabBlockColor(props['fg'] is String ? props['fg'] as String : null) ??
        (style == 'flip' || style == 'bookmark'
            ? const Color(0xFFFFFEFA)
            : green
            ? const Color(0xFF416D57)
            : const Color(0xFF1F2329));
    final bg =
        parseCollabBlockColor(props['bg'] is String ? props['bg'] as String : null) ??
        (style == 'flip'
            ? const Color(0xFF262A30)
            : style == 'bookmark'
            ? const Color(0xFF416D57)
            : style == 'ticket'
            ? fg.withValues(alpha: .07)
            : Colors.transparent);
    final bc = parseCollabBlockColor(props['bc'] is String ? props['bc'] as String : null) ?? const Color(0xFF1F2329);
    final rawFonts = props[spec.fontKey];
    final fonts = rawFonts is String ? rawFonts.trim().split(RegExp(r'\s+')) : <String>[];
    final full = card.format == 'full';
    final year = card.format != 'min';
    final day = date.day.toString().padLeft(2, '0');
    final week = '星期${'一二三四五六日'[date.weekday - 1]}';
    final month = '${date.month}月';
    final ym = year ? '${date.year}年 $month' : month;

    /// 按层级 [index] 展示 [value]；可选 [color] 覆盖该层颜色，否则跟随前景色。
    /// 覆盖字号无效时只在展示端回落设计值。
    Widget text(String value, int index, {Color? color}) {
      final parsed = index < fonts.length ? double.tryParse(fonts[index]) : null;
      final size = parsed != null && parsed.isFinite && parsed > 0 ? parsed.clamp(1.0, 512.0) : spec.fonts[index];
      return Text(
        value,
        textAlign: TextAlign.center,
        maxLines: 1,
        softWrap: false,
        style: TextStyle(
          fontSize: size,
          height: 1.15,
          fontWeight: index == 0 ? FontWeight.w700 : FontWeight.w500,
          color: color ?? fg,
          fontFamily: _fontFamilies[props['ff']],
        ),
      );
    }

    final abbr = const [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ][date.month - 1];
    final monthName = const [
      'JANUARY',
      'FEBRUARY',
      'MARCH',
      'APRIL',
      'MAY',
      'JUNE',
      'JULY',
      'AUGUST',
      'SEPTEMBER',
      'OCTOBER',
      'NOVEMBER',
      'DECEMBER',
    ][date.month - 1];
    final sub = [if (year) '${date.year}', if (full) week].join(' · ');

    /// 垂直组合借用的 [children]，高度由外部固定设计框控制。
    Widget column(List<Widget> children) =>
        Column(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: children);

    /// 水平组合借用的 [children]，内部不使用无界Expanded。
    Widget row(List<Widget> children) =>
        Row(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: children);

    /// 分隔线 [thickness] 使用当前前景色混合，不保存派生颜色。
    Widget rule({double thickness = 1}) => SizedBox(
      width: spec.width - 16,
      child: Divider(height: 8, thickness: thickness, color: fg.withValues(alpha: .5)),
    );

    final dateNumber = text(
      {'calendar', 'banner', 'minibar', 'ticket', 'stamp'}.contains(style) ? '${date.day}' : day,
      0,
    );
    final horizontalInfo = column([text('$abbr${year ? ' ${date.year}' : ''}', 1), if (full) text(week, 2)]);
    Widget content = switch (style) {
      'calendar' => Container(
        width: spec.width - 5,
        decoration: BoxDecoration(color: fg.withValues(alpha: .08), borderRadius: BorderRadius.circular(5)),
        child: column([
          Container(width: spec.width - 5, height: 16, color: fg.withValues(alpha: .07)),
          const SizedBox(height: 8),
          dateNumber,
          text('$abbr${full ? ' / 周${'一二三四五六日'[date.weekday - 1]}' : ''}', 1),
          if (year) text(ym, 2),
          const SizedBox(height: 8),
        ]),
      ),
      'square' => column([
        text(year ? '${date.year}-${date.month.toString().padLeft(2, '0')}' : abbr, 1),
        dateNumber,
        if (full) text('周${'一二三四五六日'[date.weekday - 1]}', 2),
      ]),
      'banner' => row([
        dateNumber,
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 11),
          child: SizedBox(height: 28, child: VerticalDivider(width: 1, color: fg.withValues(alpha: .28))),
        ),
        column([text(abbr.toUpperCase(), 1, color: const Color(0xFFD98515)), if (sub.isNotEmpty) text(sub, 2)]),
      ]),
      'minibar' => row([dateNumber, const SizedBox(width: 8), horizontalInfo]),
      'ticket' => row([
        dateNumber,
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 9),
          child: SizedBox(height: 40, child: VerticalDivider(width: 1, color: fg.withValues(alpha: .32))),
        ),
        horizontalInfo,
      ]),
      'stamp' => Container(
        width: 124,
        height: 124,
        padding: const EdgeInsets.all(5),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: fg, width: 2),
        ),
        child: Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: fg),
          ),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: column([
              text('$abbr${year ? ' ${date.year}' : ''}', 1),
              dateNumber,
              if (full) text(const ['MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT', 'SUN'][date.weekday - 1], 2),
            ]),
          ),
        ),
      ),
      'flip' => Stack(
        alignment: Alignment.center,
        children: [
          column([
            text(ym, 1),
            dateNumber,
            if (full) Container(width: spec.width, color: fg.withValues(alpha: .12), child: text(week, 2)),
          ]),
          Positioned(
            top: full ? 52 : 42,
            left: 0,
            right: 0,
            child: Divider(height: 1, color: fg.withValues(alpha: .22)),
          ),
        ],
      ),
      'masthead' => column([
        text('${year ? '${date.year}  ' : ''}$monthName', 2),
        rule(thickness: 2),
        row([
          dateNumber,
          const SizedBox(width: 14),
          column([text(month, 1), if (full) text(week, 2)]),
        ]),
        rule(),
        text('DAILY RECORD', 2),
      ]),
      'bookmark' => column([
        text('${year ? '${date.year}.' : ''}${date.month.toString().padLeft(2, '0')}', 1),
        dateNumber,
        if (full) ...[const SizedBox(height: 8), text(week, 2)],
      ]),
      'split' => column([
        row([
          column([text('MONTH', 2), text(date.month.toString().padLeft(2, '0'), 1)]),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Transform.rotate(
              angle: .4,
              child: SizedBox(height: 64, child: VerticalDivider(width: 1, color: fg.withValues(alpha: .4))),
            ),
          ),
          column([text('DAY', 2), dateNumber]),
        ]),
        if (sub.isNotEmpty) ...[rule(), text(sub, 2)],
      ]),
      'pill' => row([
        Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(shape: BoxShape.circle, color: fg),
          child: Center(child: text(day, 0, color: bg == Colors.transparent ? const Color(0xFFFFFEFA) : bg)),
        ),
        const SizedBox(width: 14),
        column([text(ym, 1), if (full) text(week, 2)]),
      ]),
      'rail' => column([
        row([dateNumber, const SizedBox(width: 14), text(monthName, 1)]),
        rule(thickness: 2),
        rule(),
        if (sub.isNotEmpty) text(sub, 2),
      ]),
      _ => dateNumber,
    };
    final radius = style == 'pill'
        ? 80.0
        : style == 'stamp'
        ? 66.0
        : style == 'square'
        ? 14.0
        : 8.0;
    if (style == 'bookmark') {
      content = ClipPath(
        clipper: const _BookmarkClipper(),
        child: Container(
          width: spec.width,
          height: spec.height,
          color: bg,
          padding: const EdgeInsets.only(bottom: 13),
          child: FittedBox(fit: BoxFit.scaleDown, child: content),
        ),
      );
    }
    content = Container(
      width: spec.width,
      height: dateCardSize(style, card.format).height - 8,
      decoration: BoxDecoration(
        color: style == 'bookmark' ? Colors.transparent : bg,
        border: style == 'pill' ? Border.all(color: fg) : null,
        borderRadius: BorderRadius.circular(radius),
      ),
      child: CustomPaint(
        foregroundPainter: _DateBorder(color: bc, look: card.border, radius: radius),
        child: Padding(
          padding: EdgeInsets.all(style == 'bookmark' || style == 'flip' || style == 'calendar' ? 0 : 4),
          child: FittedBox(fit: BoxFit.scaleDown, child: content),
        ),
      ),
    );
    return Semantics(
      label: '${date.year}年${date.month}月${date.day}日 $week，${collabDateCardStyles[style]}',
      child: LayoutBuilder(
        builder: (context, constraints) {
          final raw = props['width'];
          final width = raw is num && raw.isFinite && raw > 0 ? raw.toDouble() : spec.width + 8;
          final rawHeight = props['height'];
          final height = rawHeight is num && rawHeight.isFinite && rawHeight > 0
              ? rawHeight.toDouble()
              : width * (dateCardSize(style, card.format).height) / (spec.width + 8);
          final available = constraints.maxWidth.isFinite ? constraints.maxWidth : width;
          final actual = math.min(width, available).clamp(1.0, 4096.0);
          return Align(
            alignment: alignment,
            child: SizedBox(
              width: actual,
              height: (height * actual / width).clamp(1.0, 4096.0),
              child: FittedBox(fit: BoxFit.contain, alignment: alignment, child: content),
            ),
          );
        },
      ),
    );
  }
}

/// 使用系统可用字体回落，不请求或下载桌面字体文件。
const _fontFamilies = {
  'sans': null,
  'arial': 'Arial',
  'calibri': 'Calibri',
  'verdana': 'Verdana',
  'tahoma': 'Tahoma',
  'hei': 'SimHei',
  'yahei': 'Microsoft YaHei',
  'pingfang': 'PingFang SC',
  'serif': 'Songti SC',
  'times': 'Times New Roman',
  'georgia': 'Georgia',
  'simsun': 'SimSun',
  'kai': 'Kaiti SC',
  'xingkai': 'Xingkai SC',
  'fang': 'FangSong',
  'dengxian': 'DengXian',
  'lishu': 'LiSu',
  'mono': 'monospace',
};

/// 页边签色纸的V形切口，外部边框不参与裁切。
class _BookmarkClipper extends CustomClipper<Path> {
  /// 无可变配置，无资源所有权。
  const _BookmarkClipper();

  /// 在借用 [size] 内保留底部13设计像素的V形缺口。
  @override
  Path getClip(Size size) => Path()
    ..lineTo(size.width, 0)
    ..lineTo(size.width, size.height)
    ..lineTo(size.width / 2, size.height - 13)
    ..lineTo(0, size.height)
    ..close();

  /// [oldClipper]无可变配置，无需重裁切。
  @override
  bool shouldReclip(covariant _BookmarkClipper oldClipper) => false;
}

/// 桌面CSS边框的无资源绘制器；虚线、点线及双线保留独立外观。
class _DateBorder extends CustomPainter {
  /// [color]为线色，[look]为CSS宽度和线型，[radius]为逻辑像素圆角。
  const _DateBorder({required this.color, required this.look, required this.radius});

  /// 调用方解析的边框颜色。
  final Color color;

  /// 空值或零宽度表示无外框。
  final String look;

  /// 外框的逻辑像素圆角。
  final double radius;

  /// 在借用 [canvas] 的 [size] 边界内绘制，不影响布局与命中。
  @override
  void paint(Canvas canvas, Size size) {
    final width = double.tryParse(look.split('px').first) ?? 0;
    if (!width.isFinite || width <= 0) return;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = width;
    final rect = (Offset.zero & size).deflate(width / 2);
    final path = Path()..addRRect(RRect.fromRectAndRadius(rect, Radius.circular(radius)));
    if (look.contains('dashed') || look.contains('dotted')) {
      final dotted = look.contains('dotted');
      paint.strokeCap = dotted ? StrokeCap.round : StrokeCap.butt;
      var strokes = 0;
      const maximumStrokes = 2048;
      for (final metric in path.computeMetrics()) {
        final step = math.max(width * (dotted ? 3 : 7), metric.length / maximumStrokes);
        for (var offset = 0.0; offset < metric.length && strokes < maximumStrokes; offset += step) {
          canvas.drawPath(metric.extractPath(offset, offset + (dotted ? .01 : width * 4)), paint);
          strokes++;
        }
      }
    } else if (look.contains('double')) {
      paint.strokeWidth = width / 3;
      canvas.drawRRect(RRect.fromRectAndRadius(rect, Radius.circular(radius)), paint);
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect.deflate(width * 2 / 3), Radius.circular(math.max(0, radius - width))),
        paint,
      );
    } else {
      canvas.drawPath(path, paint);
    }
  }

  /// [oldDelegate]任一外观变化时才请求重绘。
  @override
  bool shouldRepaint(covariant _DateBorder oldDelegate) =>
      oldDelegate.color != color || oldDelegate.look != look || oldDelegate.radius != radius;
}
