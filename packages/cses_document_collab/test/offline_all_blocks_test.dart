import 'package:dio/dio.dart';
import 'package:cses_document_collab/src/model/collab_resource.dart';
import 'package:cses_document_collab/src/model/collab_meeting.dart';
import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:cses_document_collab/src/editor/collab_block_locks.dart';
import 'package:cses_document_collab/src/editor/collab_callout_block.dart';
import 'package:cses_document_collab/src/editor/editor_shortcut_toolbar.dart';
import 'package:cses_document_collab/src/model/collab_divider.dart';
import 'package:cses_document_collab/src/model/collab_formula.dart';
import 'package:cses_document_collab/src/model/collab_mermaid.dart';
import 'package:cses_document_collab/src/model/collab_page_divider.dart';
import 'package:cses_document_collab/src/model/collab_table.dart';
import 'package:cses_document_collab/src/native/collab_runtime.dart';
import 'package:cses_document_collab/src/ui/modal/editor_media_source_panel.dart';
import 'package:cses_document_collab/src/editor/editor_media_source_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 默认全部块的实际插入、嵌套输入、历史和离线端口隔离回归。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final creators = <String, Future<void> Function(EditorState)>{
    'code': (state) async {
      await applyBlockShortcut(state, state.selection!, 'code');
    },
    'callout': (state) async {
      await insertCollabCallout(state, state.selection!);
    },
    'table': (state) async {
      await insertCollabTable(state, state.selection!);
    },
    'formula': (state) async {
      await insertCollabFormula(state, state.selection!, r'x^2');
    },
    'mermaid': (state) async {
      await insertCollabMermaid(state, state.selection!, 'flowchart TD\n A-->B');
    },
    'divider': (state) async {
      await insertCollabDivider(state, state.selection!);
    },
    'page-divider': (state) async {
      await insertCollabPageDivider(state, state.selection!);
    },
    for (final type in [
      'image',
      'link',
      'video',
      'audio',
      'attachment',
      'bookmark',
      'embed',
      'figma-embed',
      'juejin-embed',
    ])
      type: (state) async {
        await applyUrlBlockShortcut(state, state.selection!, type, switch (type) {
          'figma-embed' => 'https://www.figma.com/file/test',
          'juejin-embed' => 'https://juejin.cn/post/123',
          _ => 'https://example.test/resource',
        });
      },
  };
  for (final entry in creators.entries) {
    test('default offline ${entry.key} inserts and has independent undo/redo', () async {
      final local = LocalEditorController(initialText: 'Anchor');
      try {
        final state = local.editorState;
        state.selection = Selection.collapsed(Position(path: [0], offset: 6));
        await entry.value(state);
        expect(state.document.root.children.any((node) => node.type == entry.key), isTrue);
        state.undoManager.undo();
        expect(state.document.root.children.any((node) => node.type == entry.key), isFalse);
        expect(state.document.root.children.first.delta!.toPlainText(), 'Anchor');
        state.undoManager.redo();
        expect(state.document.root.children.any((node) => node.type == entry.key), isTrue);
        expect(CollabBlockLocks.of(state), isNull);
      } finally {
        await local.close();
      }
    });
  }

  test('default offline table cell paste stays inside its cell and rejects locks', () async {
    final local = LocalEditorController(initialText: 'Anchor');
    try {
      final state = local.editorState;
      final selection = await insertCollabTable(state, Selection.collapsed(Position(path: [0])));
      expect(selection, isNotNull);
      state.selection = selection;
      await local.pasteText('第一行\n第二行');
      final table = state.document.root.children.firstWhere((node) => node.type == 'table');
      final cell = table.children.first.children.first;
      expect(cell.children.map((node) => node.delta!.toPlainText()), ['第一行', '第二行']);
      expect(state.selection!.start.path.length, 4);
      final revision = local.revision;
      await state.apply(state.transaction..updateNode(table, {'cses_block_lock': true}));
      expect(local.revision, revision);
    } finally {
      await local.close();
    }
  });

  testWidgets('default offline adds a table through the original menu and previews it', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 260);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showCollabImageComposer(context: context, initialText: 'Anchor'),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    final source = tester.widget<AppFlowyEditor>(find.byType(AppFlowyEditor)).editorState;
    source.selection = Selection.collapsed(Position(path: [0], offset: 6));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('editor-shortcut-add')));
    await tester.pumpAndSettle();
    for (final type in [
      'code-block',
      'image-block',
      'table',
      'formula',
      'mermaid',
      'divider',
      'page-divider',
      'callout',
    ]) {
      expect(find.byKey(ValueKey('editor-shortcut-$type')), findsOneWidget);
    }
    await tester.ensureVisible(find.byKey(const ValueKey('editor-shortcut-table')));
    await tester.tap(find.byKey(const ValueKey('editor-shortcut-table')));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(source.document.root.children.any((node) => node.type == 'table'), isTrue);
    tester.view.viewInsets = const FakeViewPadding();
    await tester.tap(find.byKey(const ValueKey('image-composer-preview-toggle')));
    await tester.pumpAndSettle();
    final preview = tester.widget<AppFlowyEditor>(find.byType(AppFlowyEditor));
    expect(preview.editorState.document.root.children.any((node) => node.type == 'table'), isTrue);
    expect(preview.disableSelectionService, isTrue);
    expect(find.byTooltip('更多操作'), findsNothing);
    expect(CollabBlockLocks.of(source), isNull);
    await tester.tap(find.byKey(const ValueKey('image-composer-back')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('offline media modal explicitly disables global upload fallback', (tester) async {
    final owner = Object();
    var errors = 0;
    final upload = _ForbiddenUpload();
    CollabRuntime.acquire(owner, CollabHostServices(mediaUpload: upload, onError: (_, _, _, _) => errors++));
    final local = LocalEditorController();
    addTearDown(local.close);
    addTearDown(() => CollabRuntime.release(owner));
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showEditorMediaSourceSheet(context, blockType: 'image', editorState: local.editorState),
              child: const Text('Media'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Media'));
    await tester.pumpAndSettle();
    final panel = tester.widget<EditorMediaSourcePanel>(find.byType(EditorMediaSourcePanel));
    expect(panel.service, isNull);
    expect(panel.useRuntimeService, isFalse);
    expect(identical(local.commandContext.services, CollabRuntime.services), isFalse);
    expect(errors, 0);
    expect(find.byKey(const ValueKey('editor-media-upload-tab')), findsNothing);
    expect(upload.calls, 0);
    await tester.tap(find.byKey(const ValueKey('editor-media-source-close')));
    await tester.pumpAndSettle();
  });
  testWidgets('offline business blocks never load through the active collaboration host', (tester) async {
    final owner = Object();
    var requests = 0;
    CollabRuntime.acquire(
      owner,
      CollabHostServices(
        loadMeetingCard: (_) async {
          requests++;
          return null;
        },
        loadTaskCard: (_) async {
          requests++;
          return null;
        },
        onError: (_, _, _, _) => requests++,
      ),
    );
    final local = LocalEditorController(initialText: 'Anchor');
    addTearDown(local.close);
    addTearDown(() => CollabRuntime.release(owner));
    final state = local.editorState;
    await state.apply(
      state.transaction..insertNodes(
        [1],
        [
          Node(
            type: 'meeting',
            attributes: CollabMeeting.nodeAttributes(CollabResource.fromValues({'meetingId': 'm1', 'title': '本地会议'})),
          ),
          Node(
            type: 'task',
            attributes: {
              collabResourceAttribute: CollabResource.fromValues({'taskId': 't1', 'title': '本地任务'}).toJson(),
            },
          ),
          Node(
            type: 'kr-list',
            attributes: {
              collabResourceAttribute: CollabResource.fromValues({'meetingId': 'm1'}).toJson(),
            },
          ),
        ],
      ),
      withUpdateSelection: false,
    );
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [AppFlowyEditorLocalizations.delegate],
        home: Scaffold(body: DocumentEditorView(editorState: state)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.drag(find.byType(AppFlowyEditor), const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(state.document.root.children.map((node) => node.type), ['paragraph', 'meeting', 'task', 'kr-list']);
    expect(requests, 0);
    expect(CollabRuntime.owns(owner), isTrue);
    expect(CollabBlockLocks.of(state), isNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

/// 一旦被离线界面调用就记录失败路径的全局上传桩，不读取磁盘或网络。
class _ForbiddenUpload extends EditorMediaUploadService {
  /// 被调用次数，正常离线流程应始终为零。
  int calls = 0;

  /// 记录[kind]的全局文件选择调用，返回取消结果。
  @override
  Future<EditorLocalFile?> pickFile(String kind) async {
    calls++;
    return null;
  }

  /// 拒绝[file]、[kind]的全局上传；[cancelToken]/[onProgress]均为借用测试参数。
  @override
  Future<EditorMediaSource> upload(
    EditorLocalFile file,
    String kind, {
    required CancelToken cancelToken,
    required void Function(double progress) onProgress,
  }) async {
    calls++;
    throw StateError('离线编辑器不得访问全局上传服务');
  }
}
