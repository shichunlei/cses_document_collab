import 'dart:async';

import 'package:cses_document_collab/src/editor/collab_color_picker.dart';
import 'package:cses_document_collab/src/editor/collab_emoji_picker.dart';
import 'package:cses_document_collab/src/model/collab_block_colors.dart';
import 'package:cses_document_collab/src/model/collab_color_palette.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 验证共用选择器的协议边界、只读回显、保存生命周期及原生Unicode完整性。
void main() {
  test(
    'CSS and ARGB compare by channel while unknown values remain distinct',
    () {
      expect(sameCollabColor('#12345680', '0x80123456'), isTrue);
      expect(sameCollabColor('rgba(18, 52, 86, .3)', '0x4d123456'), isTrue);
      expect(sameCollabColor('#abc', 'rgb(170, 187, 204)'), isTrue);
      expect(sameCollabColor('var(--custom-color)', null), isFalse);
      expect(
        sameCollabColor('var(--custom-color)', 'var(--other-color)'),
        isFalse,
      );
      expect(sameCollabColor(null, 'transparent'), isFalse);
      expect(collabColorToEditor('#12345680'), '0x80123456');
      expect(collabColorToEditor('var(--custom-color)'), 'var(--custom-color)');
      expect(collabColorToEditor(null), isNull);
    },
  );

  test(
    'mixed selection is separate from default and keeps uniform raw values',
    () {
      final uniform = CollabColorSelection.fromValues([
        'rgb(18, 52, 86)',
        '#123456',
      ]);
      expect(uniform.isMixed, isFalse);
      expect(uniform.value, 'rgb(18, 52, 86)');
      expect(
        CollabColorSelection.fromValues([null, '#123456']).isMixed,
        isTrue,
      );
      expect(CollabColorSelection.fromValues([null, null]).isMixed, isFalse);
      expect(
        CollabColorSelection.fromValues(['var(--custom-color)', null]).isMixed,
        isTrue,
      );
    },
  );

  testWidgets(
    'text, background and border select desktop colors without migrating custom values',
    (tester) async {
      final selected = <String, String?>{};
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                for (final id in ['text', 'background', 'border'])
                  CollabColorPicker(
                    keyPrefix: id,
                    textColors: id == 'text',
                    selection: const CollabColorSelection('#12345680'),
                    onSelected: (value) async {
                      selected[id] = value;
                    },
                  ),
              ],
            ),
          ),
        ),
      );
      expect(selected, isEmpty);
      for (final id in ['text', 'background', 'border']) {
        expect(find.byKey(ValueKey('$id-custom')), findsOneWidget);
        await tester.tap(find.byKey(ValueKey('$id-blue')));
        await tester.pumpAndSettle();
      }
      expect(selected, {
        'text': '#0B6E99',
        'background': '#DDEBF1',
        'border': '#DDEBF1',
      });
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'unknown CSS stays selected and opening or reselecting it never writes',
    (tester) async {
      var writes = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CollabColorPicker(
              keyPrefix: 'custom',
              selection: const CollabColorSelection('var(--project-accent)'),
              onSelected: (_) async {
                writes++;
              },
            ),
          ),
        ),
      );
      final custom = find.byKey(const ValueKey('custom-custom'));
      expect(
        tester.getSemantics(custom).flagsCollection.isSelected.toString(),
        contains('isTrue'),
      );
      await tester.tap(custom);
      await tester.pumpAndSettle();
      expect(writes, 0);
      await tester.tap(find.byKey(const ValueKey('custom-default')));
      await tester.pumpAndSettle();
      expect(writes, 1);
    },
  );

  testWidgets('mixed range does not select reset or a preset', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CollabColorPicker(
            keyPrefix: 'mixed',
            selection: const CollabColorSelection.mixed(),
            onSelected: (_) async {},
          ),
        ),
      ),
    );
    for (final id in [
      'default',
      ...collabColorPalette.map((option) => option.id),
    ]) {
      expect(
        tester
            .getSemantics(find.byKey(ValueKey('mixed-$id')))
            .flagsCollection
            .isSelected
            .toString(),
        contains('isFalse'),
      );
    }
    expect(find.byKey(const ValueKey('mixed-custom')), findsNothing);
  });

  testWidgets(
    'picker prevents concurrent writes and completion after disposal is safe',
    (tester) async {
      final pending = Completer<void>();
      var writes = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CollabColorPicker(
              keyPrefix: 'busy',
              selection: const CollabColorSelection(null),
              onSelected: (_) async {
                writes++;
                await pending.future;
              },
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('busy-blue')));
      await tester.pump();
      final button = tester.widget<IconButton>(
        find.descendant(
          of: find.byKey(const ValueKey('busy-red')),
          matching: find.byType(IconButton),
        ),
      );
      expect(button.onPressed, isNull);
      expect(writes, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      pending.complete();
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('failed color writes are visible and can be retried', (
    tester,
  ) async {
    var writes = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CollabColorPicker(
            keyPrefix: 'retry',
            selection: const CollabColorSelection(null),
            onSelected: (_) async {
              if (++writes == 1) throw StateError('offline');
            },
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('retry-blue')));
    await tester.pumpAndSettle();
    expect(find.text('颜色设置失败，请重试'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('retry-blue')));
    await tester.pump();
    expect(writes, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'emoji search and paste preserve a full skin tone and ZWJ sequence',
    (tester) async {
      final values = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: CollabEmojiPicker(
                keyPrefix: 'emoji',
                current: '👨‍👩‍👧‍👦',
                onSelected: (value) async {
                  values.add(value);
                },
              ),
            ),
          ),
        ),
      );
      expect(values, isEmpty);
      expect(find.byKey(const ValueKey('emoji-👨‍👩‍👧‍👦')), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('emoji-search')), '火箭');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('emoji-🚀')));
      await tester.pumpAndSettle();
      expect(values, ['🚀']);
      await tester.enterText(
        find.byKey(const ValueKey('emoji-search')),
        '👩🏽‍💻',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('emoji-apply')));
      await tester.pumpAndSettle();
      expect(values.last, '👩🏽‍💻');
      expect(values.last.characters.length, 1);
    },
  );

  testWidgets('emoji categories and read-only state share the same control', (
    tester,
  ) async {
    var writes = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: CollabEmojiPicker(
              keyPrefix: 'emoji',
              enabled: false,
              onSelected: (_) async {
                writes++;
              },
            ),
          ),
        ),
      ),
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('emoji-search')))
          .enabled,
      isFalse,
    );
    final tabBar = find.byKey(const ValueKey('emoji-categories'));
    expect(
      tester
          .widget<IgnorePointer>(
            find
                .ancestor(of: tabBar, matching: find.byType(IgnorePointer))
                .first,
          )
          .ignoring,
      isTrue,
    );
    expect(writes, 0);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: CollabEmojiPicker(
              keyPrefix: 'emoji',
              onSelected: (_) async {
                writes++;
              },
            ),
          ),
        ),
      ),
    );
    final nature = find.byKey(const ValueKey('emoji-category-nature'));
    await tester.ensureVisible(nature);
    await tester.tap(nature);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('emoji-search')), '幼苗');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('emoji-🌱')), findsOneWidget);
    expect(writes, 0);
  });

  test('custom RGBA stays intact and fill values are fully opaque', () {
    final original = 'rgba(16, 32, 48, .125)';
    final selected = CollabColorSelection.fromValues([original]);
    expect(selected.value, original);
    expect(parseCollabBlockColor(selected.value)!.a, .125);
    expect(parseCollabBlockColor(collabColorPalette.first.fill)!.a, 1);
  });
}
