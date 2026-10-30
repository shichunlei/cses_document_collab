import 'dart:async';

import 'package:cses_common/runtime/context/context.dart';
import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:cses_mobile_collab_demo/src/demo/cses_account_login.dart';
import 'package:cses_mobile_collab_demo/src/service/cses_meeting_card_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/common_login_harness.dart';

/// 通过真实Common封装验证会议详情传输、状态/元信息解析、错误与账号隔离。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late CommonLoginHarness harness;
  late CsesMeetingCardService service;
  setUp(() async {
    harness = CommonLoginHarness();
    await harness.install();
    await const CsesAccountLogin().login('account', 'password');
    harness.requests.clear();
    service = CsesMeetingCardService();
  });
  tearDown(() => harness.uninstall());

  for (final state in [
    'NotStarted',
    'InProgress',
    'Pause',
    'Completed',
    'Canceled',
    'Delete',
    'FutureState',
  ]) {
    test(
      'detail maps $state through Common headers without changing wire state',
      () async {
        harness.respond = (_) =>
            jsonResponse({'isSuccess': true, ..._detail(state)});
        final data = (await service.load('meeting-fixture'))!;
        expect(data.meetingId, 'meeting-fixture');
        expect(
          data.state,
          state == 'FutureState'
              ? CollabMeetingCardState.unknown
              : CollabMeetingCardState.fromValue(state),
        );
        expect(data.title, '威震天的快速会议');
        expect(data.number, '123456');
        expect(data.moderatorName, '威震天');
        expect(data.memberCount, 8);
        expect(data.startTime, DateTime.utc(2026, 10, 10, 7, 35));
        final request = harness.requests.single;
        expect(request.path, '/meeting/getDetail');
        expect(request.method, 'POST');
        expect(request.data, {'meetingId': 'meeting-fixture'});
        expect(request.headers['cookieId'], 'server-cookie');
        expect(request.headers['companyId'], 'server-company');
        expect(request.uri.host, 'api.example.test');
      },
    );
  }

  test('wrapped detail and explicit missing item/data are supported', () async {
    for (final key in ['item', 'data']) {
      harness.respond = (_) =>
          jsonResponse({'isSuccess': true, key: _detail('Completed')});
      expect(
        (await service.load('meeting-fixture'))!.state,
        CollabMeetingCardState.completed,
      );
      harness.respond = (_) => jsonResponse({'isSuccess': true, key: null});
      expect(await service.load('meeting-fixture'), isNull);
    }
  });

  test(
    'optional metadata can be omitted and memberCount is used when members are absent',
    () async {
      harness.respond = (_) => jsonResponse({
        'isSuccess': true,
        'meetingId': 'meeting-fixture',
        'memberCount': 0,
        'startTime': 0,
      });
      final data = (await service.load('meeting-fixture'))!;
      expect(data.title, isNull);
      expect(data.number, isNull);
      expect(data.startTime, isNull);
      expect(data.memberCount, 0);
      expect(data.state, CollabMeetingCardState.unknown);
    },
  );

  test(
    'rejects mismatched identity, malformed metadata and business failure',
    () async {
      for (final response in [
        {'isSuccess': false},
        {'isSuccess': true, ..._detail('Pause'), 'meetingId': 'wrong'},
        {'isSuccess': true, ..._detail('Pause'), 'meetingState': 2},
        {'isSuccess': true, ..._detail('Pause'), 'members': {}},
        {'isSuccess': true, ..._detail('Pause'), 'memberCount': -1},
        {'isSuccess': true, ..._detail('Pause'), 'title': []},
        {'isSuccess': true, ..._detail('Pause'), 'startTime': -1},
        {'isSuccess': true, ..._detail('Pause'), 'startTime': 8640000000000001},
      ]) {
        harness.respond = (_) => jsonResponse(response);
        await expectLater(
          service.load('meeting-fixture'),
          throwsFormatException,
        );
      }
    },
  );

  test('stale session refuses requests and late responses', () async {
    final originalCookie = ctx.cookieId;
    ctx.cookieId = 'changed-session';
    await expectLater(service.load('meeting-fixture'), throwsFormatException);
    expect(harness.requests, isEmpty);
    ctx.cookieId = originalCookie;
    final pending = Completer<void>();
    final started = Completer<void>();
    harness.respond = (_) async {
      started.complete();
      await pending.future;
      return jsonResponse({'isSuccess': true, ..._detail('Completed')});
    };
    final loading = service.load('meeting-fixture');
    final assertion = expectLater(loading, throwsFormatException);
    await started.future;
    ctx.cookieId = 'new-session';
    pending.complete();
    await assertion;
  });
}

/// 合成[wireState]对应的服务端详情；不使用真实会议或账号数据。
Map<String, Object?> _detail(String wireState) => {
  'meetingId': 'meeting-fixture',
  'meetingState': wireState,
  'title': '威震天的快速会议',
  'number': '123456',
  'startTime': DateTime.utc(2026, 10, 10, 7, 35).millisecondsSinceEpoch,
  'moderatorName': '威震天',
  'members': List.generate(8, (index) => {'id': 'member-$index'}),
};
