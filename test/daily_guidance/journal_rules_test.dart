import 'package:cses_mobile_collab_demo/src/daily_guidance/journal_ruled_content.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 验证实际文字换行的横格与装饰空白不抢占正文或滚动手势。
void main() {
  testWidgets('lines follow real wrapped text and scale with its layout', (
    tester,
  ) async {
    for (final scale in [1.0, 2.0]) {
      final text = Text(
        'A line that wraps onto several more lines in the same paragraph.',
        textScaler: TextScaler.linear(scale),
        textHeightBehavior: const TextHeightBehavior(
          applyHeightToFirstAscent: true,
          applyHeightToLastDescent: true,
        ),
        style: const TextStyle(fontSize: 16, height: 2),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(width: 240, child: JournalRuledContent(child: text)),
          ),
        ),
      );
      await tester.pump();
      final rules = tester.renderObject<RenderJournalRules>(
        find.byType(JournalRuledContent),
      );
      expect(rules.debugLineOffsets.length, greaterThan(1));
      final lines = rules.debugLineOffsets;
      for (var i = 1; i < lines.length; i++) {
        expect(lines[i] - lines[i - 1], closeTo(32 * scale, .1));
      }
    }
  });

  testWidgets(
    'only a tap in extra blank space focuses; text taps and drags do not',
    (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 240,
                child: JournalRuledContent(
                  minimumHeight: 96,
                  textLines: false,
                  onBlankTap: () => taps++,
                  child: const SizedBox(height: 32, child: Text('正文')),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('正文'));
      expect(taps, 0);
      await tester.tapAt(const Offset(40, 70));
      expect(taps, 1);
      await tester.dragFrom(const Offset(40, 70), const Offset(0, -40));
      expect(taps, 1);
      final rules = tester.renderObject<RenderJournalRules>(
        find.byType(JournalRuledContent),
      );
      expect(rules.debugLineOffsets, [64, 96]);
    },
  );
}
