import 'dart:math' as math;

import 'package:cses_document_collab/src/model/collab_person_card.dart';
import 'package:cses_document_collab/src/model/collab_block_colors.dart';
import 'package:cses_document_collab/src/ui/modal/collab_cached_image.dart';
import 'package:cses_document_collab/src/ui/modal/collab_card_lock_overlay.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// 编辑、预览和设置共用的原生人员卡片；只绘制定格数据，不查询或写入资料。
/// 在块锁作用域内由本体展示固定大小锁标，作用域与权限仍由调用方提供。
/// ```dart
/// import 'package:cses_document_collab/src/model/collab_person_card.dart';
/// import 'package:cses_document_collab/src/ui/modal/collab_person_card_visual.dart';
/// const visual = CollabPersonCardVisual(card: CollabPersonCard({'style': 'row'}));
/// ```
class CollabPersonCardVisual extends StatelessWidget {
  /// [key]控制组件身份；[card]借用只读属性，[alignment]默认左侧居中，预览可指定居中。
  const CollabPersonCardVisual({super.key, required this.card, this.alignment = Alignment.centerLeft});

  /// 定格资料与外观，不由展示组件修改。
  final CollabPersonCard card;

  /// 手机视口中的位置，不影响保存尺寸。
  final AlignmentGeometry alignment;

  /// 在借用[context]内布局，固定框按视口缩小，文字换行并在用户设定的外框内裁剪。
  /// 锁标随缩放后的卡片本体定位，保持14逻辑像素，不随整行可用宽度移动。
  @override
  Widget build(BuildContext context) {
    final props = card.values;
    final person = card.person;
    final scale = card.contentScale.clamp(.01, 100.0);
    final defaults = personCardSize(card.style);

    /// 对[raw]尺寸做只读安全回落，缺省使用[fallback]；不回写旧数据。
    double dimension(Object? raw, double fallback) =>
        raw is num && raw.isFinite && raw > 0 ? raw.toDouble().clamp(1, 100000) : fallback;
    final width = dimension(props['width'], defaults.width * scale);
    final height = dimension(props['height'], defaults.height * scale);
    final color =
        parseCollabBlockColor(props['color'] is String ? props['color'] as String : null) ?? const Color(0xFF1F2329);
    final borderColor = parseCollabBlockColor(props['bc'] is String ? props['bc'] as String : null) ?? color;
    final fonts = card.fonts;
    final name = person?.name ?? '文档创建人';
    final pinyin = person?.pinyin ?? (person == null ? '拼音' : '');
    final desc = card.departmentPosition == 'off' ? '' : person?.description ?? (person == null ? '部门/职务' : '');
    final column = card.style == 'column';
    final avatarSize =
        (column
            ? 56.0
            : card.style == 'rowPinyin'
            ? 40.0
            : 32.0) *
        switch (props['avatarSize']) {
          'small' => .75,
          'large' => 1.25,
          _ => 1.0,
        };
    final fallback = ColoredBox(
      color: color.withValues(alpha: .08),
      child: Icon(LucideIcons.userRound, size: avatarSize * .6, color: color),
    );
    final url = person?.avatar;
    final uri = url == null ? null : Uri.tryParse(url);
    final avatar = SizedBox(
      width: avatarSize,
      height: avatarSize,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(avatarSize * (props['avatar'] == 'rounded' ? .22 : .5)),
        child: uri != null && const {'http', 'https'}.contains(uri.scheme) && uri.host.isNotEmpty
            ? CollabCachedImage(url: url!, loading: fallback, failure: fallback, fit: BoxFit.cover)
            : fallback,
      ),
    );

    /// 将[value]以设计[size]展示，[weight]默认普通；系统字号不改变固定对象几何。
    Widget text(String value, double size, {FontWeight weight = FontWeight.normal}) => Text(
      value,
      textScaler: TextScaler.noScaling,
      textAlign: column ? TextAlign.center : TextAlign.left,
      style: TextStyle(fontSize: size.clamp(1, 512), height: 1.4, color: color, fontWeight: weight),
    );
    final identity = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: column ? CrossAxisAlignment.center : CrossAxisAlignment.start,
      children: [
        text(name, fonts.first, weight: FontWeight.w600),
        if (card.style == 'rowPinyin' && pinyin.isNotEmpty) text(pinyin, fonts[1]),
      ],
    );
    final description = text(desc, fonts.last);
    final content = LayoutBuilder(
      builder: (_, constraints) {
        final right = card.departmentPosition == 'right' && desc.isNotEmpty;
        final nameWidth = math.min(constraints.maxWidth, math.max(50.0, name.runes.length * fonts.first));
        final group = right
            ? Wrap(
                spacing: 8,
                runSpacing: 2,
                crossAxisAlignment: WrapCrossAlignment.center,
                alignment: column ? WrapAlignment.center : WrapAlignment.start,
                children: [
                  SizedBox(width: nameWidth, child: identity),
                  ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: constraints.maxWidth),
                    child: description,
                  ),
                ],
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: column ? CrossAxisAlignment.center : CrossAxisAlignment.start,
                children: [
                  if (desc.isNotEmpty && card.departmentPosition == 'above') description,
                  identity,
                  if (desc.isNotEmpty && card.departmentPosition != 'above') description,
                ],
              );
        return group;
      },
    );
    final design = SizedBox(
      width: width / scale,
      height: height / scale,
      child: CustomPaint(
        foregroundPainter: _PersonBorder(
          color: borderColor,
          look: props['bw'] is String ? props['bw'] as String : '',
          radius: 6,
        ),
        child: ClipRect(
          child: SingleChildScrollView(
            physics: const NeverScrollableScrollPhysics(),
            padding: const EdgeInsets.all(4),
            child: LayoutBuilder(
              builder: (_, constraints) => column || constraints.maxWidth < avatarSize + 24
                  ? Column(mainAxisSize: MainAxisSize.min, children: [avatar, const SizedBox(height: 6), content])
                  : Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        avatar,
                        const SizedBox(width: 8),
                        Expanded(child: content),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
    return LayoutBuilder(
      builder: (_, constraints) {
        final fit = math.min(
          1.0,
          math.min(
            constraints.maxWidth.isFinite ? constraints.maxWidth / width : 1,
            constraints.maxHeight.isFinite ? constraints.maxHeight / height : 1,
          ),
        );
        return Align(
          alignment: alignment,
          widthFactor: 1,
          heightFactor: 1,
          child: CollabCardLockOverlay(
            child: SizedBox(
              key: const ValueKey('collab-person-card-surface'),
              width: width * fit,
              height: height * fit,
              child: FittedBox(fit: BoxFit.fill, child: design),
            ),
          ),
        );
      },
    );
  }
}

/// 桌面CSS边框的无资源绘制器；虚线、点线及双线保留独立外观。
class _PersonBorder extends CustomPainter {
  /// [color]为线色，[look]为CSS宽度和线型，[radius]为逻辑像素圆角。
  const _PersonBorder({required this.color, required this.look, required this.radius});

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
  bool shouldRepaint(covariant _PersonBorder oldDelegate) =>
      oldDelegate.color != color || oldDelegate.look != look || oldDelegate.radius != radius;
}
