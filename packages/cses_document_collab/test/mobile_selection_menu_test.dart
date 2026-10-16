import 'dart:async';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/editor/collab_mobile_selection_menu.dart';
import 'package:cses_document_collab/src/editor/editor_shortcut_toolbar.dart';
import 'package:cses_document_collab/src/model/collab_inline_formula.dart';
import 'package:cses_document_collab/src/model/collab_text_range.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

/// 使用真实选区、格式控件及适配器验证划词菜单、链接、公式和迟到操作保护。
void main() {
  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
          const EventChannel('keyboardHeightEventChannel'),
          MockStreamHandler.inline(
            onListen: (_, events) => events.success(0.0),
          ),
        );
  });

  testWidgets(
    'multiline paste replaces a range in one undo and preserves surrounding styles',
    (tester) async {
      final harness = await _Harness.mount(tester);
      AppFlowyClipboard.mockSetData(const AppFlowyClipboardData(text: 'A\nB'));
      await harness.select(tester, 3, 6);
      await _choose(tester, '粘贴');
      expect(harness.adapter.blocks.map((b) => b.text), ['前😀A', 'B后']);
      expect(harness.adapter.blocks.first.segments.first.bold, isTrue);
      expect(harness.adapter.blocks.last.segments.last.bold, isTrue);
      harness.state.undoManager.undo();
      await tester.pumpAndSettle();
      expect(harness.adapter.blocks.single.text, '前😀x^2后');
      expect(harness.adapter.blocks.single.segments.single.bold, isTrue);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'cut waits for clipboard and rejects remote edits during that wait',
    (tester) async {
      final harness = await _Harness.mount(tester);
      final written = Completer<void>();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') await written.future;
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await harness.select(tester, 3, 6);
      await _choose(tester, '剪切');
      await harness.adapter.replaceFromRemote(const [
        CollabEditorBlock(id: 'body', blockType: 'paragraph', text: '远端新正文'),
      ]);
      written.complete();
      await tester.pumpAndSettle();
      expect(harness.adapter.blocks.single.text, '远端新正文');
      expect(harness.state.undoManager.undoStack.isEmpty, isTrue);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'link tracks original block after remote reorder',
    (tester) async {
      final harness = await _Harness.mount(tester);
      await harness.select(tester, 3, 6);
      await _choose(tester, '链接');
      await tester.enterText(
        find.byKey(const ValueKey('editor-text-link-input')),
        'https://example.com',
      );
      await harness.adapter.replaceFromRemote([
        const CollabEditorBlock(id: 'new', blockType: 'paragraph', text: '另一段'),
        harness.adapter.blocks.single,
      ]);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('editor-text-link-save')));
      await _settleAction(tester);
      expect(harness.adapter.blocks.first.text, '另一段');
      expect(
        harness.adapter.blocks.last.segments
            .firstWhere((s) => s.href != null)
            .text,
        'x^2',
      );
      expect(harness.state.selection?.start.path, [1]);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'formula conversion rejects remote changes while preview is open',
    (tester) async {
      final harness = await _Harness.mount(tester);
      await harness.select(tester, 3, 6);
      await _choose(tester, '转行内公式');
      await harness.adapter.replaceFromRemote(const [
        CollabEditorBlock(id: 'body', blockType: 'paragraph', text: '远端新正文'),
      ]);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('formula-save')));
      await _settleAction(tester);
      expect(harness.adapter.blocks.single.text, '远端新正文');
      expect(
        harness.adapter.blocks.single.segments.every(
          (s) => s.inlineLatex == null,
        ),
        isTrue,
      );
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  test(
    'range rejects cross-cell selection, code and whole-block selection',
    () {
      final state = EditorState(
        document: Document(
          root: Node(
            type: 'page',
            children: [
              Node(
                type: 'table',
                children: [
                  Node(
                    type: 'table-row',
                    children: [
                      Node(
                        type: 'table-cell',
                        children: [paragraphNode(text: 'first')],
                      ),
                      Node(
                        type: 'table-cell',
                        children: [paragraphNode(text: 'second')],
                      ),
                    ],
                  ),
                ],
              ),
              Node(
                type: 'code',
                attributes: {'delta': (Delta()..insert('code')).toJson()},
              ),
            ],
          ),
        ),
      );
      addTearDown(state.dispose);
      state.selection = Selection.single(
        path: [0, 0, 0, 0],
        startOffset: 0,
        endOffset: 2,
      );
      expect(CollabTextRange.capture(state), isNotNull);
      state.selection = Selection(
        start: Position(path: [0, 0, 0, 0]),
        end: Position(path: [0, 0, 1, 0], offset: 2),
      );
      expect(CollabTextRange.capture(state), isNull);
      state.selection = Selection.single(
        path: [1],
        startOffset: 0,
        endOffset: 2,
      );
      expect(CollabTextRange.capture(state), isNull);
      state.selectionType = SelectionType.block;
      state.selection = Selection.single(
        path: [0, 0, 0, 0],
        startOffset: 0,
        endOffset: 2,
      );
      expect(CollabTextRange.capture(state), isNull);
    },
  );

  testWidgets(
    'keyboard-hidden range exposes native menu and copy',
    (tester) async {
      final harness = await _Harness.mount(tester);
      await harness.select(tester, 0, 3);
      expect(
        find.byKey(const ValueKey('editor-selection-menu')),
        findsOneWidget,
      );
      expect(
        _labels(tester),
        containsAll(['复制', '剪切', '粘贴', '全选', '格式', '链接', '转行内公式']),
      );
      await tester.tap(find.text('复制'));
      await tester.pumpAndSettle();
      expect(AppFlowyClipboard.lastText, '前😀');
      expect(harness.adapter.blocks.single.text, '前😀x^2后');
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'readonly range keeps copy and select all only',
    (tester) async {
      final harness = await _Harness.mount(tester, editable: false);
      await harness.select(tester, 3, 6);
      expect(_labels(tester), ['复制', '全选']);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'select all completes and later menu actions remain available',
    (tester) async {
      final harness = await _Harness.mount(tester);
      await harness.select(tester, 3, 6);
      await _choose(tester, '全选');
      expect(
        harness.state.selection?.normalized,
        Selection.single(path: [0], startOffset: 0, endOffset: 7),
      );
      await harness.select(tester, 0, 3);
      await _choose(tester, '复制');
      expect(AppFlowyClipboard.lastText, '前😀');
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'link keeps text and styles, supports undo, edit and remove',
    (tester) async {
      final harness = await _Harness.mount(tester);
      await harness.select(tester, 6, 3); // backward UTF-16 selection
      await _choose(tester, '链接');
      await tester.enterText(
        find.byKey(const ValueKey('editor-text-link-input')),
        'javascript:alert(1)',
      );
      await tester.tap(find.byKey(const ValueKey('editor-text-link-save')));
      await tester.pumpAndSettle();
      expect(find.text('请输入完整的 http(s)、mailto 或 tel 链接'), findsOneWidget);
      expect(harness.adapter.blocks.single.segments.single.href, isNull);
      await tester.enterText(
        find.byKey(const ValueKey('editor-text-link-input')),
        'https://example.com/a',
      );
      await tester.tap(find.byKey(const ValueKey('editor-text-link-save')));
      await _settleAction(tester);
      final linked = harness.adapter.blocks.single.segments.firstWhere(
        (s) => s.href != null,
      );
      expect(linked.text, 'x^2');
      expect(linked.bold, isTrue);
      expect(linked.href, 'https://example.com/a');
      expect(harness.adapter.blocks.single.text, '前😀x^2后');
      harness.state.undoManager.undo();
      await tester.pumpAndSettle();
      expect(
        harness.adapter.blocks.single.segments.every(
          (s) => s.href == null && s.bold,
        ),
        isTrue,
      );
      harness.state.undoManager.redo();
      await tester.pumpAndSettle();
      await harness.select(tester, 3, 6);
      await _choose(tester, '链接');
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('editor-text-link-input')),
            )
            .controller!
            .text,
        'https://example.com/a',
      );
      await tester.tap(find.byKey(const ValueKey('editor-text-link-remove')));
      await _settleAction(tester);
      expect(
        harness.adapter.blocks.single.segments.every(
          (s) => s.href == null && s.bold,
        ),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  for (final change in ['text', 'delete', 'readonly', 'format']) {
    testWidgets(
      'link rejects $change while dialog is open',
      (tester) async {
        final harness = await _Harness.mount(tester);
        await harness.select(tester, 3, 6);
        await _choose(tester, '链接');
        await tester.enterText(
          find.byKey(const ValueKey('editor-text-link-input')),
          'https://example.com',
        );
        if (change == 'readonly') {
          harness.state.editable = false;
        } else {
          await harness.adapter.replaceFromRemote(
            change == 'delete'
                ? []
                : [
                    CollabEditorBlock(
                      id: 'body',
                      blockType: 'paragraph',
                      text: change == 'text' ? '远端新正文' : '前😀x^2后',
                      segments: change == 'format'
                          ? const [
                              CollabEditorTextSegment(
                                text: '前😀x^2后',
                                italic: true,
                              ),
                            ]
                          : const [],
                    ),
                  ],
          );
        }
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('editor-text-link-save')));
        await _settleAction(tester);
        expect(
          harness.adapter.blocks
              .expand((b) => b.segments)
              .every((s) => s.href == null),
          isTrue,
        );
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
  }

  testWidgets(
    'formula prefills selected text and atom undo restores styled UTF16 text',
    (tester) async {
      final harness = await _Harness.mount(tester);
      await harness.select(tester, 6, 3);
      await _choose(tester, '转行内公式');
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('formula-input')))
            .controller!
            .text,
        'x^2',
      );
      await tester.enterText(
        find.byKey(const ValueKey('formula-input')),
        r'\frac{x}{2}',
      );
      await tester.tap(find.byKey(const ValueKey('formula-save')));
      await _settleAction(tester);
      expect(harness.adapter.blocks.single.text, '前😀\uFFFC后');
      expect(
        harness.adapter.blocks.single.segments
            .firstWhere((s) => s.inlineLatex != null)
            .inlineLatex,
        r'\frac{x}{2}',
      );
      expect(harness.state.selection?.start.offset, 4);
      harness.state.undoManager.undo();
      await tester.pumpAndSettle();
      expect(harness.adapter.blocks.single.text, '前😀x^2后');
      expect(harness.adapter.blocks.single.segments.single.bold, isTrue);
      harness.state.undoManager.redo();
      await tester.pumpAndSettle();
      expect(harness.adapter.blocks.single.text, '前😀\uFFFC后');
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'cancel formula leaves original text and selection',
    (tester) async {
      final harness = await _Harness.mount(tester);
      await harness.select(tester, 3, 6);
      await _choose(tester, '转行内公式');
      await tester.tap(find.byKey(const ValueKey('formula-close')));
      await _settleAction(tester);
      expect(harness.adapter.blocks.single.text, '前😀x^2后');
      expect(
        harness.state.selection?.normalized,
        Selection.single(path: [0], startOffset: 3, endOffset: 6),
      );
      expect(harness.state.undoManager.undoStack.isEmpty, isTrue);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'format panel reuses bold, colors, heading and alignment controls without keyboard',
    (tester) async {
      final harness = await _Harness.mount(tester);
      await harness.select(tester, 3, 6);
      await _choose(tester, '格式');
      expect(
        find.byKey(const ValueKey('editor-selection-format-sheet')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('editor-inline-bold')));
      await tester.pumpAndSettle();
      expect(
        harness.adapter.blocks.single.segments.any(
          (s) => s.text == 'x^2' && !s.bold,
        ),
        isTrue,
      );
      await tester.tap(find.byKey(const ValueKey('editor-inline-text-color')));
      await tester.pumpAndSettle();
      await _tapPanelAction(
        tester,
        'editor-text-color-blue',
        menu: 'editor-text-color-menu',
      );
      expect(
        harness.adapter.blocks.single.segments
            .firstWhere((s) => s.text == 'x^2')
            .textColor,
        '0xff0b6e99',
      );
      await _tapPanelAction(
        tester,
        'editor-text-color-back',
        menu: 'editor-text-color-menu',
      );
      await tester.tap(find.byKey(const ValueKey('editor-block-align-center')));
      await tester.pumpAndSettle();
      expect(harness.adapter.blocks.single.alignment, 'center');
      await tester.tap(find.byKey(const ValueKey('editor-block-heading-1')));
      await tester.pumpAndSettle();
      expect(
        harness.state.document.first!.attributes[HeadingBlockKeys.level],
        1,
      );
      expect(find.text('选区或编辑权限已变化，请关闭后重新选择'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('editor-inline-bold')));
      await tester.pumpAndSettle();
      expect(
        harness.adapter.blocks.single.segments
            .firstWhere((s) => s.text == 'x^2')
            .bold,
        isTrue,
      );
      await tester.tap(find.byKey(const ValueKey('editor-block-align-left')));
      await tester.pumpAndSettle();
      expect(harness.adapter.blocks.single.alignment, 'left');
      await tester.tap(find.text('完成'));
      await _settleAction(tester);
      expect(harness.state.selection, isNotNull);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'format panel keeps its range through repeated local conversions',
    (tester) async {
      final harness = await _Harness.mount(tester);
      await harness.select(tester, 3, 6);
      await _choose(tester, '格式');
      for (final type in [
        'heading',
        'quote',
        'bulleted_list',
        'numbered_list',
        'todo_list',
        'paragraph',
      ]) {
        await _tapPanelAction(
          tester,
          'editor-block-$type-${type == 'heading' ? 1 : 0}',
          menu: 'editor-block-style-menu',
        );
        expect(find.text('选区或编辑权限已变化，请关闭后重新选择'), findsNothing);
        expect(harness.adapter.blocks.single.text, '前😀x^2后');
        expect(
          harness.state.selection?.normalized,
          Selection.single(path: [0], startOffset: 3, endOffset: 6),
        );
        await tester.tap(find.byKey(const ValueKey('editor-inline-italic')));
        await tester.pumpAndSettle();
        expect(
          harness.adapter.blocks.single.segments
              .firstWhere((s) => s.text == 'x^2')
              .italic,
          isTrue,
        );
        await tester.tap(find.byKey(const ValueKey('editor-inline-italic')));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('完成'));
      await _settleAction(tester);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'format panel continues after zero-depth list outdent',
    (tester) async {
      final harness = await _Harness.mount(
        tester,
        blocks: const [
          CollabEditorBlock(
            id: 'body',
            blockType: 'bulleted_list',
            text: '前😀x^2后',
          ),
        ],
      );
      await harness.select(tester, 3, 6);
      await _choose(tester, '格式');
      await tester.tap(find.byKey(const ValueKey('editor-block-outdent')));
      await tester.pumpAndSettle();
      expect(harness.adapter.blocks.single.blockType, 'paragraph');
      expect(find.text('选区或编辑权限已变化，请关闭后重新选择'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('editor-inline-italic')));
      await tester.pumpAndSettle();
      expect(
        harness.adapter.blocks.single.segments
            .firstWhere((s) => s.text == 'x^2')
            .italic,
        isTrue,
      );
      await tester.tap(find.text('完成'));
      await _settleAction(tester);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  for (final change in ['type', 'delete', 'readonly', 'text', 'reorder']) {
    testWidgets(
      'format panel validates remote $change after a local conversion',
      (tester) async {
        final harness = await _Harness.mount(tester);
        await harness.select(tester, 3, 6);
        await _choose(tester, '格式');
        await tester.tap(find.byKey(const ValueKey('editor-block-heading-1')));
        await tester.pumpAndSettle();
        final original = harness.adapter.blocks.single;
        if (change == 'readonly') {
          harness.state.editable = false;
        } else if (change == 'reorder') {
          await harness.adapter.replaceFromRemote([
            const CollabEditorBlock(
              id: 'other',
              blockType: 'paragraph',
              text: '另一段',
            ),
            original,
          ]);
        } else {
          await harness.adapter.replaceFromRemote([
            CollabEditorBlock(
              id: change == 'delete' ? 'replacement' : original.id,
              blockType: change == 'type' || change == 'delete'
                  ? 'paragraph'
                  : original.blockType,
              text: change == 'text' ? '远端正文' : original.text,
              segments: change == 'text' ? const [] : original.segments,
            ),
          ]);
        }
        await tester.pumpAndSettle();
        final before = harness.state.document.toJson();
        if (change == 'reorder') {
          expect(find.text('选区或编辑权限已变化，请关闭后重新选择'), findsNothing);
          await tester.tap(find.byKey(const ValueKey('editor-inline-italic')));
          await tester.pumpAndSettle();
          expect(harness.adapter.blocks.first.segments, isEmpty);
          expect(
            harness.adapter.blocks.last.segments
                .firstWhere((s) => s.text == 'x^2')
                .italic,
            isTrue,
          );
        } else {
          expect(find.text('选区或编辑权限已变化，请关闭后重新选择'), findsOneWidget);
          expect(
            find.byKey(const ValueKey('editor-inline-italic')).hitTestable(),
            findsNothing,
          );
          expect(harness.state.document.toJson(), before);
        }
        await tester.tap(find.text('完成'));
        await _settleAction(tester);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
  }

  for (final change in ['reorder', 'text']) {
    testWidgets(
      'format action checks live range after remote $change',
      (tester) async {
        final harness = await _Harness.mount(tester);
        await harness.select(tester, 3, 6);
        await _choose(tester, '格式');
        final original = harness.adapter.blocks.single;
        await harness.adapter.replaceFromRemote(
          change == 'reorder'
              ? [
                  const CollabEditorBlock(
                    id: 'other',
                    blockType: 'paragraph',
                    text: 'other text',
                  ),
                  original,
                ]
              : [
                  const CollabEditorBlock(
                    id: 'body',
                    blockType: 'paragraph',
                    text: 'changed text',
                  ),
                ],
        );
        await tester.pumpAndSettle();
        final button = find.byKey(const ValueKey('editor-inline-bold'));
        if (button.hitTestable().evaluate().isNotEmpty) {
          await tester.tap(button);
        }
        await tester.pumpAndSettle();
        if (change == 'reorder') {
          expect(
            harness.adapter.blocks.first.segments.every((s) => !s.bold),
            isTrue,
          );
          expect(
            harness.adapter.blocks.last.segments.any(
              (s) => s.text == 'x^2' && !s.bold,
            ),
            isTrue,
          );
        } else {
          expect(harness.adapter.blocks.single.text, 'changed text');
          expect(
            harness.adapter.blocks.single.segments.every((s) => !s.bold),
            isTrue,
          );
        }
        await tester.tap(find.text('完成'));
        await _settleAction(tester);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
  }

  testWidgets(
    'cross paragraph menu allows formats but hides link and formula',
    (tester) async {
      final harness = await _Harness.mount(
        tester,
        blocks: const [
          CollabEditorBlock(id: 'a', blockType: 'paragraph', text: 'first'),
          CollabEditorBlock(id: 'b', blockType: 'paragraph', text: 'second'),
        ],
      );
      harness.state.selection = Selection(
        start: Position(path: [0], offset: 1),
        end: Position(path: [1], offset: 3),
      );
      await tester.pumpAndSettle();
      expect(_labels(tester), contains('格式'));
      expect(_labels(tester), isNot(contains('链接')));
      expect(_labels(tester), isNot(contains('转行内公式')));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  test(
    'stable snapshot follows reorder, rejects insertion inside range and object conversion',
    () async {
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: const [
          CollabEditorBlock(id: 'a', blockType: 'paragraph', text: 'abc'),
          CollabEditorBlock(id: 'b', blockType: 'paragraph', text: 'def'),
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
      final range = CollabTextRange.capture(state)!;
      await adapter.replaceFromRemote([adapter.blocks[1], adapter.blocks[0]]);
      expect(range.resolve(state)?.start.path, [1]);
      await state.apply(
        state.transaction
          ..insertText(state.document.root.children.last, 0, 'X'),
      );
      expect(range.resolve(state), isNull);
      state.selection = Selection.single(
        path: [1],
        startOffset: 0,
        endOffset: 1,
      );
      final atom = state.document.root.children.last;
      await state.apply(
        state.transaction..updateNode(atom, {
          'delta':
              (Delta()..insert(
                    collabInlineFormulaCharacter,
                    attributes: {collabInlineLatexAttribute: 'x'},
                  ))
                  .toJson(),
        }),
      );
      state.selection = Selection.single(
        path: [1],
        startOffset: 0,
        endOffset: 1,
      );
      expect(CollabTextRange.capture(state)?.canConvert, isFalse);
    },
  );
}

/// 在真实 Android [tester] 上验证长按松手、溢出菜单和链接/公式操作。
/// 宿主测试不能改变 AppFlowy 使用的实际操作系统；此流程由 integration_test 驱动。
Future<void> verifyMobileSelectionMenuGestures(WidgetTester tester) async {
  final harness = await _Harness.mount(
    tester,
    withKeyboardToolbar: true,
    blocks: const [
      CollabEditorBlock(
        id: 'body',
        blockType: 'paragraph',
        text: 'hello world',
      ),
    ],
  );
  expect(
    find.byWidgetPredicate(
      (widget) =>
          widget.runtimeType.toString() == 'MobileSelectionServiceWidget',
    ),
    findsOneWidget,
  );
  final text = find.text('hello world', findRichText: true);
  await tester.longPressAt(tester.getTopLeft(text) + const Offset(25, 10));
  await tester.pumpAndSettle();
  expect(harness.state.selection?.isCollapsed, isFalse);
  expect(_labels(tester), contains('格式'));
  await tester.tap(find.text('复制'));
  await tester.pumpAndSettle();
  expect(AppFlowyClipboard.lastText, isNotEmpty);
  await harness.select(tester, 0, 5);
  await _tapVisibleAction(tester, '格式');
  await tester.tap(find.byKey(const ValueKey('editor-inline-italic')));
  await tester.pumpAndSettle();
  expect(harness.adapter.blocks.single.segments.first.italic, isTrue);
  await tester.tap(find.text('完成'));
  await _settleAction(tester);
  await harness.select(tester, 0, 5);
  await _tapVisibleAction(tester, '链接');
  await tester.enterText(
    find.byKey(const ValueKey('editor-text-link-input')),
    'https://example.com',
  );
  await tester.tap(find.byKey(const ValueKey('editor-text-link-save')));
  await _settleAction(tester);
  expect(
    harness.adapter.blocks.single.segments.first.href,
    'https://example.com',
  );
  await harness.select(tester, 6, 11);
  await _tapVisibleAction(tester, '转行内公式');
  expect(
    tester
        .widget<TextField>(find.byKey(const ValueKey('formula-input')))
        .controller!
        .text,
    'world',
  );
  await tester.enterText(find.byKey(const ValueKey('formula-input')), 'x^2');
  await tester.tap(find.byKey(const ValueKey('formula-save')));
  await _settleAction(tester);
  expect(harness.adapter.blocks.single.text, 'hello \uFFFC');
  harness.state.undoManager.undo();
  await tester.pumpAndSettle();
  expect(harness.adapter.blocks.single.text, 'hello world');
  expect(tester.takeException(), isNull);
}

/// 在真实触屏 [tester] 上通过溢出按钮找到并点击 [label]，不直接调用菜单回调。
Future<void> _tapVisibleAction(WidgetTester tester, String label) async {
  if (find.text(label).hitTestable().evaluate().isEmpty) {
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
  }
  await tester.tap(find.text(label).hitTestable());
  await tester.pumpAndSettle();
}

/// 返回 [tester] 当前系统菜单的功能标签，不依赖 Android/iOS 对溢出按钮的具体排版。
List<String?> _labels(WidgetTester tester) => tester
    .widget<AdaptiveTextSelectionToolbar>(
      find.byKey(const ValueKey('editor-selection-menu')),
    )
    .buttonItems!
    .map((item) => item.label)
    .toList();

/// 触发 [tester] 当前原生菜单中的 [label]，验证溢出动作也接入同一回调。
Future<void> _choose(WidgetTester tester, String label) async {
  final menu = tester.widget<AdaptiveTextSelectionToolbar>(
    find.byKey(const ValueKey('editor-selection-menu')),
  );
  menu.buttonItems!.firstWhere((item) => item.label == label).onPressed!();
  await tester.pumpAndSettle();
}

/// 等待 [tester] 中弹窗退场及既有正文输入恢复窗口。
Future<void> _settleAction(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pumpAndSettle();
}

/// 在借用 [tester] 的横向 [menu] 中滚动找到并触摸 [key]；从左端开始以支持连续反向选择。
/// 按真实命中检查按钮，避免懒加载或色板增加选项后触摸落在面板外。
Future<void> _tapPanelAction(
  WidgetTester tester,
  String key, {
  required String menu,
}) async {
  final scrollable = find
      .descendant(
        of: find.byKey(ValueKey(menu)),
        matching: find.byType(Scrollable),
      )
      .first;
  tester.state<ScrollableState>(scrollable).position.jumpTo(0);
  await tester.pumpAndSettle();
  final target = find.byKey(ValueKey(key));
  await tester.scrollUntilVisible(target, 100, scrollable: scrollable);
  await tester.pumpAndSettle();
  expect(target.hitTestable(), findsOneWidget, reason: key);
  await tester.tap(target);
  await tester.pumpAndSettle();
}

/// 测试拥有的真实适配器、滚动和焦点资源，Widget 退出后按顺序释放。
final class _Harness {
  /// 从 [adapter] 创建所属滚动与焦点资源，调用方通过 mount 注册统一清理。
  _Harness(this.adapter)
    : scroll = EditorScrollController(editorState: adapter.editorState);

  final AppFlowyBlockEditorAdapter adapter;
  final EditorScrollController scroll;
  final FocusNode focus = FocusNode();

  /// 当前借用的适配器编辑器。
  EditorState get state => adapter.editorState;

  /// 在 [tester] 中挂载无软键盘视口；[editable] 默认 true，[blocks] 默认一段带加粗的 UTF-16 正文。
  /// [withKeyboardToolbar] 默认 false，设备回归传 true 验证实际键盘工具栏与划词浮栏组合。
  static Future<_Harness> mount(
    WidgetTester tester, {
    bool editable = true,
    bool withKeyboardToolbar = false,
    List<CollabEditorBlock>? blocks,
  }) async {
    final harness = _Harness(
      AppFlowyBlockEditorAdapter(
        initialBlocks:
            blocks ??
            const [
              CollabEditorBlock(
                id: 'body',
                blockType: 'paragraph',
                text: '前😀x^2后',
                segments: [
                  CollabEditorTextSegment(text: '前😀x^2后', bold: true),
                ],
              ),
            ],
        onLocalBlocksChanged: (_) {},
      ),
    );
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      harness.scroll.dispose();
      harness.adapter.dispose();
      harness.focus.dispose();
      await tester.binding.setSurfaceSize(null);
      AppFlowyClipboard.mockSetData(null);
    });
    final editor = CollabMobileSelectionMenu(
      editorState: harness.state,
      scrollController: harness.scroll,
      child: AppFlowyEditor(
        editorState: harness.state,
        editorScrollController: harness.scroll,
        focusNode: harness.focus,
        editable: editable,
        editorStyle: const EditorStyle.mobile(),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          AppFlowyEditorLocalizations.delegate,
        ],
        home: Scaffold(
          body: withKeyboardToolbar
              ? EditorShortcutToolbar(editorState: harness.state, child: editor)
              : editor,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return harness;
  }

  /// 设置并等待 [tester] 布局第一段的 UTF-16 [start]/[end] 范围。
  Future<void> select(WidgetTester tester, int start, int end) async {
    state.selection = Selection.single(
      path: [0],
      startOffset: start,
      endOffset: end,
    );
    await tester.pumpAndSettle();
  }
}
