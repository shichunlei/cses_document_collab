import 'dart:async';

import 'package:cses_common/runtime/context/context.dart';
import 'package:cses_mobile_collab_demo/src/demo/cses_account_login.dart';
import 'package:cses_mobile_collab_demo/src/service/cses_task_card_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/common_login_harness.dart';

/// 真实Common封装下的task_v3参数、卡片快照解析与账号隔离回归。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late CommonLoginHarness harness;
  late CsesTaskCardService service;
  setUp(() async {
    harness = CommonLoginHarness();
    await harness.install();
    await const CsesAccountLogin().login('account', 'password');
    harness.requests.clear();
    service = CsesTaskCardService();
  });
  tearDown(() => harness.uninstall());

  test(
    'reads desktop detail contract through Common and maps full screenshot fields',
    () async {
      harness.respond = (_) =>
          jsonResponse({'isSuccess': true, 'item': _detail()});
      final data = (await service.load('task-fixture'))!;
      expect(data.taskId, 'task-fixture');
      expect(data.title, '测试状态111–111');
      expect(data.priority!.name, '一般');
      expect(data.priority!.color, '#59B463');
      expect(data.status!.name, '待开始');
      expect(data.leaders.single.id, 'user-id');
      expect(data.leaders.single.avatarUrl, 'https://example.test/avatar.jpg');
      expect(data.startTime, DateTime.utc(2026, 5, 29));
      expect(data.endTime, DateTime.utc(2026, 6, 14, 23, 59));
      expect(data.progress, 12.35);
      expect(data.fileCount, 0);
      expect(data.subTaskCount, 3);
      expect(data.path.map((p) => p.type), ['space', 'project', 'workItem']);
      expect(data.path.map((p) => p.name), ['企业空间', '测试状态-默认', '普通任务']);
      final request = harness.requests.single;
      expect(request.path, '/taskManage/task/detail');
      expect(request.method, 'POST');
      expect(request.data, {
        'queryType': 'detail',
        'tableName': 'task_v3',
        'id': 'task-fixture',
      });
      expect(request.headers['cookieId'], 'server-cookie');
      expect(request.headers['companyId'], 'server-company');
    },
  );

  test(
    'optional data stays unknown, explicit empty item means missing',
    () async {
      harness.respond = (_) => jsonResponse({
        'isSuccess': true,
        'item': {'id': 'task-fixture', 'startTime': 0, 'endTime': 0},
      });
      final data = (await service.load('task-fixture'))!;
      expect(data.title, isNull);
      expect(data.priority, isNull);
      expect(data.progress, isNull);
      expect(data.leaders, isEmpty);
      expect(data.path, isEmpty);
      expect(data.fileCount, isNull);
      expect(data.startTime, isNull);
      expect(data.endTime, isNull);
      harness.respond = (_) => jsonResponse({'isSuccess': true, 'item': null});
      expect(await service.load('task-fixture'), isNull);
    },
  );

  for (final (raw, expected) in <(Object, double)>[
    (-2, 0),
    (101, 100),
    ('18.888', 18.89),
    ('invalid', 0),
    ('', 0),
  ]) {
    test('normalizes desktop progress $raw -> $expected', () async {
      harness.respond = (_) => jsonResponse({
        'isSuccess': true,
        'item': {..._detail(), 'progress': raw},
      });
      expect((await service.load('task-fixture'))!.progress, expected);
    });
  }

  test(
    'malformed identity, tags, leaders, dates and counts are rejected',
    () async {
      for (final patch in [
        {'id': 'other'},
        {'title': []},
        {'status': '待开始'},
        {
          'priority': {'color': 3},
        },
        {'leaders': {}},
        {
          'leaders': [null],
        },
        {
          'leaders': [
            {
              'user': {'name': '缺少身份'},
            },
          ],
        },
        {'startTime': -1},
        {'endTime': '2026'},
        {'endTime': 8640000000000001},
        {'fileCount': -1},
        {'subCount': 1.5},
        {'space': []},
        {
          'project': {'nodeName': 3},
        },
      ]) {
        harness.respond = (_) => jsonResponse({
          'isSuccess': true,
          'item': {..._detail(), ...patch},
        });
        await expectLater(service.load('task-fixture'), throwsFormatException);
      }
      for (final body in [
        {'isSuccess': false},
        {'isSuccess': true},
        {'isSuccess': true, 'item': []},
      ]) {
        harness.respond = (_) => jsonResponse(body);
        await expectLater(service.load('task-fixture'), throwsFormatException);
      }
    },
  );

  test(
    'stale session prevents requests and rejects late successful response',
    () async {
      final original = ctx.cookieId;
      ctx.cookieId = 'other';
      await expectLater(service.load('task-fixture'), throwsFormatException);
      expect(harness.requests, isEmpty);
      ctx.cookieId = original;
      final started = Completer<void>();
      final pending = Completer<void>();
      harness.respond = (_) async {
        started.complete();
        await pending.future;
        return jsonResponse({'isSuccess': true, 'item': _detail()});
      };
      final result = service.load('task-fixture');
      await started.future;
      ctx.cookieId = 'changed';
      pending.complete();
      await expectLater(result, throwsFormatException);
    },
  );
}

/// 与桌面task_v3/detail一致的合成item，不包含真实身份或线上内容。
Map<String, Object?> _detail() => {
  'id': 'task-fixture',
  'title': '测试状态111–111',
  'priority': {'name': '一般', 'color': '#59B463'},
  'status': {'name': '待开始', 'color': '#E6E6E6'},
  'leaders': [
    {
      'user': {
        'userId': 'user-id',
        'name': '负责人',
        'avatarUrl': 'https://example.test/avatar.jpg',
      },
    },
  ],
  'startTime': DateTime.utc(2026, 5, 29).millisecondsSinceEpoch,
  'endTime': DateTime.utc(2026, 6, 14, 23, 59).millisecondsSinceEpoch,
  'progress': '12.345',
  'fileCount': 0,
  'subCount': 3,
  'space': {'nodeName': '企业空间'},
  'project': {'nodeName': '测试状态-默认'},
  'workItem': {'nodeName': '普通任务'},
};
