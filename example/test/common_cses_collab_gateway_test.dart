import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_common/cses_common_network.dart';
import 'package:cses_common/cses_common_runtime.dart';
import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:cses_mobile_collab_demo/src/demo/common_cses_collab_gateway.dart';
import 'package:cses_mobile_collab_demo/src/demo/cses_account_login.dart';
import 'package:cses_mobile_collab_demo/src/demo/cses_demo_host.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/common_login_harness.dart';

/// 用真实Common连接和公开协同控制器验证Gateway，不依赖真实账号、后台或SaaS。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late CommonLoginHarness harness;
  late _Peer peer;
  late CommonCsesCollabGateway gateway;
  const pageId = 'gateway-new-api';

  setUp(() async {
    csesWebSocketClient.close();
    harness = CommonLoginHarness();
    await harness.install();
    peer = await _Peer.open();
    harness.respond = (_) =>
        jsonResponse(success()..['webConfig'] = {'websocketHost': 'ws://127.0.0.1:${peer.server.port}/deployment/ws'});
    await const CsesAccountLogin().login('account', 'password');
    gateway = CommonCsesCollabGateway();
  });
  tearDown(() async {
    await gateway.unregister(pageId);
    await peer.close();
    await harness.uninstall();
  });

  test('multiple ready listeners do not duplicate Common subscriptions', () async {
    await gateway.register(pageId: pageId, documentId: 'doc', instanceId: 'one', callbacks: {});
    final observed = <bool>[];
    final a = gateway.connectionStates.listen(observed.add);
    final b = gateway.connectionStates.listen(observed.add);
    addTearDown(() async {
      await a.cancel();
      await b.cancel();
    });
    await peer.connect();
    await _until(() => peer.documentFrames.length == 1 && observed.where((v) => v).length == 2);
    expect(peer.documentFrames.single['action'], 'subscribe');
    expect(peer.documentFrames.single['body'], {});
    expect(gateway.send(pageId, 'collabJoin', {'stateVector': 'AA=='}), isTrue);
    await _until(() => peer.documentFrames.length >= 2);
    expect(peer.documentFrames.map((m) => m['action']), ['subscribe', 'collabJoin']);
  });

  test('ready recovers subscribe before join; local unregister prevents later recovery', () async {
    await gateway.register(pageId: pageId, documentId: 'doc', instanceId: 'one', callbacks: {});
    final events = gateway.connectionStates.listen((connected) {
      if (connected) expect(gateway.send(pageId, 'collabJoin', {'stateVector': 'AA=='}), isTrue);
    });
    addTearDown(events.cancel);
    await peer.connect();
    await _until(() => peer.documentFrames.length >= 2);
    csesWebSocketClient.disconnected();
    await peer.connect();
    await _until(() => peer.framesByConnection.length == 2 && _documentFrames(peer.framesByConnection[1]).length >= 2);
    for (final connection in peer.framesByConnection) {
      final frames = _documentFrames(connection);
      expect(frames.take(2).map((m) => m['action']), ['subscribe', 'collabJoin']);
      expect(frames.where((m) => m['action'] == 'subscribe'), hasLength(1));
      for (final frame in frames) {
        expect(frame['header'], frame['subscription']);
      }
    }
    await events.cancel();
    await gateway.unregister(pageId);
    expect(csesWebSocketClient.isConnected, isTrue);
    csesWebSocketClient.disconnected();
    await peer.connect();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(_documentFrames(peer.framesByConnection[2]), isEmpty);
    expect(gateway.send(pageId, 'collabJoin', {}), isFalse);
  });

  test('offline and synchronous send failure never enqueue document commands', () async {
    await gateway.register(pageId: pageId, documentId: 'doc', instanceId: 'one', callbacks: {});
    expect(gateway.send(pageId, 'collabJoin', {}), isFalse);
    expect(csesWebSocketClient.getStatus()['messageQueueSize'], 0);
    await peer.connect();
    expect(gateway.send(pageId, 'collabUpdate', {'data': Object()}), isFalse);
    expect(csesWebSocketClient.getStatus()['messageQueueSize'], 0);
    csesWebSocketClient.disconnected();
    expect(gateway.send(pageId, 'collabLeave', {}), isFalse);
    expect(gateway.send(pageId, 'unsubscribe', {}), isFalse);
    await gateway.unregister(pageId);
    expect(csesWebSocketClient.getStatus()['messageQueueSize'], 0);
    await peer.connect();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(_documentFrames(peer.framesByConnection[1]), isEmpty);
  });

  test('online registration awaits subscribe; explicit unsubscribe is not duplicated', () async {
    await peer.connect();
    await gateway.register(pageId: pageId, documentId: 'doc', instanceId: 'one', callbacks: {});
    expect(gateway.send(pageId, 'collabLeave', {}), isTrue);
    expect(gateway.send(pageId, 'unsubscribe', {}), isTrue);
    await gateway.unregister(pageId);
    await gateway.unregister(pageId);
    await _until(() => peer.documentFrames.length >= 3);
    expect(peer.documentFrames.map((m) => m['action']), ['subscribe', 'collabLeave', 'unsubscribe']);
    expect(csesWebSocketClient.isConnected, isTrue);
    expect(csesWebSocketClient.getCSESStatus()['subscribed_pages'], isEmpty);
  });

  test('pending registration cancellation does not resurrect or remove a reopened page', () async {
    // 仅测试持锁制造竞争；生产Gateway不借用Common锁形成完成屏障。
    final entered = Completer<void>();
    final release = Completer<void>();
    final holding = csesWebSocketClient.lock.synchronized(() async {
      entered.complete();
      await release.future;
    });
    await entered.future;
    final opening = gateway.register(pageId: pageId, documentId: 'doc', instanceId: 'old', callbacks: {});
    final cancelled = expectLater(opening, throwsStateError);
    final closing = gateway.unregister(pageId);
    final reopening = gateway.register(pageId: pageId, documentId: 'doc', instanceId: 'new', callbacks: {});
    release.complete();
    await holding;
    await cancelled;
    await closing;
    await reopening;
    await peer.connect();
    expect(gateway.send(pageId, 'collabJoin', {}), isTrue);
    await _until(() => peer.documentFrames.length >= 2);
    expect(peer.documentFrames.every((m) => (m['subscription'] as Map)['instance'] == 'new'), isTrue);
  });

  test('gateway does not send or unregister another adapter ownership', () async {
    final other = CommonCsesCollabGateway();
    await gateway.register(pageId: pageId, documentId: 'doc', instanceId: 'one', callbacks: {});
    await other.unregister(pageId);
    await peer.connect();
    expect(other.send(pageId, 'collabJoin', {}), isFalse);
    expect(gateway.send(pageId, 'collabJoin', {}), isTrue);
    await expectLater(
      gateway.register(pageId: pageId, documentId: 'doc', instanceId: 'duplicate', callbacks: {}),
      throwsStateError,
    );
  });

  test('native document sends edits, merges offline changes and replays to a read-only controller', () async {
    final directory = await Directory.systemTemp.createTemp('example-gateway-native-');
    CollabController? current;
    addTearDown(() async {
      await current?.close();
      await directory.delete(recursive: true);
    });
    final config = CollabDocumentConfig(
      documentId: 'existing-doc',
      serverIdentity: ctx.websocketHost!,
      companyId: User().companyId,
      userId: User().userId!,
      databasePath: '${directory.path}/first.sqlite',
      editable: true,
    );
    await DocumentBootstrapper.prepareBlank(
      config: config,
      operationId: 'seed-existing-doc',
      paragraphId: 'seed-paragraph',
      createdAt: DateTime.fromMillisecondsSinceEpoch(1792584000000),
    );
    final first = CollabController.cses(config: config, gateway: gateway);
    current = first;
    await first.initialize();
    await peer.connect();
    await _until(() => first.status == ConnectionStatus.online && peer.fullUpdates > 0);
    final before = peer.documentFrames.where((m) => m['action'] == 'collabUpdate').length;
    final node = first.editorState.document.first!;
    await first.editorState.apply(first.editorState.transaction..insertText(node, 0, '在线'));
    await _until(() => peer.documentFrames.where((m) => m['action'] == 'collabUpdate').length > before);
    csesWebSocketClient.disconnected();
    await _until(() => first.status == ConnectionStatus.offline);
    final offline = first.editorState.document.first!;
    await first.editorState.apply(first.editorState.transaction..insertText(offline, 2, '离线'));
    expect(first.editorState.document.first!.delta!.toPlainText(), '在线离线');
    final synced = peer.fullUpdates;
    await peer.connect();
    await _until(() => first.status == ConnectionStatus.online && peer.fullUpdates > synced);
    await first.close();
    await _until(() => peer.documentFrames.where((m) => m['action'] == 'unsubscribe').length == 1);
    expect(peer.documentFrames.where((m) => m['action'] == 'collabLeave'), hasLength(1));
    expect(csesWebSocketClient.isConnected, isTrue);
    expect(csesWebSocketClient.getCSESStatus()['subscribed_pages'], isEmpty);
    final second = CollabController.cses(
      config: CollabDocumentConfig(
        documentId: config.documentId,
        serverIdentity: config.serverIdentity,
        companyId: config.companyId,
        userId: config.userId,
        databasePath: '${directory.path}/reader.sqlite',
      ),
      gateway: gateway,
    );
    current = second;
    await second.initialize();
    await _until(
      () =>
          second.status == ConnectionStatus.online && second.editorState.document.first?.delta?.toPlainText() == '在线离线',
    );
    expect(second.canEdit, isFalse);
    await _until(() => peer.documentFrames.lastWhere((m) => m['action'] == 'collabUpdate')['body']['data'] == 'AAA=');
    expect(csesWebSocketClient.getStatus()['messageQueueSize'], 0);
    await second.close();
    await _until(() => peer.documentFrames.where((m) => m['action'] == 'unsubscribe').length == 2);
    expect(csesWebSocketClient.isConnected, isTrue);
  });
}

/// 从[frames]筛选Document通道，忽略Common全局订阅和主连接控制帧。
List<Map<String, dynamic>> _documentFrames(List<Map<String, dynamic>> frames) =>
    frames.where((m) => (m['subscription'] as Map?)?['channel'] == 'Document').toList();

/// 等待[predicate]成立，最多5秒；仅用于测试中真实连接/投影的有界等待。
Future<void> _until(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) throw TimeoutException('本机协同事件未在5秒内完成');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// 真实回环协议对端；仅回放客户端握手完整增量，不实现业务后台或保存ACK。
class _Peer {
  /// 持有[server]，由[close]释放；每个用例创建独立实例。
  _Peer(this.server);

  /// 只绑定回环地址的服务。
  final HttpServer server;

  /// 本对端接受的连接，由close统一关闭。
  final List<WebSocket> sockets = [];

  /// 各连接按到达顺序记录的协议帧，不包含真实凭证。
  final List<List<Map<String, dynamic>>> framesByConnection = [];

  /// 本对端创建的收包订阅，关闭Socket前先取消，避免清理期间处理迟到消息。
  final List<StreamSubscription<dynamic>> _messages = [];

  /// 接受连接的服务订阅，由close等待取消。
  StreamSubscription<WebSocket>? _accepts;

  /// 最近握手中收到的完整V1状态；初始为空合法update。
  String _snapshot = 'AAA=';

  /// 按连接索引和instance标记join后的第一份上行，避免把后续增量误作完整状态。
  final Set<String> _expectingFull = {};

  /// 非空完整正文上行次数，用于等待重连补传。
  int fullUpdates = 0;

  /// 关闭开始即拒绝新的协议处理，阻止迟到回包使用已关闭Socket。
  bool _closing = false;

  /// 合并各连接的文档帧；不改变接收顺序或协议内容。
  List<Map<String, dynamic>> get documentFrames => _documentFrames(framesByConnection.expand((f) => f).toList());

  /// 创建真实回环服务，每条连接先发hello，协同握手回放同源增量及空状态向量。
  static Future<_Peer> open() async {
    final peer = _Peer(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    peer._accepts = peer.server.transform(WebSocketTransformer()).listen((socket) {
      peer.sockets.add(socket);
      final index = peer.framesByConnection.length;
      final frames = <Map<String, dynamic>>[];
      peer.framesByConnection.add(frames);
      peer._messages.add(
        socket.listen((raw) {
          if (peer._closing) return;
          final message = jsonDecode(raw as String) as Map<String, dynamic>;
          frames.add(message);
          final route = message['subscription'] as Map<String, dynamic>?;
          final key = '$index/${route?['instance']}';
          if (message['action'] == 'collabJoin') {
            peer._expectingFull.add(key);
            socket.add(
              jsonEncode({
                'action': 'collabSync',
                'subscription': route,
                'body': {'data': peer._snapshot, 'stateVector': 'AA=='},
              }),
            );
          } else if (message['action'] == 'collabUpdate' && peer._expectingFull.remove(key)) {
            final data = message['body']['data'] as String;
            if (base64Decode(data).length > 2) {
              peer._snapshot = data;
              peer.fullUpdates++;
            }
          }
        }),
      );
      socket.add(jsonEncode({'action': 'hello', 'serverName': 'gateway-loopback'}));
    });
    return peer;
  }

  /// 启动已登录Common主连接并等待hello-ready；不会关闭旧文档。
  Future<void> connect() async {
    await const CsesDemoHost().connect();
    await _until(() => csesWebSocketClient.isConnected);
  }

  /// 停止处理协议，再关闭客户端、监听和服务；身份由CommonLoginHarness清理。
  Future<void> close() async {
    _closing = true;
    csesWebSocketClient.close();
    for (final messages in _messages) {
      await messages.cancel();
    }
    await _accepts?.cancel();
    for (final socket in sockets) {
      await socket.close();
    }
    await server.close(force: true);
  }
}
