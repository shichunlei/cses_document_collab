import 'dart:io';
import 'dart:ui' as ui;
import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/native/collab_runtime.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 真实正文面板、会议/任务共享转换及文档仅保留行内形式的交互回归。
void main() {
  setUpAll(() async {
    await _loadPreviewFonts();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
          const EventChannel('keyboardHeightEventChannel'),
          MockStreamHandler.inline(
            onListen: (_, events) => events.success(0.0),
          ),
        );
  });
  for (final type in ['meeting', 'task']) {
    testWidgets(
      '$type menu does not notify host; card conversion preserves surrounding content',
      (tester) async {
        final received = <CollabMentionTap>[];
        var meetingTaps = 0;
        final adapter = await _mount(
          tester,
          type,
          CollabHostServices(
            onMentionTap: received.add,
            onMeetingCardTap: (_, _, _) => meetingTaps++,
          ),
        );
        await tester.tap(_chip);
        await tester.pumpAndSettle();
        expect(received, isEmpty);
        expect(find.text('切换为卡片视图'), findsOneWidget);
        await _capture(tester, '$type-menu');
        await tester.tap(
          find.byKey(const ValueKey('entity-mention-switch-view')),
        );
        await tester.pumpAndSettle();
        expect(adapter.blocks.map((b) => b.text), ['前😀', '', '后']);
        expect(adapter.blocks[1].blockType, type);
        expect(adapter.blocks[1].resource!.string('title'), '$type名称');
        expect(received, isEmpty);
        expect(meetingTaps, 0);
        await _capture(tester, '$type-card');
        if (type == 'task') {
          final id = adapter.blocks[1].id;
          await tester.tap(find.byKey(ValueKey('task-card-open-$id')));
          await tester.pumpAndSettle();
          expect(received.single.type, CollabMentionType.task);
          expect(received.single.id, 'task-id');
          expect(received.single.attributes, {
            'taskId': 'task-id',
            'title': 'task名称',
          });
          received.clear();
          await tester.tap(find.byKey(ValueKey('task-card-more-$id')));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(ValueKey('task-card-delete-$id')));
          await tester.pumpAndSettle();
          expect(adapter.blocks.map((b) => b.text), ['前😀', '后']);
          expect(received, isEmpty);
          adapter.editorState.undoManager.undo();
          await tester.pumpAndSettle();
          expect(
            adapter.blocks.where((b) => b.blockType == 'task'),
            hasLength(1),
          );
        }
        adapter.editorState.undoManager.undo();
        await tester.pumpAndSettle();
        expect(adapter.blocks.single.text, '前😀\uFFFC后');
        adapter.editorState.undoManager.redo();
        await tester.pumpAndSettle();
        expect(adapter.blocks.map((b) => b.text), ['前😀', '', '后']);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'document has no card switch and preserves shared data when opening details',
    (tester) async {
      final received = <CollabMentionTap>[];
      final adapter = await _mount(
        tester,
        'doc',
        CollabHostServices(onMentionTap: received.add),
        size: const Size(320, 568),
      );
      final original = adapter.blocks.single;
      final historyEmpty = adapter.editorState.undoManager.undoStack.isEmpty;
      for (var i = 0; i < 2; i++) {
        await tester.tap(_chip);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('entity-mention-switch-view')),
          findsNothing,
        );
        expect(find.text('切换为卡片视图'), findsNothing);
        expect(find.text('切换为链接视图'), findsNothing);
        await tester.tap(
          find.byKey(const ValueKey('entity-mention-open-detail')),
        );
        await tester.pumpAndSettle();
        expect(adapter.blocks.single, original);
        expect(adapter.editorState.undoManager.undoStack.isEmpty, historyEmpty);
      }
      expect(received, hasLength(2));
      expect(received.first.type, CollabMentionType.doc);
      expect(received.first.attributes, _raw('doc'));
      expect(tester.takeException(), isNull);
    },
  );
  for (final change in ['permission', 'text', 'session']) {
    testWidgets('open menu refuses stale action after $change change', (
      tester,
    ) async {
      final received = <CollabMentionTap>[];
      final owner = Object();
      final adapter = await _mount(
        tester,
        'task',
        CollabHostServices(onMentionTap: received.add),
        runtimeOwner: owner,
      );
      await tester.tap(_chip);
      await tester.pumpAndSettle();
      if (change == 'permission') {
        adapter.editorState.editable = false;
      } else if (change == 'text') {
        await adapter.replaceFromRemote([
          const CollabEditorBlock(
            id: 'body',
            blockType: 'paragraph',
            text: '远端正文',
          ),
        ]);
      } else {
        // The old host identity is replaced while its route is still open.
        CollabRuntime.release(owner);
        final nextOwner = Object();
        CollabRuntime.acquire(nextOwner, const CollabHostServices());
        addTearDown(() => CollabRuntime.release(nextOwner));
      }
      await tester.pumpAndSettle();
      if (change == 'permission') {
        expect(
          tester
              .widget<ListTile>(
                find.byKey(const ValueKey('entity-mention-switch-view')),
              )
              .enabled,
          isFalse,
        );
        await tester.tap(find.byTooltip('关闭'));
      } else {
        await tester.tap(
          find.byKey(const ValueKey('entity-mention-switch-view')),
        );
      }
      await tester.pumpAndSettle();
      expect(adapter.blocks.where((b) => b.blockType == 'task'), isEmpty);
      expect(received, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }
}

/// 带emoji前文后的真实提及命中范围。
final _chip = find.byKey(const ValueKey('collab-inline-entity-body-3'));

/// [type]的完整原始属性，供详情回调一致性验证。
Map<String, Object?> _raw(String type) => {
  'mentionType': type,
  'mentionId': '$type-id',
  'extension': {'keep': true},
};

/// 在[tester]中挂载[type]提及，借用[services]；[runtimeOwner]可指定会话所有者用于替换测试。
/// [size]为逻辑像素预览大小，默认390×844；测试负责清理页面、编辑器和runtime所有权。
Future<AppFlowyBlockEditorAdapter> _mount(
  WidgetTester tester,
  String type,
  CollabHostServices services, {
  Object? runtimeOwner,
  Size size = const Size(390, 844),
}) async {
  await tester.binding.setSurfaceSize(size);
  final owner = runtimeOwner ?? Object();
  CollabRuntime.acquire(owner, services);
  final adapter = AppFlowyBlockEditorAdapter(
    initialBlocks: [
      CollabEditorBlock(
        id: 'body',
        blockType: 'paragraph',
        text: '前😀\uFFFC后',
        segments: [
          const CollabEditorTextSegment(text: '前😀', bold: true),
          CollabEditorTextSegment(
            text: '\uFFFC',
            inlineMention: '$type名称',
            mentionId: '$type-id',
            mentionType: type,
            mentionAttributes: jsonEncode(_raw(type)),
          ),
          const CollabEditorTextSegment(text: '后', italic: true),
        ],
      ),
    ],
    onLocalBlocksChanged: (_) {},
  );
  final controller = _ReadyController(adapter.editorState);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 500));
    controller.dispose();
    adapter.dispose();
    CollabRuntime.release(owner);
    await tester.binding.setSurfaceSize(null);
  });
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(
        fontFamily: Platform.environment['MENTION_PREVIEW_FONT'] == null
            ? null
            : 'MentionPreview',
      ),
      builder: (context, child) => RepaintBoundary(
        key: const ValueKey('mention-actions-capture'),
        child: child!,
      ),
      home: CollaborativeEditorPage(collab: controller),
    ),
  );
  await tester.pumpAndSettle();
  return adapter;
}

/// 借用测试编辑器，不创建原生连接。
class _ReadyController extends CollabController {
  /// [state]由测试释放，不转移所有权。
  _ReadyController(this.state) : super.localDraft(databasePath: '/unused');

  /// 借用编辑器。
  final EditorState state;

  /// 返回借用编辑器。
  @override
  EditorState get editorState => state;

  /// 测试数据已就绪。
  @override
  bool get initialized => true;

  /// 页面允许切换预览。
  @override
  bool get canEdit => true;
}

/// 可选将[tester]的真实Flutter渲染以[name]保存到MENTION_PREVIEW_DIR，常规测试不写文件。
Future<void> _capture(WidgetTester tester, String name) async {
  final directory = Platform.environment['MENTION_PREVIEW_DIR'];
  if (directory == null) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('mention-actions-capture')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory(directory).create(recursive: true);
      await File(
        '$directory/entity-mention-$name-20261015.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

/// 可选字体仅用于预览，常规测试不依赖系统资源；字体字节由测试读取后交给Flutter。
Future<void> _loadPreviewFonts() async {
  for (final (variable, family) in [
    ('MENTION_PREVIEW_FONT', 'MentionPreview'),
    ('MENTION_ICON_FONT', 'MaterialIcons'),
  ]) {
    final path = Platform.environment[variable];
    if (path == null) continue;
    final bytes = await File(path).readAsBytes();
    await (FontLoader(
      family,
    )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
    if (family == 'MentionPreview') {
      await (FontLoader(
        'Roboto',
      )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
    }
  }
}
