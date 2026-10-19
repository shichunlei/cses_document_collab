import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/editor/collab_block_actions.dart';
import 'package:cses_document_collab/src/editor/collab_paragraph_links.dart';
import 'package:cses_document_collab/src/editor/collab_callout_block.dart';
import 'package:cses_document_collab/src/editor/collab_code_block.dart';
import 'package:cses_document_collab/src/editor/collab_image_block.dart';
import 'package:cses_document_collab/src/editor/collab_video_block.dart';
import 'package:cses_document_collab/src/editor/collab_formula_block.dart';
import 'package:cses_document_collab/src/editor/collab_meeting_block.dart';
import 'package:cses_document_collab/src/editor/collab_audio_block.dart';
import 'package:cses_document_collab/src/editor/collab_attachment_block.dart';
import 'package:cses_document_collab/src/editor/collab_task_card_block.dart';
import 'package:cses_document_collab/src/ui/modal/collab_modal.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
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
        'image': CollabImageBlockComponentBuilder(),
        'video': CollabVideoBlockComponentBuilder(),
        'attachment': CollabAttachmentBlockComponentBuilder(),
        'audio': CollabAudioBlockComponentBuilder(),
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

  for (final (kind, label) in const [
    ('image', '图片'),
    ('video', '视频'),
    ('audio', '音频'),
  ]) {
    for (final scenario in const [
      'reorder',
      'source',
      'delete',
      'revokeRestore',
      'cancel',
      'failure',
    ]) {
      testWidgets('$kind copies full media URL with $scenario protection', (
        tester,
      ) async {
        const url =
            'https://example.test/%E4%B8%AD%20media?signature=a%2Bb%2Fc%3D&x=1#frame';
        final copied = <String>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, (call) async {
              if (call.method == 'Clipboard.setData') {
                if (scenario == 'failure') {
                  throw PlatformException(code: 'clipboard-denied');
                }
                copied.add((call.arguments as Map)['text'] as String);
              }
              return null;
            });
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(SystemChannels.platform, null),
        );
        var writes = 0;
        final media = CollabEditorBlock(
          id: 'card',
          blockType: kind,
          text: url,
          image: kind == 'image' ? const CollabImage(widthRatio: 60) : null,
          resource: kind == 'audio' ? const CollabResource() : null,
        );
        const tail = CollabEditorBlock(
          id: 'tail',
          blockType: 'paragraph',
          text: '后置正文',
        );
        final adapter = AppFlowyBlockEditorAdapter(
          initialBlocks: [media, tail],
          onLocalBlocksChanged: (_) => writes++,
        );
        addTearDown(adapter.dispose);
        await _mount(tester, adapter);
        await tester.pumpAndSettle();
        final more = find.byKey(const ValueKey('block-more-card'));
        await tester.ensureVisible(more);
        await tester.tap(more);
        await tester.pumpAndSettle();
        final copy = find.byKey(const ValueKey('media-copy-link-card'));
        expect(find.text('复制链接'), findsOneWidget);
        final tile = tester.widget<ListTile>(copy);
        expect((tile.leading as Icon).icon, LucideIcons.copy);
        final state = adapter.editorState;
        if (scenario == 'reorder') {
          await adapter.replaceFromRemote([tail, media]);
        } else if (scenario == 'source') {
          await adapter.replaceFromRemote([
            CollabEditorBlock(
              id: media.id,
              blockType: kind,
              text: '$url-changed',
              image: media.image,
              resource: media.resource,
            ),
            tail,
          ]);
        } else if (scenario == 'delete') {
          await adapter.replaceFromRemote([tail]);
        } else if (scenario == 'revokeRestore') {
          state.editable = false;
          state.editable = true;
        }
        await tester.pumpAndSettle();
        if (scenario == 'cancel') {
          await tester.tap(find.byTooltip('关闭'));
        } else {
          await tester.ensureVisible(copy);
          await tester.tap(copy);
        }
        await tester.pumpAndSettle();
        await tester.pump(const Duration(milliseconds: 400));
        expect(copied, scenario == 'reorder' ? [url] : isEmpty);
        expect(writes, 0);
        expect(state.undoManager.undoStack.isEmpty, isTrue);
        if (scenario == 'reorder') {
          expect(find.text('$label链接已复制'), findsOneWidget);
        }
        if (scenario == 'source' || scenario == 'delete') {
          expect(find.text('内容已更新，请重新选择'), findsOneWidget);
        }
        if (scenario == 'failure') {
          expect(find.text('操作失败，请重试'), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      });
    }
  }

  for (final changePermission in [false, true]) {
    testWidgets(
      'preview command validates permission lifetime ($changePermission)',
      (tester) async {
        final adapter = AppFlowyBlockEditorAdapter(
          initialBlocks: _blocks('attachment'),
          onLocalBlocksChanged: (_) {},
        );
        addTearDown(adapter.dispose);
        final editor = adapter.editorState..editable = false;
        var invoked = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: CollabBlockMoreButton(
                editor: editor,
                node: editor.document.first!,
                actions: [
                  (
                    label: '禁止编辑',
                    key: null,
                    run: () async {
                      fail('readonly mutation');
                    },
                  ),
                ],
                readOnlyActions: [
                  (
                    label: '打开资源',
                    key: null,
                    run: () async {
                      invoked++;
                    },
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.tap(find.byTooltip('更多操作'));
        await tester.pumpAndSettle();
        expect(find.text('禁止编辑'), findsNothing);
        expect(find.text('在下方插入'), findsNothing);
        if (changePermission) {
          editor.editable = true;
          editor.editable = false;
        }
        await tester.tap(find.text('打开资源'));
        await tester.pumpAndSettle();
        expect(invoked, changePermission ? 0 : 1);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
    );
  }

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
    testWidgets('$kind production menu copies its paragraph reference', (
      tester,
    ) async {
      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: _blocks(kind),
        onLocalBlocksChanged: (_) => fail('copy wrote content'),
      );
      addTearDown(adapter.dispose);
      final links = CollabParagraphLinks(
        editor: adapter.editorState,
        documentId: 'formal-doc',
        buildLink: (doc, block) => Uri.http('doc-pre.cses7.com', '/doc/$doc', {
          'blockId': block,
        }).toString(),
      );
      addTearDown(links.dispose);
      await _mount(tester, adapter);
      await tester.pumpAndSettle();
      final more = find.byKey(
        ValueKey(kind == 'task' ? 'task-card-more-card' : 'block-more-card'),
      );
      await tester.ensureVisible(more);
      await tester.tap(more);
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('block-copy-paragraph-link-card')),
      );
      await tester.pumpAndSettle();
      expect(copied, ['http://doc-pre.cses7.com/doc/formal-doc?blockId=card']);
      expect(find.text('段落链接已复制'), findsOneWidget);
      expect(adapter.editorState.undoManager.undoStack, isEmpty);
      expect(adapter.editorState.selection, isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    });

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
        final expectedHeader = switch (kind) {
          'image' => ('图片', LucideIcons.image),
          'video' => ('视频', LucideIcons.film),
          'code' => ('代码块', LucideIcons.codeXml),
          'callout' => ('高亮块', LucideIcons.highlighter),
          'audio' => ('音频', LucideIcons.audioLines),
          'attachment' => ('附件', LucideIcons.paperclip),
          'formula' => ('公式', LucideIcons.sigma),
          'meeting' => ('会议操作', LucideIcons.users),
          'task' => ('任务操作', LucideIcons.listTodo),
          _ => throw StateError('missing production header expectation: $kind'),
        };
        final sheet = tester.widget<CollabBottomSheet>(
          find.byType(CollabBottomSheet),
        );
        expect((sheet.title as Text).data, expectedHeader.$1);
        expect(sheet.icon, expectedHeader.$2);
        expect(find.text('块操作'), findsNothing);
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
      if (const {'video', 'attachment'}.contains(kind)) {
        expect(find.byTooltip('更多操作'), findsOneWidget);
        await tester.tap(find.byTooltip('更多操作'));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('block-insert-below-card')),
          findsNothing,
        );
      } else {
        expect(find.byTooltip('更多操作'), findsNothing);
      }
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
