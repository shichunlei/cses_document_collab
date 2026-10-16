import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/editor/collab_task_card_block.dart';
import 'package:cses_document_collab/src/model/collab_resource.dart';
import 'package:cses_document_collab/src/native/collab_runtime.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 任务卡片真实布局、宿主加载/头像注入、按钮导航及生命周期回归。
void main() {
  setUpAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
          const EventChannel('keyboardHeightEventChannel'),
          MockStreamHandler.inline(
            onListen: (_, events) => events.success(0.0),
          ),
        );
    await _loadFonts();
  });

  test(
    'snapshot freezes lists and rejects invalid identity, progress and counts',
    () {
      final people = <CollabMentionUser>[
        const CollabMentionUser(id: 'u1', name: '甲'),
      ];
      final path = <CollabTaskCardPath>[
        const CollabTaskCardPath(name: '空间', type: 'space'),
      ];
      final data = CollabTaskCardData(
        taskId: 't1',
        leaders: people,
        path: path,
      );
      people.clear();
      path.clear();
      expect(data.leaders, hasLength(1));
      expect(data.path, hasLength(1));
      expect(() => data.leaders.clear(), throwsUnsupportedError);
      for (final progress in [-1.0, 101.0, double.nan, double.infinity]) {
        expect(
          () => CollabTaskCardData(taskId: 't1', progress: progress),
          throwsArgumentError,
        );
      }
      expect(() => CollabTaskCardData(taskId: ''), throwsArgumentError);
      expect(
        () => CollabTaskCardData(taskId: 't1', fileCount: -1),
        throwsArgumentError,
      );
      expect(
        () => CollabTaskCardData(taskId: 't1', subTaskCount: -1),
        throwsArgumentError,
      );
    },
  );

  for (final (width, scale) in [(390.0, 1.0), (320.0, 1.5)]) {
    testWidgets(
      'desktop layout with labels, avatars, times and stats at $width/$scale',
      (tester) async {
        final avatars = <String>[];
        final harness = await _mount(
          tester,
          width: width,
          scale: scale,
          services: CollabHostServices(
            loadTaskCard: (id) async =>
                _detail(id, leaders: width == 390 ? 1 : 4),
            mentionAvatarBuilder:
                (
                  context, {
                  required userId,
                  required name,
                  required size,
                  avatarUrl,
                }) {
                  avatars.add(userId);
                  return CircleAvatar(
                    backgroundColor: Colors.green,
                    child: Text(name.characters.first),
                  );
                },
          ),
        );
        expect(find.text('测试状态111-111'), findsOneWidget);
        expect(find.text('一般'), findsOneWidget);
        expect(find.text('待开始'), findsOneWidget);
        expect(find.text('05-29 00:00'), findsOneWidget);
        expect(find.text('06-14 23:59'), findsOneWidget);
        expect(
          find.textContaining('测试状态-默认', findRichText: true),
          findsOneWidget,
        );
        expect(find.text('0'), findsNWidgets(2));
        expect(avatars.toSet(), width == 390 ? {'u0'} : {'u0', 'u1', 'u2'});
        if (width == 320) expect(find.text('+1'), findsOneWidget);
        final box = tester.widget<Container>(
          find.byKey(const ValueKey('task-card-surface-card')),
        );
        expect((box.decoration as BoxDecoration).color, Colors.white);
        expect(
          find.byKey(const ValueKey('task-card-progress-dot-card')),
          findsOneWidget,
        );
        expect(
          harness.adapter.blocks.first.resource!.string('title'),
          '共享任务标题',
        );
        expect(
          harness.adapter.blocks.first.resource!.values.containsKey('progress'),
          isFalse,
        );
        await _capture(tester, width == 390 ? 'normal' : 'narrow');
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'selected task card still receives detail and menu deletion taps',
    (tester) async {
      var opens = 0;
      final harness = await _mount(
        tester,
        services: CollabHostServices(
          onMentionTap: (_) {
            opens++;
          },
        ),
      );
      final editor = harness.adapter.editorState;
      await tester.tap(find.text('共享任务标题'));
      editor.selectionType = SelectionType.block;
      editor.selection = Selection.single(
        path: [0],
        startOffset: 0,
        endOffset: 1,
      );
      await tester.pumpAndSettle();
      expect(editor.selectionType, SelectionType.block);
      expect(editor.selection, isNotNull);
      await tester.tap(_open);
      await tester.pumpAndSettle();
      expect(opens, 1);
      editor.selectionType = SelectionType.block;
      editor.selection = Selection.single(
        path: [0],
        startOffset: 0,
        endOffset: 1,
      );
      await tester.pumpAndSettle();
      await tester.tap(_more);
      await tester.pumpAndSettle();
      await tester.tap(_delete);
      await tester.pumpAndSettle();
      expect(harness.adapter.blocks.any((b) => b.blockType == 'task'), isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'only expand icon dispatches raw reference and never reloads or reopens keyboard',
    (tester) async {
      final pending = Completer<void>();
      final received = <CollabMentionTap>[];
      var loads = 0;
      await _mount(
        tester,
        services: CollabHostServices(
          loadTaskCard: (id) async {
            loads++;
            return _detail(id);
          },
          onMentionTap: (event) {
            received.add(event);
            return pending.future;
          },
        ),
      );
      tester.testTextInput.log.clear();
      await tester.tap(find.text('测试状态111-111'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('待开始'));
      await tester.pumpAndSettle();
      expect(received, isEmpty);
      await tester.tap(_open);
      await tester.pump();
      expect(received, hasLength(1));
      expect(received.single.id, 't1');
      expect(received.single.name, '共享任务标题');
      expect(received.single.attributes, {'taskId': 't1', 'title': '共享任务标题'});
      expect(tester.widget<IconButton>(_open).onPressed, isNull);
      pending.complete();
      await tester.pumpAndSettle();
      expect(loads, 1);
      expect(tester.widget<IconButton>(_open).onPressed, isNotNull);
      expect(
        tester.testTextInput.log.where((c) => c.method == 'TextInput.show'),
        isEmpty,
      );
    },
  );

  for (final progress in [0.0, 50.0, 100.0]) {
    testWidgets('progress dot remains inside track at $progress percent', (
      tester,
    ) async {
      await _mount(
        tester,
        services: CollabHostServices(
          loadTaskCard: (id) async =>
              CollabTaskCardData(taskId: id, progress: progress),
        ),
      );
      final track = tester.getRect(
        find.byKey(const ValueKey('task-card-progress-card')),
      );
      final dot = tester.getRect(
        find.byKey(const ValueKey('task-card-progress-dot-card')),
      );
      expect(dot.left, greaterThanOrEqualTo(track.left));
      expect(dot.right, lessThanOrEqualTo(track.right));
      if (progress == 50) expect(dot.center.dx, closeTo(track.center.dx, 0.01));
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('failed detail callback retains snapshot and never reloads', (
    tester,
  ) async {
    var loads = 0;
    final errors = <Object>[];
    await _mount(
      tester,
      services: CollabHostServices(
        loadTaskCard: (id) async {
          loads++;
          return _detail(id);
        },
        onMentionTap: (_) =>
            Future<void>.error(StateError('navigation failed')),
        onError: (_, e, _, _) => errors.add(e),
      ),
    );
    tester.testTextInput.log.clear();
    await tester.tap(_open);
    await tester.pumpAndSettle();
    expect(loads, 1);
    expect(errors, hasLength(1));
    expect(find.text('测试状态111-111'), findsOneWidget);
    expect(tester.widget<IconButton>(_open).onPressed, isNotNull);
    expect(
      tester.testTextInput.log.where((c) => c.method == 'TextInput.show'),
      isEmpty,
    );
  });

  testWidgets(
    'menu delete only removes reference and supports undo; preview hides menu',
    (tester) async {
      var taps = 0;
      final harness = await _mount(
        tester,
        services: CollabHostServices(onMentionTap: (_) => taps++),
      );
      await tester.tap(_more);
      await tester.pumpAndSettle();
      await tester.tap(_delete);
      await tester.pumpAndSettle();
      expect(harness.adapter.blocks, hasLength(1));
      expect(harness.adapter.blocks.single.text, '正文');
      expect(taps, 0);
      harness.adapter.editorState.undoManager.undo();
      await tester.pumpAndSettle();
      expect(harness.adapter.blocks.first.blockType, 'task');
      harness.adapter.editorState.editable = false;
      await tester.pumpAndSettle();
      expect(_more, findsNothing);
      expect(tester.widget<IconButton>(_open).onPressed, isNotNull);
      await tester.tap(_open);
      await tester.pumpAndSettle();
      expect(taps, 1);
    },
  );

  testWidgets('old open menu cannot delete a remotely changed reference', (
    tester,
  ) async {
    final harness = await _mount(tester, services: const CollabHostServices());
    await tester.tap(_more);
    await tester.pumpAndSettle();
    await harness.adapter.replaceFromRemote([_card('other'), _tail]);
    await tester.pumpAndSettle();
    await tester.tap(_delete);
    await tester.pumpAndSettle();
    expect(harness.adapter.blocks.first.resource!.string('taskId'), 'other');
    expect(harness.adapter.blocks, hasLength(2));
  });

  testWidgets(
    'failure is reported once, retry loads and missing/deleted disable navigation',
    (tester) async {
      var attempt = 0;
      final errors = <Object>[];
      await _mount(
        tester,
        services: CollabHostServices(
          onError: (_, e, _, _) => errors.add(e),
          onMentionTap: (_) {},
          loadTaskCard: (id) async {
            if (attempt++ == 0) throw StateError('offline');
            return _detail(id);
          },
        ),
      );
      expect(errors, hasLength(1));
      expect(tester.widget<IconButton>(_open).onPressed, isNull);
      await tester.tap(find.byKey(const ValueKey('task-card-retry-card')));
      await tester.pumpAndSettle();
      expect(find.text('测试状态111-111'), findsOneWidget);
      expect(attempt, 2);
    },
  );
  for (final deleted in [false, true]) {
    testWidgets('explicit unavailable task disables detail, deleted=$deleted', (
      tester,
    ) async {
      await _mount(
        tester,
        services: CollabHostServices(
          onMentionTap: (_) {},
          loadTaskCard: (id) async =>
              deleted ? CollabTaskCardData(taskId: id, deleted: true) : null,
        ),
      );
      expect(find.text('任务不存在或已删除'), findsOneWidget);
      expect(tester.widget<IconButton>(_open).onPressed, isNull);
      expect(_more, findsOneWidget);
    });
  }

  testWidgets(
    'reference changes reject stale result/error; plain rebuild reuses one request',
    (tester) async {
      final old = Completer<CollabTaskCardData?>();
      final errors = <Object>[];
      var loads = 0;
      final harness = await _mount(
        tester,
        settle: false,
        services: CollabHostServices(
          onError: (_, e, _, _) => errors.add(e),
          loadTaskCard: (id) {
            loads++;
            return id == 't1' ? old.future : Future.value(_detail(id));
          },
        ),
      );
      expect(tester.widget<IconButton>(_open).onPressed, isNull);
      await harness.adapter.replaceFromRemote([_card('other'), _tail]);
      await tester.pumpAndSettle();
      expect(find.text('测试状态111-111'), findsOneWidget);
      old.completeError(StateError('old request'));
      await tester.pumpAndSettle();
      harness.adapter.editorState.editable = false;
      await tester.pumpAndSettle();
      expect(loads, 2);
      expect(errors, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('session change isolates late data and loads new host', (
    tester,
  ) async {
    final pending = Completer<CollabTaskCardData?>();
    final harness = await _mount(
      tester,
      settle: false,
      services: CollabHostServices(loadTaskCard: (_) => pending.future),
    );
    CollabRuntime.release(harness.owner);
    final owner = Object();
    CollabRuntime.acquire(
      owner,
      CollabHostServices(
        loadTaskCard: (id) async =>
            CollabTaskCardData(taskId: id, title: '新账号任务'),
      ),
    );
    addTearDown(() => CollabRuntime.release(owner));
    harness.adapter.editorState.editable = false;
    await tester.pumpAndSettle();
    pending.complete(_detail('t1'));
    await tester.pumpAndSettle();
    expect(find.text('新账号任务'), findsOneWidget);
    expect(find.text('测试状态111-111'), findsNothing);
  });

  testWidgets(
    'disposed request is ignored; wrong task identity reports failure',
    (tester) async {
      final errors = <Object>[];
      final harness = await _mount(
        tester,
        services: CollabHostServices(
          onError: (_, e, _, _) => errors.add(e),
          loadTaskCard: (_) async => _detail('wrong'),
        ),
      );
      expect(errors, hasLength(1));
      expect(find.text('任务加载失败'), findsOneWidget);
      final pending = Completer<CollabTaskCardData?>();
      CollabRuntime.acquire(
        harness.owner,
        CollabHostServices(
          loadTaskCard: (_) => pending.future,
          onError: (_, e, _, _) => errors.add(e),
        ),
      );
      harness.adapter.editorState.editable = false;
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      pending.completeError(StateError('after dispose'));
      await tester.pumpAndSettle();
      expect(errors, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('no loader has no fake business metadata or avatars', (
    tester,
  ) async {
    await _mount(tester, services: const CollabHostServices());
    expect(find.text('共享任务标题'), findsOneWidget);
    expect(find.text('一般'), findsNothing);
    expect(find.text('待开始'), findsNothing);
    expect(
      find.byKey(const ValueKey('task-card-progress-dot-card')),
      findsNothing,
    );
    expect(find.byType(CircleAvatar), findsNothing);
    expect(find.text('0'), findsNothing);
  });
}

/// 当前卡片的右上详情图标。
final _open = find.byKey(const ValueKey('task-card-open-card'));

/// 当前卡片的更多菜单。
final _more = find.byKey(const ValueKey('task-card-more-card'));

/// 当前已打开菜单的删除项。
final _delete = find.byKey(const ValueKey('task-card-delete-card'));

/// 合成后置正文。
const _tail = CollabEditorBlock(id: 'tail', blockType: 'paragraph', text: '正文');

/// 生成稳定块card引用的任务[id]，业务展示字段不进入props。
CollabEditorBlock _card(String id) => CollabEditorBlock(
  id: 'card',
  blockType: 'task',
  text: '',
  resource: CollabResource.fromValues({'taskId': id, 'title': '共享任务标题'}),
);

/// 合成任务[id]的截图快照；[leaders]控制头像叠放数量，不读取真实账号。
CollabTaskCardData _detail(String id, {int leaders = 1}) => CollabTaskCardData(
  taskId: id,
  title: '测试状态111-111',
  priority: const CollabTaskCardTag(name: '一般', color: '#59B463'),
  status: const CollabTaskCardTag(name: '待开始', color: '#E6E6E6'),
  startTime: DateTime(2026, 5, 29),
  endTime: DateTime(2026, 6, 14, 23, 59),
  progress: 0,
  fileCount: 0,
  subTaskCount: 0,
  leaders: List.generate(
    leaders,
    (i) => CollabMentionUser(id: 'u$i', name: '负责人$i'),
  ),
  path: const [
    CollabTaskCardPath(name: '企业空间', type: 'space'),
    CollabTaskCardPath(name: '测试状态-默认', type: 'project'),
    CollabTaskCardPath(name: '普通任务', type: 'workItem'),
  ],
);

/// 测试拥有的编辑器和runtime身份，清理由挂载工具负责。
class _Harness {
  /// [adapter]为测试拥有的编辑器，[owner]对应本次宿主身份。
  _Harness(this.adapter, this.owner);

  /// 测试拥有的适配器。
  final AppFlowyBlockEditorAdapter adapter;

  /// 测试拥有的runtime身份。
  final Object owner;
}

/// 在[tester]中挂载真实任务组件，借用[services]；[width]为逻辑宽度，[scale]为文字倍率。
/// [settle]默认等待详情完成，false用于挂起请求；测试退出时释放页面/编辑器/runtime。
Future<_Harness> _mount(
  WidgetTester tester, {
  required CollabHostServices services,
  double width = 390,
  double scale = 1,
  bool settle = true,
}) async {
  await tester.binding.setSurfaceSize(Size(width, 450));
  final owner = Object();
  CollabRuntime.acquire(owner, services);
  final adapter = AppFlowyBlockEditorAdapter(
    initialBlocks: [_card('t1'), _tail],
    onLocalBlocksChanged: (_) {},
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    adapter.dispose();
    CollabRuntime.release(owner);
    await tester.binding.setSurfaceSize(null);
  });
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(
        fontFamily: Platform.environment['TASK_CARD_FONT'] == null
            ? null
            : 'TaskPreview',
      ),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: Scaffold(
        body: RepaintBoundary(
          key: const ValueKey('task-card-capture'),
          child: ColoredBox(
            color: Colors.white,
            child: AppFlowyEditor(
              editorState: adapter.editorState,
              editorStyle: const EditorStyle.mobile(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              ),
              blockComponentBuilders: {
                ...standardBlockComponentBuilderMap,
                'task': CollabTaskCardBlockComponentBuilder(),
              },
            ),
          ),
        ),
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
  return _Harness(adapter, owner);
}

/// 按环境变量可选保存[tester]中[name]对应的卡片区域真实Flutter渲染，默认测试不写文件。
Future<void> _capture(WidgetTester tester, String name) async {
  final directory = Platform.environment['TASK_CARD_PREVIEWS'];
  if (directory == null) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('task-card-capture')),
  );
  final captureRect = tester
      .getRect(find.byKey(const ValueKey('task-card-surface-card')))
      .shift(
        -tester.getTopLeft(find.byKey(const ValueKey('task-card-capture'))),
      );
  await tester.runAsync(() async {
    final image = await (boundary.debugLayer! as OffsetLayer).toImage(
      captureRect,
      pixelRatio: 2,
    );
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory(directory).create(recursive: true);
      await File(
        '$directory/task-card-$name-20261015.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

/// 可选预览字体由环境提供，普通回归不依赖系统字体文件。
Future<void> _loadFonts() async {
  for (final (variable, family) in [
    ('TASK_CARD_FONT', 'TaskPreview'),
    ('TASK_CARD_ICONS', 'MaterialIcons'),
  ]) {
    final path = Platform.environment[variable];
    if (path == null) continue;
    final bytes = await File(path).readAsBytes();
    await (FontLoader(
      family,
    )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
  }
}
