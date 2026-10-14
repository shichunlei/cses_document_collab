import 'dart:async';
import 'package:cses_document_collab/src/editor/editor_media_source_sheet.dart';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/model/editor_media_upload.dart';
import 'package:cses_document_collab/src/editor/collab_embed_block.dart';
import 'package:cses_document_collab/src/editor/editor_shortcut_toolbar.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

const _a = CollabEditorBlock(id: 'a', blockType: 'paragraph', text: '第一段正文');
const _b = CollabEditorBlock(id: 'b', blockType: 'paragraph', text: '第二段正文');
const _remote = CollabEditorBlock(
  id: 'remote',
  blockType: 'paragraph',
  text: '远端插入',
);

class _PendingUpload extends EditorMediaUploadService {
  final pending = Completer<EditorMediaSource>();
  @override
  Future<EditorLocalFile?> pickFile(String kind) async => const EditorLocalFile(
    path: '/tmp/test.png',
    name: 'test.png',
    size: 100,
    mimeType: 'image/png',
  );
  @override
  Future<EditorMediaSource> upload(
    EditorLocalFile file,
    String kind, {
    required CancelToken cancelToken,
    required void Function(double) onProgress,
  }) => pending.future;
}

class _Harness {
  final adapter = AppFlowyBlockEditorAdapter(
    initialBlocks: [_a, _b],
    onLocalBlocksChanged: (_) {},
  );
  final focus = FocusNode(debugLabel: 'test body');
  late BuildContext context;
  EditorState get state => adapter.editorState;

  Future<void> mount(WidgetTester tester, {Selection? selection}) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      adapter.dispose();
      focus.dispose();
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
        home: Scaffold(
          body: Builder(
            builder: (context) {
              this.context = context;
              return MediaQuery(
                data: const MediaQueryData(
                  viewInsets: EdgeInsets.only(bottom: 300),
                ),
                child: EditorShortcutToolbar(
                  editorState: state,
                  child: AppFlowyEditor(
                    editorState: state,
                    focusNode: focus,
                    editorStyle: const EditorStyle.mobile(),
                    blockComponentBuilders: {
                      ...standardBlockComponentBuilderMap,
                      'image': CollabEmbedBlockComponentBuilder(
                        kind: CollabEmbedKind.image,
                      ),
                      csesLinkBlockType: CollabEmbedBlockComponentBuilder(
                        kind: CollabEmbedKind.link,
                      ),
                    },
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pump();
    final selected = state.updateSelectionWithReason(
      selection ?? Selection.single(path: [0], startOffset: 3),
      reason: SelectionUpdateReason.uiEvent,
    );
    await tester.pump();
    await selected;
    await tester.pump(const Duration(milliseconds: 150));
    expect(focus.hasFocus, isTrue);
  }
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 450));
  await tester.pump();
}

Future<void> _finishModal(WidgetTester tester, Future<void> modal) async {
  var finished = false;
  final observed = modal.whenComplete(() => finished = true);
  // Two route transitions, widget registration and the guarded Android retry.
  for (var i = 0; i < 16; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(finished, isTrue);
  await observed;
}

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
    'source input owns focus; cancel waits for dismissal and restores body caret',
    (tester) async {
      final h = _Harness();
      await h.mount(tester);
      final original = h.state.selection;
      h.state.selectionExtraInfo = {'origin': 'body'};
      h.state.updateToggledStyle(AppFlowyRichTextKeys.bold, true);
      final modal = showEditorUrlBlockDialog(h.context, h.state, 'image');
      await _settle(tester);
      expect(h.state.selection, isNull);
      expect(h.focus.hasFocus, isFalse);
      expect(tester.testTextInput.hasAnyClients, isFalse);
      final input = find.byKey(const ValueKey('editor-url-block-input'));
      await tester.tap(input);
      await tester.enterText(input, 'https://example.test/photo.png');
      await tester.pump(const Duration(milliseconds: 500));
      expect(h.focus.hasFocus, isFalse);
      expect(h.state.selection, isNull);
      expect(h.adapter.blocks.first.text, _a.text);
      await tester.tap(find.byKey(const ValueKey('editor-media-source-close')));
      await tester.pump();
      expect(
        h.focus.hasFocus,
        isFalse,
        reason: 'body remains suspended during the reverse transition',
      );
      await _settle(tester);
      await _finishModal(tester, modal);
      expect(h.state.selection, original);
      expect(h.focus.hasFocus, isTrue);
      expect(h.state.selectionExtraInfo, {'origin': 'body'});
      expect(h.state.toggledStyle[AppFlowyRichTextKeys.bold], isTrue);
      expect(h.adapter.blocks, [_a, _b]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'cancelling add sheet restores a directional range after remote reordering',
    (tester) async {
      final h = _Harness();
      await h.mount(
        tester,
        selection: Selection(
          start: Position(path: [1], offset: 4),
          end: Position(path: [0], offset: 2),
        ),
      );
      final modal = showEditorAddBlockSheet(h.context, h.state);
      await _settle(tester);
      expect(h.state.selection, isNull);
      expect(h.focus.hasFocus, isFalse);
      await h.adapter.replaceFromRemote([_remote, _a, _b]);
      await tester.pump();
      Navigator.pop(h.context);
      await _settle(tester);
      await _finishModal(tester, modal);
      expect(
        h.state.selection,
        Selection(
          start: Position(path: [2], offset: 4),
          end: Position(path: [1], offset: 2),
        ),
      );
      expect(h.focus.hasFocus, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'nested resource insertion follows the block saved before opening add menu',
    (tester) async {
      final h = _Harness();
      await h.mount(tester);
      final modal = showEditorAddBlockSheet(h.context, h.state);
      await _settle(tester);
      await h.adapter.replaceFromRemote([_remote, _a, _b]);
      await tester.pump();
      final link = find.byKey(const ValueKey('editor-shortcut-link-block'));
      await tester.ensureVisible(link);
      await tester.tap(link);
      await _settle(tester);
      await tester.enterText(
        find.byKey(const ValueKey('editor-url-block-input')),
        'https://example.test/page',
      );
      await tester.pump();
      expect(h.focus.hasFocus, isFalse);
      await tester.tap(find.byKey(const ValueKey('editor-url-block-submit')));
      await _settle(tester);
      await _settle(tester);
      await _finishModal(tester, modal);
      expect(h.adapter.blocks.map((b) => b.blockType), [
        'paragraph',
        'paragraph',
        'link',
        'paragraph',
        'paragraph',
      ]);
      expect(h.adapter.blocks[1].id, 'a');
      expect(h.adapter.blocks.last.id, 'b');
      expect(h.state.selection?.start.path, [3]);
      expect(h.focus.hasFocus, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'cancelling nested source keeps body blurred until parent menu closes',
    (tester) async {
      final h = _Harness();
      await h.mount(tester);
      final original = h.state.selection;
      final modal = showEditorAddBlockSheet(h.context, h.state);
      await _settle(tester);
      final link = find.byKey(const ValueKey('editor-shortcut-link-block'));
      await tester.ensureVisible(link);
      await tester.tap(link);
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('editor-media-source-close')));
      await _settle(tester);
      expect(
        find.byKey(const ValueKey('editor-add-block-sheet')),
        findsOneWidget,
      );
      expect(h.focus.hasFocus, isFalse);
      expect(h.state.selection, isNull);
      Navigator.pop(h.context);
      await _settle(tester);
      await _finishModal(tester, modal);
      expect(h.state.selection, original);
      expect(h.focus.hasFocus, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'pending local upload uses the original block after remote insertion',
    (tester) async {
      final h = _Harness();
      await h.mount(tester);
      final upload = _PendingUpload();
      final modal = showEditorUrlBlockDialog(
        h.context,
        h.state,
        'image',
        service: upload,
      );
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('editor-media-upload-tab')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('editor-media-pick-file')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('editor-url-block-submit')));
      await tester.pump();
      await h.adapter.replaceFromRemote([_remote, _a, _b]);
      await tester.pump();
      expect(h.state.selection, isNull);
      expect(h.focus.hasFocus, isFalse);
      upload.pending.complete(
        const EditorMediaSource('https://example.test/photo.png'),
      );
      await _settle(tester);
      await _finishModal(tester, modal);
      expect(h.adapter.blocks[1].id, 'a');
      expect(h.adapter.blocks[2].blockType, 'image');
      expect(h.state.selection?.start.path, [3]);
      expect(h.focus.hasFocus, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'deleted anchor prevents insertion and never focuses another paragraph',
    (tester) async {
      final h = _Harness();
      await h.mount(tester);
      final modal = showEditorUrlBlockDialog(
        h.context,
        h.state,
        csesLinkBlockType,
      );
      await _settle(tester);
      await h.adapter.replaceFromRemote([_b]);
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('editor-url-block-input')),
        'https://example.test/page',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('editor-url-block-submit')));
      await _settle(tester);
      await _finishModal(tester, modal);
      expect(h.adapter.blocks, [_b]);
      expect(h.state.selection, isNull);
      expect(h.focus.hasFocus, isFalse);
      expect(find.text('插入位置已变化，请重新选择正文位置'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'readonly while modal is open prevents cancellation from reopening body input',
    (tester) async {
      final h = _Harness();
      await h.mount(tester);
      final modal = showEditorUrlBlockDialog(h.context, h.state, 'image');
      await _settle(tester);
      h.state.editable = false;
      await tester.tap(find.byKey(const ValueKey('editor-media-source-close')));
      await _settle(tester);
      await _finishModal(tester, modal);
      expect(h.state.selection, isNull);
      expect(h.focus.hasFocus, isFalse);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('drag dismissal restores the original caret', (tester) async {
    final h = _Harness();
    await h.mount(tester);
    final original = h.state.selection;
    final modal = showEditorUrlBlockDialog(h.context, h.state, 'video');
    await _settle(tester);
    await tester.drag(find.byType(BottomSheet), const Offset(0, 600));
    await _finishModal(tester, modal);
    expect(h.state.selection, original);
    expect(h.focus.hasFocus, isTrue);
    expect(h.adapter.blocks, [_a, _b]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancel clamps the saved offset after remote text shortening', (
    tester,
  ) async {
    final h = _Harness();
    await h.mount(tester);
    final modal = showEditorUrlBlockDialog(h.context, h.state, 'audio');
    await _settle(tester);
    await h.adapter.replaceFromRemote([
      const CollabEditorBlock(id: 'a', blockType: 'paragraph', text: '短'),
      _b,
    ]);
    await tester.pump();
    Navigator.pop(h.context);
    await _finishModal(tester, modal);
    expect(h.state.selection, Selection.single(path: [0], startOffset: 1));
    expect(h.focus.hasFocus, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'business header action leaves body untouched and restores caret',
    (tester) async {
      final h = _Harness();
      await h.mount(tester);
      final original = h.state.selection;
      final modal = runEditorHeaderAction<void>(h.context, h.state, () async {
        await showEditorMediaSourceSheet(
          h.context,
          blockType: 'document_banner',
          canEdit: () => h.state.editable,
        );
      });
      await _settle(tester);
      expect(h.focus.hasFocus, isFalse);
      expect(h.state.selection, isNull);
      Navigator.pop(h.context);
      await _finishModal(tester, modal);
      expect(h.adapter.blocks, [_a, _b]);
      expect(h.state.selection, original);
      expect(h.focus.hasFocus, isTrue);
      expect(tester.takeException(), isNull);
    },
  );
}
