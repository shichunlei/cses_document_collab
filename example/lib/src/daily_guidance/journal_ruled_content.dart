import 'dart:math' as math;
import 'dart:ui' show BoxHeightStyle;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// 在实际文字布局下绘制横格的装饰，不参与输入、选区、复制或文档数据。
///
/// ```dart
/// import 'package:flutter/material.dart';
/// import 'package:cses_mobile_collab_demo/src/daily_guidance/journal_ruled_content.dart';
/// const paper = JournalRuledContent(child: Text('记录今天', style: TextStyle(height: 2)));
/// ```
class JournalRuledContent extends SingleChildRenderObjectWidget {
  /// [key]控制身份，[child]为借用的正文组件。
  /// [lineHeight]为补齐空白横格的逻辑像素间距，默认32；须为正有限值。
  /// [minimumHeight]为空白书写区最小逻辑高度，默认0；须非负且有限。
  /// [textLines]默认true，按子树最宽文字组件的实际行框绘制；false只补齐底部空白。
  /// [onBlankTap]只在正文下方的补齐留白收到点击，不拦截正文的光标和选区操作。
  const JournalRuledContent({
    super.key,
    required super.child,
    this.lineHeight = 32,
    this.minimumHeight = 0,
    this.textLines = true,
    this.onBlankTap,
  });

  /// 补齐装饰空行的实际行高，调用方随文字缩放更新。
  final double lineHeight;

  /// 栏目最小书写高度，不生成空段落或换行。
  final double minimumHeight;

  /// 是否绘制实际文字行；栏目外层只负责底部补行。
  final bool textLines;

  /// 空白书写区域点击回调，null时不处理该区域的指针事件。
  final VoidCallback? onBlankTap;

  /// 使用[context]创建不接管命中测试的横格绘制对象。
  @override
  RenderJournalRules createRenderObject(BuildContext context) =>
      RenderJournalRules(
        lineHeight: lineHeight,
        minimumHeight: minimumHeight,
        textLines: textLines,
        onBlankTap: onBlankTap,
      );

  /// 在[context]的配置变化后更新借用的[renderObject]并重新布局。
  @override
  void updateRenderObject(
    BuildContext context,
    RenderJournalRules renderObject,
  ) => renderObject.configure(
    lineHeight: lineHeight,
    minimumHeight: minimumHeight,
    textLines: textLines,
    onBlankTap: onBlankTap,
  );
}

/// 横格的局部绘制对象；扫描当前文字布局，不缓存跨字体或跨宽度的行框。
///
/// ```dart
/// import 'package:cses_mobile_collab_demo/src/daily_guidance/journal_ruled_content.dart';
/// final rules = RenderJournalRules(lineHeight: 32, minimumHeight: 96, textLines: true);
/// // 通常交由JournalRuledContent创建及管理挂载生命周期。
/// ```
class RenderJournalRules extends RenderProxyBox {
  /// [lineHeight]为空行间距，[minimumHeight]为书写区最小高度，[textLines]决定是否绘制文字行。
  /// [onBlankTap]仅处理补齐留白的点击，null禁用。
  RenderJournalRules({
    required double lineHeight,
    required double minimumHeight,
    required bool textLines,
    VoidCallback? onBlankTap,
  }) {
    configure(
      lineHeight: lineHeight,
      minimumHeight: minimumHeight,
      textLines: textLines,
      onBlankTap: onBlankTap,
    );
  }

  double _lineHeight = 32;
  double _minimumHeight = 0;
  bool _textLines = true;
  VoidCallback? _onBlankTap;

  /// 单次留白点击的起点；移动超过阈值或取消后失效，滚动不触发键盘。
  Offset? _blankDown;
  int? _blankPointer;

  /// 最近一次绘制使用的局部纵坐标，仅供布局回归检查，返回不可变快照。
  @visibleForTesting
  List<double> get debugLineOffsets => List.unmodifiable(_lines);
  final List<double> _lines = [];

  /// 更新[lineHeight]、[minimumHeight]、[textLines]及留白回调[onBlankTap]；非法尺寸抛ArgumentError。
  void configure({
    required double lineHeight,
    required double minimumHeight,
    required bool textLines,
    VoidCallback? onBlankTap,
  }) {
    if (!lineHeight.isFinite ||
        lineHeight <= 0 ||
        !minimumHeight.isFinite ||
        minimumHeight < 0) {
      throw ArgumentError('行线尺寸无效');
    }
    _lineHeight = lineHeight;
    _minimumHeight = minimumHeight;
    _textLines = textLines;
    _onBlankTap = onBlankTap;
    markNeedsLayout();
  }

  /// 只让正文下方的空白[position]成为命中对象，不抢占实际正文的选区手势。
  @override
  bool hitTestSelf(Offset position) =>
      _onBlankTap != null && position.dy >= (child?.size.height ?? 0);

  /// [entry]是本对象的命中结果；[event]未发生明显移动且仍在留白内抬起时请求聚焦。
  @override
  void handleEvent(PointerEvent event, BoxHitTestEntry entry) {
    if (event is PointerDownEvent) {
      _blankPointer = event.pointer;
      _blankDown = event.localPosition;
    } else if (event.pointer == _blankPointer) {
      if (event is PointerMoveEvent &&
          _blankDown != null &&
          (event.localPosition - _blankDown!).distance > 12) {
        _blankDown = null;
      }
      if (event is PointerUpEvent || event is PointerCancelEvent) {
        final tap =
            event is PointerUpEvent &&
            _blankDown != null &&
            event.localPosition.dy >= (child?.size.height ?? 0);
        _blankPointer = null;
        _blankDown = null;
        if (tap) _onBlankTap?.call();
      }
    }
  }

  /// 用松弛最小高度排版子内容，再补齐书写留白；保持实际正文宽度。
  @override
  void performLayout() {
    child?.layout(constraints.copyWith(minHeight: 0), parentUsesSize: true);
    size = constraints.constrain(
      Size(
        child?.size.width ?? 0,
        math.max(child?.size.height ?? 0, _minimumHeight),
      ),
    );
  }

  /// 在[context]的[offset]位置先绘制横格再绘制正文，线条不覆盖文字或选区。
  @override
  void paint(PaintingContext context, Offset offset) {
    _lines.clear();
    if (_textLines) {
      RenderParagraph? text;

      /// 查找[object]子树中最宽的文字区域，排除列表符号等窄小前缀。
      void visit(RenderObject object) {
        if (object is RenderParagraph &&
            object.hasSize &&
            (text == null || object.size.width > text!.size.width)) {
          text = object;
        }
        object.visitChildren(visit);
      }

      child?.visitChildren(visit);
      if (child case final RenderParagraph paragraph) visit(paragraph);
      if (text case final paragraph?) {
        final top = paragraph.localToGlobal(Offset.zero, ancestor: this).dy;
        final boxes = paragraph.getBoxesForSelection(
          TextSelection(
            baseOffset: 0,
            extentOffset: paragraph.text.toPlainText().length,
          ),
          boxHeightStyle: BoxHeightStyle.max,
        );
        for (final box in boxes) {
          final y = top + box.bottom;
          if (y > 0 &&
              y <= size.height + .5 &&
              !_lines.any((line) => (line - y).abs() < .5)) {
            _lines.add(y);
          }
        }
        if (_lines.isEmpty) _lines.add(top + paragraph.size.height);
        // 选择框不包含尾部空行，使用同一RenderParagraph的光标布局补齐，避免另建文字排版。
        final plain = paragraph.text.toPlainText();
        if (plain.endsWith('\n')) {
          final position = TextPosition(offset: plain.length);
          final y =
              top +
              paragraph.getOffsetForCaret(position, Rect.zero).dy +
              paragraph.getFullHeightForCaret(position);
          if (y > 0 &&
              y <= size.height + .5 &&
              !_lines.any((line) => (line - y).abs() < .5)) {
            _lines.add(y);
          }
        }
        _lines.sort();
      }
    }
    final contentHeight = child?.size.height ?? 0;
    for (
      var y = contentHeight + _lineHeight;
      y <= size.height + .5;
      y += _lineHeight
    ) {
      _lines.add(y);
    }
    final pen = Paint()
      ..color = const Color(0xffe5ddcf)
      ..strokeWidth = .75;
    for (final y in _lines) {
      context.canvas.drawLine(
        offset + Offset(0, y - .5),
        offset + Offset(size.width, y - .5),
        pen,
      );
    }
    super.paint(context, offset);
  }
}
