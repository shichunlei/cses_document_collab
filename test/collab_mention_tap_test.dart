import 'dart:async';
import 'dart:convert';
import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/editor/collab_mention_tap_handler.dart';
import 'package:cses_document_collab/src/native/collab_runtime.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cses_document_collab/src/ui/modal/collab_menu_row.dart';

/// 公开回调契约与真实编辑页点击路由，不使用线上账号或业务请求。
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
  test(
    'payload detaches and freezes nested maps/lists without changing raw keys',
    () {
      final status = <String, Object?>{'name': '未开始'};
      final tags = <Object?>[status, true, null, 123];
      final attrs = <String, Object?>{
        'd:mentionId': 'm1',
        'status': status,
        'tags': tags,
      };
      final tap = CollabMentionTap(
        type: CollabMentionType.meeting,
        id: 'm1',
        name: '周会',
        attributes: attrs,
      );
      status['name'] = '已完成';
      tags.add('迟到修改');
      attrs.clear();
      expect(tap.attributes['d:mentionId'], 'm1');
      expect((tap.attributes['status'] as Map)['name'], '未开始');
      expect(tap.attributes['tags'], hasLength(4));
      expect(() => tap.attributes['new'] = true, throwsUnsupportedError);
      expect(
        () => (tap.attributes['status'] as Map)['name'] = '修改',
        throwsUnsupportedError,
      );
      expect(
        () => (tap.attributes['tags'] as List).add(0),
        throwsUnsupportedError,
      );
    },
  );
  test(
    'toJson supports automatic JSON encoding for all mention types and preserves raw attributes',
    () {
      final attributes = <String, Object?>{
        'd:mentionId': '原始-ID',
        'status': {'name': '未开始'},
        'values': [null, true, 123, 1.25, '😀'],
      };
      for (final type in CollabMentionType.values) {
        final tap = CollabMentionTap(
          type: type,
          id: '实体-ID',
          name: '',
          attributes: attributes,
        );
        expect(jsonDecode(jsonEncode(tap)), {
          'type': type.name,
          'id': '实体-ID',
          'name': '',
          'attributes': attributes,
        });
        final json = tap.toJson();
        json['name'] = '仅修改导出结果';
        json['attributes'] = {};
        expect(tap.toJson()['name'], isEmpty);
        expect(tap.toJson()['attributes'], attributes);
        expect(
          () => (tap.toJson()['attributes'] as Map)['extra'] = true,
          throwsUnsupportedError,
        );
      }
    },
  );
  test('invalid payloads fail explicitly', () {
    final cycle = <Object?>[];
    cycle.add(cycle);
    for (final value in [
      DateTime(2026),
      double.nan,
      {1: 'bad key'},
      cycle,
    ]) {
      expect(
        () => CollabMentionTap(
          type: CollabMentionType.doc,
          id: 'd1',
          name: '',
          attributes: {'value': value},
        ),
        throwsArgumentError,
      );
    }
    expect(
      () => CollabMentionTap(
        type: CollabMentionType.user,
        id: '',
        name: '',
        attributes: {},
      ),
      throwsArgumentError,
    );
  });
  for (final kind in CollabMentionType.values) {
    testWidgets(
      '${kind.name} opens details with full snapshot in edit and preview',
      (tester) async {
        final received = <CollabMentionTap>[];
        final adapter = await _mount(
          tester,
          kind,
          CollabHostServices(onMentionTap: received.add),
        );
        await _tapDetails(tester, kind);
        await tester.pumpAndSettle();
        expect(received, hasLength(1));
        final tap = received.single;
        expect(tap.type, kind);
        expect(tap.id, '${kind.name}-id');
        expect(tap.name, '${kind.name}原名');
        expect(tap.attributes, _raw(kind));
        expect(tap.attributes.keys.any((k) => k.startsWith('cses_')), isFalse);
        expect(find.text('删除提及'), findsNothing);
        expect(find.text('用户ID：user-id'), findsNothing);
        expect(adapter.blocks.single.text, '前\uFFFC后');
        await tester.tap(find.text('预览'));
        await tester.pumpAndSettle();
        await _tapDetails(tester, kind);
        await tester.pumpAndSettle();
        expect(received, hasLength(2));
        expect(adapter.editorState.editable, isFalse);
        expect(adapter.blocks.single.text, '前\uFFFC后');
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'async handler is awaited, duplicate taps ignored, selection restored',
    (tester) async {
      final pending = Completer<void>();
      var calls = 0;
      final adapter = await _mount(
        tester,
        CollabMentionType.meeting,
        CollabHostServices(
          onMentionTap: (_) {
            calls++;
            return pending.future;
          },
        ),
      );
      adapter.editorState.selection = Selection.single(
        path: [0],
        startOffset: 2,
      );
      await _tapDetails(tester, CollabMentionType.meeting);
      await tester.pump();
      expect(adapter.editorState.selection, isNull);
      await tester.tap(_chip(CollabMentionType.meeting));
      await tester.pump();
      expect(calls, 1);
      pending.complete();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(
        adapter.editorState.selection,
        Selection.single(path: [0], startOffset: 2),
      );
      expect(find.text('删除提及'), findsNothing);
    },
  );
  testWidgets(
    'real awaited host route returns to the same editor without a panel',
    (tester) async {
      final nav = GlobalKey<NavigatorState>();
      final adapter = await _mount(
        tester,
        CollabMentionType.doc,
        CollabHostServices(
          onMentionTap: (tap) async {
            await nav.currentState!.push<void>(
              MaterialPageRoute(
                builder: (_) => Scaffold(
                  appBar: AppBar(title: Text(tap.name)),
                  body: Text(tap.id),
                ),
              ),
            );
          },
        ),
        navigatorKey: nav,
      );
      adapter.editorState.selection = Selection.single(
        path: [0],
        startOffset: 2,
      );
      await _tapDetails(tester, CollabMentionType.doc);
      await tester.pumpAndSettle();
      expect(find.text('doc-id'), findsOneWidget);
      expect(adapter.editorState.selection, isNull);
      nav.currentState!.pop();
      await tester.pumpAndSettle();
      expect(
        adapter.editorState.selection,
        Selection.single(path: [0], startOffset: 2),
      );
      expect(find.text('删除提及'), findsNothing);
    },
  );
  testWidgets(
    'sync and async exceptions report once and never open the fallback panel',
    (tester) async {
      final errors = <Object>[];
      var attempt = 0;
      await _mount(
        tester,
        CollabMentionType.task,
        CollabHostServices(
          onError: (_, error, _, _) => errors.add(error),
          onMentionTap: (_) {
            if (attempt++ == 0) throw StateError('sync');
            return Future<void>.error(StateError('async'));
          },
        ),
      );
      for (var i = 0; i < 2; i++) {
        await _tapDetails(tester, CollabMentionType.task);
        await tester.pumpAndSettle();
        expect(errors, hasLength(i + 1));
        expect(find.text('操作失败，请重试'), findsWidgets);
        expect(find.text('删除提及'), findsNothing);
        expect(tester.takeException(), isNull);
      }
    },
  );
  testWidgets(
    'late failure after disposal is reported without navigating or restoring dead state',
    (tester) async {
      final pending = Completer<void>();
      final errors = <Object>[];
      final adapter = await _mount(
        tester,
        CollabMentionType.user,
        CollabHostServices(
          onMentionTap: (_) => pending.future,
          onError: (_, error, _, _) => errors.add(error),
        ),
      );
      await tester.tap(_chip(CollabMentionType.user));
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      adapter.dispose();
      pending.completeError(StateError('late failure'));
      await tester.pumpAndSettle();
      expect(errors, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'session replacement never restores the old caret or reports to the new host',
    (tester) async {
      final pending = Completer<void>();
      final oldErrors = <Object>[];
      final newErrors = <Object>[];
      final owner = Object();
      final adapter = await _mount(
        tester,
        CollabMentionType.user,
        CollabHostServices(
          onMentionTap: (_) => pending.future,
          onError: (_, error, _, _) => oldErrors.add(error),
        ),
        runtimeOwner: owner,
      );
      adapter.editorState.selection = Selection.single(
        path: [0],
        startOffset: 2,
      );
      await tester.tap(_chip(CollabMentionType.user));
      await tester.pump();
      CollabRuntime.release(owner);
      final nextOwner = Object();
      CollabRuntime.acquire(
        nextOwner,
        CollabHostServices(onError: (_, error, _, _) => newErrors.add(error)),
      );
      addTearDown(() => CollabRuntime.release(nextOwner));
      pending.completeError(StateError('old account callback'));
      await tester.pumpAndSettle();
      expect(oldErrors, hasLength(1));
      expect(newErrors, isEmpty);
      expect(adapter.editorState.selection, isNull);
      expect(find.text('操作失败，请重试'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'missing raw attributes reports failure instead of fabricating a payload',
    (tester) async {
      var calls = 0;
      final errors = <Object>[];
      await _mount(
        tester,
        CollabMentionType.user,
        CollabHostServices(
          onMentionTap: (_) {
            calls++;
          },
          onError: (_, error, _, _) => errors.add(error),
        ),
        includeRaw: false,
      );
      await tester.tap(_chip(CollabMentionType.user));
      await tester.pumpAndSettle();
      expect(calls, 0);
      expect(errors, hasLength(1));
      expect(find.text('操作失败，请重试'), findsOneWidget);
      expect(find.text('用户ID：user-id'), findsNothing);
    },
  );
  for (final includeRaw in [false, true]) {
    testWidgets(
      'user without callback has no profile or input side effects, raw=$includeRaw',
      (tester) async {
        final errors = <Object>[];
        final adapter = await _mount(
          tester,
          CollabMentionType.user,
          CollabHostServices(onError: (_, error, _, _) => errors.add(error)),
          includeRaw: includeRaw,
        );
        final state = adapter.editorState;
        final selection = Selection.single(path: [0], startOffset: 2);
        state.selection = selection;
        final beforeExtraInfo = state.selectionExtraInfo;
        final chip = tester.widget<GestureDetector>(
          _chip(CollabMentionType.user),
        );
        expect(chip.onTap, isNull);
        // Even a direct dispatch without fallback does not suspend editor input.
        await handleCollabMentionTap(
          tester.element(_chip(CollabMentionType.user)),
          state,
          state.document.first!,
          1,
        );
        expect(state.selection, selection);
        expect(state.selectionExtraInfo, beforeExtraInfo);
        await tester.tap(_chip(CollabMentionType.user));
        await tester.pumpAndSettle();
        expect(find.byType(BottomSheet), findsNothing);
        expect(find.text('复制姓名'), findsNothing);
        expect(find.text('删除提及'), findsNothing);
        expect(adapter.blocks.single.text, '前\uFFFC后');
        await tester.tap(find.text('预览'));
        await tester.pumpAndSettle();
        expect(
          tester.widget<GestureDetector>(_chip(CollabMentionType.user)).onTap,
          isNull,
        );
        await tester.tap(_chip(CollabMentionType.user));
        await tester.pumpAndSettle();
        expect(find.byType(BottomSheet), findsNothing);
        expect(errors, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets('missing callback retains entity default panel', (tester) async {
    await _mount(tester, CollabMentionType.meeting, const CollabHostServices());
    await tester.tap(_chip(CollabMentionType.meeting));
    await tester.pumpAndSettle();
    expect(find.text('打开会议详情'), findsOneWidget);
    expect(
      tester
          .widget<CollabMenuRow>(
            find.byKey(const ValueKey('entity-mention-open-detail')),
          )
          .enabled,
      isFalse,
    );
    expect(find.text('切换为卡片视图'), findsOneWidget);
    expect(find.text('删除提及'), findsOneWidget);
  });
}

/// 点击[tester]中的[kind]提及；非用户必须明确选择打开详情。
Future<void> _tapDetails(WidgetTester tester, CollabMentionType kind) async {
  await tester.tap(_chip(kind));
  if (kind != CollabMentionType.user) {
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('entity-mention-open-detail')));
    await tester.pumpAndSettle();
  }
}

/// 取得 [kind] 对应的真实正文点击区域。
Finder _chip(CollabMentionType kind) => find.byKey(
  ValueKey(
    kind == CollabMentionType.user
        ? 'collab-inline-mention-body-1'
        : 'collab-inline-entity-body-1',
  ),
);

/// [kind] 的原始属性；用户用历史键验证不被规范身份覆盖。
Map<String, Object?> _raw(CollabMentionType kind) => {
  if (kind == CollabMentionType.user) ...{
    'd:mentionType': 'user',
    'd:mentionId': 'user-id',
    'deptName': '测试部门',
  } else ...{
    'mentionType': kind.name,
    'mentionId': '${kind.name}-id',
  },
  'status': {'name': '未开始'},
  'unknown': [
    1,
    {'keep': true},
  ],
  'a:bold': true,
};

/// 将 [kind] 挂到真实编辑页并注入 [services]；[navigatorKey] 可借用宿主路由测试跳转。
/// [runtimeOwner] 可指定会话所有者以验证切换；null由测试创建。
/// [includeRaw] 默认为true，false模拟缺少原始属性的未确认用户投影。
/// 测试持有控制器和适配器，退场后释放；回调不拥有这些资源。
Future<AppFlowyBlockEditorAdapter> _mount(
  WidgetTester tester,
  CollabMentionType kind,
  CollabHostServices services, {
  GlobalKey<NavigatorState>? navigatorKey,
  Object? runtimeOwner,
  bool includeRaw = true,
}) async {
  final owner = runtimeOwner ?? Object();
  CollabRuntime.acquire(owner, services);
  final adapter = AppFlowyBlockEditorAdapter(
    initialBlocks: [
      CollabEditorBlock(
        id: 'body',
        blockType: 'paragraph',
        text: '前\uFFFC后',
        segments: [
          const CollabEditorTextSegment(text: '前'),
          CollabEditorTextSegment(
            text: '\uFFFC',
            inlineMention: '${kind.name}原名',
            mentionId: '${kind.name}-id',
            mentionType: kind == CollabMentionType.user ? null : kind.name,
            mentionAttributes: includeRaw ? jsonEncode(_raw(kind)) : null,
          ),
          const CollabEditorTextSegment(text: '后'),
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
    if (!adapter.editorState.isDisposed) adapter.dispose();
    CollabRuntime.release(owner);
  });
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: navigatorKey,
      home: CollaborativeEditorPage(collab: controller),
    ),
  );
  await tester.pumpAndSettle();
  return adapter;
}

/// 测试控制器借用编辑器，不初始化原生资源。
class _ReadyController extends CollabController {
  /// [state] 由测试拥有并负责释放。
  _ReadyController(this.state) : super.localDraft(databasePath: '/unused');

  /// 借用的测试编辑器，不转移所有权。
  final EditorState state;

  /// 返回借用编辑器。
  @override
  EditorState get editorState => state;

  /// 测试投影已就绪。
  @override
  bool get initialized => true;

  /// 页面可切换预览；业务跳转不受编辑权限限制。
  @override
  bool get canEdit => true;
}
