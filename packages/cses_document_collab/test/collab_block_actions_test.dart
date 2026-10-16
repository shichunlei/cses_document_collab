import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/editor/collab_block_actions.dart';
import 'package:cses_document_collab/src/editor/collab_callout_block.dart';
import 'package:cses_document_collab/src/editor/collab_code_block.dart';
import 'package:cses_document_collab/src/editor/collab_embed_block.dart';
import 'package:cses_document_collab/src/editor/collab_formula_block.dart';
import 'package:cses_document_collab/src/editor/collab_meeting_block.dart';
import 'package:cses_document_collab/src/editor/collab_resource_block.dart';
import 'package:cses_document_collab/src/editor/collab_task_card_block.dart';
import 'package:cses_document_collab/src/model/collab_image.dart';
import 'package:cses_document_collab/src/model/collab_host_services.dart';
import 'package:cses_document_collab/src/native/collab_runtime.dart';
import 'package:cses_document_collab/src/model/collab_resource.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

/// Fails media initialization locally, exercising menus even when media is unavailable.
class _UnavailableVideo extends VideoPlayerPlatform {
  /// Initializes the fixture without a native channel.
  @override
  Future<void> init() async {}

  /// Rejects borrowed [options]; no native player or stream is allocated.
  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async =>
      throw StateError('fixture offline');
}

/// Creates a final block of [kind]; [nested] places it inside a callout.
/// Callout/table fixtures retain editable children to verify sibling insertion.
List<CollabEditorBlock> _blocks(String kind, {bool nested = false}) => [
  if (nested)
    const CollabEditorBlock(id: 'outer', blockType: 'callout', text: ''),
  CollabEditorBlock(
    id: 'card',
    blockType: kind,
    parentId: nested ? 'outer' : null,
    text: kind == 'code'
        ? '原代码'
        : const {'image', 'video', 'audio', 'attachment'}.contains(kind)
        ? 'https://example.test/resource'
        : '',
    image: kind == 'image' ? const CollabImage(widthRatio: 60) : null,
    resource: CollabResource.fromValues(switch (kind) {
      'task' => {'taskId': 't1', 'title': '任务'},
      'meeting' => {'meetingId': 'm1', 'title': '会议'},
      'formula' => {'latex': 'x^2'},
      _ => {},
    }),
  ),
  if (kind == 'callout')
    const CollabEditorBlock(
      id: 'child',
      parentId: 'card',
      blockType: 'paragraph',
      text: '块内原正文',
    ),
];

/// Builds the real renderers with a real input service for borrowed [adapter].
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
      editorStyle: const EditorStyle.mobile(),
      blockComponentBuilders: {
        ...standardBlockComponentBuilderMap,
        'callout': CollabCalloutBlockComponentBuilder(),
        'task': CollabTaskCardBlockComponentBuilder(),
        'meeting': CollabMeetingBlockComponentBuilder(),
        'code': CollabCodeBlockComponentBuilder(),
        'formula': CollabFormulaBlockComponentBuilder(),
        'image': CollabEmbedBlockComponentBuilder(kind: CollabEmbedKind.image),
        'video': CollabEmbedBlockComponentBuilder(kind: CollabEmbedKind.video),
        for (final type in ['attachment', 'audio'])
          type: CollabResourceBlockComponentBuilder(),
      },
    ),
  ),
);

/// Mounts borrowed [adapter] on a phone surface using [tester]; restores its size on teardown.
Future<void> _mount(
  WidgetTester tester,
  AppFlowyBlockEditorAdapter adapter,
) async {
  await tester.binding.setSurfaceSize(const Size(390, 844));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(_app(adapter));
}

/// Exercises each production menu, input, undo and stale-target protections.
void main() {
  setUp(() {
    final previous = VideoPlayerPlatform.instance;
    VideoPlayerPlatform.instance = _UnavailableVideo();
    addTearDown(() => VideoPlayerPlatform.instance = previous);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
          const EventChannel('keyboardHeightEventChannel'),
          MockStreamHandler.inline(
            onListen: (_, events) => events.success(0.0),
          ),
        );
  });

  for (final kind in [
    'callout',
    'meeting',
    'task',
    'image',
    'video',
    'audio',
    'attachment',
    'formula',
    'code',
  ]) {
    testWidgets(
      '$kind production more menu inserts an editable final sibling',
      (tester) async {
        final original = _blocks(kind);
        final adapter = AppFlowyBlockEditorAdapter(
          initialBlocks: original,
          onLocalBlocksChanged: (_) {},
        );
        addTearDown(adapter.dispose);
        final state = adapter.editorState;
        await _mount(tester, adapter);
        await tester.pumpAndSettle();
        final snapshot = state.document.first!.toJson();
        final more = find.byKey(
          ValueKey(kind == 'task' ? 'task-card-more-card' : 'block-more-card'),
        );
        await tester.ensureVisible(more);
        await tester.tap(more);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('block-insert-below-card')));
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 400));
        expect(adapter.blocks.length, original.length + 1);
        expect(state.document.first!.toJson(), snapshot);
        expect(adapter.blocks.last.blockType, 'paragraph');
        expect(adapter.blocks.last.parentId, isNull);
        expect(adapter.blocks.last.text, isEmpty);
        expect(state.selection, Selection.single(path: [1], startOffset: 0));
        expect(tester.testTextInput.hasAnyClients, isTrue);
        expect(tester.testTextInput.isVisible, isTrue);
        state.undoManager.undo();
        await tester.pumpAndSettle();
        expect(adapter.blocks.length, original.length);
        expect(state.document.first!.toJson(), snapshot);
        state.undoManager.redo();
        await tester.pumpAndSettle();
        expect(adapter.blocks.length, original.length + 1);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );

    testWidgets('$kind readonly hides insertion controls', (tester) async {
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: _blocks(kind),
        onLocalBlocksChanged: (_) {},
      );
      addTearDown(adapter.dispose);
      adapter.editorState.editable = false;
      await _mount(tester, adapter);
      await tester.pumpAndSettle();
      expect(find.byTooltip('更多操作'), findsNothing);
      expect(adapter.editorState.undoManager.undoStack.isEmpty, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
  }

  testWidgets(
    'nested task insertion stays inside callout and accepts IME input',
    (tester) async {
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: _blocks('task', nested: true),
        onLocalBlocksChanged: (_) {},
      );
      addTearDown(adapter.dispose);
      await _mount(tester, adapter);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('task-card-more-card')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('block-insert-below-card')));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 400));
      expect(adapter.blocks.last.parentId, 'outer');
      expect(
        adapter.editorState.selection,
        Selection.single(path: [0, 1], startOffset: 0),
      );
      final value = TextEditingValue.fromJSON(
        tester.testTextInput.editingState!,
      );
      final offset = value.selection.extentOffset;
      tester.testTextInput.updateEditingValue(
        value.copyWith(
          text: value.text.replaceRange(offset, offset, '继续输入'),
          selection: TextSelection.collapsed(offset: offset + 4),
        ),
      );
      await tester.pumpAndSettle();
      expect(adapter.blocks.last.text, '继续输入');
      expect(adapter.blocks[1].resource!.string('taskId'), 't1');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  for (final mutation in [
    'reorder',
    'delete',
    'readonly',
    'reference',
    'session',
    'revokeRestore',
  ]) {
    testWidgets('open task menu handles $mutation safely', (tester) async {
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: _blocks('task'),
        onLocalBlocksChanged: (_) {},
      );
      addTearDown(adapter.dispose);
      await _mount(tester, adapter);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('task-card-more-card')));
      await tester.pumpAndSettle();
      if (mutation == 'readonly' || mutation == 'revokeRestore') {
        adapter.editorState.editable = false;
        if (mutation == 'revokeRestore') adapter.editorState.editable = true;
      } else if (mutation == 'session') {
        final owner = Object();
        CollabRuntime.acquire(
          owner,
          CollabHostServices(onError: (_, _, _, _) {}),
        );
        addTearDown(() => CollabRuntime.release(owner));
      } else {
        await adapter.replaceFromRemote([
          if (mutation == 'reorder' || mutation == 'delete')
            const CollabEditorBlock(
              id: 'remote',
              blockType: 'paragraph',
              text: '远端正文',
            ),
          if (mutation != 'delete')
            mutation == 'reference'
                ? CollabEditorBlock(
                    id: 'card',
                    blockType: 'task',
                    text: '',
                    resource: CollabResource.fromValues({
                      'taskId': 'other',
                      'title': '其他任务',
                    }),
                  )
                : adapter.blocks.single,
        ]);
      }
      await tester.tap(find.byKey(const ValueKey('block-insert-below-card')));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 400));
      expect(adapter.blocks.length, mutation == 'reorder' ? 3 : 1);
      expect(
        adapter.editorState.undoManager.undoStack.isEmpty,
        mutation != 'reorder',
      );
      if (mutation == 'reorder') {
        expect(adapter.blocks[1].id, 'card');
        expect(
          adapter.editorState.selection,
          Selection.single(path: [2], startOffset: 0),
        );
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
  }

  test(
    'insertion refuses detached nodes and unsupported table parents',
    () async {
      final state = EditorState(
        document: Document(
          root: Node(
            type: 'page',
            children: [
              Node(
                type: 'table',
                children: [Node(type: 'table-row')],
              ),
            ],
          ),
        ),
      );
      addTearDown(state.dispose);
      expect(await insertCollabParagraphBelow(state, paragraphNode()), isNull);
      expect(
        await insertCollabParagraphBelow(
          state,
          state.document.first!.children.first,
        ),
        isNull,
      );
      expect(state.undoManager.undoStack.isEmpty, isTrue);
    },
  );
}
