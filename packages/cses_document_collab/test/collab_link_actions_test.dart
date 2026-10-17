import 'package:cses_document_collab/src/editor/collab_link_preview.dart';
import 'package:cses_document_collab/src/editor/collab_embedded_page.dart';
import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/editor/collab_link_actions.dart';
import 'package:cses_document_collab/src/editor/collab_callout_block.dart';
import 'package:cses_document_collab/src/editor/collab_audio_block.dart';
import 'package:cses_document_collab/src/editor/collab_attachment_block.dart';
import 'package:cses_document_collab/src/editor/collab_web_block.dart';
import 'package:cses_document_collab/src/model/collab_resource.dart';
import 'package:cses_document_collab/src/model/collab_host_services.dart';
import 'package:cses_document_collab/src/native/collab_runtime.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:metalink/metalink.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import 'support/fake_link_web_platform.dart';

/// Returns metadata from fixture HTML for original [url], without external requests.
Future<ExtractionResult<LinkMetadata>> _metadata(String url) => MetaLinkParser()
    .parseHtml('<head><title>预览标题</title></head>', documentUrl: Uri.parse(url));

/// Returns the real mobile decorator with whole-link actions for borrowed inputs.
/// [context]/[node] identify the editor, [index]/[text] identify the run,
/// [before]/[after] provide the upstream text formatting.
InlineSpan _decorate(
  BuildContext context,
  Node node,
  int index,
  TextInsert text,
  TextSpan before,
  TextSpan after,
) => decorateCollabLinkSpan(
  context,
  node,
  mobileTextSpanDecoratorForAttribute(
    context,
    node,
    index,
    text,
    before,
    after,
  ),
);

/// Returns an editor borrowing [adapter], with production link/card/frame renderers.
/// [keyboard] enables the real input connection for insertion/focus checks.
Widget _app(AppFlowyBlockEditorAdapter adapter, {bool keyboard = false}) =>
    MaterialApp(
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        AppFlowyEditorLocalizations.delegate,
      ],
      home: Scaffold(
        body: AppFlowyEditor(
          editorState: adapter.editorState,
          editable: adapter.editorState.editable,
          disableKeyboardService: !keyboard,
          editorStyle: const EditorStyle.mobile(textSpanDecorator: _decorate),
          blockComponentBuilders: {
            ...standardBlockComponentBuilderMap,
            'callout': CollabCalloutBlockComponentBuilder(),
            'audio': CollabAudioBlockComponentBuilder(),
            'attachment': CollabAttachmentBlockComponentBuilder(),
            for (final kind in [
              'bookmark',
              'embed',
              'juejin-embed',
              'figma-embed',
            ])
              kind: CollabWebBlockComponentBuilder(loadPreview: _metadata),
          },
        ),
      ),
    );

/// Opens a view menu through the visible link or resource button using [tester]/[adapter].
Future<void> _open(
  WidgetTester tester,
  AppFlowyBlockEditorAdapter adapter,
) async {
  if (adapter.blocks.first.blockType == 'paragraph') {
    final text = find.text(adapter.blocks.first.text, findRichText: true).last;
    final paragraph = tester.renderObject<RenderParagraph>(text);
    final box = paragraph
        .getBoxesForSelection(
          const TextSelection(baseOffset: 2, extentOffset: 3),
        )
        .first;
    await tester.tapAt(paragraph.localToGlobal(box.toRect().center));
  } else {
    await tester.tap(
      find.byKey(ValueKey('resource-more-${adapter.blocks.first.id}')),
    );
  }
  await tester.pumpAndSettle();
}

/// Creates a sole link of [kind]; [inCallout] nests it in a supported container.
/// The original URL remains identical in card, embed and whole-link paragraph form.
AppFlowyBlockEditorAdapter _adapter(String kind, {bool inCallout = false}) {
  final url = switch (kind) {
    'figma-embed' => 'https://www.figma.com/design/x',
    'juejin-embed' => 'https://juejin.cn/post/123',
    _ => 'https://example.test/page',
  };
  return AppFlowyBlockEditorAdapter(
    initialBlocks: [
      if (inCallout)
        const CollabEditorBlock(
          id: 'container',
          blockType: 'callout',
          text: '',
        ),
      CollabEditorBlock(
        id: 'resource',
        parentId: inCallout ? 'container' : null,
        blockType: kind,
        text: url,
        segments: kind == 'paragraph'
            ? [CollabEditorTextSegment(text: url, href: url)]
            : const [],
        resource: kind == 'paragraph' ? null : const CollabResource(),
      ),
    ],
    onLocalBlocksChanged: (_) {},
  );
}

/// Verifies actions, input restoration and conflict checks across sheet dismissal.
void main() {
  setUp(() {
    WebViewPlatform.instance = FakeLinkWebPlatform();
  });
  for (final kind in [
    'bookmark',
    'embed',
    'figma-embed',
    'juejin-embed',
    'paragraph',
  ]) {
    testWidgets(
      '$kind copies the original URL without document/history edits',
      (tester) async {
        final adapter = _adapter(kind);
        addTearDown(adapter.dispose);
        final calls = <MethodCall>[];
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            calls.add(call);
            return null;
          },
        );
        await tester.pumpWidget(_app(adapter));
        await tester.pumpAndSettle();
        await _open(tester, adapter);
        await tester.tap(find.byKey(const ValueKey('link-copy')));
        await tester.pumpAndSettle();
        final copied = calls
            .where((call) => call.method == 'Clipboard.setData')
            .single;
        expect(copied.arguments, {'text': adapter.blocks.single.text});
        expect(adapter.blocks.single.id, 'resource');
        expect(adapter.editorState.undoManager.undoStack, isEmpty);
        expect(find.text('链接已复制'), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );

    testWidgets(
      '$kind inserts below a final block, focuses and supports undo/redo',
      (tester) async {
        final adapter = _adapter(kind);
        addTearDown(adapter.dispose);
        final state = adapter.editorState;
        await tester.pumpWidget(_app(adapter, keyboard: true));
        await tester.pumpAndSettle();
        await _open(tester, adapter);
        expect(tester.testTextInput.hasAnyClients, isFalse);
        await tester.tap(find.byKey(const ValueKey('link-insert-below')));
        await tester.pumpAndSettle();
        expect(adapter.blocks.length, 2);
        expect(adapter.blocks.first.id, 'resource');
        expect(adapter.blocks.last.blockType, 'paragraph');
        expect(adapter.blocks.last.text, isEmpty);
        expect(state.selection, Selection.single(path: [1], startOffset: 0));
        expect(tester.testTextInput.hasAnyClients, isTrue);
        expect(tester.testTextInput.isVisible, isTrue);
        state.undoManager.undo();
        await tester.pumpAndSettle();
        expect(adapter.blocks.length, 1);
        state.undoManager.redo();
        await tester.pumpAndSettle();
        expect(adapter.blocks.length, 2);
        expect(adapter.blocks.last.text, isEmpty);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'inserted paragraph accepts real input after an existing body selection',
    (tester) async {
      final adapter = _adapter('bookmark');
      addTearDown(adapter.dispose);
      final state = adapter.editorState;
      await state.apply(
        state.transaction..insertNode([0], paragraphNode(text: '原正文')),
      );
      await tester.pumpWidget(_app(adapter, keyboard: true));
      await tester.pumpAndSettle();
      final selection = state.updateSelectionWithReason(
        Selection.single(path: [0], startOffset: 1),
        reason: SelectionUpdateReason.uiEvent,
      );
      await tester.pumpAndSettle();
      await selection;
      await tester.tap(find.byKey(const ValueKey('resource-more-resource')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('link-insert-below')));
      await tester.pumpAndSettle();
      expect(state.selection, Selection.single(path: [2], startOffset: 0));
      final editing = TextEditingValue.fromJSON(
        tester.testTextInput.editingState!,
      );
      final offset = editing.selection.extentOffset;
      tester.testTextInput.updateEditingValue(
        editing.copyWith(
          text: editing.text.replaceRange(offset, offset, '继续输入'),
          selection: TextSelection.collapsed(offset: offset + 4),
        ),
      );
      await tester.pumpAndSettle();
      expect(adapter.blocks.first.text, '原正文');
      expect(adapter.blocks.last.text, '继续输入');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('insert below follows a remotely reordered card', (tester) async {
    final adapter = _adapter('bookmark');
    addTearDown(adapter.dispose);
    await tester.pumpWidget(_app(adapter));
    await tester.pumpAndSettle();
    await _open(tester, adapter);
    await adapter.replaceFromRemote([
      const CollabEditorBlock(id: 'body', blockType: 'paragraph', text: '远端正文'),
      adapter.blocks.single,
    ]);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('link-insert-below')));
    await tester.pumpAndSettle();
    expect(adapter.blocks.map((block) => block.text), [
      '远端正文',
      'https://example.test/page',
      '',
    ]);
    expect(
      adapter.editorState.selection,
      Selection.single(path: [2], startOffset: 0),
    );
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('insert below keeps the new paragraph inside its callout', (
    tester,
  ) async {
    final adapter = _adapter('bookmark', inCallout: true);
    addTearDown(adapter.dispose);
    await tester.pumpWidget(_app(adapter));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('resource-more-resource')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('link-insert-below')));
    await tester.pumpAndSettle();
    expect(adapter.blocks.length, 3);
    expect(adapter.blocks.last.parentId, 'container');
    expect(
      adapter.editorState.selection,
      Selection.single(path: [0, 1], startOffset: 0),
    );
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final mutation in ['url', 'delete', 'readonly', 'session']) {
    testWidgets('$mutation during an open sheet prevents insertion', (
      tester,
    ) async {
      final adapter = _adapter('bookmark');
      addTearDown(adapter.dispose);
      await tester.pumpWidget(_app(adapter));
      await tester.pumpAndSettle();
      await _open(tester, adapter);
      if (mutation == 'readonly') {
        adapter.editorState.editable = false;
      } else if (mutation == 'session') {
        final owner = Object();
        CollabRuntime.acquire(
          owner,
          CollabHostServices(onError: (_, _, _, _) {}),
        );
        addTearDown(() => CollabRuntime.release(owner));
      } else {
        await adapter.replaceFromRemote([
          CollabEditorBlock(
            id: mutation == 'delete' ? 'body' : 'resource',
            blockType: mutation == 'delete' ? 'paragraph' : 'bookmark',
            text: 'https://example.test/remote',
            resource: mutation == 'delete' ? null : const CollabResource(),
          ),
        ]);
      }
      await tester.tap(find.byKey(const ValueKey('link-insert-below')));
      await tester.pumpAndSettle();
      expect(adapter.blocks.length, 1);
      expect(adapter.editorState.undoManager.undoStack, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
    'readonly whole-link paragraphs allow copying but hide insertion and conversion',
    (tester) async {
      final adapter = _adapter('paragraph');
      addTearDown(adapter.dispose);
      adapter.editorState.editable = false;
      await tester.pumpWidget(_app(adapter));
      await tester.pumpAndSettle();
      await _open(tester, adapter);
      expect(find.byKey(const ValueKey('link-copy')), findsOneWidget);
      expect(find.byKey(const ValueKey('link-insert-below')), findsNothing);
      expect(find.byKey(const ValueKey('link-view-card')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('link-copy')));
      await tester.pumpAndSettle();
      expect(adapter.editorState.undoManager.undoStack, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('clipboard failures leave document intact and allow retry', (
    tester,
  ) async {
    final adapter = _adapter('bookmark');
    addTearDown(adapter.dispose);
    var fail = true;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData' && fail) {
          throw PlatformException(code: 'unavailable');
        }
        return null;
      },
    );
    await tester.pumpWidget(_app(adapter));
    await tester.pumpAndSettle();
    await _open(tester, adapter);
    await tester.tap(find.byKey(const ValueKey('link-copy')));
    await tester.pumpAndSettle();
    expect(find.text('操作失败，请重试'), findsOneWidget);
    expect(adapter.editorState.undoManager.undoStack, isEmpty);
    fail = false;
    await _open(tester, adapter);
    await tester.tap(find.byKey(const ValueKey('link-copy')));
    await tester.pumpAndSettle();
    expect(find.text('链接已复制'), findsOneWidget);
    expect(adapter.blocks.single.id, 'resource');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final kind in ['bookmark', 'embed', 'figma-embed', 'juejin-embed']) {
    testWidgets('$kind header observes readonly without replacing content', (
      tester,
    ) async {
      final adapter = _adapter(kind);
      addTearDown(adapter.dispose);
      await tester.pumpWidget(_app(adapter));
      await tester.pumpAndSettle();
      final node = adapter.editorState.document.first!;
      final content = find.byType(
        kind == 'bookmark' ? CollabLinkPreview : CollabEmbeddedPage,
      );
      final element = tester.element(content);
      expect(find.byTooltip('更多操作'), findsOneWidget);
      adapter.editorState.editable = false;
      await tester.pumpAndSettle();
      expect(find.byTooltip('更多操作'), findsNothing);
      expect(tester.element(content), same(element));
      adapter.editorState.editable = true;
      await tester.pumpAndSettle();
      expect(find.byTooltip('更多操作'), findsOneWidget);
      expect(adapter.editorState.document.first, same(node));
      expect(adapter.editorState.undoManager.undoStack, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final kind in ['bookmark', 'embed', 'figma-embed', 'juejin-embed']) {
    testWidgets(
      '$kind has one more button and edits/deletes through the menu',
      (tester) async {
        final adapter = _adapter(kind);
        addTearDown(adapter.dispose);
        final state = adapter.editorState;
        await tester.pumpWidget(_app(adapter));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('resource-more-resource')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('resource-open-resource')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('resource-view-resource')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('resource-edit-resource')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('resource-delete-resource')),
          findsNothing,
        );
        await _open(tester, adapter);
        expect(find.byKey(const ValueKey('link-copy')), findsOneWidget);
        expect(find.byKey(const ValueKey('link-insert-below')), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('resource-edit-resource')));
        await tester.pumpAndSettle();
        final updated = switch (kind) {
          'figma-embed' => 'https://www.figma.com/design/next',
          'juejin-embed' => 'https://juejin.cn/post/999',
          _ => 'https://example.test/edited',
        };
        await tester.enterText(
          find.byKey(const ValueKey('resource-field-url')),
          updated,
        );
        await tester.tap(find.text('保存'));
        await tester.pumpAndSettle();
        expect(adapter.blocks.single.text, updated);
        await _open(tester, adapter);
        await tester.tap(
          find.byKey(const ValueKey('resource-delete-resource')),
        );
        await tester.pumpAndSettle();
        expect(adapter.blocks.single.blockType, 'paragraph');
        expect(adapter.blocks.single.text, isEmpty);
        state.undoManager.undo();
        await tester.pumpAndSettle();
        expect(adapter.blocks.single.blockType, kind);
        expect(adapter.blocks.single.text, updated);
        state.undoManager.undo();
        await tester.pumpAndSettle();
        expect(adapter.blocks.single.text, isNot(updated));
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'menu deletion of a sole nested card preserves callout and undo',
    (tester) async {
      final adapter = _adapter('bookmark', inCallout: true);
      addTearDown(adapter.dispose);
      await tester.pumpWidget(_app(adapter));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('resource-more-resource')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('resource-delete-resource')));
      await tester.pumpAndSettle();
      expect(adapter.blocks.length, 2);
      expect(adapter.blocks.first.id, 'container');
      expect(adapter.blocks.last.blockType, 'paragraph');
      expect(adapter.blocks.last.parentId, 'container');
      expect(adapter.blocks.last.id, isNot('resource'));
      adapter.editorState.undoManager.undo();
      await tester.pumpAndSettle();
      expect(adapter.blocks.length, 2);
      expect(adapter.blocks.last.id, 'resource');
      expect(adapter.blocks.last.blockType, 'bookmark');
      expect(adapter.blocks.last.parentId, 'container');
      adapter.editorState.undoManager.redo();
      await tester.pumpAndSettle();
      expect(adapter.blocks.length, 2);
      expect(adapter.blocks.last.blockType, 'paragraph');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final action in ['edit', 'delete']) {
    for (final mutation in ['readonly', 'url', 'revokeRestore']) {
      testWidgets('$mutation prevents a stale menu $action operation', (
        tester,
      ) async {
        final adapter = _adapter('bookmark');
        addTearDown(adapter.dispose);
        await tester.pumpWidget(_app(adapter));
        await tester.pumpAndSettle();
        await _open(tester, adapter);
        if (mutation == 'url') {
          await adapter.replaceFromRemote([
            CollabEditorBlock(
              id: 'resource',
              blockType: 'bookmark',
              text: 'https://example.test/remote',
              resource: const CollabResource(),
            ),
          ]);
        } else {
          adapter.editorState.editable = false;
          if (mutation == 'revokeRestore') adapter.editorState.editable = true;
        }
        await tester.tap(find.byKey(ValueKey('resource-$action-resource')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('resource-field-url')), findsNothing);
        expect(adapter.blocks.single.blockType, 'bookmark');
        expect(adapter.editorState.undoManager.undoStack.isEmpty, isTrue);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }

  for (final kind in ['bookmark', 'figma-embed', 'juejin-embed']) {
    testWidgets('$kind exposes all views and whole-link text can switch back', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await tester.binding.setSurfaceSize(null);
        await tester.pumpAndSettle();
      });
      final url = kind == 'figma-embed'
          ? 'https://www.figma.com/design/x'
          : kind == 'juejin-embed'
          ? 'https://juejin.cn/post/123'
          : 'https://example.test/page';
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: [
          CollabEditorBlock(
            id: 'resource',
            blockType: kind,
            text: url,
            resource: const CollabResource(),
          ),
        ],
        onLocalBlocksChanged: (_) {},
      );
      addTearDown(adapter.dispose);
      await tester.pumpWidget(_app(adapter));
      await tester.pumpAndSettle();
      for (final mode in [
        'inline',
        'embed',
        'card',
        'inline',
        'card',
        'embed',
      ]) {
        await _open(tester, adapter);
        for (final option in ['inline', 'embed', 'card']) {
          expect(find.byKey(ValueKey('link-view-$option')), findsOneWidget);
        }
        await tester.tap(find.byKey(ValueKey('link-view-$mode')));
        await tester.pumpAndSettle();
        expect(adapter.blocks.single.blockType, switch (mode) {
          'inline' => 'paragraph',
          'card' => 'bookmark',
          _ => 'embed',
        });
        expect(adapter.blocks.single.text, url);
      }
      adapter.editorState.editable = false;
      await tester.pumpWidget(_app(adapter));
      await tester.pumpAndSettle();
      expect(find.byTooltip('切换视图'), findsNothing);
      expect(find.byTooltip('在浏览器打开'), findsNothing);
      expect(find.byTooltip('更多操作'), findsNothing);
      expect(find.byKey(const ValueKey('link-copy')), findsNothing);
      expect(find.byKey(const ValueKey('link-view-card')), findsNothing);
      expect(
        find.byKey(ValueKey('resource-delete-${adapter.blocks.first.id}')),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final mutation in ['url', 'delete', 'readonly']) {
    testWidgets('$mutation during an open sheet prevents conversion', (
      tester,
    ) async {
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: [
          CollabEditorBlock(
            id: 'resource',
            blockType: 'bookmark',
            text: 'https://example.test/a',
            resource: const CollabResource(),
          ),
        ],
        onLocalBlocksChanged: (_) {},
      );
      addTearDown(adapter.dispose);
      await tester.pumpWidget(_app(adapter));
      await tester.pumpAndSettle();
      await _open(tester, adapter);
      if (mutation == 'readonly') {
        adapter.editorState.editable = false;
      } else {
        await adapter.replaceFromRemote(
          mutation == 'url'
              ? [
                  CollabEditorBlock(
                    id: 'resource',
                    blockType: 'bookmark',
                    text: 'https://example.test/remote',
                    resource: const CollabResource(),
                  ),
                ]
              : [
                  const CollabEditorBlock(
                    id: 'body',
                    blockType: 'paragraph',
                    text: '正文',
                  ),
                ],
        );
      }
      await tester.tap(find.byKey(const ValueKey('link-view-embed')));
      await tester.pumpAndSettle();
      expect(
        adapter.blocks.single.blockType,
        mutation == 'delete' ? 'paragraph' : 'bookmark',
      );
      if (mutation == 'url') {
        expect(adapter.blocks.single.text, 'https://example.test/remote');
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
