import 'dart:async';

import 'package:cses_common/runtime/context/context.dart';
import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:cses_mobile_collab_demo/src/demo/mention_avatar.dart';
import 'package:cses_mobile_collab_demo/src/demo/mention_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 宿主人员选择器的搜索、头像、异步竞态、权限及路由资源释放。
void main() {
  setUp(() {
    ctx.faceDomain = 'https://face.example.test';
    ctx.timestamp = DateTime.fromMillisecondsSinceEpoch(1234);
  });
  testWidgets(
    'host picker searches initial keyword and returns selected user after transition',
    (tester) async {
      final context = await _mount(tester);
      final canEdit = _Permission();
      addTearDown(canEdit.dispose);
      final directory = _Directory();
      final result = showDemoMentionPicker(
        context,
        directory: directory,
        canEdit: canEdit,
        keyword: '张',
      );
      await tester.pumpAndSettle();
      expect(directory.keywords, ['张']);
      expect(find.byType(DemoMentionAvatar), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('mention-search')),
        '不存在',
      );
      await tester.pump(const Duration(milliseconds: 260));
      await tester.pumpAndSettle();
      expect(find.text('没有匹配的人员'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('mention-search')), '张');
      await tester.pump(const Duration(milliseconds: 260));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('mention-user-u1')));
      await tester.pumpAndSettle();
      expect(await result, _user);
      expect(canEdit.isObserved, isFalse);
      expect(find.byKey(const ValueKey('mention-search')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'old query cannot replace new query; failed requests retry; closing ignores late result',
    (tester) async {
      final context = await _mount(tester);
      final canEdit = _Permission();
      addTearDown(canEdit.dispose);
      final directory = _PendingDirectory();
      final result = showDemoMentionPicker(
        context,
        directory: directory,
        canEdit: canEdit,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.enterText(find.byKey(const ValueKey('mention-search')), '新');
      await tester.pump(const Duration(milliseconds: 260));
      directory.requests['新']!.complete([
        const CollabMentionUser(id: 'new', name: '新用户'),
      ]);
      await tester.pumpAndSettle();
      directory.requests['']!.complete([_user]);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('mention-user-new')), findsOneWidget);
      expect(find.byKey(const ValueKey('mention-user-u1')), findsNothing);
      await tester.enterText(
        find.byKey(const ValueKey('mention-search')),
        '失败',
      );
      await tester.pump(const Duration(milliseconds: 260));
      directory.requests['失败']!.completeError(
        StateError('expected search failure'),
      );
      await tester.pumpAndSettle();
      expect(find.text('人员加载失败，请重试'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('mention-retry')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('mention-close')));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(await result, isNull);
      directory.requests['失败']!.complete([_user]);
      await tester.pumpAndSettle();
      expect(canEdit.isObserved, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'permission change disables selection and ignores pending request',
    (tester) async {
      final context = await _mount(tester);
      final canEdit = _Permission();
      addTearDown(canEdit.dispose);
      final directory = _PendingDirectory();
      final result = showDemoMentionPicker(
        context,
        directory: directory,
        canEdit: canEdit,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      canEdit.value = false;
      await tester.pumpAndSettle();
      directory.requests['']!.complete([_user]);
      await tester.pumpAndSettle();
      expect(find.text('当前不可编辑'), findsOneWidget);
      expect(find.byKey(const ValueKey('mention-user-u1')), findsNothing);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('mention-search')))
            .enabled,
        isFalse,
      );
      await tester.tap(find.byKey(const ValueKey('mention-close')));
      await tester.pumpAndSettle();
      expect(await result, isNull);
      expect(canEdit.isObserved, isFalse);
      expect(
        await showDemoMentionPicker(
          context,
          directory: directory,
          canEdit: canEdit,
        ),
        isNull,
      );
      expect(tester.takeException(), isNull);
    },
  );
}

/// 仅挂载宿主Navigator，[tester] 驱动路由及搜索输入，不引入编辑器实现。
Future<BuildContext> _mount(WidgetTester tester) async {
  late BuildContext context;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (value) {
            context = value;
            return const SizedBox();
          },
        ),
      ),
    ),
  );
  return context;
}

/// 选择器显示的稳定人员快照，不进入真实文档。
const _user = CollabMentionUser(id: 'u1', name: '张三', department: '研发');

/// 宿主持有的测试目录，记录初始和后续查询。
class _Directory implements CollabMentionDirectory {
  /// 按调用顺序保留输入关键词。
  final keywords = <String>[];

  /// 按 [keyword] 过滤固定测试人员。
  @override
  Future<List<CollabMentionUser>> search(String keyword) async {
    keywords.add(keyword);
    return keyword.isEmpty || _user.name.contains(keyword) ? [_user] : [];
  }

  /// 选择器不读取 [userId] 的资料。
  @override
  Future<CollabMentionUser?> load(String userId) async => null;
}

/// 宿主持有的挂起请求，由测试控制完成顺序。
class _PendingDirectory implements CollabMentionDirectory {
  /// 每个关键词最新的请求，重试覆盖上次已完成请求。
  final requests = <String, Completer<List<CollabMentionUser>>>{};

  /// 挂起 [keyword] 的请求，用于过期和失败回归。
  @override
  Future<List<CollabMentionUser>> search(String keyword) =>
      (requests[keyword] = Completer()).future;

  /// 选择器不读取 [userId] 的资料。
  @override
  Future<CollabMentionUser?> load(String userId) async => null;
}

/// 暴露监听状态供测试验证借用信号的注销，不在测试外访问protected成员。
class _Permission extends ValueNotifier<bool> {
  /// 每个选择流程创建独立可编辑信号，测试结束释放。
  _Permission() : super(true);

  /// 当前宿主面板是否仍持有权限监听。
  bool get isObserved => hasListeners;
}
