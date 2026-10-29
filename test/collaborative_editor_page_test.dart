import 'dart:async';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/controller/document_metadata_controller.dart';
import 'package:cses_document_collab/src/model/document_metadata.dart';
import 'package:cses_document_collab/src/model/collab_host_services.dart';
import 'package:cses_document_collab/src/model/collab_document_feedback.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/controller/collab_controller.dart';
import 'package:cses_document_collab/src/editor/collab_block_delete.dart';
import 'package:cses_document_collab/src/editor/collab_code_editing.dart';
import 'package:cses_document_collab/src/editor/collab_paragraph_editing.dart';
import 'package:cses_document_collab/src/editor/collaborative_editor_page.dart';
import 'package:cses_document_collab/src/editor/editor_shortcut_toolbar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

/// 验证页面只拥有展示模式，始终遵守宿主的文档编辑能力。
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
    'host AppBar actions work in editing and preview without owning controller',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 720));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final collab = _ReadyCollabController();
      addTearDown(collab.dispose);
      var clicks = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: CollaborativeEditorPage(
            collab: collab,
            showDiagnostics: false,
            actionsBuilder: (_) => [
              IconButton(
                tooltip: 'host-webview',
                onPressed: () => clicks++,
                icon: const Icon(Icons.open_in_browser),
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('host-webview'));
      await tester.tap(find.byKey(const ValueKey('editor-mode-toggle')));
      await tester.pumpAndSettle();
      expect(find.byTooltip('host-webview'), findsOneWidget);
      await tester.tap(find.byTooltip('host-webview'));
      expect(clicks, 2);
      expect(find.textContaining('demo-room'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(collab.hasPageListeners, isFalse);
    },
  );

  testWidgets('host feedback flag controls scrolling footer in both modes', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    tester.view.padding = const FakeViewPadding(bottom: 24);
    addTearDown(tester.view.resetPadding);
    final calls = <String>[];
    final collab = _ReadyCollabController(
      services: CollabHostServices(
        showDocumentFeedback: true,
        onDocumentLike: (id, likes) {
          calls.add(id);
          return CollabDocumentLikes(isLiked: true);
        },
        onDocumentComment: (id, count) {
          calls.add(id);
          return count + 2;
        },
      ),
    );
    addTearDown(collab.dispose);
    await tester.pumpWidget(
      MaterialApp(home: CollaborativeEditorPage(collab: collab)),
    );
    await tester.pumpAndSettle();
    final editor = tester.widget<AppFlowyEditor>(find.byType(AppFlowyEditor));
    expect(editor.footer, isNotNull);
    final before = collab.editorState.document.toJson();
    expect(
      find.byKey(const ValueKey('document-like')).hitTestable(),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('document-comment')).hitTestable(),
      findsNothing,
    );
    await tester.drag(find.byType(AppFlowyEditor), const Offset(0, -600));
    await tester.pumpAndSettle();
    final viewportBottom = tester.getBottomLeft(find.byType(AppFlowyEditor)).dy;
    expect(
      tester.getBottomLeft(find.byKey(const ValueKey('document-comment'))).dy,
      closeTo(viewportBottom - 20, 1),
    );
    await tester.tap(find.byKey(const ValueKey('document-like')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('editor-mode-toggle')));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(AppFlowyEditor), const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(find.text('你已赞'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('document-comment')));
    await tester.pumpAndSettle();
    expect(calls, [collab.documentId, collab.documentId]);
    expect(find.text('评论全文（2）'), findsOneWidget);
    expect(collab.editorState.document.toJson(), before);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final scenario in [
    'success',
    'cancel',
    'invalid',
    'revoked',
    'closed',
  ]) {
    testWidgets(
      'Markdown import $scenario respects transaction and lifecycle',
      (tester) async {
        final changes = <List<CollabEditorBlock>>[];
        final adapter = AppFlowyBlockEditorAdapter(
          initialBlocks: const [
            CollabEditorBlock(
              id: 'original',
              blockType: 'paragraph',
              text: '原正文',
            ),
          ],
          onLocalBlocksChanged: changes.add,
        );
        addTearDown(adapter.dispose);
        final controller = _ReadyCollabController(
          testEditorState: adapter.editorState,
        );
        addTearDown(controller.dispose);
        final picked = Completer<String?>();
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: const [
              GlobalMaterialLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              AppFlowyEditorLocalizations.delegate,
            ],
            home: CollaborativeEditorPage(
              collab: controller,
              pickMarkdown: () => picked.future,
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('editor-import-markdown')));
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.textContaining('追加到当前文档末尾'), findsOneWidget);
        await tester.tap(find.text('选择文件'));
        await tester.pump(const Duration(milliseconds: 300));
        expect(adapter.editorState.editable, isFalse);
        if (scenario == 'revoked') controller.setReadOnlyReason('权限收回');
        if (scenario == 'closed') {
          await tester.pumpWidget(const SizedBox.shrink());
        }
        picked.complete(
          scenario == 'cancel'
              ? null
              : scenario == 'invalid'
              ? ' '
              : '# 导入标题\n\n**导入内容**',
        );
        // compute 使用真实 Isolate；离开测试的虚拟时钟等待其完成。
        await tester.runAsync(() async {
          for (var attempt = 0; attempt < 100; attempt++) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
            if (scenario == 'closed' || scenario == 'revoked') {
              if (attempt > 10) break;
            } else if (adapter.editorState.editable) {
              break;
            }
          }
        });
        await tester.pumpAndSettle();
        if (scenario == 'success') {
          expect(adapter.blocks.map((e) => e.text), [
            '原正文',
            '导入标题',
            '导入内容',
            '',
          ]);
          expect(changes.length, 1);
          adapter.editorState.undoManager.undo();
          await tester.pumpAndSettle();
          expect(adapter.blocks.single.text, '原正文');
          adapter.editorState.undoManager.redo();
          await tester.pumpAndSettle();
          expect(adapter.blocks.length, 4);
        } else {
          expect(adapter.blocks.single.text, '原正文');
          expect(changes, isEmpty);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  for (final source in [
    '',
    'blob:desktop-only',
    'file:///desktop/video.mp4',
    null,
  ]) {
    testWidgets('unrenderable video $source uses the unified placeholder', (
      tester,
    ) async {
      final changes = <List<CollabEditorBlock>>[];
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: [
          CollabEditorBlock(
            id: 'video',
            blockType: csesVideoBlockType,
            text: source ?? '',
          ),
          const CollabEditorBlock(
            id: 'body',
            blockType: 'paragraph',
            text: '正文',
          ),
        ],
        onLocalBlocksChanged: changes.add,
      );
      addTearDown(adapter.dispose);
      if (source == null) {
        // Reproduce a builder validation failure, separate from an opaque native projection.
        adapter.editorState.document.first!.updateAttributes({
          csesEmbedUrlAttribute: null,
        });
      }
      final collab = _ReadyCollabController(
        testEditorState: adapter.editorState,
      );
      addTearDown(collab.dispose);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            AppFlowyEditorLocalizations.delegate,
          ],
          home: CollaborativeEditorPage(collab: collab),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('placeholder'), findsNothing);
      expect(find.text('未适配的块（不可编辑）'), findsOneWidget);
      expect(find.text('原始内容已保留'), findsOneWidget);
      final state = adapter.editorState;
      expect(state.editable, isTrue);
      await state.apply(
        state.transaction..insertText(state.document.last!, 2, '修改'),
      );
      await tester.pumpAndSettle();
      expect(changes.last.first.text, source ?? '');
      expect(changes.last.last.text, '正文修改');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
    'unknown blocks stay opaque while surrounding text remains editable',
    (tester) async {
      final changes = <List<CollabEditorBlock>>[];
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: const [
          CollabEditorBlock(id: 'before', blockType: 'paragraph', text: '前文'),
          CollabEditorBlock(
            id: 'unknown',
            blockType: csesUnsupportedBlockType,
            text: '',
          ),
          CollabEditorBlock(id: 'after', blockType: 'paragraph', text: '后文'),
        ],
        onLocalBlocksChanged: changes.add,
      );
      addTearDown(adapter.dispose);
      final collab = _ReadyCollabController(
        testEditorState: adapter.editorState,
      );
      addTearDown(collab.dispose);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            AppFlowyEditorLocalizations.delegate,
          ],
          home: CollaborativeEditorPage(collab: collab),
        ),
      );
      await tester.pumpAndSettle();
      final state = adapter.editorState;
      expect(find.text('未适配的块（不可编辑）'), findsOneWidget);
      expect(find.textContaining('只读：'), findsNothing);
      expect(state.editable, isTrue);
      expect(find.byType(EditorShortcutToolbar), findsOneWidget);
      expect(find.byKey(const ValueKey('editor-undo')), findsOneWidget);
      expect(
        tester
            .widget<TextButton>(
              find.byKey(const ValueKey('editor-mode-toggle')),
            )
            .onPressed,
        isNotNull,
      );
      expect(state.document.nodeAtPath([1])!.delta, isNull);
      state.selection = Selection.single(path: [2], startOffset: 2);
      await tester.pump();
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '后文修改',
          selection: TextSelection.collapsed(offset: 4),
        ),
      );
      await tester.pumpAndSettle();
      expect(adapter.blocks.last.text, '后文修改');
      expect(changes.last[1].blockType, csesUnsupportedBlockType);
      expect(changes.last[1].text, isEmpty);
      final changeCount = changes.length;
      await tester.tap(find.byKey(const ValueKey('editor-mode-toggle')));
      await tester.pumpAndSettle();
      expect(state.editable, isFalse);
      await adapter.replaceFromRemote(const [
        CollabEditorBlock(id: 'before', blockType: 'paragraph', text: '远端前文'),
        CollabEditorBlock(
          id: 'unknown',
          blockType: csesUnsupportedBlockType,
          text: '',
        ),
        CollabEditorBlock(id: 'after', blockType: 'paragraph', text: '后文修改'),
      ]);
      await tester.pumpAndSettle();
      expect(adapter.blocks.first.text, '远端前文');
      expect(state.editable, isFalse);
      expect(changes.length, changeCount);
      await tester.tap(find.byKey(const ValueKey('editor-mode-toggle')));
      await tester.pumpAndSettle();
      expect(state.editable, isTrue);
      state.selection = Selection.single(path: [0], startOffset: 4);
      await tester.pump();
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '远端前文修改',
          selection: TextSelection.collapsed(offset: 6),
        ),
      );
      await tester.pumpAndSettle();
      expect(adapter.blocks.first.text, '远端前文修改');
      expect(adapter.blocks[1].blockType, csesUnsupportedBlockType);
      expect(find.text('未适配的块（不可编辑）'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'desktop quote background and border render in edit and preview',
    (tester) async {
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: const [
          CollabEditorBlock(
            id: 'quote',
            blockType: 'quote',
            text: '引用正文',
            blockBackgroundColor: '#ffecdf',
            blockBorderColor: 'rgba(255, 0, 0, 0.5)',
          ),
        ],
        onLocalBlocksChanged: (_) {},
      );
      addTearDown(adapter.dispose);
      final collab = _ReadyCollabController(
        testEditorState: adapter.editorState,
      );
      addTearDown(collab.dispose);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            AppFlowyEditorLocalizations.delegate,
          ],
          home: CollaborativeEditorPage(collab: collab),
        ),
      );
      await tester.pumpAndSettle();
      void expectColors() {
        final border = tester.widget<Container>(
          find.byKey(const ValueKey('collab-quote-border')),
        );
        expect(border.color, const Color.fromRGBO(255, 0, 0, 0.5));
        final containers = tester.widgetList<Container>(
          find.descendant(
            of: find.byType(QuoteBlockComponentWidget),
            matching: find.byType(Container),
          ),
        );
        expect(
          containers.any(
            (c) =>
                c.decoration is BoxDecoration &&
                (c.decoration! as BoxDecoration).color ==
                    const Color(0xffffecdf),
          ),
          isTrue,
        );
        expect(tester.takeException(), isNull);
      }

      expectColors();
      await tester.tap(find.byKey(const ValueKey('editor-mode-toggle')));
      await tester.pumpAndSettle();
      expectColors();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('alignment switches keep the live paragraph caret and text', (
    tester,
  ) async {
    final adapter = AppFlowyBlockEditorAdapter(
      initialBlocks: const [
        CollabEditorBlock(id: 'p', blockType: 'paragraph', text: '切换对齐方式'),
      ],
      onLocalBlocksChanged: (_) {},
    );
    addTearDown(adapter.dispose);
    final collab = _ReadyCollabController(testEditorState: adapter.editorState);
    addTearDown(collab.dispose);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          AppFlowyEditorLocalizations.delegate,
        ],
        home: CollaborativeEditorPage(collab: collab),
      ),
    );
    await tester.pumpAndSettle();
    final state = adapter.editorState;
    final node = state.document.first!;
    state.selection = Selection.single(path: [0], startOffset: 3);
    for (final mode in ['distributed', 'justify', 'left', 'distributed']) {
      await state.apply(
        state.transaction..updateNode(node, {blockComponentAlign: mode}),
        withUpdateSelection: false,
      );
      await tester.pumpAndSettle();
      expect(state.selection?.startIndex, 3);
      expect(
        node.selectable!.getCursorRectInPosition(
          Position(path: [0], offset: 3),
        ),
        isNotNull,
      );
      expect(adapter.blocks.single.text, '切换对齐方式');
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final alignment in ['justify', 'distributed']) {
    for (final type in [
      'paragraph',
      'heading_2',
      'quote',
      'bulleted_list',
      'numbered_list',
      'todo_list',
    ]) {
      testWidgets(
        '$type renders $alignment and preserves selection in preview',
        (tester) async {
          final adapter = AppFlowyBlockEditorAdapter(
            initialBlocks: [
              CollabEditorBlock(
                id: 'text',
                blockType: type,
                text: '测试段落的对齐方式',
                alignment: alignment,
              ),
            ],
            onLocalBlocksChanged: (_) {},
          );
          addTearDown(adapter.dispose);
          final collab = _ReadyCollabController(
            testEditorState: adapter.editorState,
          );
          addTearDown(collab.dispose);
          await tester.pumpWidget(
            MaterialApp(
              localizationsDelegates: const [
                GlobalMaterialLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                AppFlowyEditorLocalizations.delegate,
              ],
              home: CollaborativeEditorPage(collab: collab),
            ),
          );
          await tester.pumpAndSettle();
          void expectLayout() {
            final richText = tester.widget<AppFlowyRichText>(
              find.byType(AppFlowyRichText),
            );
            expect(richText.textAlign, TextAlign.justify);
            final texts = tester.widgetList<RichText>(
              find.descendant(
                of: find.byType(AppFlowyRichText),
                matching: find.byType(RichText),
              ),
            );
            final rendered = texts.firstWhere(
              (t) => t.text.toPlainText() == '测试段落的对齐方式',
            );
            expect(rendered.text.toPlainText(), adapter.blocks.single.text);
            final caret = adapter.editorState.document.first!.selectable!
                .getCursorRectInPosition(Position(path: [0], offset: 3));
            expect(caret, isNotNull);
            expect(caret!.left.isFinite, isTrue);
            expect(tester.takeException(), isNull);
          }

          expectLayout();
          await tester.tap(find.byKey(const ValueKey('editor-mode-toggle')));
          await tester.pumpAndSettle();
          expectLayout();
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }

  for (final blockType in [
    ParagraphBlockKeys.type,
    NumberedListBlockKeys.type,
    BulletedListBlockKeys.type,
    TodoListBlockKeys.type,
  ]) {
    testWidgets('$blockType rows stay compact in edit and preview', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: [
          for (var i = 0; i < 6; i++)
            CollabEditorBlock(id: 'row-$i', blockType: blockType, text: '$i'),
        ],
        onLocalBlocksChanged: (_) {},
      );
      addTearDown(adapter.dispose);
      final collab = _ReadyCollabController(
        testEditorState: adapter.editorState,
      );
      addTearDown(collab.dispose);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            AppFlowyEditorLocalizations.delegate,
          ],
          home: CollaborativeEditorPage(collab: collab),
        ),
      );
      await tester.pumpAndSettle();

      void expectCompactRows() {
        final nodes = adapter.editorState.document.root.children;
        for (var i = 1; i < nodes.length; i++) {
          final previous = tester.getTopLeft(find.byKey(nodes[i - 1].key));
          final current = tester.getTopLeft(find.byKey(nodes[i].key));
          // Measure rendered positions: page padding must not repeat per row.
          expect(current.dy - previous.dy, inInclusiveRange(20, 32));
        }
        expect(tester.takeException(), isNull);
      }

      expectCompactRows();
      await tester.tap(find.byKey(const ValueKey('editor-mode-toggle')));
      await tester.pumpAndSettle();
      expectCompactRows();
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
    'formal cover fills page width; centered controls overlay image and icon crosses its bottom',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: const [
          CollabEditorBlock(id: 'body', blockType: 'paragraph', text: '正文'),
        ],
        onLocalBlocksChanged: (_) {},
      );
      final header = DocumentMetadataController(
        documentId: 'doc',
        service: _HeaderService(),
        canEdit: () => true,
      );
      await header.refresh();
      final collab = _ReadyCollabController(
        testEditorState: adapter.editorState,
        testHeader: header,
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        collab.dispose();
        adapter.dispose();
        await tester.binding.setSurfaceSize(null);
      });
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            AppFlowyEditorLocalizations.delegate,
          ],
          home: CollaborativeEditorPage(collab: collab),
        ),
      );
      await tester.pumpAndSettle();
      final cover = tester.getRect(
        find.byKey(const ValueKey('document-banner-image')),
      );
      expect(cover.left, 0);
      expect(cover.right, 390);
      final controls = tester.getRect(
        find.byKey(const ValueKey('document-banner-actions')),
      );
      expect(controls.center.dx, closeTo(cover.center.dx, 0.5));
      expect(controls.center.dy, closeTo(cover.center.dy, 0.5));
      for (final key in [
        'document-banner-edit',
        'document-banner-remove',
        'document-banner-position',
      ]) {
        final bounds = tester.getRect(find.byKey(ValueKey(key)));
        expect(cover.contains(bounds.topLeft), isTrue);
        expect(cover.contains(bounds.bottomRight), isTrue);
      }
      final icon = tester.getRect(
        find.byKey(const ValueKey('document-icon-edit')),
      );
      expect(icon.left, 20);
      expect(icon.top, closeTo(cover.bottom - 32, 0.5));
      expect(icon.bottom, closeTo(cover.bottom + 16, 0.5));
      final title = tester.getRect(
        find.descendant(
          of: find.byKey(const ValueKey('formal-document-header')),
          matching: find.text(header.value!.name),
        ),
      );
      expect(title.left, 20);
      expect(title.top, greaterThan(icon.bottom));
      final body = tester.getRect(
        find.byKey(adapter.editorState.document.first!.key),
      );
      expect(body.left, 20);
      await tester.tap(find.byKey(const ValueKey('editor-mode-toggle')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('document-banner-actions')),
        findsNothing,
      );
      expect(
        tester.getRect(find.byKey(const ValueKey('document-banner-image'))),
        cover,
      );
      expect(
        tester.getRect(find.byKey(const ValueKey('document-icon-edit'))),
        icon,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('standalone page owns the full-screen editor UI', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final collab = _ReadyCollabController();
    addTearDown(collab.dispose);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          AppFlowyEditorLocalizations.delegate,
        ],
        home: CollaborativeEditorPage(collab: collab),
      ),
    );

    expect(
      find.byKey(const ValueKey('collaborative-editor-page')),
      findsOneWidget,
    );
    expect(find.byType(AppFlowyEditor), findsOneWidget);
    final editor = tester.widget<AppFlowyEditor>(find.byType(AppFlowyEditor));
    expect(editor.characterShortcutEvents.first, same(collabParagraphEnter));
    expect(editor.characterShortcutEvents[1], same(collabCodeEnter));
    expect(editor.shrinkWrap, isFalse);
    expect(editor.blockComponentBuilders, contains(csesCodeBlockType));
    // Link and video are custom components; image remains available through
    // AppFlowy's standard builder map. All three must render in both modes.
    expect(editor.blockComponentBuilders, contains(csesLinkBlockType));
    expect(editor.blockComponentBuilders, contains(csesVideoBlockType));
    expect(editor.blockComponentBuilders, contains(ImageBlockKeys.type));
    expect(editor.blockComponentBuilders, isNot(contains('document_cover')));
    expect(editor.blockComponentBuilders, isNot(contains('document_title')));
    expect(editor.header, isNull); // 本地草稿只显示正文。
    expect(editor.footer, isNull); // 未启用时整区隐藏。
    expect(
      find.byKey(const ValueKey('document-feedback-footer')),
      findsNothing,
    );
    expect(
      editor.commandShortcutEvents.first,
      same(collabBlockBackspaceCommand),
    );
    expect(
      find.byKey(const ValueKey('collaborative-appflowy-editor')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('editor-undo')), findsOneWidget);
    expect(find.byKey(const ValueKey('editor-redo')), findsOneWidget);
    expect(find.byKey(const ValueKey('editor-mode-toggle')), findsOneWidget);
    expect(find.text('预览'), findsOneWidget);
    expect(find.byKey(const ValueKey('editor-connection-bar')), findsOneWidget);
    expect(collab.editorState.editable, isTrue);
    expect(tester.takeException(), isNull);

    collab.editorState.selection = Selection.single(path: [0], startOffset: 0);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('editor-mode-toggle')));
    await tester.pumpAndSettle();

    expect(collab.editorState.editable, isFalse);
    expect(collab.editorState.selection, isNull);
    expect(find.text('编辑'), findsOneWidget);
    expect(find.byKey(const ValueKey('editor-undo')), findsNothing);
    expect(find.byKey(const ValueKey('editor-redo')), findsNothing);
    expect(find.byType(EditorShortcutToolbar), findsNothing);
    expect(find.byType(AppFlowyEditor), findsOneWidget);
    expect(
      tester.widget<AppFlowyEditor>(find.byType(AppFlowyEditor)).editable,
      isFalse,
    );
    expect(
      tester
          .widget<AppFlowyEditor>(find.byType(AppFlowyEditor))
          .disableKeyboardService,
      isTrue,
    );

    await tester.tap(find.byKey(const ValueKey('editor-mode-toggle')));
    await tester.pumpAndSettle();

    expect(collab.editorState.editable, isTrue);
    expect(find.text('预览'), findsOneWidget);
    expect(find.byKey(const ValueKey('editor-undo')), findsOneWidget);
    expect(find.byKey(const ValueKey('editor-redo')), findsOneWidget);
    expect(find.byType(EditorShortcutToolbar), findsOneWidget);
    expect(
      tester
          .widget<AppFlowyEditor>(find.byType(AppFlowyEditor))
          .disableKeyboardService,
      isFalse,
    );

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'remote read-only capability disables all editing and preserves preview choice',
    (tester) async {
      final collab = _ReadyCollabController();
      addTearDown(collab.dispose);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            AppFlowyEditorLocalizations.delegate,
          ],
          home: CollaborativeEditorPage(collab: collab),
        ),
      );
      collab.setReadOnlyReason('包含锁定块');
      await tester.pumpAndSettle();
      expect(collab.editorState.editable, isFalse);
      expect(find.text('只读：包含锁定块'), findsOneWidget);
      expect(find.byType(EditorShortcutToolbar), findsNothing);
      expect(find.byKey(const ValueKey('editor-undo')), findsNothing);
      expect(
        tester
            .widget<TextButton>(
              find.byKey(const ValueKey('editor-mode-toggle')),
            )
            .onPressed,
        isNull,
      );
      collab.setReadOnlyReason(null);
      await tester.pumpAndSettle();
      expect(collab.editorState.editable, isTrue);
      await tester.tap(find.byKey(const ValueKey('editor-mode-toggle')));
      await tester.pumpAndSettle();
      collab.setReadOnlyReason('包含锁定块');
      collab.setReadOnlyReason(null);
      await tester.pumpAndSettle();
      expect(collab.editorState.editable, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(collab.hasPageListeners, isFalse);
    },
  );
}

/// 不加载原生库的页面宿主 Fake；只模拟已初始化文档的能力变化。
class _ReadyCollabController extends CollabController {
  /// [testEditorState]借用正文，[testHeader]借用头部，null使用默认空正文/无头部。
  /// [services]注入宿主展示配置和事件；均不加载原生库。
  _ReadyCollabController({
    this.testEditorState,
    this.testHeader,
    super.services,
  }) : super.localDraft(databasePath: '/unused');

  /// 可选借用的正文，由测试创建者释放。
  final EditorState? testEditorState;

  /// 可选借用的业务头部，由测试创建者释放。
  final DocumentMetadataController? testHeader;

  /// 使用测试头部替代原生正式文档初始化。
  @override
  DocumentMetadataController? get header => testHeader;

  @override
  EditorState get editorState => testEditorState ?? super.editorState;

  String? _reason;

  /// 页面卸载后不应再持有模式监听，测试通过子类访问受保护状态。
  bool get hasPageListeners => hasListeners;

  /// 页面测试的离线文档已加载。
  @override
  bool get initialized => true;

  /// 模拟 Rust 返回的只读原因，null 表示结构可编辑。
  @override
  String? get readOnlyReason => _reason;

  /// 文档能力由测试持有，不访问全局 Rust 引擎。
  @override
  bool get canEdit => _reason == null;

  /// 发布 [reason] 的能力变化；null 恢复编辑，已有预览选择由页面保留。
  void setReadOnlyReason(String? reason) {
    _reason = reason;
    notifyListeners();
  }
}

/// 头部几何测试借用的业务数据；不进行 HTTP 或原生读写。
class _HeaderService implements DocumentMetadataService {
  /// 用固定测试数据读取 [documentId] 的业务头部；不发请求或拥有编辑器资源。
  @override
  Future<DocumentMetadata> load(String documentId) async => DocumentMetadata(
    id: documentId,
    name: '正式标题',
    icon: {'type': 'emoji', 'value': '📚'},
    banner: {'url': 'https://example.test/cover.png', 'y': 30},
    canRename: true,
    canChangeAppearance: true,
  );

  /// 接受测试文档 [documentId] 的 [patch] 作为成功ACK，不写任何共享数据。
  @override
  Future<void> update(String documentId, DocumentMetadataPatch patch) async {}
}
