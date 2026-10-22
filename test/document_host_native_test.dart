import 'dart:async';
import 'dart:io';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_common/runtime/context/context.dart';
import 'package:cses_common/runtime/session/user.dart';
import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:cses_mobile_collab_demo/src/demo/cses_account_login.dart';
import 'package:cses_mobile_collab_demo/src/demo/document_host.dart';
import 'package:cses_mobile_collab_demo/src/demo/document_creation/cses_document_creation_service.dart';
import 'package:cses_mobile_collab_demo/src/demo/document_creation/document_creation_operation.dart';
import 'package:cses_mobile_collab_demo/src/demo/document_creation/document_creation_store.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'support/common_login_harness.dart';

/// 用真实宿主、公开包端口及FRB/SQLite验证列表打开、缓存恢复与原生撤销/重做。
/// 原生库通过FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR选择；HTTP使用替身，
/// Common主连接仅指向本机关闭端口，不连接真实账号或远端服务。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late CommonLoginHarness harness;
  late Directory directory;
  late DemoDocumentHost host;
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('document-host-recovery-');
    harness = CommonLoginHarness();
    await harness.install();
    await const CsesAccountLogin().login('account', 'password');
    ctx.websocketHost = 'wss://127.0.0.1:1/ws';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      pathChannel,
      (_) async => directory.path,
    );
    final config = CollabDocumentConfig(
      documentId: 'cached-host-document',
      serverIdentity: ctx.websocketHost!,
      companyId: User().companyId,
      userId: User().userId!,
      databasePath: p.join(directory.path, 'cses_mobile_collab_demo', 'updates.sqlite3'),
      editable: true,
    );
    await DocumentBootstrapper.prepareBlank(
      config: config,
      operationId: 'host-operation',
      paragraphId: 'host-paragraph',
      createdAt: DateTime.fromMillisecondsSinceEpoch(1792584000000),
    );
    final seed = CollabController.cses(config: config, gateway: _OfflineGateway());
    try {
      await seed.initialize();
      final node = seed.editorState.document.first!;
      await seed.editorState.apply(seed.editorState.transaction..insertText(node, 0, '离线缓存正文'));
    } finally {
      await seed.close();
    }
    harness.requests.clear();
    host = DemoDocumentHost();
  });
  tearDown(() async {
    await host.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      pathChannel,
      null,
    );
    await harness.uninstall();
    await directory.delete(recursive: true);
  });

  test('home initialization and reconnect never select or request a document', () async {
    await host.initialize();
    expect(host.creation, isNotNull);
    expect(host.controller, isNull);
    expect(harness.requests, isEmpty);
    await host.reconnect();
    expect(host.controller, isNull);
    expect(harness.requests, isEmpty);
  });

  test(
    'a completed creation record is restored without automatically opening its document',
    () async {
      final api = CsesDocumentCreationService();
      final store = FileDocumentCreationStore(
        directory: Directory(p.join(directory.path, 'cses_mobile_collab_demo', 'creation')),
        scope: api.scope,
      );
      await store.write(
        const DocumentCreationOperation(
          operationId: 'previous-operation',
          paragraphId: 'previous-paragraph',
          createdAt: 1792584000000,
          target: DocumentCreationTarget(id: 'space', name: '个人空间'),
          stage: DocumentCreationStage.completed,
          documentId: 'cached-host-document',
        ),
      );
      await host.initialize();
      expect(host.creation!.operation!.documentId, 'cached-host-document');
      expect(host.controller, isNull);
      expect(harness.requests, isEmpty);
    },
  );

  test(
    'selecting another cached document releases the old engine and keeps the new one read-only',
    () async {
      final config = CollabDocumentConfig(
        documentId: 'another-document',
        serverIdentity: ctx.websocketHost!,
        companyId: User().companyId,
        userId: User().userId!,
        databasePath: p.join(directory.path, 'cses_mobile_collab_demo', 'updates.sqlite3'),
        editable: true,
      );
      await DocumentBootstrapper.prepareBlank(
        config: config,
        operationId: 'another-operation',
        paragraphId: 'another-paragraph',
        createdAt: DateTime.fromMillisecondsSinceEpoch(1792584000000),
      );
      final seed = CollabController.cses(config: config, gateway: _OfflineGateway());
      try {
        await seed.initialize();
        await seed.editorState.apply(
          seed.editorState.transaction..insertText(seed.editorState.document.first!, 0, '另一篇正文'),
        );
      } finally {
        await seed.close();
      }
      harness.respond = (request) => jsonResponse({
        'isSuccess': true,
        'role': 400,
        'id': (request.data as Map)['id'] ?? 'cached-host-document',
        'name': '文档',
      });
      await host.initialize();
      await host.openListedDocument('cached-host-document');
      final previous = host.controller!;
      expect(await host.openListedDocument(config.documentId), config.documentId);
      expect(previous.editorState.isDisposed, isTrue);
      expect(host.controller!.initialized, isTrue);
      expect(host.controller!.canEdit, isFalse);
      expect(host.controller!.editorState.document.first!.delta!.toPlainText(), '另一篇正文');
      expect(host.creation!.operation, isNull);
      expect(
        harness.requests.any(
          (request) =>
              request.path == '/doc/document/create' || request.path == '/doc/document/edit',
        ),
        isFalse,
      );
    },
  );

  test('opening the same selected document retains its controller and undo history', () async {
    harness.respond = (_) =>
        jsonResponse({'isSuccess': true, 'role': 600, 'id': 'cached-host-document'});
    await host.initialize();
    expect(await host.openListedDocument('cached-host-document'), 'cached-host-document');
    final controller = host.controller!;
    await _waitForHost(host, () => controller.canEdit);
    final original = controller.editorState.document.first!.delta!.toJson();
    await controller.editorState.apply(
      controller.editorState.transaction
        ..insertText(controller.editorState.document.first!, 0, '新增'),
    );
    await _waitForHost(host, () => controller.canUndo);
    final edited = controller.editorState.document.first!.delta!.toJson();
    final requestCount = harness.requests.length;
    expect(await host.openListedDocument('cached-host-document'), 'cached-host-document');
    expect(identical(host.controller, controller), isTrue);
    expect(controller.canUndo, isTrue);
    expect(harness.requests.length, requestCount);
    await controller.undo();
    expect(controller.editorState.document.first!.delta!.toJson(), original);
    expect(controller.canRedo, isTrue);
    await controller.redo();
    expect(controller.editorState.document.first!.delta!.toJson(), edited);
  });

  test('a rejected list selection preserves the current document and permits retry', () async {
    var reject = false;
    harness.respond = (request) =>
        jsonResponse({'isSuccess': !reject, 'role': 600, 'id': 'cached-host-document'});
    await host.initialize();
    await host.openListedDocument('cached-host-document');
    final controller = host.controller!;
    await _waitForHost(host, () => controller.canEdit);
    reject = true;
    expect(await host.openListedDocument('denied-document'), isNull);
    expect(identical(host.controller, controller), isTrue);
    expect(controller.initialized, isTrue);
    expect(controller.editorState.document.first!.delta!.toPlainText(), '离线缓存正文');
    expect(host.creation!.error, isNotNull);
    reject = false;
    expect(await host.openListedDocument('cached-host-document'), 'cached-host-document');
    expect(host.creation!.error, isNull);
    expect(harness.requests.any((request) => request.path == '/doc/document/create'), isFalse);
  });

  test('a late access check after logout cannot open a document', () async {
    final response = Completer<ResponseBody>();
    final started = Completer<void>();
    harness.respond = (_) {
      started.complete();
      return response.future;
    };
    await host.initialize();
    final opening = host.openListedDocument('cached-host-document');
    try {
      await started.future.timeout(const Duration(seconds: 5));
      final closing = host.close();
      response.complete(jsonResponse({'isSuccess': true, 'id': 'cached-host-document'}));
      expect(await opening, isNull);
      await closing;
      expect(host.controller, isNull);
      expect(User().userId, anyOf(isNull, isEmpty));
    } finally {
      if (!response.isCompleted) response.complete(jsonResponse({'isSuccess': false}));
      await opening;
    }
  });

  test(
    'cached formal document opens read-only before a pending permission HTTP response',
    () async {
      final readStarted = Completer<void>();
      final response = Completer<ResponseBody>();
      harness.respond = (request) {
        if (request.path == '/doc/permission/read') {
          if (!readStarted.isCompleted) readStarted.complete();
          return response.future;
        }
        return jsonResponse({'isSuccess': true, 'id': 'cached-host-document'});
      };
      await host.initialize();
      expect(host.controller, isNull);
      expect(harness.requests, isEmpty);
      final initialization = host.openListedDocument('cached-host-document');
      try {
        await readStarted.future.timeout(const Duration(seconds: 5));
        expect(host.controller, isNotNull);
        expect(host.controller!.initialized, isTrue);
        expect(host.controller!.canEdit, isFalse);
        expect(host.controller!.editorState.document.first!.delta!.toPlainText(), '离线缓存正文');
        await initialization.timeout(const Duration(seconds: 2));
      } finally {
        response.complete(jsonResponse({'isSuccess': true, 'role': 600}));
        await initialization;
      }
    },
  );
  test(
    'transient permissions recover on explicit retry and an explicit denial revokes editing',
    () async {
      var state = 0;
      harness.respond = (request) {
        if (request.path != '/doc/permission/read') {
          return jsonResponse({'isSuccess': true, 'id': 'cached-host-document'});
        }
        if (state == 0) throw StateError('offline permission service');
        return jsonResponse(state == 1 ? {'isSuccess': true, 'role': 600} : {'isSuccess': false});
      };
      await host.initialize();
      await host.openListedDocument('cached-host-document');
      await _waitForHost(host, () => host.error?.contains('权限暂未确认') == true);
      final controller = host.controller!;
      expect(controller.initialized, isTrue);
      expect(controller.canEdit, isFalse);
      await Future<void>.delayed(Duration.zero);
      state = 1;
      final retry = host.reconnect();
      await _waitForHost(host, () => controller.canEdit && host.error == null);
      expect(identical(controller, host.controller), isTrue);
      expect(host.error, isNull);
      await retry;
      state = 2;
      final revoked = host.reconnect();
      await _waitForHost(host, () => !controller.canEdit);
      expect(controller.editorState.document.first!.delta!.toPlainText(), '离线缓存正文');
      await revoked;
    },
  );

  test(
    'foreground recovery refreshes authorization even when the socket remains offline',
    () async {
      var online = false;
      harness.respond = (request) {
        if (request.path != '/doc/permission/read') {
          return jsonResponse({'isSuccess': true, 'id': 'cached-host-document'});
        }
        if (!online) throw StateError('offline');
        return jsonResponse({'isSuccess': true, 'role': 600});
      };
      await host.initialize();
      await host.openListedDocument('cached-host-document');
      await _waitForHost(host, () => host.error != null);
      await Future<void>.delayed(Duration.zero);
      online = true;
      host.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await _waitForHost(host, () => host.controller!.canEdit);
      expect(host.controller!.editorState.document.first!.delta!.toPlainText(), '离线缓存正文');
    },
  );

  test(
    'late permission response cannot re-enable a closed host or retain its native engine',
    () async {
      final response = Completer<ResponseBody>();
      final started = Completer<void>();
      harness.respond = (request) {
        if (request.path != '/doc/permission/read') {
          return jsonResponse({'isSuccess': true, 'id': 'cached-host-document'});
        }
        if (!started.isCompleted) started.complete();
        return response.future;
      };
      await host.initialize();
      await host.openListedDocument('cached-host-document');
      await started.future;
      final controller = host.controller!;
      final closing = host.close();
      response.complete(jsonResponse({'isSuccess': true, 'role': 600}));
      await closing;
      expect(controller.canEdit, isFalse);
      expect(User().userId, anyOf(isNull, isEmpty));
      await expectLater(host.initialize(), throwsStateError);
    },
  );

  test(
    'storage failure can retry local opening without recreating or losing the cached document',
    () async {
      var available = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        pathChannel,
        (_) async {
          if (!available) {
            throw PlatformException(code: 'storage-unavailable');
          }
          return directory.path;
        },
      );
      harness.respond = (_) =>
          jsonResponse({'isSuccess': true, 'role': 400, 'id': 'cached-host-document'});
      await host.initialize();
      expect(host.controller, isNull);
      expect(host.error, isNotNull);
      available = true;
      await host.reconnect();
      expect(host.controller, isNull);
      expect(harness.requests, isEmpty);
      await host.openListedDocument('cached-host-document');
      expect(host.controller!.initialized, isTrue);
      expect(host.controller!.canEdit, isFalse);
      expect(host.controller!.editorState.document.first!.delta!.toPlainText(), '离线缓存正文');
      expect(harness.requests.any((request) => request.path == '/doc/document/create'), isFalse);
    },
  );
  test('account change during a permission refresh revokes the old editable controller', () async {
    harness.respond = (_) =>
        jsonResponse({'isSuccess': true, 'role': 600, 'id': 'cached-host-document'});
    await host.initialize().timeout(const Duration(seconds: 5));
    await host.openListedDocument('cached-host-document');
    final controller = host.controller!;
    await _waitForHost(host, () => controller.canEdit && host.error == null);
    await host.reconnect().timeout(const Duration(seconds: 12));
    final response = Completer<ResponseBody>();
    final started = Completer<void>();
    harness.respond = (request) {
      if (request.path != '/doc/permission/read') {
        return jsonResponse({'isSuccess': true, 'id': 'cached-host-document'});
      }
      started.complete();
      return response.future;
    };
    final refresh = host.reconnect();
    await started.future.timeout(const Duration(seconds: 5));
    ctx.cookieId = 'changed-session';
    response.complete(jsonResponse({'isSuccess': true, 'role': 600}));
    await _waitForHost(host, () => !controller.canEdit);
    await refresh.timeout(const Duration(seconds: 12));
    expect(identical(controller, host.controller), isTrue);
    expect(controller.editorState.document.first!.delta!.toPlainText(), '离线缓存正文');
  });
}

/// 等待[host]通知后满足[matches]，超时报告失败，并始终注销本测试监听器。
Future<void> _waitForHost(DemoDocumentHost host, bool Function() matches) async {
  if (matches()) return;
  final done = Completer<void>();

  /// 将满足条件的宿主状态转换为一次性测试完成信号。
  void changed() {
    if (matches() && !done.isCompleted) done.complete();
  }

  host.addListener(changed);
  try {
    await done.future.timeout(const Duration(seconds: 5));
  } finally {
    host.removeListener(changed);
  }
}

/// 为缓存种子借用的离线会话端口，不创建连接或发布数据。
class _OfflineGateway implements CsesCollabGateway {
  /// 种子只操作本地缓存，连接始终离线。
  @override
  bool get isConnected => false;

  /// 不提供网络事件，由会话释放自己的空流订阅。
  @override
  Stream<bool> get connectionStates => const Stream.empty();

  /// 接受[pageId]、[documentId]、[instanceId]及[callbacks]，不产生实际订阅。
  @override
  Future<void> register({
    required String pageId,
    required String documentId,
    required String instanceId,
    required Map<String, void Function(Map<String, dynamic>)> callbacks,
  }) async {}

  /// 只读本地测试不会通过[pageId]发送[action]或[body]。
  @override
  bool send(String pageId, String action, Map<String, dynamic> body) => false;

  /// 种子会话释放[pageId]；不释放外部资源。
  @override
  Future<void> unregister(String pageId) async {}
}
