import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cses_document_collab/src/sync/cses_collab_gateway.dart';
import 'package:cses_document_collab/src/sync/cses_doc_collaboration_session.dart';
import 'package:flutter_test/flutter_test.dart';

/// 测试主连接端口，保留业务路由回调和发送顺序，不创建 Socket。
class _Gateway implements CsesCollabGateway {
  bool connected = true;
  bool sendResult = true;
  final states = StreamController<bool>.broadcast(sync: true);
  final sent = <(String, Map<String, dynamic>)>[];
  Map<String, void Function(Map<String, dynamic>)> callbacks = {};
  int unregisterCount = 0;

  /// 当前测试主连接状态。
  @override
  bool get isConnected => connected;

  /// 可控主连接事件，订阅者拥有取消责任。
  @override
  Stream<bool> get connectionStates => states.stream;

  /// 登记 [pageId]、[documentId]、[instanceId] 和 [callbacks] 并模拟平台订阅。
  @override
  Future<void> register({
    required String pageId,
    required String documentId,
    required String instanceId,
    required Map<String, void Function(Map<String, dynamic>)> callbacks,
  }) async {
    this.callbacks = callbacks;
    if (connected) sent.add(('subscribe', {}));
  }

  /// 记录 [pageId] 的 [action]/[body]，模拟同步发送结果。
  @override
  bool send(String pageId, String action, Map<String, dynamic> body) {
    if (!connected) return false;
    sent.add((action, body));
    return sendResult;
  }

  /// 清除 [pageId] 接收回调并统计注销次数。
  @override
  Future<void> unregister(String pageId) async {
    callbacks = {};
    unregisterCount += 1;
  }

  /// 发布 [value] 状态，重连时先恢复 subscribe。
  void connection(bool value) {
    connected = value;
    if (value) sent.add(('subscribe', {}));
    states.add(value);
  }

  /// 投递 [action] 的 [body]，保留迟到回调测试所需的原函数由调用方保存。
  void receive(String action, Map<String, dynamic> body) =>
      callbacks[action]?.call(body);
}

/// 空文档同步响应；正文和状态向量都是原始 V1 的 Base64。
Map<String, dynamic> _sync() => {'data': 'AAA=', 'stateVector': 'AA=='};

/// 创建 [gateway] 的逻辑会话，使用可选 [onUpdate]、[onSync]、[onState]、[retries]。
CsesDocCollaborationSession _session(
  _Gateway gateway, {
  CsesUpdateHandler? onUpdate,
  CsesSyncHandler? onSync,
  CsesSessionStateHandler? onState,
  int retries = 0,
}) => CsesDocCollaborationSession(
  gateway: gateway,
  documentId: 'doc',
  instanceId: 'editor',
  stateVectorFactory: () => Uint8List.fromList([0]),
  onSync: onSync ?? (update, vector) => Uint8List.fromList([0, 0]),
  onUpdate: onUpdate ?? (_) {},
  onStateChanged: onState ?? (state, event, error) {},
  awarenessFactory: (_) => Uint8List.fromList([0]),
  onAwareness: (_) {},
  syncTimeout: const Duration(seconds: 1),
  retryBaseDelay: const Duration(milliseconds: 1),
  maxRetries: retries,
);

/// 验证协议握手、失败及会话资源释放边界，不依赖真实账号。
void main() {
  late _Gateway gateway;
  late CsesDocCollaborationSession session;
  setUp(() => gateway = _Gateway());
  tearDown(() async {
    await session.dispose();
    await gateway.states.close();
  });

  test(
    'subscribe precedes join; sync status never completes handshake',
    () async {
      session = _session(gateway);
      await session.start();
      expect(gateway.sent.map((message) => message.$1), [
        'subscribe',
        'collabJoin',
      ]);
      expect(gateway.sent.last.$2, {'stateVector': 'AA=='});
      gateway.receive('collabSyncStatus', {'synced': true});
      expect(session.state, CsesCollabState.syncing);
      gateway.receive('collabSync', _sync());
      expect(session.state, CsesCollabState.ready);
      expect(gateway.sent[2].$1, 'collabUpdate');
      expect(gateway.sent[2].$2, {'data': 'AAA='});
      expect(gateway.sent.last.$1, 'collabAwareness');
    },
  );

  test(
    'applies server update before calculating unframed reverse diff',
    () async {
      var called = false;
      session = _session(
        gateway,
        onSync: (update, vector) {
          expect(update, [0, 0]);
          expect(vector, [0]);
          called = true;
          return Uint8List.fromList([1, 2, 3]);
        },
      );
      await session.start();
      gateway.receive('collabSync', _sync());
      expect(called, isTrue);
      expect(gateway.sent[2].$2['data'], base64Encode([1, 2, 3]));
    },
  );

  test(
    'remote updates apply without echo; local edits only send while ready',
    () async {
      var remoteCount = 0;
      session = _session(gateway, onUpdate: (_) => remoteCount++);
      await session.start();
      expect(session.sendLocalUpdate(Uint8List.fromList([1])), isFalse);
      gateway.receive('collabSync', _sync());
      final count = gateway.sent.length;
      gateway.receive('collabUpdate', {'data': 'AAA='});
      expect(remoteCount, 1);
      expect(gateway.sent.length, count);
      expect(session.sendLocalUpdate(Uint8List.fromList([1])), isTrue);
      expect(gateway.sent.last.$1, 'collabUpdate');
      expect(gateway.sent.last.$2, {'data': 'AQ=='});
      gateway.connection(false);
      final offlineCount = gateway.sent.length;
      expect(session.sendLocalUpdate(Uint8List.fromList([2])), isFalse);
      expect(gateway.sent.length, offlineCount);
      gateway.connection(true);
      expect(gateway.sent.last.$1, 'collabJoin');
    },
  );

  test(
    'terminal document errors survive reconnect and foreground recovery',
    () async {
      session = _session(gateway);
      await session.start();
      gateway.receive('collabError', {'code': 'DOCUMENT_NOT_FOUND'});
      expect(session.state, CsesCollabState.error);
      gateway.connection(false);
      gateway.connection(true);
      final count = gateway.sent.length;
      session.resync();
      expect(gateway.sent.length, count);
      session.retry();
      expect(gateway.sent.last.$1, 'collabJoin');
    },
  );

  test('collabClose retries join with a bounded retry count', () async {
    final retried = Completer<void>();
    session = _session(
      gateway,
      retries: 1,
      onState: (state, event, error) {
        if (event == 'collabJoin' &&
            gateway.sent.length > 1 &&
            !retried.isCompleted) {
          retried.complete();
        }
      },
    );
    await session.start();
    gateway.receive('collabClose', {});
    await retried.future.timeout(const Duration(seconds: 2));
    expect(
      gateway.sent.where((message) => message.$1 == 'collabJoin').length,
      2,
    );
    gateway.receive('collabClose', {});
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(
      gateway.sent.where((message) => message.$1 == 'collabJoin').length,
      2,
    );
  });

  test(
    'online disposal sends awareness removal, leave, unsubscribe once',
    () async {
      session = _session(gateway);
      await session.start();
      gateway.receive('collabSync', _sync());
      final lateCallback = gateway.callbacks['collabUpdate']!;
      await session.dispose();
      await session.dispose();
      expect(
        gateway.sent.skip(gateway.sent.length - 3).map((message) => message.$1),
        ['collabAwareness', 'collabLeave', 'unsubscribe'],
      );
      expect(gateway.unregisterCount, 1);
      lateCallback({'data': 'not-base64'});
      expect(session.state, CsesCollabState.ready);
    },
  );

  test('offline disposal sends no stale exit commands', () async {
    session = _session(gateway);
    await session.start();
    gateway.connection(false);
    final count = gateway.sent.length;
    await session.dispose();
    expect(gateway.sent.length, count);
    expect(gateway.unregisterCount, 1);
  });

  test('upstream larger than 1 MiB stops without byte slicing', () async {
    session = _session(gateway);
    await session.start();
    gateway.receive('collabSync', _sync());
    final count = gateway.sent.length;
    expect(session.sendLocalUpdate(Uint8List(1024 * 1024 + 1)), isFalse);
    expect(session.state, CsesCollabState.error);
    expect(gateway.sent.length, count);
  });

  test('downstream sync may exceed upstream limit', () async {
    session = _session(
      gateway,
      onSync: (update, vector) {
        expect(update.length, 1024 * 1024 + 1);
        return Uint8List.fromList([0, 0]);
      },
    );
    await session.start();
    gateway.receive('collabSync', {
      'data': base64Encode(Uint8List(1024 * 1024 + 1)),
      'stateVector': 'AA==',
    });
    expect(session.state, CsesCollabState.ready);
  });

  test('send failure leaves ready without claiming delivery or save', () async {
    session = _session(gateway);
    await session.start();
    gateway.receive('collabSync', _sync());
    gateway.sendResult = false;
    expect(session.sendLocalUpdate(Uint8List.fromList([1])), isFalse);
    expect(session.state, CsesCollabState.error);
  });
}
