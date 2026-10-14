import 'package:cses_document_collab/src/editor/collab_text_alignment.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final text in [
    '中文分散对齐',
    'English text',
    'A longer English paragraph with spaces and several lines of text.',
    '第一行\n末行',
    '中文与emoji😀混合，较长的一段正文需要换行验证末行分散对齐。',
  ]) {
    testWidgets('distributed layout fills every line without changing $text', (
      tester,
    ) async {
      final source = TextSpan(
        style: const TextStyle(fontSize: 16),
        children: [TextSpan(text: text)],
      );
      const width = 240.0;
      final natural = TextPainter(
        text: source,
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: width);
      final distributed = distributeTextSpan(
        source,
        width: width,
        direction: TextDirection.ltr,
      );
      expect(distributed.toPlainText(), text);
      final painter = TextPainter(
        text: distributed,
        textAlign: TextAlign.justify,
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: width);
      final lines = painter.computeLineMetrics();
      expect(lines.length, natural.computeLineMetrics().length);
      for (final line in lines) {
        expect(line.width, closeTo(width, 1));
      }
      // 实际绘制布局与命中/光标使用同一套偏移，不向正文补空格。
      for (var offset = 0; offset < text.length; offset++) {
        final caret = painter.getOffsetForCaret(
          TextPosition(offset: offset),
          Rect.zero,
        );
        expect(caret.dx.isFinite, isTrue);
      }
      painter.dispose();
      natural.dispose();
    });
  }
  testWidgets('distributed text preserves mixed styles when scaled', (
    tester,
  ) async {
    const source = TextSpan(
      style: TextStyle(fontSize: 16),
      children: [
        TextSpan(
          text: '加粗',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        TextSpan(
          text: '红色与普通文字',
          style: TextStyle(color: Colors.red),
        ),
      ],
    );
    final span = distributeTextSpan(
      source,
      width: 320,
      direction: TextDirection.ltr,
      scaler: const TextScaler.linear(1.5),
    );
    final leaves = <TextSpan>[];
    span.visitChildren((child) {
      if (child is TextSpan && child.text?.isNotEmpty == true) {
        leaves.add(child);
      }
      return true;
    });
    expect(leaves.first.style!.fontWeight, FontWeight.bold);
    expect(leaves.last.style!.color, Colors.red);
    final painter = TextPainter(
      text: span,
      textDirection: TextDirection.ltr,
      textScaler: const TextScaler.linear(1.5),
    )..layout(maxWidth: 320);
    expect(painter.computeLineMetrics().single.width, closeTo(320, 1));
    expect(span.toPlainText(), source.toPlainText());
    painter.dispose();
  });

  testWidgets('empty and single character lines stay natural', (tester) async {
    for (final text in ['', '字', '\n', '字\n']) {
      final source = TextSpan(text: text, style: const TextStyle(fontSize: 16));
      expect(
        distributeTextSpan(
          source,
          width: 240,
          direction: TextDirection.ltr,
        ).toPlainText(),
        text,
      );
    }
  });
}
