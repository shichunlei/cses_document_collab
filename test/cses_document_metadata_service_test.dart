import 'dart:async';
import 'package:cses_common/runtime/context/context.dart';
import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:cses_mobile_collab_demo/src/demo/cses_account_login.dart';
import 'package:cses_mobile_collab_demo/src/service/cses_document_metadata_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/common_login_harness.dart';

/// 注册Common业务端口契约回归；测试保留真实上下文与拦截器，逐例安装/还原传输替身。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late CommonLoginHarness harness;
  late CsesDocumentMetadataService service;
  Map<String, dynamic> detail = {};
  Map<String, dynamic> permission = {};
  setUp(() async {
    harness = CommonLoginHarness();
    await harness.install();
    await const CsesAccountLogin().login('account', 'password');
    harness.requests.clear();
    service = CsesDocumentMetadataService();
    detail = {
      'isSuccess': true,
      'id': 'doc',
      'name': '桌面标题',
      'icon': {'type': 'emoji', 'value': '😘'},
      'banner': {
        'url': 'https://example.test/image.png',
        'y': 42,
        'x': 2,
        'title': '原始封面',
      },
      'owner': {'id': 'server-user'},
      'localUser': {'role': 1000},
    };
    permission = {
      'isSuccess': true,
      'role': 1000,
      'abilities': {'rename': true},
    };
    harness.respond = (request) => jsonResponse(switch (request.path) {
      '/doc/document/view' => detail,
      '/doc/permission/read' => permission,
      _ => {'isSuccess': true},
    });
  });
  tearDown(() => harness.uninstall());
  test(
    'view and permission use real Common headers; preserve desktop fields',
    () async {
      final data = await service.load('doc');
      expect(data.name, '桌面标题');
      expect(data.icon, {'type': 'emoji', 'value': '😘'});
      expect(data.banner, detail['banner']);
      expect(data.canRename, isTrue);
      expect(data.canChangeAppearance, isTrue);
      expect(harness.requests.map((r) => r.path), [
        '/doc/document/view',
        '/doc/permission/read',
      ]);
      for (final request in harness.requests) {
        expect(request.method, 'POST');
        expect(request.data, {'id': 'doc'});
        expect(request.headers['cookieId'], 'server-cookie');
        expect(request.headers['companyId'], 'server-company');
        expect(request.uri.host, 'api-pre.jinqidongli.com');
      }
    },
  );
  test(
    'block unlock grants match desktop manager role and revoke after failed reload',
    () async {
      const lock = CollabBlockUnlockContext(
        documentId: 'doc',
        blockId: 'block',
        currentUserId: 'server-user',
        ownerId: 'another-user',
        template: true,
      );
      expect(service.canUnlockBlock(lock), isFalse);
      detail['localUser'] = {'role': 800};
      await service.load('doc');
      expect(service.canUnlockBlock(lock), isTrue);
      detail['localUser'] = {'role': 600};
      await service.load('doc');
      expect(service.canUnlockBlock(lock), isFalse);
      detail['localUser'] = {'role': 1000};
      await service.load('doc');
      expect(service.canUnlockBlock(lock), isTrue);
      permission = {'isSuccess': false};
      await expectLater(service.load('doc'), throwsA(isA<FormatException>()));
      expect(service.canUnlockBlock(lock), isFalse);
    },
  );
  test(
    'single-field updates and dedicated remove routes match desktop contract',
    () async {
      await service.update('doc', const DocumentMetadataPatch.rename('新标题'));
      await service.update(
        'doc',
        const DocumentMetadataPatch.icon({'type': 'emoji', 'value': '🚀'}),
      );
      await service.update(
        'doc',
        const DocumentMetadataPatch.banner({
          'url': 'https://example.test/a.png',
          'y': 12,
        }),
      );
      await service.update('doc', const DocumentMetadataPatch.icon(null));
      await service.update('doc', const DocumentMetadataPatch.banner(null));
      expect(harness.requests.map((r) => [r.path, r.data]), [
        [
          '/doc/document/modify',
          {'id': 'doc', 'name': '新标题'},
        ],
        [
          '/doc/document/modify',
          {
            'id': 'doc',
            'icon': {'type': 'emoji', 'value': '🚀'},
          },
        ],
        [
          '/doc/document/modify',
          {
            'id': 'doc',
            'banner': {'url': 'https://example.test/a.png', 'y': 12},
          },
        ],
        [
          '/doc/document/icon/remove',
          {'id': 'doc'},
        ],
        [
          '/doc/document/banner/remove',
          {'id': 'doc'},
        ],
      ]);
    },
  );
  for (final entry in <String, Map<String, dynamic>?>{
    'rename omitted': {},
    'rename null': {'rename': null},
    'abilities omitted': null,
  }.entries) {
    test(
      'owner can rename when ${entry.key}; save uses Common while preserving other header fields',
      () async {
        if (entry.value == null) {
          permission.remove('abilities');
        } else {
          permission['abilities'] = entry.value;
        }
        var editable = true;
        final controller = DocumentMetadataController(
          documentId: 'doc',
          service: service,
          canEdit: () => editable,
        );
        addTearDown(controller.close);
        await controller.refresh();
        expect(controller.canRename, isTrue);
        harness.requests.clear();
        expect(
          await controller.save(const DocumentMetadataPatch.rename('手机修改标题')),
          isTrue,
        );
        expect(controller.value!.name, '手机修改标题');
        expect(controller.value!.icon, detail['icon']);
        expect(controller.value!.banner, detail['banner']);
        expect(harness.requests, hasLength(1));
        final request = harness.requests.single;
        expect(request.path, '/doc/document/modify');
        expect(request.data, {'id': 'doc', 'name': '手机修改标题'});
        expect(request.headers['cookieId'], 'server-cookie');
        expect(request.headers['companyId'], 'server-company');
        editable = false;
        harness.requests.clear();
        expect(controller.canRename, isFalse);
        expect(
          await controller.save(const DocumentMetadataPatch.rename('只读改名')),
          isFalse,
        );
        expect(harness.requests, isEmpty);
        editable = true;
        // The omitted ability must never grant a different user rename access.
        detail['owner'] = {'id': 'another-user'};
        await controller.refresh();
        harness.requests.clear();
        expect(controller.canRename, isFalse);
        expect(
          await controller.save(const DocumentMetadataPatch.rename('禁止改名')),
          isFalse,
        );
        expect(harness.requests, isEmpty);
      },
    );
  }

  test(
    'owner identity, owner role and rename ability follow desktop restrictions',
    () async {
      detail['owner'] = {'id': 'another-user'};
      var data = await service.load('doc');
      expect(data.canRename, isFalse);
      detail['owner'] = {'id': 'server-user'};
      detail['localUser'] = {'role': 600};
      permission['abilities'] = {'rename': false};
      data = await service.load('doc');
      expect(data.canRename, isFalse);
      expect(data.canChangeAppearance, isFalse);
      detail['localUser'] = {'role': 1000};
      data = await service.load('doc');
      expect(data.canRename, isFalse);
      expect(data.canChangeAppearance, isTrue);
    },
  );
  test('business failure never acts as a successful ACK', () async {
    harness.respond = (_) =>
        jsonResponse({'isSuccess': false, 'message': '无权限'});
    await expectLater(
      service.update('doc', const DocumentMetadataPatch.rename('失败')),
      throwsA(anything),
    );
  });
  test('changed login prevents requests and rejects late responses', () async {
    final pending = Completer<Map<String, dynamic>>();
    harness.respond = (_) async => jsonResponse(await pending.future);
    final writing = service.update(
      'doc',
      const DocumentMetadataPatch.icon(null),
    );
    await Future<void>.delayed(Duration.zero);
    ctx.cookieId = 'different-session';
    pending.complete({'isSuccess': true});
    await expectLater(writing, throwsFormatException);
    final count = harness.requests.length;
    await expectLater(service.load('doc'), throwsFormatException);
    expect(harness.requests, hasLength(count));
  });
}
