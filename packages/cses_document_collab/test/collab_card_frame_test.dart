import 'package:cses_document_collab/src/editor/collab_card_frame.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 验证窄屏大字标题不覆盖操作、只读移除占位和音频使用标准标题栏。
void main() {
  testWidgets(
    'readonly removes more and releases title width without hiding content',
    (tester) async {
      final readonly = ValueNotifier(false);
      addTearDown(readonly.dispose);
      var actions = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(fontFamily: 'CardFamily'),
          home: Scaffold(
            body: SizedBox(
              width: 320,
              child: ValueListenableBuilder(
                valueListenable: readonly,
                builder: (context, value, _) => CollabCardFrame(
                  header: CollabCardHeader(
                    leading: const Icon(Icons.language),
                    title: const Text(
                      '这是一个用于验证剩余宽度的很长的网页标题',
                      key: ValueKey('title'),
                    ),
                    subtitle: 'https://example.com/path/to/document',
                    readOnly: value,
                    more: IconButton(
                      key: const ValueKey('more'),
                      onPressed: () {
                        actions++;
                      },
                      icon: const Icon(Icons.more_horiz),
                    ),
                  ),
                  child: const Text('网页内容'),
                ),
              ),
            ),
          ),
        ),
      );
      expect(
        DefaultTextStyle.of(
          tester.element(find.byKey(const ValueKey('title'))),
        ).style.fontFamily,
        'CardFamily',
      );
      final width = tester.getSize(find.byKey(const ValueKey('title'))).width;
      await tester.tap(find.byKey(const ValueKey('more')));
      expect(actions, 1);
      readonly.value = true;
      await tester.pump();
      expect(find.byKey(const ValueKey('more')), findsNothing);
      expect(
        tester.getSize(find.byKey(const ValueKey('title'))).width,
        greaterThan(width),
      );
      expect(find.text('网页内容'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'long titles keep independent action targets at narrow width and large text',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(2)),
              child: SizedBox(
                width: 260,
                child: CollabCardFrame(
                  header: CollabCardHeader(
                    leading: const Icon(Icons.account_tree_outlined),
                    title: const Text('这是一个非常长的代码绘图标题以及补充内容'),
                    subtitle: 'https://example.com/very/long/path/long-path',
                    actions: [
                      IconButton(
                        key: const ValueKey('view'),
                        onPressed: () {},
                        icon: const Icon(Icons.swap_horiz),
                      ),
                    ],
                    more: IconButton(
                      key: const ValueKey('more'),
                      onPressed: () {},
                      icon: const Icon(Icons.more_horiz),
                    ),
                  ),
                  child: const Text('原内容'),
                ),
              ),
            ),
          ),
        ),
      );
      final view = tester.getRect(find.byKey(const ValueKey('view')));
      final more = tester.getRect(find.byKey(const ValueKey('more')));
      expect(view.overlaps(more), isFalse);
      expect(more.width, greaterThanOrEqualTo(44));
      expect(more.height, greaterThanOrEqualTo(44));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'audio shares the standard divided header and separate player body',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CollabCardFrame(
              header: CollabCardHeader(
                key: const ValueKey('audio-header'),
                leading: const Icon(Icons.audiotrack_outlined),
                title: const Text('录音.mp3'),
                more: IconButton(
                  key: const ValueKey('more'),
                  onPressed: () {},
                  icon: const Icon(Icons.more_horiz),
                ),
              ),
              child: const Text('播放器'),
            ),
          ),
        ),
      );
      expect(find.byType(Divider), findsOneWidget);
      expect(
        tester.getSize(find.byKey(const ValueKey('more'))),
        const Size(44, 44),
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('audio-header'))).height,
        lessThan(64),
      );
      expect(find.text('播放器'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
