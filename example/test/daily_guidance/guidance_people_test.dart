import 'dart:async';

import 'package:cses_common/runtime/context/context.dart';
import 'package:cses_mobile_collab_demo/src/daily_guidance/guidance_people.dart';
import 'package:cses_mobile_collab_demo/src/demo/cses_account_login.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/common_login_harness.dart';

/// 验证组织身份、真实 HTTP 树解析与弹窗取消/权限/会话边界。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('引用 JSON 保留身份种类和子树，拒绝非法身份', () {
    const person = GuidancePerson(
      id: 'same-id',
      name: '研发',
      type: 'department',
      children: [GuidancePerson(id: 'same-id', name: '同名成员', department: '研发')],
    );
    final restored = GuidancePerson.fromJson(person.toJson());
    expect(restored.identity, 'department:same-id');
    expect(restored.children.single.identity, 'user:same-id');
    expect(restored.children.single.department, '研发');
    expect(GuidancePerson.fromJson({'id': 'u', 'name': '成员'}).type, 'user');
    for (final json in [
      {'id': '', 'name': '成员'},
      {'id': 'u', 'name': '成员', 'type': 'unknown'},
      {'id': 'u', 'name': '成员', 'children': 2},
    ]) {
      expect(() => GuidancePerson.fromJson(json), throwsFormatException);
    }
  });

  group('真实组织目录', () {
    late CommonLoginHarness harness;
    late CsesGuidanceDirectory directory;
    setUp(() async {
      harness = CommonLoginHarness();
      await harness.install();
      await const CsesAccountLogin().login('account', 'password');
      harness.requests.clear();
      directory = CsesGuidanceDirectory();
      harness.respond = (_) => jsonResponse({
        'isSuccess': true,
        'items': [
          {
            'id': 'company',
            'name': '企业',
            'isUser': false,
            'children': [
              {
                'id': 'same',
                'name': '研发',
                'isUser': false,
                'children': [
                  {'id': 'same', 'name': '张三', 'isUser': true},
                  {'id': 'same', 'name': '重复人员', 'isUser': true},
                  {'id': 'u2', 'name': '张三', 'isUser': true, 'deptName': '技术'},
                ],
              },
            ],
          },
        ],
      });
    });
    tearDown(() => harness.uninstall());

    test('保留真实部门树、同名不同 ID 与跨类型同 ID，缓存同会话结果', () async {
      final roots = await directory.load();
      final department = roots.single.children.single;
      expect(department.identity, 'department:same');
      expect(department.children.map((person) => person.identity), [
        'user:same',
        'user:u2',
      ]);
      expect(department.children.first.name, '张三');
      expect(department.children.first.department, '研发');
      expect(department.children.last.department, '技术');
      expect(identical(roots, await directory.load()), isTrue);
      final request = harness.requests.single;
      expect(request.path, '/Company/readAllChildren');
      expect(request.data, {'orgId': 'server-company', 'isReadUser': true});
      expect(request.headers['cookieId'], 'server-cookie');
    });

    test('失败与非法子树不缓存，重试重新请求', () async {
      harness.respond = (_) => jsonResponse({'isSuccess': false});
      await expectLater(directory.load(), throwsFormatException);
      harness.respond = (_) => jsonResponse({
        'isSuccess': true,
        'items': [
          {'id': 'd', 'name': '研发', 'children': 'bad'},
        ],
      });
      await expectLater(directory.load(), throwsFormatException);
      harness.respond = (_) => jsonResponse({'isSuccess': true, 'items': []});
      expect(await directory.load(), isEmpty);
      expect(harness.requests.length, 3);
    });

    test('会话切换拒绝缓存与请求迟到结果', () async {
      final pending = Completer<void>();
      harness.respond = (_) async {
        await pending.future;
        return jsonResponse({'isSuccess': true, 'items': []});
      };
      final request = directory.load();
      await pumpEventQueue();
      ctx.cookieId = 'new-session';
      pending.complete();
      await expectLater(request, throwsFormatException);
      await expectLater(directory.load(), throwsFormatException);
      expect(harness.requests.length, 1);
    });
  });

  const tree = [
    GuidancePerson(
      id: 'company',
      name: '企业',
      type: 'department',
      children: [
        GuidancePerson(
          id: 'd1',
          name: '研发',
          type: 'department',
          children: [
            GuidancePerson(id: 'same', name: '张三', department: '研发'),
            GuidancePerson(id: 'u2', name: '张三', department: '研发'),
          ],
        ),
        GuidancePerson(
          id: 'same',
          name: '设计',
          type: 'department',
          children: [GuidancePerson(id: 'u3', name: 'Alice', department: '设计')],
        ),
      ],
    ),
  ];

  testWidgets('组织钻取和面包屑、多选部门和同名人员，一次返回多个引用', (tester) async {
    List<GuidancePerson>? result;
    await _open(tester, _Directory(tree), (value) => result = value);
    await tester.tap(
      find.byKey(const ValueKey('guidance-open-department:company')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('guidance-select-department:same')),
    );
    await tester.tap(find.byKey(const ValueKey('guidance-open-department:d1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('guidance-select-user:same')));
    await tester.tap(find.byKey(const ValueKey('guidance-select-user:u2')));
    await tester.tap(find.byKey(const ValueKey('guidance-people-confirm')));
    await tester.pumpAndSettle();
    expect(result!.map((person) => person.identity), [
      'department:same',
      'user:same',
      'user:u2',
    ]);
    expect(result!.every((person) => person.children.isEmpty), isTrue);
  });

  testWidgets('搜索跨部门但身份唯一，关闭不返回任何选择', (tester) async {
    List<GuidancePerson>? result;
    var completed = false;
    await _open(tester, _Directory(tree), (value) {
      result = value;
      completed = true;
    });
    await tester.enterText(
      find.byKey(const ValueKey('guidance-people-search')),
      '张三',
    );
    await tester.pump(const Duration(milliseconds: 210));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('guidance-person-user:same')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('guidance-person-user:u2')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('guidance-select-user:same')));
    await tester.tap(find.byKey(const ValueKey('guidance-people-close')));
    await tester.pumpAndSettle();
    expect(completed, isTrue);
    expect(result, isNull);
  });

  testWidgets('搜索部门后钻取恢复完整组织面包屑', (tester) async {
    await _open(tester, _Directory(tree), (_) {});
    await tester.enterText(
      find.byKey(const ValueKey('guidance-people-search')),
      '研发',
    );
    await tester.pump(const Duration(milliseconds: 210));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('guidance-open-department:d1')));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextButton, '企业'), findsOneWidget);
    expect(find.widgetWithText(TextButton, '研发'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '企业'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('guidance-person-department:d1')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('guidance-people-close')));
    await tester.pumpAndSettle();
  });

  testWidgets('空目录、加载失败与显式重试均有真实状态', (tester) async {
    final directory = _Directory(
      const [],
      error: const FormatException('offline'),
    );
    await _open(tester, directory, (_) {});
    expect(find.text('组织加载失败，请重试'), findsOneWidget);
    directory.error = null;
    await tester.tap(find.byKey(const ValueKey('guidance-people-retry')));
    await tester.pumpAndSettle();
    expect(find.text('当前组织暂无成员'), findsOneWidget);
    expect(directory.loads, 2);
    await tester.tap(find.byKey(const ValueKey('guidance-people-close')));
    await tester.pumpAndSettle();
  });

  testWidgets('权限撤销使选择失效，恢复后仍需重开', (tester) async {
    var canEdit = true;
    List<GuidancePerson>? result;
    await _open(
      tester,
      _Directory(tree),
      (value) => result = value,
      canEdit: () => canEdit,
    );
    await tester.tap(
      find.byKey(const ValueKey('guidance-select-department:company')),
    );
    canEdit = false;
    await tester.pump(const Duration(milliseconds: 210));
    expect(find.text('当前不可编辑，请关闭后重新打开'), findsOneWidget);
    canEdit = true;
    await tester.pump(const Duration(milliseconds: 210));
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('guidance-people-confirm')),
          )
          .onPressed,
      isNull,
    );
    await tester.tap(find.byKey(const ValueKey('guidance-people-close')));
    await tester.pumpAndSettle();
    expect(result, isNull);
  });

  testWidgets('确认后等待退场，退场期间会话切换返回 null', (tester) async {
    final previousCookie = ctx.cookieId;
    addTearDown(() => ctx.cookieId = previousCookie);
    var completed = false;
    List<GuidancePerson>? result;
    await _open(tester, _Directory(tree), (value) {
      completed = true;
      result = value;
    });
    await tester.tap(
      find.byKey(const ValueKey('guidance-select-department:company')),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('guidance-people-confirm')));
    await tester.pump(const Duration(milliseconds: 20));
    expect(completed, isFalse);
    ctx.cookieId = 'changed-during-exit';
    await tester.pumpAndSettle();
    expect(completed, isTrue);
    expect(result, isNull);
  });

  testWidgets('关闭后迟到加载不更新面板，大字和键盘约束不溢出', (tester) async {
    final pending = Completer<List<GuidancePerson>>();
    final directory = _Directory(tree)..pending = pending.future;
    await _open(
      tester,
      directory,
      (_) {},
      textScale: 2,
      keyboard: 280,
      settle: false,
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const ValueKey('guidance-people-close')));
    await tester.pumpAndSettle();
    pending.complete(tree);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('选择用户和部门'), findsNothing);
  });
}

/// 在 [tester] 中打开注入 [directory] 的面板，结果交给 [onResult]。
/// [canEdit] 默认始终可写；[textScale] 和 [keyboard] 分别模拟字号倍率及键盘高度；
/// [settle] 为 false 时允许目录请求保持未完成，不等待加载动画结束。
Future<void> _open(
  WidgetTester tester,
  GuidanceDirectory directory,
  void Function(List<GuidancePerson>?) onResult, {
  bool Function()? canEdit,
  double textScale = 1,
  double keyboard = 0,
  bool settle = true,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(
          size: const Size(800, 600),
          textScaler: TextScaler.linear(textScale),
          viewInsets: EdgeInsets.only(bottom: keyboard),
        ),
        child: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                final result = await showGuidancePeoplePicker(
                  context,
                  directory: directory,
                  canEdit: canEdit ?? () => true,
                );
                onResult(result);
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开'));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

/// 无网络测试目录，仅控制真实入口的加载完成或失败，不参与生产数据。
class _Directory implements GuidanceDirectory {
  /// [roots] 为测试组织树，[error] 为可重试加载错误。
  _Directory(this.roots, {this.error});

  /// 当前测试树。
  final List<GuidancePerson> roots;

  /// 非空时下一次加载抛出的错误。
  Object? error;

  /// 可选迟到结果，用于验证关闭后的异步边界。
  Future<List<GuidancePerson>>? pending;

  /// 实际请求次数，验证明确重试。
  int loads = 0;

  /// 返回测试树或抛出受控错误；每次调用均记录次数。
  @override
  Future<List<GuidancePerson>> load() async {
    loads++;
    if (error != null) throw error!;
    return pending == null ? roots : await pending!;
  }
}
