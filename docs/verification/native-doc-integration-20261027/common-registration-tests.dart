import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cses_common/cses_common_network.dart';
import 'package:cses_common/runtime/context/context.dart';
import 'package:cses_common/runtime/config/config.dart';
import 'package:cses_common/runtime/config/env_type.dart';
import 'package:flutter_test/flutter_test.dart';

/// 覆盖等待屏障、页面身份隔离、即时发送及既有页面排队/重连契约。
void main() {
  final client = csesWebSocketClient;
  final route = SocketSubscription(channel: 'Document', topic: 'doc-test', instance: 'editor-test');

  setUp(() {
    client.close();
    Config().appType = 'websocket-local-test';
    Config().envType = EnvType.debug;
    ctx.cookieId = 'local-test';
    ctx.osVersion = 'test';
    ctx.deviceId = 'local-test';
    ctx.cpuVersion = 'test';
  });
  tearDown(client.close);

  test('即时离线发送不入队，旧接口仍排队', () {
    expect(client.trySendMessage({'action': 'collabJoin'}), isFalse);
    expect(client.getStatus()['messageQueueSize'], 0);
    expect(client.sendMessageWithResult({'action': 'meeting-command'}), isFalse);
    expect(client.getStatus()['messageQueueSize'], 1);
  });

  test('await注册后立即可分发，await注销后不可分发', () async {
    var received = 0;
    await client.registerListenersAsync(
      pageId: 'editor',
      subscription: route,
      onlyListen: true,
      eventCallbacks: {'collabUpdate': (_) => received++},
    );
    client.onMessage(_frame(route));
    await Future<void>.delayed(Duration.zero);
    expect(received, 1);
    await client.unregisterListenersAsync('editor', localOnly: true);
    client.onMessage(_frame(route));
    await Future<void>.delayed(Duration.zero);
    expect(received, 1);
    expect(client.getCSESStatus()['listener_pages'], isEmpty);
  });

  test('等待锁的注册被注销取消，注销完成后不会复活', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final held = client.lock.synchronized(() async {
      entered.complete();
      await release.future;
    });
    await entered.future;
    final registering = client.registerListenersAsync(
      pageId: 'cancelled',
      subscription: route,
      eventCallbacks: {},
      immediateOnly: true,
    );
    final rejected = expectLater(registering, throwsStateError);
    final unregistering = client.unregisterListenersAsync('cancelled', localOnly: true);
    release.complete();
    await held;
    await rejected;
    await unregistering;
    expect(client.getCSESStatus()['subscribed_pages'], isEmpty);
  });

  test('关闭取消等待锁的注册', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final held = client.lock.synchronized(() async {
      entered.complete();
      await release.future;
    });
    await entered.future;
    final registering = client.registerListenersAsync(pageId: 'closed', subscription: route, eventCallbacks: {});
    final rejected = expectLater(registering, throwsStateError);
    client.close();
    release.complete();
    await held;
    await rejected;
    expect(client.getCSESStatus()['listener_pages'], isEmpty);
  });

  test('同名页面在注销期间重开只保留新监听', () async {
    var oldCount = 0;
    var newCount = 0;
    await client.registerListenersAsync(
      pageId: 'reopen',
      subscription: route,
      onlyListen: true,
      eventCallbacks: {'collabUpdate': (_) => oldCount++},
    );
    final closing = client.unregisterListenersAsync('reopen', localOnly: true);
    final opening = client.registerListenersAsync(
      pageId: 'reopen',
      subscription: route,
      onlyListen: true,
      eventCallbacks: {'collabUpdate': (_) => newCount++},
    );
    await closing;
    await opening;
    client.onMessage(_frame(route));
    await Future<void>.delayed(Duration.zero);
    expect(oldCount, 0);
    expect(newCount, 1);
  });

  test('离线即时登记/注销不入队，既有登记注销仍排队', () async {
    await client.registerListenersAsync(
      pageId: 'immediate',
      subscription: route,
      eventCallbacks: {},
      immediateOnly: true,
    );
    expect(client.trySendWithPage(pageId: 'immediate', action: 'collabJoin'), isFalse);
    await client.unregisterListenersAsync('immediate');
    expect(client.getStatus()['messageQueueSize'], 0);
    await client.registerListenersAsync(pageId: 'legacy', subscription: route, eventCallbacks: {});
    await client.unregisterListenersAsync('legacy');
    expect(client.getStatus()['messageQueueSize'], 1);
  });

  test('仅本地注销不发送且重复注销安全', () async {
    await client.registerListenersAsync(pageId: 'local', subscription: route, eventCallbacks: {});
    await client.unregisterListenersAsync('local', localOnly: true);
    await client.unregisterListenersAsync('local', localOnly: true);
    expect(client.getStatus()['messageQueueSize'], 0);
    expect(client.trySendWithPage(pageId: 'local', action: 'collabJoin', ensureSubscribed: false), isFalse);
  });

  test('实例完整路由隔离，注销一页不影响另一页', () async {
    var a = 0;
    var b = 0;
    final routeB = SocketSubscription(channel: 'Document', topic: 'doc-test', instance: 'other');
    await client.registerListenersAsync(
      pageId: 'a',
      subscription: route,
      onlyListen: true,
      eventCallbacks: {'collabUpdate': (_) => a++},
    );
    await client.registerListenersAsync(
      pageId: 'b',
      subscription: routeB,
      onlyListen: true,
      eventCallbacks: {'collabUpdate': (_) => b++},
    );
    await client.unregisterListenersAsync('a', localOnly: true);
    client.onMessage(_frame(route));
    client.onMessage(_frame(routeB));
    await Future<void>.delayed(Duration.zero);
    expect(a, 0);
    expect(b, 1);
  });

  test('纯监听不允许订阅正文，失败不留下半登记', () async {
    await expectLater(
      client.registerListenersAsync(
        pageId: 'invalid',
        subscription: route,
        eventCallbacks: {},
        onlyListen: true,
        params: {},
      ),
      throwsArgumentError,
    );
    expect(client.getCSESStatus()['listener_pages'], isEmpty);
  });

  test('真实连接先订阅后业务，双路由字段一致且只订阅一次', () async {
    final peer = await _LocalPeer.open();
    addTearDown(peer.close);
    await client.registerListenersAsync(pageId: 'online', subscription: route, eventCallbacks: {}, immediateOnly: true);
    await peer.connect(client);
    expect(client.trySendWithPage(pageId: 'online', action: 'collabJoin', body: {'stateVector': 'AA=='}), isTrue);
    expect(client.trySendWithPage(pageId: 'online', action: 'collabSync', body: {}), isTrue);
    await peer.waitFor(3, channel: 'Document');
    final frames = peer.frames.where((m) => (m['subscription'] as Map?)?['channel'] == 'Document').toList();
    expect(frames.map((m) => m['action']), ['subscribe', 'collabJoin', 'collabSync']);
    for (final frame in frames) {
      expect(frame['subscription'], route.toJson());
      expect(frame['header'], route.toJson());
    }
    final before = peer.frames.length;
    await client.unregisterListenersAsync('online', localOnly: true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(peer.frames.length, before);
    expect(client.isConnected, isTrue);
  });

  test('同步编码失败即时不入队，旧发送失败仍入队', () async {
    final peer = await _LocalPeer.open();
    addTearDown(peer.close);
    await peer.connect(client);
    expect(client.trySendMessage({'action': 'bad', 'body': Object()}), isFalse);
    expect(client.getStatus()['messageQueueSize'], 0);
    expect(client.sendMessageWithResult({'action': 'bad', 'body': Object()}), isFalse);
    expect(client.getStatus()['messageQueueSize'], 1);
  });

  test('订阅发送失败阻断业务且不入队，修复参数后按顺序重试', () async {
    final peer = await _LocalPeer.open();
    addTearDown(peer.close);
    await peer.connect(client);
    final params = <String, dynamic>{'invalid': Object()};
    await client.registerListenersAsync(
      pageId: 'failed-subscribe',
      subscription: route,
      eventCallbacks: {},
      params: params,
      immediateOnly: true,
    );
    expect(client.trySendWithPage(pageId: 'failed-subscribe', action: 'collabJoin'), isFalse);
    expect(client.getStatus()['messageQueueSize'], 0);
    params.clear();
    expect(client.trySendWithPage(pageId: 'failed-subscribe', action: 'collabJoin'), isTrue);
    await peer.waitFor(2, channel: 'Document');
    expect(peer.frames.where((m) => (m['subscription'] as Map?)?['channel'] == 'Document').map((m) => m['action']), [
      'subscribe',
      'collabJoin',
    ]);
  });

  test('重连后新登记的首次订阅失败重试仍使用首次参数', () async {
    final peer = await _LocalPeer.open();
    addTearDown(peer.close);
    await peer.connect(client);
    client.disconnected();
    await client.init();
    await _until(() => client.isConnected);
    final params = <String, dynamic>{'phase': 'initial', 'invalid': Object()};
    await client.registerListenersAsync(
      pageId: 'new-after-reconnect',
      subscription: route,
      eventCallbacks: {},
      params: params,
      reconnectParams: {'phase': 'restore'},
      immediateOnly: true,
    );
    params.remove('invalid');
    expect(client.trySendWithPage(pageId: 'new-after-reconnect', action: 'collabJoin'), isTrue);
    await peer.waitFor(2, channel: 'Document');
    expect(peer.frames.firstWhere((m) => (m['subscription'] as Map?)?['channel'] == 'Document')['body'], {
      'phase': 'initial',
    });
    expect(client.getStatus()['messageQueueSize'], 0);
  });

  test('注销开始后立即阻断回调和恢复，即使仍在等待锁', () async {
    var received = 0;
    var restored = 0;
    await client.registerListenersAsync(
      pageId: 'closing',
      subscription: route,
      eventCallbacks: {'collabUpdate': (_) => received++},
      onReconnect: () => restored++,
    );
    final entered = Completer<void>();
    final release = Completer<void>();
    final held = client.lock.synchronized(() async {
      entered.complete();
      await release.future;
    });
    await entered.future;
    final closing = client.unregisterListenersAsync('closing', localOnly: true);
    client.onMessage(_frame(route));
    client.onReconnect();
    await Future<void>.delayed(Duration.zero);
    expect(received, 0);
    expect(restored, 0);
    release.complete();
    await held;
    await closing;
  });

  test('首次/恢复订阅正文沿用会议直播参数约定', () async {
    final peer = await _LocalPeer.open();
    addTearDown(peer.close);
    final meeting = SocketSubscription(channel: 'Meeting', topic: 'meeting-test');
    client.registerListeners(
      pageId: 'meeting',
      subscription: meeting,
      eventCallbacks: {},
      params: {'isReconnect': false},
      reconnectParams: {'isReconnect': true},
    );
    await client.lock.synchronized(() {});
    await peer.connect(client);
    await peer.waitFor(1, channel: 'Meeting');
    expect(peer.frames.firstWhere((m) => (m['subscription'] as Map?)?['channel'] == 'Meeting')['body'], {
      'isReconnect': false,
    });
    client.disconnected();
    await client.init();
    await _until(() => client.isConnected);
    await peer.waitFor(2, channel: 'Meeting');
    expect(peer.frames.lastWhere((m) => (m['subscription'] as Map?)?['channel'] == 'Meeting')['body'], {
      'isReconnect': true,
    });
    client.unregisterListeners('meeting');
    await client.lock.synchronized(() {});
    await peer.waitFor(3, channel: 'Meeting');
    expect(peer.frames.lastWhere((m) => (m['subscription'] as Map?)?['channel'] == 'Meeting')['action'], 'unsubscribe');
  });
  test('直播旧入口保持首次参数、恢复参数和自动退出', () async {
    final peer = await _LocalPeer.open();
    addTearDown(peer.close);
    final meeting = SocketSubscription(channel: 'Live', topic: 'live-test');
    client.registerListeners(
      pageId: 'live',
      subscription: meeting,
      eventCallbacks: {},
      params: {'isReconnect': false},
      reconnectParams: {'isReconnect': true},
    );
    await client.lock.synchronized(() {});
    await peer.connect(client);
    await peer.waitFor(1, channel: 'Live');
    expect(peer.frames.firstWhere((m) => (m['subscription'] as Map?)?['channel'] == 'Live')['body'], {
      'isReconnect': false,
    });
    client.disconnected();
    await client.init();
    await _until(() => client.isConnected);
    await peer.waitFor(2, channel: 'Live');
    expect(peer.frames.lastWhere((m) => (m['subscription'] as Map?)?['channel'] == 'Live')['body'], {
      'isReconnect': true,
    });
    client.unregisterListeners('live');
    await client.lock.synchronized(() {});
    await peer.waitFor(3, channel: 'Live');
    expect(peer.frames.lastWhere((m) => (m['subscription'] as Map?)?['channel'] == 'Live')['action'], 'unsubscribe');
  });
}

/// 用[route]构造实际分发信封，不包含账号或凭证。
String _frame(SocketSubscription route) =>
    jsonEncode({'action': 'collabUpdate', 'subscription': route.toJson(), 'body': {}});

/// 等待[ready]成立，最多3秒；只用于真实本机连接事件的有界等待。
Future<void> _until(bool Function() ready) async {
  final end = DateTime.now().add(const Duration(seconds: 3));
  while (!ready()) {
    if (DateTime.now().isAfter(end)) throw TimeoutException('本机协议事件超时');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// 真实本机WebSocket对端，持有服务、客户端连接及原上下文配置。
class _LocalPeer {
  /// 借用[server]和[previousHost]，由[close]恢复配置及关闭资源。
  _LocalPeer(this.server, this.previousHost);

  final HttpServer server;
  final String? previousHost;
  final List<WebSocket> sockets = [];
  final List<Map<String, dynamic>> frames = [];
  StreamSubscription<HttpRequest>? _requests;

  /// 创建只监听回环地址的测试服务，每条连接发送hello，不访问业务服务。
  static Future<_LocalPeer> open() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final peer = _LocalPeer(server, ctx.websocketHost);
    peer._requests = server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      peer.sockets.add(socket);
      socket.listen((frame) {
        final message = jsonDecode(frame as String) as Map<String, dynamic>;
        peer.frames.add(message);
      });
      socket.add(jsonEncode({'action': 'hello', 'serverName': 'local-test'}));
    });
    return peer;
  }

  /// 通过公开入口启动[client]并等待hello-ready，保留原账号上下文。
  Future<void> connect(CSESWebSocketClient client) async {
    ctx.websocketHost = 'ws://127.0.0.1:${server.port}';
    await client.init();
    await _until(() => client.isConnected);
  }

  /// 等待[channel]的[count]个帧，按完整channel字段过滤全局订阅。
  Future<void> waitFor(int count, {required String channel}) =>
      _until(() => frames.where((m) => (m['subscription'] as Map?)?['channel'] == channel).length >= count);

  /// 关闭主客户端再释放测试服务及所有连接，恢复原host；重复资源关闭由平台处理。
  Future<void> close() async {
    csesWebSocketClient.close();
    ctx.websocketHost = previousHost;
    for (final socket in sockets) {
      await socket.close();
    }
    await _requests?.cancel();
    await server.close(force: true);
  }
}
