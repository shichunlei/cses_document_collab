import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/editor/collab_meeting_block.dart';
import 'package:cses_document_collab/src/model/collab_resource.dart';
import 'package:cses_document_collab/src/native/collab_runtime.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 会议状态卡片、按钮命中、键盘和详情请求失效回归，使用公开宿主数据契约。
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
  for (final (state, label, action, color) in [
    (CollabMeetingCardState.notStarted, '未开始', '加入会议', const Color(0xFF4A7AFE)),
    (CollabMeetingCardState.inProgress, '进行中', '加入会议', const Color(0xFF00B42A)),
    (CollabMeetingCardState.paused, '已暂停', '加入会议', const Color(0xFFFF7D00)),
    (CollabMeetingCardState.completed, '已结束', '查看会议', const Color(0xFF86909C)),
    (CollabMeetingCardState.canceled, '已取消', '查看会议', const Color(0xFF86909C)),
  ]) {
    testWidgets(
      '${state.name} renders status, tone and primary action without writing shared props',
      (tester) async {
        var changes = 0;
        final harness = await _mount(
          tester,
          services: CollabHostServices(
            loadMeetingCard: (id) async => CollabMeetingCardData(
              meetingId: id,
              state: state,
              title: '威震天的快速会议',
              number: '888',
              startTime: DateTime(2026, 10, 10, 15, 35),
              moderatorName: '威震天',
              memberCount: 8,
            ),
            onMeetingCardTap: (_, _, _) {},
          ),
          onChanged: (_) {
            changes++;
          },
        );
        expect(
          tester
              .widget<ColoredBox>(
                find.byKey(const ValueKey('meeting-card-content-meeting')),
              )
              .color,
          Colors.white,
          reason: '会议内容不按状态绘制渐变底色',
        );
        expect(find.text('● $label'), findsOneWidget);
        expect(find.text(action), findsOneWidget);
        expect(find.text('威震天的快速会议'), findsOneWidget);
        expect(find.text('10-10 15:35'), findsOneWidget);
        expect(find.text('威震天'), findsOneWidget);
        expect(find.text('8人'), findsOneWidget);
        expect(
          tester
              .widget<ColoredBox>(
                find.byKey(const ValueKey('meeting-card-accent-meeting')),
              )
              .color,
          color,
        );
        expect(changes, 0);
        expect(harness.adapter.blocks.first.resource!.values, {
          'meetingId': 'm1',
          'title': '共享周会',
          'number': '123456',
        });
        expect(_delete, findsNothing);
        final remove = tester.getRect(_more);
        final open = tester.getRect(_open);
        expect(remove.overlaps(open), isFalse);
        expect(remove.bottom, lessThan(open.top));
        await _capture(tester, state.value);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'selected meeting card still receives primary and delete button taps',
    (tester) async {
      var opens = 0;
      final harness = await _mount(
        tester,
        services: CollabHostServices(
          onMeetingCardTap: (_, _, _) {
            opens++;
          },
        ),
      );
      final editor = harness.adapter.editorState;
      await tester.tap(find.text('共享周会'));
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
      expect(
        harness.adapter.blocks.any((b) => b.blockType == 'meeting'),
        isFalse,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'only primary button dispatches and never reopens a hidden keyboard',
    (tester) async {
      final received = <List<String>>[];
      var loads = 0;
      final harness = await _mount(
        tester,
        services: CollabHostServices(
          loadMeetingCard: (id) async {
            loads++;
            return CollabMeetingCardData(
              meetingId: id,
              state: CollabMeetingCardState.paused,
              title: '业务会议',
              number: '888',
            );
          },
          onMeetingCardTap: (id, title, number) {
            received.add([id, title, number]);
          },
        ),
      );
      final bounds = tester.getRect(_surface);
      for (final point in [
        bounds.topLeft + const Offset(20, 3),
        tester.getCenter(find.text('业务会议')),
        bounds.centerLeft + const Offset(2, 0),
      ]) {
        await tester.tapAt(point);
        await tester.pumpAndSettle();
      }
      expect(received, isEmpty);
      final state = harness.adapter.editorState;
      final selection = state.updateSelectionWithReason(
        Selection.single(path: [1], startOffset: 1),
        reason: SelectionUpdateReason.uiEvent,
      );
      await tester.pump();
      await selection;
      await tester.pump(const Duration(milliseconds: 150));
      expect(tester.testTextInput.hasAnyClients, isTrue);
      tester.testTextInput.hide();
      tester.testTextInput.log.clear();
      await tester.tap(_open);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 500));
      expect(received, [
        ['m1', '业务会议', '888'],
      ]);
      expect(find.text('加入会议'), findsOneWidget);
      expect(loads, 1);
      expect(
        tester.testTextInput.log.where(
          (call) => call.method == 'TextInput.show',
        ),
        isEmpty,
      );
      expect(state.selection, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  for (final state in [
    CollabMeetingCardState.paused,
    CollabMeetingCardState.completed,
  ]) {
    for (final fails in [false, true]) {
      testWidgets(
        '${state.name} button only invokes host callback, failure=$fails',
        (tester) async {
          var loads = 0;
          var calls = 0;
          final pending = Completer<void>();
          final errors = <Object>[];
          await _mount(
            tester,
            services: CollabHostServices(
              loadMeetingCard: (id) async {
                loads++;
                return CollabMeetingCardData(meetingId: id, state: state);
              },
              onMeetingCardTap: (_, _, _) {
                calls++;
                return pending.future;
              },
              onError: (_, error, _, _) => errors.add(error),
            ),
          );
          tester.testTextInput.log.clear();
          await tester.tap(_open);
          await tester.pump();
          expect(calls, 1);
          expect(loads, 1);
          if (fails) {
            pending.completeError(StateError('expected callback failure'));
          } else {
            pending.complete();
          }
          await tester.pumpAndSettle();
          await tester.pump(const Duration(milliseconds: 500));
          expect(loads, 1);
          expect(errors, hasLength(fails ? 1 : 0));
          expect(find.text('● ${state.label}'), findsOneWidget);
          expect(
            find.text(
              state == CollabMeetingCardState.completed ? '查看会议' : '加入会议',
            ),
            findsOneWidget,
          );
          expect(tester.widget<FilledButton>(_open).onPressed, isNotNull);
          expect(
            tester.testTextInput.log.where(
              (call) => call.method == 'TextInput.show',
            ),
            isEmpty,
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'loading disables primary; failure reports once and retry succeeds',
    (tester) async {
      final pending = Completer<CollabMeetingCardData?>();
      final errors = <Object>[];
      var loads = 0;
      await _mount(
        tester,
        settle: false,
        services: CollabHostServices(
          loadMeetingCard: (id) {
            loads++;
            return loads == 1
                ? pending.future
                : Future.value(
                    CollabMeetingCardData(
                      meetingId: id,
                      state: CollabMeetingCardState.canceled,
                    ),
                  );
          },
          onMeetingCardTap: (_, _, _) {},
          onError: (_, error, _, _) => errors.add(error),
        ),
      );
      expect(tester.widget<FilledButton>(_open).onPressed, isNull);
      pending.completeError(StateError('expected request failure'));
      await tester.pumpAndSettle();
      expect(errors, hasLength(1));
      expect(find.text('● 状态加载失败'), findsOneWidget);
      expect(tester.widget<FilledButton>(_open).onPressed, isNull);
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(find.text('● 已取消'), findsOneWidget);
      expect(find.text('查看会议'), findsOneWidget);
      expect(tester.widget<FilledButton>(_open).onPressed, isNotNull);
    },
  );

  for (final missing in [false, true]) {
    testWidgets(
      'missing or deleted meeting disables primary, missing=$missing',
      (tester) async {
        await _mount(
          tester,
          services: CollabHostServices(
            loadMeetingCard: (id) async => missing
                ? null
                : CollabMeetingCardData(
                    meetingId: id,
                    state: CollabMeetingCardState.deleted,
                  ),
            onMeetingCardTap: (_, _, _) {},
          ),
        );
        expect(tester.widget<FilledButton>(_open).onPressed, isNull);
        expect(
          tester
              .widget<IconButton>(
                find.descendant(of: _more, matching: find.byType(IconButton)),
              )
              .onPressed,
          isNotNull,
        );
        expect(find.text(missing ? '● 会议不存在' : '● 已删除'), findsOneWidget);
      },
    );
  }

  testWidgets('reference change ignores stale detail and late error', (
    tester,
  ) async {
    final requests = <String, Completer<CollabMeetingCardData?>>{};
    final errors = <Object>[];
    final harness = await _mount(
      tester,
      settle: false,
      services: CollabHostServices(
        loadMeetingCard: (id) => (requests[id] = Completer()).future,
        onError: (_, error, _, _) => errors.add(error),
        onMeetingCardTap: (_, _, _) {},
      ),
    );
    await harness.adapter.replaceFromRemote([_meeting('m2'), _tail]);
    await tester.pumpAndSettle();
    requests['m2']!.complete(
      const CollabMeetingCardData(
        meetingId: 'm2',
        state: CollabMeetingCardState.completed,
        title: '新会议',
      ),
    );
    await tester.pumpAndSettle();
    requests['m1']!.completeError(StateError('old request'));
    await tester.pumpAndSettle();
    expect(find.text('新会议'), findsOneWidget);
    expect(find.text('查看会议'), findsOneWidget);
    expect(errors, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'session replacement discards old result and loads new host data',
    (tester) async {
      final pending = Completer<CollabMeetingCardData?>();
      final errors = <Object>[];
      final harness = await _mount(
        tester,
        settle: false,
        services: CollabHostServices(
          loadMeetingCard: (_) => pending.future,
          onError: (_, error, _, _) => errors.add(error),
        ),
      );
      CollabRuntime.acquire(
        harness.owner,
        CollabHostServices(
          loadMeetingCard: (id) async => CollabMeetingCardData(
            meetingId: id,
            state: CollabMeetingCardState.canceled,
            title: '新会话会议',
          ),
          onMeetingCardTap: (_, _, _) {},
        ),
      );
      harness.adapter.editorState.reload();
      await tester.pumpAndSettle();
      pending.completeError(StateError('old session request'));
      await tester.pumpAndSettle();
      expect(find.text('新会话会议'), findsOneWidget);
      expect(find.text('查看会议'), findsOneWidget);
      expect(errors, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'absent detail loader shows unknown state and preserves shared reference',
    (tester) async {
      await _mount(
        tester,
        services: CollabHostServices(onMeetingCardTap: (_, _, _) {}),
      );
      expect(find.text('● 状态未知'), findsOneWidget);
      expect(find.text('共享周会'), findsOneWidget);
      expect(find.text('加入会议'), findsOneWidget);
      expect(tester.widget<FilledButton>(_open).onPressed, isNotNull);
    },
  );

  testWidgets(
    'wrong detail identity is rejected and disposed requests do not report',
    (tester) async {
      final pending = Completer<CollabMeetingCardData?>();
      final errors = <Object>[];
      var calls = 0;
      final harness = await _mount(
        tester,
        services: CollabHostServices(
          loadMeetingCard: (_) {
            calls++;
            return calls == 1
                ? Future.value(const CollabMeetingCardData(meetingId: 'wrong'))
                : pending.future;
          },
          onError: (_, error, _, _) => errors.add(error),
          onMeetingCardTap: (_, _, _) {},
        ),
      );
      expect(errors, hasLength(1));
      expect(tester.widget<FilledButton>(_open).onPressed, isNull);
      await tester.tap(find.text('重试'));
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      pending.completeError(StateError('after disposal'));
      await tester.pumpAndSettle();
      expect(errors, hasLength(1));
      expect(harness.adapter.blocks.first.resource!.string('title'), '共享周会');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    '320px large text layout keeps actions apart; preview hides delete but permits primary',
    (tester) async {
      var calls = 0;
      final harness = await _mount(
        tester,
        width: 320,
        scale: 1.5,
        services: CollabHostServices(
          loadMeetingCard: (id) async => CollabMeetingCardData(
            meetingId: id,
            state: CollabMeetingCardState.canceled,
            title: '很长的会议标题很长的会议标题很长的会议标题',
            moderatorName: '很长的主持人名称很长的主持人名称',
            memberCount: 999,
          ),
          onMeetingCardTap: (_, _, _) {
            calls++;
          },
        ),
      );
      expect(_delete, findsNothing);
      expect(tester.getRect(_more).overlaps(tester.getRect(_open)), isFalse);
      await _capture(tester, 'narrow');
      harness.adapter.editorState.editable = false;
      await tester.pumpAndSettle();
      expect(_delete, findsNothing);
      await tester.ensureVisible(_open);
      await tester.tap(_open);
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(tester.takeException(), isNull);
    },
  );
}

/// 当前合成会议的主按钮。
final _open = find.byKey(const ValueKey('meeting-open-meeting'));

/// 当前已展开更多菜单中的删除项。
final _delete = find.byKey(const ValueKey('meeting-delete-meeting'));

/// 当前会议卡片右上的更多入口。
final _more = find.byKey(const ValueKey('block-more-meeting'));

/// 当前合成会议的着色背景。
final _surface = find.byKey(const ValueKey('meeting-card-surface-meeting'));

/// 合成后置正文，供键盘和文档内容保留验证。
const _tail = CollabEditorBlock(id: 'tail', blockType: 'paragraph', text: '正文');

/// 为稳定会议[id]创建共享引用；业务状态故意不写正文。
CollabEditorBlock _meeting(String id) => CollabEditorBlock(
  id: 'meeting',
  blockType: 'meeting',
  text: '',
  resource: CollabResource.fromValues({
    'meetingId': id,
    'title': '共享周会',
    'number': '123456',
  }),
);

/// 测试拥有的适配器与会话，仅用于控制失效请求。
class _Harness {
  /// [adapter]为测试创建的适配器，[owner]为对应会话持有者，测试退出时统一释放。
  _Harness(this.adapter, this.owner);

  /// 测试拥有的编辑器适配器。
  final AppFlowyBlockEditorAdapter adapter;

  /// 测试拥有的会话身份。
  final Object owner;
}

/// 在[tester]挂载真实编辑器，注入[services]；[width]/[scale]控制窄屏与文字缩放。
/// [settle]默认等待请求及布局完成，挂起请求时可为false；[onChanged]统计正文提交，不拥有回调资源。
/// 测试退出时解除挂载、释放编辑器/会话并还原屏幕约束。
Future<_Harness> _mount(
  WidgetTester tester, {
  required CollabHostServices services,
  double width = 390,
  double scale = 1,
  bool settle = true,
  void Function(List<CollabEditorBlock>)? onChanged,
}) async {
  await tester.binding.setSurfaceSize(Size(width, 350));
  final owner = Object();
  CollabRuntime.acquire(owner, services);
  final adapter = AppFlowyBlockEditorAdapter(
    initialBlocks: [_meeting('m1'), _tail],
    onLocalBlocksChanged: onChanged ?? (_) {},
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
        fontFamily: Platform.environment['MEETING_CARD_PREVIEW_FONT'] == null
            ? null
            : 'MeetingPreview',
      ),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: Scaffold(
        body: RepaintBoundary(
          key: const ValueKey('meeting-capture'),
          child: ColoredBox(
            color: Colors.white,
            child: AppFlowyEditor(
              editorStyle: const EditorStyle.mobile(
                padding: EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              ),
              editorState: adapter.editorState,
              blockComponentBuilders: {
                ...standardBlockComponentBuilderMap,
                'meeting': CollabMeetingBlockComponentBuilder(),
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

/// [tester]可选输出[name]的真实渲染PNG；仅设置MEETING_CARD_SCREENSHOTS环境变量时写入该目录。
Future<void> _capture(WidgetTester tester, String name) async {
  final directory = Platform.environment['MEETING_CARD_SCREENSHOTS'];
  if (directory == null) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('meeting-capture')),
  );
  await tester.runAsync(() async {
    final capture = await boundary.toImage(pixelRatio: 2);
    try {
      final bytes = await capture.toByteData(format: ui.ImageByteFormat.png);
      await Directory(directory).create(recursive: true);
      await File(
        '$directory/meeting-card-$name.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      capture.dispose();
    }
  });
}

/// 可选读取测试预览字体，路径由环境变量提供；默认回归使用Flutter测试字体，不依赖系统文件。
Future<void> _loadPreviewFonts() async {
  for (final (variable, family) in [
    ('MEETING_CARD_PREVIEW_FONT', 'MeetingPreview'),
    ('MEETING_CARD_ICON_FONT', 'MaterialIcons'),
  ]) {
    final path = Platform.environment[variable];
    if (path == null) continue;
    final bytes = await File(path).readAsBytes();
    await (FontLoader(
      family,
    )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
  }
}
