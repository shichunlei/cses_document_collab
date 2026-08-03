import 'dart:async';
import 'dart:typed_data';

import 'package:cses_mobile_collab_demo/src/collab/io_collab_socket_transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('builds room URL and forwards binary y-websocket frames', () async {
    final connection = _FakeSocketConnection();
    final endpoints = <Uri>[];
    final inbound = <Uint8List>[];
    final states = <CollabTransportStatus>[];
    final logs = <String>[];
    final syncStep1 = Uint8List.fromList([0, 0, 1, 0]);
    final transport = IoCollabSocketTransport(
      serverUrl: 'ws://127.0.0.1:1234/collaboration/',
      roomId: 'doc-1',
      syncFrameFactory: () => syncStep1,
      onBinaryMessage: inbound.add,
      onStateChanged: (status, _, _) => states.add(status),
      logSink: logs.add,
      connector: (endpoint) async {
        endpoints.add(endpoint);
        return connection;
      },
      resyncInterval: const Duration(hours: 1),
      staleTimeout: const Duration(hours: 1),
      watchdogInterval: const Duration(hours: 1),
    );
    addTearDown(transport.dispose);

    await transport.start();

    expect(
      endpoints.single,
      Uri.parse('ws://127.0.0.1:1234/collaboration/doc-1'),
    );
    expect(connection.sent, [syncStep1]);
    expect(states, contains(CollabTransportStatus.online));

    connection.addIncoming([0, 2, 1, 7]);
    await _waitUntil(() => inbound.isNotEmpty);
    expect(inbound.single, Uint8List.fromList([0, 2, 1, 7]));
    expect(
      logs.any((line) => line.contains('[OUT] sync-step-1 bytes=4')),
      isTrue,
    );
    expect(
      logs.any((line) => line.contains('[IN] sync-update bytes=4')),
      isTrue,
    );
    expect(
      logs.any(
        (line) => line.contains('[STATE] status=online event=socket-connected'),
      ),
      isTrue,
    );
  });

  test('describes y-websocket frames without decoding payloads', () {
    expect(
      describeYWebSocketFrame(Uint8List.fromList([0, 0, 1, 0])),
      'sync-step-1',
    );
    expect(
      describeYWebSocketFrame(Uint8List.fromList([0, 1, 0])),
      'sync-step-2',
    );
    expect(
      describeYWebSocketFrame(Uint8List.fromList([0, 2, 1, 7])),
      'sync-update',
    );
    expect(describeYWebSocketFrame(Uint8List.fromList([1, 1, 0])), 'awareness');
    expect(describeYWebSocketFrame(Uint8List(0)), 'malformed');
  });

  test('periodically sends Sync Step 1 while online', () async {
    final connection = _FakeSocketConnection();
    final transport = IoCollabSocketTransport(
      serverUrl: 'ws://127.0.0.1:1234',
      roomId: 'doc-1',
      syncFrameFactory: () => Uint8List.fromList([0, 0, 1, 0]),
      onBinaryMessage: (_) {},
      onStateChanged: (_, _, _) {},
      connector: (_) async => connection,
      resyncInterval: const Duration(milliseconds: 10),
      staleTimeout: const Duration(seconds: 1),
      watchdogInterval: const Duration(milliseconds: 50),
    );
    addTearDown(transport.dispose);

    await transport.start();
    await _waitUntil(() => connection.sent.length >= 3);

    expect(connection.sent.length, greaterThanOrEqualTo(3));
  });

  test('reconnects when no inbound application frame arrives', () async {
    final connections = <_FakeSocketConnection>[];
    final events = <String>[];
    final transport = IoCollabSocketTransport(
      serverUrl: 'ws://127.0.0.1:1234',
      roomId: 'doc-1',
      syncFrameFactory: () => Uint8List.fromList([0, 0, 1, 0]),
      onBinaryMessage: (_) {},
      onStateChanged: (_, event, _) => events.add(event),
      connector: (_) async {
        final connection = _FakeSocketConnection();
        connections.add(connection);
        return connection;
      },
      resyncInterval: const Duration(seconds: 1),
      staleTimeout: const Duration(milliseconds: 30),
      watchdogInterval: const Duration(milliseconds: 5),
      reconnectBaseDelay: const Duration(milliseconds: 5),
      maxReconnectDelay: const Duration(milliseconds: 10),
    );
    addTearDown(transport.dispose);

    await transport.start();
    await _waitUntil(() => connections.length >= 2);

    expect(events, contains('socket-stale-reconnect'));
    expect(connections.first.isOpen, isFalse);
  });

  test('retries a failed initial connection', () async {
    var attempts = 0;
    final events = <String>[];
    final connection = _FakeSocketConnection();
    final transport = IoCollabSocketTransport(
      serverUrl: 'ws://127.0.0.1:1234',
      roomId: 'doc-1',
      syncFrameFactory: () => Uint8List.fromList([0, 0, 1, 0]),
      onBinaryMessage: (_) {},
      onStateChanged: (_, event, _) => events.add(event),
      connector: (_) async {
        attempts += 1;
        if (attempts == 1) {
          throw const SocketExceptionForTest();
        }
        return connection;
      },
      resyncInterval: const Duration(hours: 1),
      staleTimeout: const Duration(hours: 1),
      watchdogInterval: const Duration(hours: 1),
      reconnectBaseDelay: const Duration(milliseconds: 5),
      maxReconnectDelay: const Duration(milliseconds: 10),
    );
    addTearDown(transport.dispose);

    await transport.start();
    await _waitUntil(() => attempts >= 2 && transport.isOnline);

    expect(events, contains('socket-connect-failed'));
    expect(connection.sent, isNotEmpty);
  });

  test('closes a WebSocket handshake that succeeds after timeout', () async {
    final lateConnection = _FakeSocketConnection();
    final pendingConnection = Completer<CollabSocketConnection>();
    final transport = IoCollabSocketTransport(
      serverUrl: 'ws://127.0.0.1:1234',
      roomId: 'doc-1',
      syncFrameFactory: () => Uint8List.fromList([0, 0, 1, 0]),
      onBinaryMessage: (_) {},
      onStateChanged: (_, _, _) {},
      connector: (_) => pendingConnection.future,
      resyncInterval: const Duration(hours: 1),
      staleTimeout: const Duration(hours: 1),
      watchdogInterval: const Duration(hours: 1),
      reconnectBaseDelay: const Duration(hours: 1),
      maxReconnectDelay: const Duration(hours: 1),
      connectTimeout: const Duration(milliseconds: 5),
    );
    addTearDown(transport.dispose);

    await transport.start();
    expect(transport.status, CollabTransportStatus.offline);

    pendingConnection.complete(lateConnection);
    await _waitUntil(() => !lateConnection.isOpen);

    expect(lateConnection.sent, isEmpty);
  });
}

final class _FakeSocketConnection implements CollabSocketConnection {
  final StreamController<Object?> _incoming = StreamController<Object?>();
  final List<Uint8List> sent = [];
  bool _isOpen = true;

  @override
  bool get isOpen => _isOpen;

  @override
  Stream<Object?> get messages => _incoming.stream;

  void addIncoming(List<int> bytes) {
    _incoming.add(Uint8List.fromList(bytes));
  }

  @override
  void send(Uint8List bytes) {
    if (!_isOpen) {
      throw StateError('socket is closed');
    }
    sent.add(Uint8List.fromList(bytes));
  }

  @override
  Future<void> close() async {
    if (!_isOpen) {
      return;
    }
    _isOpen = false;
    await _incoming.close();
  }
}

final class SocketExceptionForTest implements Exception {
  const SocketExceptionForTest();

  @override
  String toString() => 'test connection failure';
}

Future<void> _waitUntil(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Condition was not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}
