import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/editor/collab_link_actions.dart';
import 'package:cses_document_collab/src/editor/collab_resource_block.dart';
import 'package:cses_document_collab/src/model/collab_resource.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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

/// Returns an editor borrowing [adapter], with the production link/card/frame renderers.
Widget _app(AppFlowyBlockEditorAdapter adapter) => MaterialApp(
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
      disableKeyboardService: true,
      editorStyle: const EditorStyle.mobile(textSpanDecorator: _decorate),
      blockComponentBuilders: {
        ...standardBlockComponentBuilderMap,
        for (final type in collabResourceTypes)
          type: CollabResourceBlockComponentBuilder(loadPreview: _metadata),
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
      find.byKey(ValueKey('resource-view-${adapter.blocks.first.id}')),
    );
  }
  await tester.pumpAndSettle();
}

/// Verifies tap-driven switching and permission/conflict checks across action-sheet dismissal.
void main() {
  setUp(() {
    WebViewPlatform.instance = FakeLinkWebPlatform();
  });
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
      expect(find.byTooltip('在浏览器打开'), findsOneWidget);
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
