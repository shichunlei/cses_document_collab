import 'dart:async';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/editor/collab_kr_block.dart';
import 'package:cses_document_collab/src/model/collab_kr.dart';
import 'package:cses_document_collab/src/model/collab_resource.dart';
import 'package:cses_document_collab/src/model/collab_user_mention.dart';
import 'package:cses_document_collab/src/native/collab_runtime.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 验证正式投影、事务历史、分页及迟到请求；不访问业务网络。
void main() {
  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
          const EventChannel('keyboardHeightEventChannel'),
          MockStreamHandler.inline(onListen: (_, sink) => sink.success(0.0)),
        );
  });
  test('KR projection and local transaction keep reference only', () {
    final adapter = _adapter();
    addTearDown(adapter.dispose);
    final node = adapter.editorState.document.root.children.first;
    expect(node.type, collabKrType);
    expect(node.delta, isNull);
    expect(node.children, isEmpty);
    expect(
      CollabResource.fromJson(node.attributes[collabResourceAttribute]).values,
      {'meetingId': 'm1'},
    );
  });
  testWidgets('convert preserves author mention and supports undo redo', (
    tester,
  ) async {
    final adapter = _adapter();
    addTearDown(adapter.dispose);
    final state = adapter.editorState;
    expect(
      await convertCollabKr(
        state,
        state.document.root.children.first,
        const CollabKrItem(
          id: 'k1',
          title: '交付',
          rank: 1,
          authorId: 'u1',
          authorName: '张三',
        ),
      ),
      isTrue,
    );
    final todo = state.document.root.children[1];
    expect(todo.type, 'todo_list');
    expect(todo.attributes['checked'], false);
    expect(
      todo.delta!.toJson().first['attributes'][collabMentionIdAttribute],
      'u1',
    );
    expect(todo.delta!.toPlainText(), '\uFFFC 交付');
    state.undoManager.undo();
    await tester.pumpAndSettle();
    expect(state.document.root.children.length, 2);
    state.undoManager.redo();
    await tester.pumpAndSettle();
    expect(state.document.root.children[1].type, 'todo_list');
  });
  testWidgets('readonly rejects conversion', (tester) async {
    final adapter = _adapter();
    addTearDown(adapter.dispose);
    adapter.editorState.editable = false;
    expect(
      await convertCollabKr(
        adapter.editorState,
        adapter.editorState.document.root.children.first,
        const CollabKrItem(id: 'k1', title: '交付', rank: 1),
      ),
      isFalse,
    );
  });
  testWidgets('collect meeting reference is one undo step', (tester) async {
    final adapter = AppFlowyBlockEditorAdapter(
      initialBlocks: [
        CollabEditorBlock(
          id: 'meeting',
          blockType: 'meeting',
          text: '',
          resource: CollabResource.fromValues({
            'meetingId': 'm1',
            'title': '周会',
          }),
        ),
        const CollabEditorBlock(id: 'tail', blockType: 'paragraph', text: ''),
      ],
      onLocalBlocksChanged: (_) {},
    );
    addTearDown(adapter.dispose);
    final editor = adapter.editorState;
    expect(
      await collectCollabKr(
        editor,
        editor.document.root.children.first,
        'wrong',
      ),
      false,
    );
    expect(
      await collectCollabKr(editor, editor.document.root.children.first, 'm1'),
      true,
    );
    expect(editor.document.root.children[1].type, collabKrType);
    editor.undoManager.undo();
    await tester.pumpAndSettle();
    expect(editor.document.root.children.length, 2);
    editor.undoManager.redo();
    await tester.pumpAndSettle();
    expect(editor.document.root.children[1].type, collabKrType);
  });
  testWidgets('topics pagination deduplicates and stops at empty page', (
    tester,
  ) async {
    final service = _Service();
    final adapter = await _mount(tester, service);
    service.topics.complete([_topic]);
    await tester.pumpAndSettle();
    expect(find.text('交付主题'), findsOneWidget);
    expect(find.text('第一项'), findsOneWidget);
    await tester.tap(find.text('加载更多'));
    await tester.pump();
    expect(service.offsets, [1]);
    service.page.complete(const [
      CollabKrItem(id: 'k1', title: '重复', rank: 1),
      CollabKrItem(id: 'k2', title: '第二项', rank: 2),
    ]);
    await tester.pumpAndSettle();
    expect(find.text('第二项'), findsOneWidget);
    expect(find.text('重复'), findsNothing);
    expect(adapter.editorState.document.root.children.length, 2);
  });
  testWidgets('failed first load can retry', (tester) async {
    final service = _Service();
    await _mount(tester, service);
    service.topics.completeError(StateError('offline'));
    await tester.pumpAndSettle();
    expect(find.text('重试'), findsOneWidget);
    service.topics = Completer();
    await tester.tap(find.text('重试'));
    await tester.pump();
    service.topics.complete([]);
    await tester.pumpAndSettle();
    expect(find.text('本次会议暂无 KR'), findsOneWidget);
  });
  testWidgets('late response after unmount is ignored', (tester) async {
    final service = _Service();
    await _mount(tester, service);
    await tester.pumpWidget(const SizedBox());
    service.topics.complete([_topic]);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'narrow large text readonly keeps pagination and hides mutation',
    (tester) async {
      final service = _Service();
      final adapter = await _mount(tester, service, width: 320, scale: 1.5);
      adapter.editorState.editable = false;
      service.topics.complete([_topic]);
      await tester.pumpAndSettle();
      expect(find.text('加载更多'), findsOneWidget);
      expect(find.text('转为待办'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('reference replacement discards old response', (tester) async {
    final service = _Service();
    final adapter = await _mount(tester, service);
    final old = service.topics;
    service.topics = Completer();
    await adapter.replaceFromRemote([
      CollabEditorBlock(
        id: 'kr',
        blockType: collabKrType,
        text: '',
        resource: CollabResource.fromValues({'meetingId': 'm2'}),
      ),
      const CollabEditorBlock(id: 'tail', blockType: 'paragraph', text: '正文'),
    ]);
    await tester.pump();
    old.complete([_topic]);
    await tester.pump();
    expect(find.text('第一项'), findsNothing);
    service.topics.complete([]);
    await tester.pumpAndSettle();
    expect(find.text('本次会议暂无 KR'), findsOneWidget);
  });
  testWidgets('pagination failure keeps old items and offers retry', (
    tester,
  ) async {
    final service = _Service();
    await _mount(tester, service);
    service.topics.complete([_topic]);
    await tester.pumpAndSettle();
    await tester.tap(find.text('加载更多'));
    await tester.pump();
    service.page.completeError(StateError('offline'));
    await tester.pumpAndSettle();
    expect(find.text('第一项'), findsOneWidget);
    expect(find.text('加载失败，重试'), findsOneWidget);
  });
  testWidgets('empty page ends pagination without editing document', (
    tester,
  ) async {
    final service = _Service();
    final adapter = await _mount(tester, service);
    service.topics.complete([_topic]);
    await tester.pumpAndSettle();
    await tester.tap(find.text('加载更多'));
    await tester.pump();
    service.page.complete([]);
    await tester.pumpAndSettle();
    expect(find.text('加载更多'), findsNothing);
    expect(adapter.editorState.document.root.children.length, 2);
  });
  testWidgets('delete KR from public menu and undo restores it', (
    tester,
  ) async {
    final service = _Service();
    final adapter = await _mount(tester, service);
    service.topics.complete([]);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除 KR 列表'));
    await tester.pumpAndSettle();
    expect(adapter.editorState.document.root.children.length, 1);
    adapter.editorState.undoManager.undo();
    await tester.pumpAndSettle();
    expect(adapter.editorState.document.root.children.first.type, collabKrType);
  });
  for (final width in [320.0, 390.0]) {
    testWidgets('conversion stays at trailing edge at $width with large text', (
      tester,
    ) async {
      final service = _Service();
      await _mount(tester, service, width: width, scale: 1.5);
      service.topics.complete(const [
        CollabKrTopic(
          id: 'topic',
          title: '主题',
          total: 1,
          items: [
            CollabKrItem(
              id: 'item',
              title: '需要换行的很长关键结果内容需要换行的很长关键结果内容',
              rank: 1,
              authorName: '作者姓名',
              votes: 12,
            ),
          ],
        ),
      ]);
      await tester.pumpAndSettle();
      expect(find.text('转为待办'), findsNothing);
      await tester.tap(find.text('需要换行的很长关键结果内容需要换行的很长关键结果内容'));
      await tester.pumpAndSettle();
      final title = tester.getRect(find.text('需要换行的很长关键结果内容需要换行的很长关键结果内容'));
      final button = tester.getRect(find.widgetWithText(TextButton, '转为待办'));
      final topic = tester.getRect(find.text('主题'));
      expect(title.right, lessThanOrEqualTo(button.left));
      expect(button.right, closeTo(topic.right, 0.1));
      expect(button.top, greaterThanOrEqualTo(title.top));
      expect(button.top, lessThan(title.bottom));
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets(
    'tap switches conversion target, toggles off and clears after conversion',
    (tester) async {
      final service = _Service();
      final adapter = await _mount(tester, service);
      service.topics.complete(const [
        CollabKrTopic(
          id: 't1',
          title: '主题',
          total: 2,
          items: [
            CollabKrItem(id: 'k1', title: '第一项', rank: 1),
            CollabKrItem(id: 'k2', title: '第二项', rank: 2),
          ],
        ),
      ]);
      await tester.pumpAndSettle();
      expect(find.text('转为待办'), findsNothing);
      await tester.tap(find.text('第一项'));
      await tester.pumpAndSettle();
      expect(find.text('转为待办'), findsOneWidget);
      await tester.tap(find.text('第一项'));
      await tester.pumpAndSettle();
      expect(find.text('转为待办'), findsNothing);
      await tester.tap(find.text('第一项'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('第二项'));
      await tester.pumpAndSettle();
      expect(find.text('转为待办'), findsOneWidget);
      await tester.tap(find.text('转为待办'));
      await tester.pumpAndSettle();
      expect(
        adapter.editorState.document.root.children[1].delta!.toPlainText(),
        '第二项',
      );
      expect(find.text('转为待办'), findsNothing);
    },
  );
  testWidgets('default top three are bold colored digits without images', (
    tester,
  ) async {
    final service = _Service();
    await _mount(tester, service);
    service.topics.complete(const [
      CollabKrTopic(
        id: 'medals',
        title: '主题',
        total: 4,
        items: [
          CollabKrItem(id: 'k1', title: '金牌条目', rank: 1),
          CollabKrItem(id: 'k2', title: '银牌条目', rank: 2),
          CollabKrItem(id: 'k3', title: '铜牌条目', rank: 3),
          CollabKrItem(id: 'k4', title: '普通条目', rank: 4),
        ],
      ),
    ]);
    await tester.pumpAndSettle();
    for (final (rank, color) in [
      (1, const Color(0xFFC8A65A)),
      (2, const Color(0xFF9AA4B2)),
      (3, const Color(0xFFCD8B73)),
    ]) {
      final number = tester.widget<Text>(find.text('$rank'));
      expect(number.style?.color, color);
      expect(number.style?.fontWeight, FontWeight.bold);
    }
    expect(find.byType(Image), findsNothing);
    expect(find.text('4'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('host can supply three rank widgets', (tester) async {
    final service = _Service();
    await _mount(
      tester,
      service,
      rankIcons: (
        first: const Text('宿主金'),
        second: const Text('宿主银'),
        third: const Text('宿主铜'),
      ),
    );
    service.topics.complete(const [
      CollabKrTopic(
        id: 'ranks',
        title: '主题',
        total: 4,
        items: [
          CollabKrItem(id: 'k1', title: '第一项', rank: 1),
          CollabKrItem(id: 'k2', title: '第二项', rank: 2),
          CollabKrItem(id: 'k3', title: '第三项', rank: 3),
          CollabKrItem(id: 'k4', title: '第四项', rank: 4),
        ],
      ),
    ]);
    await tester.pumpAndSettle();
    for (final text in ['宿主金', '宿主银', '宿主铜', '4']) {
      expect(find.text(text), findsOneWidget);
    }
    for (final rank in ['1', '2', '3']) {
      expect(find.text(rank), findsNothing);
    }
    expect(tester.takeException(), isNull);
  });
}

/// 固定首屏，保留后续页用于测试分页。
const _topic = CollabKrTopic(
  id: 't1',
  title: '交付主题',
  total: 3,
  items: [CollabKrItem(id: 'k1', title: '第一项', rank: 1)],
);

/// 测试拥有的可控查询端口，不持有连接。
class _Service implements CollabKrService {
  /// 首屏请求，重试时由测试替换。
  Completer<List<CollabKrTopic>> topics = Completer();

  /// 当前分页请求。
  final page = Completer<List<CollabKrItem>>();

  /// 记录分页偏移，确保重复点击不重复请求。
  final offsets = <int>[];

  /// 返回会议[meetingId]的可控首屏。
  @override
  Future<List<CollabKrTopic>> loadTopics(String meetingId) => topics.future;

  /// 记录[meetingId]/[topicId]的[offset]后返回可控分页。
  @override
  Future<List<CollabKrItem>> loadMore(
    String meetingId,
    String topicId,
    int offset,
  ) {
    offsets.add(offset);
    return page.future;
  }
}

/// 创建测试拥有的编辑器，由调用方释放。
AppFlowyBlockEditorAdapter _adapter() => AppFlowyBlockEditorAdapter(
  initialBlocks: [
    CollabEditorBlock(
      id: 'kr',
      blockType: collabKrType,
      text: '',
      resource: CollabResource.fromValues({'meetingId': 'm1'}),
    ),
    const CollabEditorBlock(id: 'tail', blockType: 'paragraph', text: '正文'),
  ],
  onLocalBlocksChanged: (_) {},
);

/// 在[tester]挂载借用[service]的真实块；[width]/[scale]控制窄屏大字，
/// [rankIcons]可注入前三名图标，null使用数字；资源在tearDown释放。
Future<AppFlowyBlockEditorAdapter> _mount(
  WidgetTester tester,
  CollabKrService service, {
  double width = 390,
  double scale = 1,
  ({Widget first, Widget second, Widget third})? rankIcons,
}) async {
  await tester.binding.setSurfaceSize(Size(width, 600));
  final adapter = _adapter();
  final owner = Object();
  CollabRuntime.acquire(
    owner,
    CollabHostServices(
      kr: service,
      krRankIcons: rankIcons,
      onError: (_, _, _, _) {},
    ),
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    adapter.dispose();
    CollabRuntime.release(owner);
    await tester.binding.setSurfaceSize(null);
  });
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: Scaffold(
        body: AppFlowyEditor(
          editorState: adapter.editorState,
          editorStyle: const EditorStyle.mobile(padding: EdgeInsets.all(12)),
          blockComponentBuilders: {
            ...standardBlockComponentBuilderMap,
            collabKrType: CollabKrBlockComponentBuilder(),
          },
        ),
      ),
    ),
  );
  await tester.pump();
  return adapter;
}
