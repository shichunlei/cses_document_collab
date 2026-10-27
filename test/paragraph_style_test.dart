import 'package:cses_document_collab/src/editor/collab_paragraph_text_style.dart';
import 'dart:convert';
import 'dart:io';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/editor/collab_paragraph_editing.dart';
import 'package:cses_document_collab/src/model/collab_paragraph_style.dart';
import 'package:cses_document_collab/src/model/collab_resource.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 对照发布版函数输出验证段落默认格式、回车、输入历史及0.11.21远端默认值更新。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final oracle =
      jsonDecode(
            File(
              'test/fixtures/blockcraft-0.11.20-paragraph.json',
            ).readAsStringSync(),
          )
          as Map;
  test('published normalization including every font family', () {
    for (final sample in oracle['normalization'] as List) {
      expect(
        normalizeParagraphTextDefaults(sample['input']),
        sample['expected'],
        reason: '${sample['input']}',
      );
    }
  });
  for (final sample in oracle['next'] as List) {
    final flavour = sample['flavour'] as String;
    final props = Map<String, dynamic>.from(sample['props'] as Map);
    final atEnd = sample['atEnd'] as bool;
    final expected = sample['expected'] as Map;
    final type = switch (flavour) {
      'bullet' => 'bulleted_list',
      'ordered' => 'numbered_list',
      'todo' => 'todo_list',
      'blockquote' => 'quote',
      _ => props['heading'] == 2 ? 'heading_2' : 'paragraph',
    };
    test(
      'published Enter $flavour heading=${props['heading']} next=${props['nextParagraphStyle']} end=$atEnd',
      () async {
        final adapter = _adapter(text: 'ab', type: type, props: props);
        addTearDown(adapter.dispose);
        final state = adapter.editorState;
        state.selection = Selection.single(
          path: [0],
          startOffset: atEnd ? 2 : 1,
        );
        expect(await handleCollabParagraphEnter(state), isTrue);
        final next = adapter.blocks.last;
        expect(
          next.blockType,
          expected['flavour'] == 'paragraph'
              ? (expected['props']['heading'] == 2 ? 'heading_2' : 'paragraph')
              : type,
        );
        expect(
          next.alignment,
          expected['continueTextFormat'] == true ? 'center' : 'left',
        );
        expect(
          next.paragraphStyle?.values['nextParagraphStyle'],
          expected['props']['nextParagraphStyle'],
        );
        expect(next.checked, isFalse);
        expect(next.text, atEnd ? '' : 'b');
        expect(
          next.paragraphStyle?.values['textDefaults'],
          expected['continueTextFormat'] == true ? {'a:bold': true} : null,
        );
        expect(
          state.toggledStyle[AppFlowyRichTextKeys.bold],
          expected['continueTextFormat'] == true ? true : null,
        );
      },
    );
  }
  test(
    'empty color defaults use desktop CSS and retain editor alpha after reopen',
    () async {
      final adapter = _adapter();
      addTearDown(adapter.dispose);
      final state = adapter.editorState;
      state.selection = Selection.single(path: [0], startOffset: 0);
      await setCollabTypingAttributes(state, {
        AppFlowyRichTextKeys.textColor: '0xff123456',
        AppFlowyRichTextKeys.backgroundColor: '0x4dffc107',
      });
      final defaults =
          adapter.blocks.single.paragraphStyle!.values['textDefaults'] as Map;
      expect(defaults['s:color'], '#123456');
      expect(defaults['s:background'], 'rgba(255, 193, 7, ${77 / 255})');
      state.selection = null;
      state.selection = Selection.single(path: [0], startOffset: 0);
      expect(state.toggledStyle[AppFlowyRichTextKeys.textColor], '0xff123456');
      expect(
        state.toggledStyle[AppFlowyRichTextKeys.backgroundColor],
        '0x4dffc107',
      );
    },
  );
  for (final type in ['paragraph', 'heading_2', 'quote', 'bulleted_list']) {
    for (final replace in [false, true]) {
      test(
        'remote empty defaults $type replace=$replace refresh typing',
        () async {
          final adapter = _adapter(
            type: type,
            props: {
              'textDefaults': {
                'a:bold': true,
                's:color': '#123456',
                't:px': 24,
                't:ff': 'courier',
                't:ls': .1,
              },
            },
          );
          addTearDown(adapter.dispose);
          final state = adapter.editorState;
          final selection = Selection.single(path: [0], startOffset: 0);
          state.selection = selection;
          expect(state.toggledStyle[AppFlowyRichTextKeys.bold], isTrue);
          final published = <List<CollabEditorBlock>>[];
          final subscription = state.transactionStream.listen((event) {
            if (event.$1 == TransactionTime.after) {
              published.add(adapter.blocks);
            }
          });
          addTearDown(subscription.cancel);
          await adapter.replaceFromRemote([
            CollabEditorBlock(
              id: 'p',
              blockType: type,
              text: '',
              paragraphStyle: replace
                  ? CollabResource.fromValues({
                      'textDefaults': {'a:italic': true, 't:fs': 1.5},
                    })
                  : null,
            ),
          ]);
          expect(state.selection, selection);
          expect(published, isEmpty);
          for (final key in [
            AppFlowyRichTextKeys.bold,
            AppFlowyRichTextKeys.textColor,
            't:px',
            't:ff',
            't:ls',
          ]) {
            expect(state.toggledStyle[key], isNull, reason: key);
          }
          expect(
            state.toggledStyle[AppFlowyRichTextKeys.italic],
            replace ? isTrue : isNull,
          );
          await state.apply(
            state.transaction
              ..insertText(
                state.document.first!,
                0,
                '字',
                toggledAttributes: state.toggledStyle,
              )
              ..afterSelection = Selection.single(path: [0], startOffset: 1),
          );
          final segments = adapter.blocks.single.segments;
          if (replace) {
            expect(segments.single.bold, isFalse);
            expect(segments.single.italic, isTrue);
            expect(jsonDecode(segments.single.typography!), {'t:fs': 1.5});
          } else {
            expect(segments, isEmpty);
          }
          state.undoManager.undo();
          await Future<void>.delayed(Duration.zero);
          expect(adapter.blocks.single.text, isEmpty);
          expect(state.toggledStyle[AppFlowyRichTextKeys.bold], isNull);
        },
      );
    }
  }
  test(
    'empty defaults persist in a field transaction and restore on navigation and undo',
    () async {
      final adapter = _adapter();
      addTearDown(adapter.dispose);
      final state = adapter.editorState;
      state.selection = Selection.single(path: [0], startOffset: 0);
      await setCollabTypingAttributes(state, {
        AppFlowyRichTextKeys.bold: true,
        AppFlowyRichTextKeys.href: 'https://excluded.test',
      });
      expect(adapter.blocks.single.paragraphStyle!.values['textDefaults'], {
        'a:bold': true,
      });
      state.selection = null;
      state.selection = Selection.single(path: [0], startOffset: 0);
      expect(state.toggledStyle[AppFlowyRichTextKeys.bold], isTrue);
      expect(state.toggledStyle[AppFlowyRichTextKeys.href], isNull);
      state.undoManager.undo();
      await Future<void>.delayed(Duration.zero);
      expect(state.toggledStyle[AppFlowyRichTextKeys.bold], isNull);
      expect(
        normalizeParagraphTextDefaults(
          adapter.blocks.single.paragraphStyle?.values['textDefaults'],
        ),
        isEmpty,
      );
      state.undoManager.redo();
      await Future<void>.delayed(Duration.zero);
      expect(adapter.blocks.single.paragraphStyle!.values['textDefaults'], {
        'a:bold': true,
      });
      final reopened = AppFlowyBlockEditorAdapter(
        initialBlocks: adapter.blocks,
        onLocalBlocksChanged: (_) {},
      );
      addTearDown(reopened.dispose);
      reopened.editorState.selection = Selection.single(
        path: [0],
        startOffset: 0,
      );
      expect(
        reopened.editorState.toggledStyle[AppFlowyRichTextKeys.bold],
        isTrue,
      );
    },
  );
  for (final empty in [false, true]) {
    test(
      'explicit local input survives remote defaults empty=$empty until navigation',
      () async {
        final adapter = _adapter(text: empty ? '' : 'ab');
        addTearDown(adapter.dispose);
        final state = adapter.editorState;
        final offset = empty ? 0 : 1;
        state.selection = Selection.single(path: [0], startOffset: offset);
        await setCollabTypingAttributes(state, {
          AppFlowyRichTextKeys.bold: null,
          AppFlowyRichTextKeys.italic: true,
          't:px': 18,
        });
        final local = adapter.blocks.single;
        await adapter.replaceFromRemote([
          CollabEditorBlock(
            id: 'p',
            blockType: 'paragraph',
            text: local.text,
            segments: local.segments,
            paragraphStyle: CollabResource.fromValues({
              'fs': 22,
              'textDefaults': {'a:bold': true, 't:px': 30},
            }),
          ),
        ]);
        expect(state.toggledStyle[AppFlowyRichTextKeys.bold], isNull);
        expect(state.toggledStyle[AppFlowyRichTextKeys.italic], isTrue);
        expect(state.toggledStyle['t:px'], 18);
        await state.apply(
          state.transaction
            ..insertText(
              state.document.first!,
              offset,
              '字',
              toggledAttributes: state.toggledStyle,
            )
            ..afterSelection = Selection.single(
              path: [0],
              startOffset: offset + 1,
            ),
        );
        expect(
          adapter.blocks.single.segments
              .firstWhere((run) => run.text == '字')
              .italic,
          isTrue,
        );
        expect(
          adapter.blocks.single.segments
              .firstWhere((run) => run.text == '字')
              .bold,
          isFalse,
        );
        state.selection = null;
        state.selection = Selection.single(path: [0], startOffset: 0);
        expect(
          state.toggledStyle[AppFlowyRichTextKeys.bold],
          empty ? isNull : isTrue,
        );
      },
    );
  }
  test(
    'whole paragraph format updates marker, partial format does not, clearing text retains last input appearance',
    () async {
      final adapter = _adapter(text: 'ab');
      addTearDown(adapter.dispose);
      final state = adapter.editorState;
      await state.formatDelta(
        Selection.single(path: [0], startOffset: 0, endOffset: 1),
        {AppFlowyRichTextKeys.italic: true},
      );
      expect(adapter.blocks.single.paragraphStyle, isNull);
      await state.formatDelta(
        Selection.single(path: [0], startOffset: 0, endOffset: 2),
        {AppFlowyRichTextKeys.underline: true},
      );
      expect(adapter.blocks.single.paragraphStyle!.values['textDefaults'], {
        'a:bold': true,
        'a:underline': true,
      });
      state.selection = Selection.single(path: [0], startOffset: 2);
      final transaction = state.transaction
        ..deleteText(state.document.first!, 0, 2);
      transaction.afterSelection = Selection.single(path: [0], startOffset: 0);
      await state.apply(transaction, skipHistoryDebounce: true);
      expect(adapter.blocks.single.text, isEmpty);
      expect(adapter.blocks.single.paragraphStyle!.values['textDefaults'], {
        'a:bold': true,
        'a:underline': true,
      });
      expect(state.toggledStyle[AppFlowyRichTextKeys.bold], isTrue);
      state.undoManager.undo();
      await Future<void>.delayed(Duration.zero);
      expect(adapter.blocks.single.text, 'ab');
    },
  );
  test(
    'formatting a multi paragraph range includes empty markers in the same undo step',
    () async {
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: [
          const CollabEditorBlock(
            id: 'a',
            blockType: 'paragraph',
            text: 'a',
            segments: [CollabEditorTextSegment(text: 'a', bold: true)],
          ),
          CollabEditorBlock(
            id: 'empty',
            blockType: 'paragraph',
            text: '',
            paragraphStyle: CollabResource.fromValues({
              'textDefaults': {'a:italic': true},
            }),
          ),
          const CollabEditorBlock(id: 'b', blockType: 'paragraph', text: 'b'),
        ],
        onLocalBlocksChanged: (_) {},
      );
      addTearDown(adapter.dispose);
      final state = adapter.editorState;
      state.selection = Selection(
        start: Position(path: [0]),
        end: Position(path: [2], offset: 1),
      );
      await formatCollabParagraphSelection(state, state.selection!, {
        AppFlowyRichTextKeys.underline: true,
      });
      expect(adapter.blocks[1].paragraphStyle!.values['textDefaults'], {
        'a:italic': true,
        'a:underline': true,
      });
      expect(adapter.blocks.last.paragraphStyle!.values['textDefaults'], {
        'a:underline': true,
      });
      state.undoManager.undo();
      await Future<void>.delayed(Duration.zero);
      expect(adapter.blocks[1].paragraphStyle!.values['textDefaults'], {
        'a:italic': true,
      });
      expect(adapter.blocks.last.paragraphStyle, isNull);
    },
  );
  test(
    'deleting a mixed range retains common appearance and excludes links',
    () async {
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: const [
          CollabEditorBlock(
            id: 'mixed',
            blockType: 'paragraph',
            text: 'ab',
            segments: [
              CollabEditorTextSegment(
                text: 'a',
                bold: true,
                href: 'https://example.test',
              ),
              CollabEditorTextSegment(text: 'b'),
            ],
          ),
        ],
        onLocalBlocksChanged: (_) {},
      );
      addTearDown(adapter.dispose);
      final state = adapter.editorState;
      state.selection = Selection.single(
        path: [0],
        startOffset: 0,
        endOffset: 2,
      );
      await state.deleteSelection(state.selection!);
      expect(
        normalizeParagraphTextDefaults(
          adapter.blocks.single.paragraphStyle?.values['textDefaults'],
        ),
        isEmpty,
      );
      expect(state.toggledStyle[AppFlowyRichTextKeys.bold], isNull);
      expect(state.toggledStyle[AppFlowyRichTextKeys.href], isNull);
    },
  );
  test(
    'reverse cross paragraph Enter is atomic and allocates a fresh next identity',
    () async {
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: const [
          CollabEditorBlock(id: 'first', blockType: 'heading_2', text: 'ab'),
          CollabEditorBlock(id: 'middle', blockType: 'paragraph', text: 'cd'),
          CollabEditorBlock(id: 'last', blockType: 'paragraph', text: 'ef'),
        ],
        onLocalBlocksChanged: (_) {},
      );
      addTearDown(adapter.dispose);
      final state = adapter.editorState;
      state.selection = Selection(
        start: Position(path: [2], offset: 1),
        end: Position(path: [0], offset: 1),
      );
      await handleCollabParagraphEnter(state);
      expect(adapter.blocks.map((b) => b.text), ['a', 'f']);
      expect(adapter.blocks.last.blockType, 'heading_2');
      expect(adapter.blocks.last.id, isNot(anyOf('middle', 'last')));
      state.undoManager.undo();
      await Future<void>.delayed(Duration.zero);
      expect(adapter.blocks.map((b) => b.text), ['ab', 'cd', 'ef']);
    },
  );
  test(
    'manual caret navigation in the same block resets temporary input styles',
    () async {
      final adapter = _adapter(text: 'ab');
      addTearDown(adapter.dispose);
      final state = adapter.editorState;
      state.selection = Selection.single(path: [0], startOffset: 2);
      await setCollabTypingAttributes(state, {AppFlowyRichTextKeys.bold: null});
      state.selection = Selection.single(path: [0], startOffset: 1);
      expect(state.toggledStyle[AppFlowyRichTextKeys.bold], isTrue);
    },
  );
  test(
    'undo and redo restore explicit local typing format before nonempty insertion',
    () async {
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: const [
          CollabEditorBlock(id: 'plain', blockType: 'paragraph', text: 'a'),
        ],
        onLocalBlocksChanged: (_) {},
      );
      addTearDown(adapter.dispose);
      final state = adapter.editorState;
      state.selection = Selection.single(path: [0], startOffset: 1);
      await setCollabTypingAttributes(state, {AppFlowyRichTextKeys.bold: true});
      await state.apply(
        state.transaction
          ..insertText(
            state.document.first!,
            1,
            'b',
            toggledAttributes: state.toggledStyle,
          )
          ..afterSelection = Selection.single(path: [0], startOffset: 2),
        skipHistoryDebounce: true,
      );
      state.undoManager.undo();
      await Future<void>.delayed(Duration.zero);
      expect(adapter.blocks.single.text, 'a');
      expect(state.toggledStyle[AppFlowyRichTextKeys.bold], isTrue);
      state.undoManager.redo();
      await Future<void>.delayed(Duration.zero);
      expect(adapter.blocks.single.text, 'ab');
      expect(state.toggledStyle[AppFlowyRichTextKeys.bold], isTrue);
    },
  );
  for (final style in ['same', 'body']) {
    test(
      'empty quote exits in place for $style and keeps only continuing defaults',
      () async {
        final adapter = _adapter(
          type: 'quote',
          props: {
            'nextParagraphStyle': style,
            'textDefaults': {'a:italic': true},
          },
        );
        addTearDown(adapter.dispose);
        final state = adapter.editorState;
        state.selection = Selection.single(path: [0], startOffset: 0);
        await handleCollabParagraphEnter(state);
        expect(adapter.blocks, hasLength(1));
        expect(adapter.blocks.single.blockType, 'paragraph');
        expect(
          state.toggledStyle[AppFlowyRichTextKeys.italic],
          style == 'same' ? true : null,
        );
      },
    );
  }
  test(
    'next style edits are read-only safe and undo follows stable identity after reorder',
    () async {
      final adapter = _adapter(text: 'ab');
      addTearDown(adapter.dispose);
      final state = adapter.editorState;
      state.selection = Selection.single(path: [0], startOffset: 2);
      await setCollabNextParagraphStyle(state, 'body');
      final first = adapter.blocks.single;
      await adapter.replaceFromRemote([
        const CollabEditorBlock(id: 'other', blockType: 'paragraph', text: 'x'),
        first,
      ]);
      state.undoManager.undo();
      await Future<void>.delayed(Duration.zero);
      expect(
        adapter.blocks.first.paragraphStyle?.values['nextParagraphStyle'],
        isNull,
      );
      expect(
        adapter.blocks.last.paragraphStyle?.values['nextParagraphStyle'],
        isNull,
      );
      state.editable = false;
      expect(await setCollabNextParagraphStyle(state, 'same'), isFalse);
      expect(await handleCollabParagraphEnter(state), isFalse);
    },
  );
  for (final type in ['paragraph', 'quote', 'heading_2']) {
    test(
      'empty $type retains character defaults while outdenting raw paragraph depth',
      () async {
        final adapter = _adapter(
          type: type,
          props: {
            'depth': 2,
            'nextParagraphStyle': 'same',
            'textDefaults': {'a:italic': true},
          },
        );
        addTearDown(adapter.dispose);
        final state = adapter.editorState;
        state.selection = Selection.single(path: [0], startOffset: 0);
        await handleCollabParagraphEnter(state);
        expect(adapter.blocks, hasLength(1));
        expect(adapter.blocks.single.blockType, type);
        expect(adapter.blocks.single.paragraphStyle!.values['depth'], 1);
        expect(adapter.blocks.single.paragraphStyle!.values['textDefaults'], {
          'a:italic': true,
        });
        state.undoManager.undo();
        await Future<void>.delayed(Duration.zero);
        expect(adapter.blocks.single.paragraphStyle!.values['depth'], 2);
      },
    );
  }
  test(
    'empty heading body resets in place and undo restores heading defaults',
    () async {
      final adapter = _adapter(
        type: 'heading_2',
        props: {
          'textDefaults': {'a:bold': true},
          'fs': 28,
        },
      );
      addTearDown(adapter.dispose);
      final state = adapter.editorState;
      state.selection = Selection.single(path: [0], startOffset: 0);
      await handleCollabParagraphEnter(state);
      expect(adapter.blocks, hasLength(1));
      expect(adapter.blocks.single.blockType, 'paragraph');
      expect(adapter.blocks.single.paragraphStyle!.values['fs'], isNull);
      state.undoManager.undo();
      await Future<void>.delayed(Duration.zero);
      expect(adapter.blocks.single.blockType, 'heading_2');
      expect(adapter.blocks.single.paragraphStyle!.values['fs'], 28);
    },
  );
  test(
    'same paragraph preserves typography and next body drops all appearance overrides',
    () async {
      final adapter = _adapter(
        text: 'ab',
        type: 'quote',
        props: {
          'nextParagraphStyle': 'same',
          'textDefaults': {'a:bold': true},
          'fs': 20,
          'pfs': 1.25,
          'lh': 2,
        },
      );
      addTearDown(adapter.dispose);
      final node = adapter.editorState.document.first!;
      final style = collabParagraphTextStyle(
        node,
        const TextStyle(fontSize: 16),
        {'t:px': 24, 't:fs': 1.5, 't:ls': .1, 't:ff': 'courier'},
      );
      expect(style.fontSize, 45);
      expect(style.letterSpacing, closeTo(4.5, .001));
      expect(style.fontFamily, 'Courier New');
    },
  );
}

/// 创建带 [props] 的 [type] 测试段落，正文 [text] 默认空；调用方负责释放适配器。
AppFlowyBlockEditorAdapter _adapter({
  String text = '',
  String type = 'paragraph',
  Map<String, dynamic> props = const {},
}) => AppFlowyBlockEditorAdapter(
  initialBlocks: [
    CollabEditorBlock(
      id: 'p',
      blockType: type,
      text: text,
      alignment: 'center',
      segments: text.isEmpty
          ? const []
          : [CollabEditorTextSegment(text: text, bold: true)],
      paragraphStyle: props.isEmpty ? null : CollabResource.fromValues(props),
    ),
  ],
  onLocalBlocksChanged: (_) {},
);
