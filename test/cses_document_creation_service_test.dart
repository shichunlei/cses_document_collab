import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:cses_common/runtime/session/user.dart';
import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:cses_mobile_collab_demo/src/demo/cses_account_login.dart';
import 'package:cses_mobile_collab_demo/src/demo/document_creation/cses_document_creation_service.dart';
import 'package:cses_mobile_collab_demo/src/demo/document_creation/document_creation_api.dart';
import 'package:cses_mobile_collab_demo/src/demo/document_creation/document_creation_coordinator.dart';
import 'package:cses_mobile_collab_demo/src/demo/document_creation/document_creation_operation.dart';
import 'package:cses_mobile_collab_demo/src/demo/document_creation/document_creation_store.dart';
import 'package:cses_mobile_collab_demo/src/demo/document_creation/document_list_page.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/common_login_harness.dart';

/// 保留真实Common鉴权与拦截器，只替换传输验证新建业务协议。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late CommonLoginHarness harness;
  late CsesDocumentCreationService service;
  setUp(() async {
    harness = CommonLoginHarness();
    await harness.install();
    await const CsesAccountLogin().login('account', 'password');
    harness.requests.clear();
    service = CsesDocumentCreationService();
  });
  tearDown(() => harness.uninstall());
  test(
    'space documents use parent id and totalCount pagination without requiring hasMore',
    () async {
      harness.respond = (_) => jsonResponse({
        'isSuccess': true,
        'totalCount': 21,
        'hasMore': null,
        'items': [
          {
            'id': 'doc-a',
            'name': '',
            'updatedAt': 1792584000000,
            'owner': {'name': '所有者'},
          },
        ],
      });
      final page = await service.loadDocuments(_target, 1);
      expect(harness.requests.single.path, '/doc/document/list');
      expect(harness.requests.single.data, {
        'id': 'space',
        'pageNumber': 1,
        'pageSize': 20,
        'timeSort': 'createdAt',
      });
      expect(page.hasMore, isTrue);
      expect(page.items.single.displayName, '无标题文档');
      expect(page.items.single.ownerName, '所有者');
      final last = await service.loadDocuments(_target, 2);
      expect(last.hasMore, isFalse);
      expect(harness.requests.last.headers['cookieId'], 'server-cookie');
    },
  );

  test(
    'document list rejects invalid metadata, request bounds and stale account results',
    () async {
      await expectLater(service.loadDocuments(_target, 0), throwsFormatException);
      await expectLater(service.loadDocuments(_target, 1, pageSize: 101), throwsFormatException);
      expect(harness.requests, isEmpty);
      for (final data in [
        {'isSuccess': true, 'items': [], 'totalCount': '20'},
        {
          'isSuccess': true,
          'items': [
            {'name': 'missing-id'},
          ],
          'totalCount': 1,
        },
      ]) {
        harness.respond = (_) => jsonResponse(data);
        await expectLater(service.loadDocuments(_target, 1), throwsFormatException);
      }
      final response = Completer<void>();
      harness.respond = (_) async {
        await response.future;
        return jsonResponse({'isSuccess': true, 'items': [], 'totalCount': 0});
      };
      final request = service.loadDocuments(_target, 1);
      await Future<void>.delayed(Duration.zero);
      User().userId = 'different-account';
      response.complete();
      await expectLater(request, throwsFormatException);
    },
  );

  test(
    'document metadata preserves immutable pages and uses the most recent available timestamp',
    () {
      final entry = DocumentListEntry.fromJson({
        'id': 'doc',
        'name': '标题',
        'createdAt': 100,
        'updatedAt': 300,
        'editedAt': 200,
      });
      expect(entry.modifiedAt!.millisecondsSinceEpoch, 300);
      expect(entry.displayName, '标题');
      final source = [entry];
      final page = DocumentListPage(items: source, totalCount: 1, pageNumber: 1, pageSize: 20);
      source.clear();
      expect(page.items, hasLength(1));
      expect(() => page.items.clear(), throwsUnsupportedError);
      expect(
        () => DocumentListEntry.fromJson({'id': 'doc', 'updatedAt': 'invalid'}),
        throwsFormatException,
      );
    },
  );
  test('first use initializes personal space then reloads real IDs', () async {
    var reads = 0;
    harness.respond = (r) => jsonResponse(switch (r.path) {
      '/doc/space/list' => {
        'isSuccess': true,
        'items': ++reads == 1
            ? []
            : [
                {'id': 'personal-id', 'name': '我的空间', 'spaceType': 'personal'},
              ],
      },
      '/doc/space/init' => {'isSuccess': true},
      _ => throw StateError(r.path),
    });
    final targets = await service.loadTargets();
    expect(targets.single.id, 'personal-id');
    expect(harness.requests.map((r) => r.path), [
      '/doc/space/list',
      '/doc/space/init',
      '/doc/space/list',
    ]);
    expect(harness.requests[1].data, {'type': 'personal'});
    for (final request in harness.requests) {
      expect(request.headers['cookieId'], 'server-cookie');
      expect(request.headers['companyId'], 'server-company');
    }
  });
  test('createChild permission is required; role alone does not grant creation', () async {
    harness.respond = (r) => jsonResponse({
      'isSuccess': true,
      'role': 1000,
      'abilities': {'createChild': false},
    });
    await expectLater(service.verifyTarget(_target), throwsA(isA<DocumentCreationRejected>()));
    harness.respond = (r) => jsonResponse({
      'isSuccess': true,
      'abilities': {'createChild': true},
    });
    await service.verifyTarget(_target);
    expect(harness.requests.last.data, {'id': 'space'});
  });
  test('create uses empty title and formal text type; snapshot has two Insert blocks', () async {
    harness.respond = (r) =>
        jsonResponse({'isSuccess': true, 'result': r.path.endsWith('/create') ? 'new-doc' : true});
    expect(await service.createBlank(_target), 'new-doc');
    expect(harness.requests.single.data, {'name': '', 'documentType': 'text', 'targetId': 'space'});
    final prepared = _prepared();
    await service.writeInitial(prepared);
    final request = harness.requests.last;
    expect(request.path, '/doc/document/edit');
    expect(request.data['docId'], 'new-doc');
    expect((request.data['blocks'] as List).length, 2);
    expect(request.data['blocks'][1]['content'], isEmpty);
    expect(request.data['blocks'][1].containsKey('children'), isFalse);
    expect(request.data['blocks'][1]['parentId'], 'new-doc');
  });
  test('known create ID remains available when account changes during response', () async {
    final gate = Completer<void>();
    harness.respond = (r) async {
      await gate.future;
      return jsonResponse({'isSuccess': true, 'result': 'old-account-doc'});
    };
    final creation = service.createBlank(_target);
    await Future<void>.delayed(Duration.zero);
    User().userId = 'next-user';
    gate.complete();
    expect(await creation, 'old-account-doc');
    expect(service.checkSession, throwsFormatException);
  });
  test('missing ID and failed business result never count as success', () async {
    harness.respond = (r) => jsonResponse({'isSuccess': true});
    await expectLater(service.createBlank(_target), throwsFormatException);
    harness.respond = (r) => jsonResponse({'isSuccess': true, 'result': false});
    await expectLater(service.writeInitial(_prepared()), throwsA(isA<DocumentCreationRejected>()));
  });
  test(
    'transport failures stay unknown while explicit HTTP permission denials are rejected',
    () async {
      for (final status in [401, 403]) {
        harness.respond = (_) => jsonResponse({'isSuccess': false}, status: status);
        await expectLater(service.createBlank(_target), throwsA(isA<DocumentCreationRejected>()));
      }
      harness.respond = (request) =>
          throw DioException(requestOptions: request, type: DioExceptionType.receiveTimeout);
      await expectLater(service.createBlank(_target), throwsA(isA<DioException>()));
      harness.respond = (_) => jsonResponse({'unexpected': 'response'});
      await expectLater(service.createBlank(_target), throwsFormatException);
      harness.respond = (_) => jsonResponse({'isSuccess': false});
      await expectLater(service.createBlank(_target), throwsA(isA<DocumentCreationRejected>()));
    },
  );

  test('real Common timeout persists unknown create and never repeats the HTTP create', () async {
    final directory = await Directory.systemTemp.createTemp('common-create-timeout-');
    var sequence = 0;
    final coordinator = DocumentCreationCoordinator(
      api: service,
      store: FileDocumentCreationStore(directory: directory, scope: service.scope),
      createId: () => 'id-${sequence++}',
      prepare: (_) => throw StateError('未知建档不得准备正文'),
      closeDocument: () async {},
      openDocument: (_) async => fail('未知建档不得打开正文'),
    );
    harness.respond = (request) {
      if (request.path == '/doc/permission/read') {
        return jsonResponse({
          'isSuccess': true,
          'abilities': {'createChild': true},
        });
      }
      throw DioException(requestOptions: request, type: DioExceptionType.receiveTimeout);
    };
    try {
      await coordinator.restore();
      expect(await coordinator.start(_target), isNull);
      expect(coordinator.operation!.stage, DocumentCreationStage.createUnknown);
      expect(await coordinator.start(_target), isNull);
      expect(
        harness.requests.where((request) => request.path == '/doc/document/create'),
        hasLength(1),
      );
    } finally {
      await coordinator.close();
      await directory.delete(recursive: true);
    }
  });
  test('snapshot recovery distinguishes missing, exact match and changed content', () async {
    final prepared = _prepared();
    var data = <String, dynamic>{'isSuccess': true};
    harness.respond = (r) => jsonResponse(data);
    expect(await service.readInitial(prepared), InitialSnapshotState.missing);
    data = {
      'isSuccess': true,
      for (final block in prepared.insertDiffs) block['id'] as String: block,
    };
    expect(await service.readInitial(prepared), InitialSnapshotState.matches);
    (data['p'] as Map)['content'] = [
      {'insert': '其他用户正文'},
    ];
    expect(await service.readInitial(prepared), InitialSnapshotState.different);
    expect(harness.requests.every((r) => r.path == '/doc/document/block/read'), isTrue);
    expect(harness.requests.last.data, {
      'docId': 'new-doc',
      'blockId': 'new-doc',
      'recursive': true,
    });
  });
  test('editing needs server editor role and honors explicit modify denial', () async {
    var role = 400;
    var modify = true;
    harness.respond = (r) => jsonResponse({
      'isSuccess': true,
      'role': role,
      'abilities': {'modify': modify},
    });
    expect(await service.editableFor('doc'), isFalse);
    role = 600;
    expect(await service.editableFor('doc'), isTrue);
    modify = false;
    expect(await service.editableFor('doc'), isFalse);
  });
  test('scope is stable across cookie rotations but service refuses stale identity', () async {
    final before = service.scope;
    expect(before, hasLength(64));
    User().companyId = 'other-company';
    expect(service.checkSession, throwsFormatException);
    expect(CsesDocumentCreationService().scope, isNot(before));
  });
}

const _target = DocumentCreationTarget(id: 'space', name: '个人空间');

/// 构造空文档协议样本；原生结构的验证由FRB互通测试覆盖。
PreparedDocument _prepared() => PreparedDocument.fromSnapshotJson(
  jsonEncode({
    'id': 'new-doc',
    'flavour': 'root',
    'nodeType': 'root',
    'props': <String, dynamic>{},
    'meta': {
      'createdTime': 1792584000000,
      'lastModified': {'time': 1792584000000, 'user': null},
    },
    'children': [
      {
        'id': 'p',
        'flavour': 'paragraph',
        'nodeType': 'editable',
        'props': {'depth': 0},
        'meta': <String, dynamic>{},
        'children': <dynamic>[],
      },
    ],
  }),
);
