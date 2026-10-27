import 'package:cses_mobile_collab_demo/src/demo/cses_account_login.dart';
import 'dart:async';

import 'package:cses_common/runtime/context/context.dart';
import 'package:cses_mobile_collab_demo/src/demo/cses_mention_directory.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/common_login_harness.dart';

/// 验证同源企业人员查询、缓存、失败重试与账号隔离，使用真实Common封装。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late CommonLoginHarness harness;
  late CsesMentionDirectory directory;
  setUp(() async {
    harness = CommonLoginHarness();
    await harness.install();
    await const CsesAccountLogin().login('account', 'password');
    harness.requests.clear();
    directory = CsesMentionDirectory();
    harness.respond = (_) => jsonResponse({
      'isSuccess': true,
      'items': [
        {
          'id': 'server-company',
          'name': '企业',
          'isUser': false,
          'children': [
            {
              'id': 'dept',
              'name': '部门',
              'isUser': false,
              'children': [
                {
                  'id': 'u1',
                  'name': '张三',
                  'isUser': true,
                  'deptName': '研发',
                  'orgName': '工程师',
                },
                {'id': 'u2', 'name': 'Alice', 'isUser': true, 'deptName': '设计'},
              ],
            },
          ],
        },
      ],
    });
  });
  tearDown(() => harness.uninstall());
  test(
    'organization route, auth, real users only, name/department filtering, cached details',
    () async {
      final users = await directory.search('');
      expect(users.map((u) => u.id).toSet(), {'u1', 'u2'});
      expect((await directory.search('张')).single.id, 'u1');
      expect((await directory.search('ALICE')).single.id, 'u2');
      expect((await directory.search('研发')).single.id, 'u1');
      expect((await directory.load('u1'))!.position, '工程师');
      expect(await directory.load('missing'), isNull);
      expect(harness.requests.length, 1);
      final request = harness.requests.single;
      expect(request.path, '/Company/readAllChildren');
      expect(request.data, {'orgId': 'server-company', 'isReadUser': true});
      expect(request.headers['cookieId'], 'server-cookie');
      expect(request.headers['companyId'], 'server-company');
    },
  );
  test('failed response is not cached; retry queries server again', () async {
    harness.respond = (_) => jsonResponse({'isSuccess': false});
    await expectLater(directory.search(''), throwsFormatException);
    harness.respond = (_) => jsonResponse({'isSuccess': true, 'items': []});
    expect(await directory.search(''), isEmpty);
    expect(harness.requests.length, 2);
  });
  test('changed session rejects cached data and delayed response', () async {
    final pending = Completer<void>();
    harness.respond = (_) async {
      await pending.future;
      return jsonResponse({'isSuccess': true, 'items': []});
    };
    final request = directory.search('');
    await pumpEventQueue();
    ctx.cookieId = 'other-cookie';
    pending.complete();
    await expectLater(request, throwsFormatException);
    await expectLater(directory.search(''), throwsFormatException);
    expect(harness.requests.length, 1);
  });
}
