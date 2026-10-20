import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:cses_document_collab/src/model/collab_block_colors.dart';
import 'package:cses_document_collab/src/model/collab_divider.dart';
import 'package:cses_document_collab/src/model/collab_divider_artwork.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// 按桌面尺寸与矢量图案绘制分割线，供正文和设置缩略图共用。
/// ```dart
/// import 'package:cses_document_collab/src/ui/modal/collab_divider_visual.dart';
/// import 'package:cses_document_collab/src/model/collab_divider.dart';
/// final preview = CollabDividerVisual(divider: CollabDivider({'style': 'edge-vine'}));
/// ```
class CollabDividerVisual extends StatelessWidget {
  /// [divider] 为借用的只读属性，[key] 控制身份与状态复用。
  /// [preview] 默认 false；true 使用缩略图大小并展示全长、完全不透明的样式。
  const CollabDividerVisual({super.key, required this.divider, this.preview = false});

  /// 必需的样式解析，不持有编辑器或共享文档。
  final CollabDivider divider;

  /// 是否为设置面板缩略图，默认 false。
  final bool preview;

  /// 在 [context] 的有限宽度中居中绘制；无本地状态或写入副作用。
  @override
  Widget build(BuildContext context) {
    final style = divider.style;
    final level = preview
        ? 1
        : switch (divider.thickness) {
            'regular' => 2,
            'thick' => 3,
            _ => 1,
          };
    final edge = style.startsWith('edge-');
    final tape = style.startsWith('tape-');
    final height = tape
        ? (preview ? 24.0 : [28.0, 40.0, 52.0][level - 1])
        : edge
        ? (preview ? 20.0 : [16.0, 23.0, 32.0][level - 1])
        : 24.0;
    final color = parseCollabBlockColor(divider.lineColor) ?? Theme.of(context).dividerColor;
    return SizedBox(
      height: height,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth * (preview ? 1 : divider.widthRatio);
          if (width <= 0) {
            return const SizedBox.shrink();
          }
          final inkHeight = edge ? (preview ? 18.0 : [14.0, 21.0, 30.0][level - 1]) : [4.0, 6.0, 9.0][level - 1];
          final maskKey = edge ? style.substring(5) : style;
          final svg = dividerSvgMasks[maskKey];
          final repeated = style == 'edge-vine' || !edge;
          final shape = svg == null ? const SizedBox.shrink() : _svgPattern(svg, width, inkHeight, repeated, color);
          return Center(
            child: Opacity(
              opacity: preview ? 1 : divider.opacity,
              child: Transform.rotate(
                angle: tape && !preview && level < 3 ? (level == 1 ? .6 : .8) * math.pi / 180 : 0,
                child: SizedBox(
                  width: width,
                  height: height,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Positioned.fill(
                        child: CustomPaint(painter: _DividerPainter(style, color, level, edge ? inkHeight : 0)),
                      ),
                      if (svg != null) shape,
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// 将桌面 [svg] 遮罩按 [width]/[height] 逻辑像素展示并以 [color] 着色。
  /// [repeated] 决定横向平铺或单饰居中，窄列单饰整体缩小而不裁切。
  Widget _svgPattern(String svg, double width, double height, bool repeated, Color color) {
    final viewBox = RegExp(r'viewBox=["\x27]0 0 ([\d.]+) ([\d.]+)').firstMatch(svg)!;
    final aspect = double.parse(viewBox[1]!) / double.parse(viewBox[2]!);
    if (!repeated) {
      return SvgPicture.string(
        svg,
        width: math.min(width, aspect * height),
        height: height,
        colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
        fit: BoxFit.contain,
      );
    }
    final tileWidth = aspect * height;
    final count = (width / tileWidth).ceil();
    return SizedBox(
      width: width,
      height: height,
      child: ClipRect(
        child: OverflowBox(
          alignment: Alignment.centerLeft,
          minWidth: count * tileWidth,
          maxWidth: count * tileWidth,
          minHeight: height,
          maxHeight: height,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < count; i++)
                SvgPicture.string(
                  svg,
                  width: tileWidth,
                  height: height,
                  colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 绘制普通线型、花边两侧渐隐线及桌面胶带的叠加渐变，矢量遮罩由 Widget 绘制。
class _DividerPainter extends CustomPainter {
  /// [style] 是已识别样式，[color] 是主题或自定义线色，[level] 为粗细 1～3。
  /// [edgeHeight] 为单饰遮罩高度（非花边为 0），用于计算两侧留白。
  const _DividerPainter(this.style, this.color, this.level, this.edgeHeight);

  /// 已识别预设键，未知键在上层解析时回退。
  final String style;

  /// CSS 或主题解析的线色，不替换多色胶带渐变。
  final Color color;

  /// 粗细等级 1～3，决定逻辑像素尺寸。
  final int level;

  /// 单饰遮罩高度，决定花边两侧呼吸留白。
  final double edgeHeight;

  /// 在借用 [canvas] 的 [size] 内绘图，不访问编辑状态或修改样式。
  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) {
      return;
    }
    final paint = Paint()
      ..color = color
      ..strokeWidth = level.toDouble();
    final y = size.height / 2;
    final width = size.width;
    if (style.startsWith('tape-')) {
      _tape(canvas, size);
    } else if (style.startsWith('edge-') && style != 'edge-vine') {
      final end = math.max(0.0, width / 2 - edgeHeight * 1.75 - 8);
      if (end == 0) {
        return;
      }
      paint.shader = ui.Gradient.linear(Offset.zero, Offset(end, 0), [
        color.withValues(alpha: 0),
        color.withValues(alpha: color.a * .36),
      ]);
      canvas.drawRect(Rect.fromLTWH(0, y - .5, end, 1), paint);
      paint.shader = ui.Gradient.linear(Offset(width - end, 0), Offset(width, 0), [
        color.withValues(alpha: color.a * .36),
        color.withValues(alpha: 0),
      ]);
      canvas.drawRect(Rect.fromLTWH(width - end, y - .5, end, 1), paint);
    } else if (style == 'solid' || style == 'fade') {
      if (style == 'fade') {
        paint.shader = ui.Gradient.linear(
          Offset.zero,
          Offset(width, 0),
          [color.withValues(alpha: 0), color, color, color.withValues(alpha: 0)],
          [0, .18, .82, 1],
        );
      }
      canvas.drawRect(Rect.fromLTWH(0, y - level / 2, width, level.toDouble()), paint);
    } else if (style == 'dashed') {
      for (var x = 0.0; x < width; x += 16) {
        canvas.drawRect(Rect.fromLTWH(x, y - level / 2, math.min(8, width - x), level.toDouble()), paint);
      }
    } else if (style == 'dotted' || style == 'triple-dot') {
      final radius = style == 'triple-dot' ? (level == 3 ? 2.3 : 1.8) : [1.5, 2.0, 3.0][level - 1];
      if (style == 'triple-dot') {
        for (final x in [-11.0, 0.0, 11.0]) {
          canvas.drawCircle(Offset(width / 2 + x, y), radius, paint);
        }
      } else {
        final step = [16.0, 20.0, 24.0][level - 1];
        for (var x = step / 2; x < width; x += step) {
          canvas.drawCircle(Offset(x, y), radius, paint);
        }
      }
    } else if (style == 'double') {
      final total = [3.0, 5.0, 8.0][level - 1];
      final stroke = total / 3;
      canvas.drawRect(Rect.fromLTWH(0, y - total / 2, width, stroke), paint);
      canvas.drawRect(Rect.fromLTWH(0, y + total / 2 - stroke, width, stroke), paint);
    } else if (style == 'diamond') {
      paint.strokeWidth = 1;
      canvas.drawLine(Offset.zero.translate(0, y), Offset(math.max(0, width / 2 - 11), y), paint);
      canvas.drawLine(Offset(math.min(width, width / 2 + 11), y), Offset(width, y), paint);
      final radius = (level == 3 ? 7 : 5) / math.sqrt2;
      final path = Path()
        ..moveTo(width / 2, y - radius)
        ..lineTo(width / 2 + radius, y)
        ..lineTo(width / 2, y + radius)
        ..lineTo(width / 2 - radius, y)
        ..close();
      canvas.drawPath(
        path,
        paint
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2,
      );
    }
  }

  /// 按桌面 CSS 叠加顺序绘制胶带到 [canvas] 的 [size]，并裁成撕边多边形。
  void _tape(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final points = [
      (.01, 0.0),
      (0.0, .12),
      (.01, .26),
      (0.0, .38),
      (.008, .51),
      (0.0, .66),
      (.008, .84),
      (.002, 1.0),
      (.998, 1.0),
      (1.0, .86),
      (.995, .72),
      (1.0, .58),
      (.995, .44),
      (1.0, .28),
      (.995, .14),
      (.998, 0.0),
    ];
    final clip = Path()..moveTo(points.first.$1 * w, points.first.$2 * h);
    for (final point in points.skip(1)) {
      clip.lineTo(point.$1 * w, point.$2 * h);
    }
    clip.close();
    canvas.save();
    canvas.clipPath(clip);
    for (final layer in (dividerTapeLayers[style] ?? const []).reversed) {
      final radians = (layer['angle'] as num).toDouble() * math.pi / 180;
      final direction = Offset(math.sin(radians), -math.cos(radians));
      final extent = w * direction.dx.abs() + h * direction.dy.abs();
      final raw = layer['stops'] as List;
      final pixels = layer['pixels'] == true;
      final positions = <double>[
        for (var i = 0; i < raw.length; i++)
          (raw[i]['position'] as num?)?.toDouble() ?? i / (raw.length - 1) * (pixels ? extent : 100),
      ];
      final span = layer['repeat'] == true ? positions.last : (pixels ? extent : 100.0);
      if (span <= 0) {
        continue;
      }
      final start = Offset(w / 2, h / 2) - direction * (extent / 2);
      final length = pixels ? span : extent;
      final shader = ui.Gradient.linear(
        start,
        start + direction * length,
        [for (final stop in raw) Color(stop['color'] as int)],
        [for (final p in positions) (p / span).clamp(0.0, 1.0)],
        layer['repeat'] == true ? TileMode.repeated : TileMode.clamp,
      );
      canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
    }
    canvas.restore();
  }

  /// [oldDelegate] 的任一视觉输入改变时重绘，不为未变化的选区重绘。
  @override
  bool shouldRepaint(covariant _DividerPainter oldDelegate) =>
      oldDelegate.style != style ||
      oldDelegate.color != color ||
      oldDelegate.level != level ||
      oldDelegate.edgeHeight != edgeHeight;
}
