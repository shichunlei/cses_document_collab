import 'dart:math' as math;

import 'package:cses_document_collab/src/model/collab_block_colors.dart';
import 'package:cses_document_collab/src/model/collab_weather.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// 七种桌面天气布局的原生展示；只借用快照，不创建请求、不写共享属性。
/// ```dart
/// import 'package:cses_document_collab/src/model/collab_weather.dart';
/// import 'package:cses_document_collab/src/ui/modal/collab_weather_visual.dart';
/// const preview = CollabWeatherVisual(card: CollabWeather({'style': 'card'}));
/// ```
class CollabWeatherVisual extends StatelessWidget {
  /// [key]控制身份复用；[card]为必需外观，[weather]为可空真实快照。
  /// [status]为空时无状态提示，加载/失败可传中文；无天气时显示明确占位。
  /// [alignment]默认左侧居中；设置预览可传Alignment.center，使实际卡片位于区域中心。
  const CollabWeatherVisual({
    super.key,
    required this.card,
    this.weather,
    this.status,
    this.alignment = Alignment.centerLeft,
  });

  /// 借用的只读外观属性，坏值只在展示端回落。
  final CollabWeather card;

  /// 已定格或宿主返回的天气；null显示--，不生成假数据。
  final CollabWeatherData? weather;

  /// 可选的加载/错误状态，仅在城市/天气副行显示。
  final String? status;

  /// 卡片在可用区域内的对齐，默认保持正文左侧居中，调用方可设置预览居中。
  final AlignmentGeometry alignment;

  /// 按借用 [context] 的文档字色和可用宽度绘制固定比例；窄屏只缩小展示不改尺寸。
  @override
  Widget build(BuildContext context) {
    final props = card.values;
    final layout = collabWeatherLayouts[card.style]!;
    final palette = collabWeatherPalettes[props['palette']]?.$2 ?? collabWeatherPalettes['document']!.$2;
    final inherited = DefaultTextStyle.of(context).style.color ?? Theme.of(context).colorScheme.onSurface;

    /// [key]读取显式颜色；[fallback]是色调/文档回落色，CSS继承不持久化。
    Color color(String key, Color fallback) =>
        parseCollabBlockColor(props[key] is String ? props[key] as String : null) ?? fallback;
    final legacy = card.style == 'classic' && (props['palette'] == null || props['palette'] == '');
    final fg = color('fg', legacy ? const Color(0xff1f2329) : parseCollabBlockColor(palette[0]) ?? inherited);
    final accent = color('accent', parseCollabBlockColor(palette[1]) ?? fg);
    final line = color('line', parseCollabBlockColor(palette[2]) ?? fg.withValues(alpha: .35));
    final bg = color('bg', parseCollabBlockColor(palette[3]) ?? Colors.transparent);
    final bc = color('bc', fg);
    final border = RegExp(r'^(\d+)px (solid|dashed|dotted|double)$').firstMatch('${props['bw'] ?? ''}');
    final bw = double.tryParse(border?.group(1) ?? '') ?? 0;
    final data = weather;
    final tone = data?.tone ?? 'sunny';
    final iconColor = props['iconMode'] == 'mono'
        ? accent
        : switch (tone) {
            'sunny' => const Color(0xffe9ad35),
            'rainy' || 'snowy' => const Color(0xff5596b9),
            'stormy' => const Color(0xff8578aa),
            _ => const Color(0xff8d9da9),
          };
    final icon = Icon(
      switch (tone) {
        'cloudy' => LucideIcons.cloud,
        'rainy' => LucideIcons.cloudRain,
        'snowy' => LucideIcons.cloudSnow,
        'stormy' => LucideIcons.cloudLightning,
        'foggy' => LucideIcons.cloudFog,
        _ => LucideIcons.sun,
      },
      color: iconColor,
      size: card.style == 'classic' ? 33.6 : 38,
    );

    /// [value]为展示文字，[size]为设计字号；[strong]控制主温度，[tint]覆盖颜色。
    Widget text(String value, double size, {bool strong = false, Color? tint}) => Text(
      value,
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: size,
        height: 1.2,
        color: tint ?? fg,
        fontWeight: strong ? FontWeight.w600 : FontWeight.w400,
      ),
    );
    final temp = text(
      data == null ? '--°' : '${_temperature(data.temp)}°',
      card.style == 'classic'
          ? 16
          : card.style == 'stack'
          ? 32
          : 36,
      strong: card.style == 'classic',
    );
    final city = text(data == null || data.location.isEmpty ? '城市' : data.location, 12, strong: true);
    final condition = text(status ?? data?.condition ?? '天气', 10, tint: fg.withValues(alpha: .65));
    final range = Visibility(
      visible: props['range'] != 'off',
      maintainSize: true,
      maintainAnimation: true,
      maintainState: true,
      child: text(
        data == null
            ? '--° / --°'
            : '${_temperature(data.low ?? data.temp)}° / ${_temperature(data.high ?? data.temp)}°',
        9,
        tint: fg.withValues(alpha: .65),
      ),
    );
    final details = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [city, condition, range],
    );
    final content = switch (card.style) {
      'classic' => Row(
        children: [
          icon,
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                temp,
                text(
                  [data?.location ?? '城市', status ?? data?.condition ?? '天气'].join(' · '),
                  11,
                  tint: fg.withValues(alpha: .52),
                ),
              ],
            ),
          ),
        ],
      ),
      'inline' => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          children: [
            icon,
            const SizedBox(width: 12),
            temp,
            const SizedBox(width: 12),
            Expanded(child: details),
          ],
        ),
      ),
      'ruled' => Container(
        decoration: BoxDecoration(
          border: Border.symmetric(horizontal: BorderSide(color: line)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                icon,
                const SizedBox(width: 12),
                Expanded(child: city),
                temp,
              ],
            ),
            Row(
              children: [
                Expanded(child: condition),
                range,
              ],
            ),
          ],
        ),
      ),
      'sidebar' => Container(
        decoration: BoxDecoration(
          border: Border(left: BorderSide(color: accent, width: 3)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Expanded(child: city),
                Flexible(child: condition),
              ],
            ),
            Row(
              children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [temp, range]),
                ),
                icon,
              ],
            ),
          ],
        ),
      ),
      'card' => Container(
        decoration: BoxDecoration(
          border: Border.all(color: line),
          borderRadius: BorderRadius.circular(6),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 17, vertical: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            city,
            Row(children: [icon, const SizedBox(width: 12), temp]),
            Container(
              padding: const EdgeInsets.only(top: 9),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: line)),
              ),
              child: Row(
                children: [
                  Expanded(child: condition),
                  range,
                ],
              ),
            ),
          ],
        ),
      ),
      'stack' => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [city, icon, temp, condition, range],
        ),
      ),
      _ => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          border: Border.symmetric(horizontal: BorderSide(color: line)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            text('WEATHER / 天气', 8, tint: accent),
            Expanded(
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [city, condition, range],
                    ),
                  ),
                  Container(width: 1, color: line, margin: const EdgeInsets.symmetric(horizontal: 12)),
                  icon,
                  const SizedBox(width: 8),
                  temp,
                ],
              ),
            ),
          ],
        ),
      ),
    };
    final size = weatherSize(card.style);
    final rawWidth = props['width'];
    final width = rawWidth is num && rawWidth.isFinite && rawWidth > 0
        ? rawWidth.toDouble().clamp(1.0, 4096.0)
        : size.width;
    final rawHeight = props['height'];
    final height = rawHeight is num && rawHeight.isFinite && rawHeight > 0
        ? rawHeight.toDouble().clamp(1.0, 4096.0)
        : size.height * width / size.width;
    // The desktop frame scales its contents uniformly with the width. FittedBox
    // also contains system large text within its authored fixed geometry.
    return Semantics(
      label: data == null
          ? '天气：${status ?? '暂无数据'}'
          : '${data.location} ${data.condition} ${_temperature(data.temp)}摄氏度',
      child: LayoutBuilder(
        builder: (context, constraints) {
          final fittedWidth = constraints.maxWidth.isFinite ? math.min(width, constraints.maxWidth) : width;
          return Align(
            alignment: alignment,
            child: SizedBox(
              width: fittedWidth,
              height: height * fittedWidth / width,
              child: FittedBox(
                fit: BoxFit.contain,
                alignment: alignment,
                child: SizedBox(
                  width: size.width,
                  height: size.height,
                  child: CustomPaint(
                    foregroundPainter: _WeatherBorder(bw, bc, border?.group(2) ?? 'solid'),
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: SizedBox(
                        width: layout.width,
                        height: layout.height,
                        child: ColoredBox(
                          color: bg,
                          child: MediaQuery.withClampedTextScaling(maxScaleFactor: 1.0, child: content),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 格式化摄氏温度 [value]，整数不带.0；小数保留一位。
String _temperature(double value) =>
    value == value.roundToDouble() ? value.toInt().toString() : value.toStringAsFixed(1);

/// 沿固定外框绘制桌面线型，纯展示且不持有资源。
class _WeatherBorder extends CustomPainter {
  /// [width]为线宽，[color]为边色，[style]为桌面线型。
  const _WeatherBorder(this.width, this.color, this.style);

  /// 桌面设计线宽。
  final double width;

  /// 边框实际颜色。
  final Color color;

  /// solid/dashed/dotted/double之一。
  final String style;

  /// 在借用 [canvas] 和固定 [size] 上绘制内缩圆角框。
  @override
  void paint(Canvas canvas, Size size) {
    if (width <= 0) return;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = style == 'double' ? width / 3 : width;
    final rect = RRect.fromRectAndRadius((Offset.zero & size).deflate(width / 2), const Radius.circular(6));
    if (style == 'dashed' || style == 'dotted') {
      final path = Path()..addRRect(rect);
      for (final metric in path.computeMetrics()) {
        for (double offset = 0; offset < metric.length; offset += width * (style == 'dotted' ? 3 : 6)) {
          canvas.drawPath(
            metric.extractPath(offset, math.min(offset + width * (style == 'dotted' ? 1 : 3), metric.length)),
            paint,
          );
        }
      }
    } else {
      canvas.drawRRect(rect, paint);
      if (style == 'double') canvas.drawRRect(rect.deflate(width * .65), paint);
    }
  }

  /// [oldDelegate]尺寸外观未变时不重绘。
  @override
  bool shouldRepaint(covariant _WeatherBorder oldDelegate) =>
      width != oldDelegate.width || color != oldDelegate.color || style != oldDelegate.style;
}
