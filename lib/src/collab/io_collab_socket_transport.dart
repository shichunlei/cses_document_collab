import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

enum CollabTransportStatus { idle, connecting, online, offline }

typedef CollabBinaryMessageHandler = void Function(Uint8List bytes);
typedef CollabSyncFrameFactory = Uint8List Function();
typedef CollabTransportStateHandler =
    void Function(CollabTransportStatus status, String event, Object? error);
typedef CollabTransportLogSink = void Function(String message);
typedef CollabSocketConnector =
    Future<CollabSocketConnection> Function(Uri endpoint);

abstract interface class CollabSocketConnection {
  Stream<Object?> get messages;

  bool get isOpen;

  void send(Uint8List bytes);

  Future<void> close();
}

final class DartIoCollabSocketConnection implements CollabSocketConnection {
  DartIoCollabSocketConnection._(this._socket);

  final WebSocket _socket;

  static Future<DartIoCollabSocketConnection> connect(
    Uri endpoint, {
    Map<String, dynamic>? headers,
    Duration? pingInterval,
  }) async {
    final socket = await WebSocket.connect(
      endpoint.toString(),
      headers: headers,
    );
    socket.pingInterval = pingInterval;
    return DartIoCollabSocketConnection._(socket);
  }

  @override
  bool get isOpen => _socket.readyState == WebSocket.open;

  @override
  Stream<Object?> get messages => _socket;

  @override
  void send(Uint8List bytes) {
    _socket.add(bytes);
  }

  @override
  Future<void> close() async {
    await _socket.close(WebSocketStatus.normalClosure);
  }
}

/// `dart:io` WebSocket transport for the y-websocket binary protocol.
///
/// Rust/Yrs remains the owner of CRDT state and protocol encoding. This class
/// only owns the socket lifecycle and periodically asks Rust for a Sync Step 1
/// frame so dropped/offline updates converge after reconnect.
final class IoCollabSocketTransport {
  IoCollabSocketTransport({
    required String serverUrl,
    required this.roomId,
    required this.syncFrameFactory,
    required this.onBinaryMessage,
    required this.onStateChanged,
    Map<String, dynamic>? headers,
    CollabSocketConnector? connector,
    this.resyncInterval = const Duration(seconds: 20),
    this.staleTimeout = const Duration(seconds: 30),
    this.watchdogInterval = const Duration(seconds: 3),
    this.reconnectBaseDelay = const Duration(milliseconds: 100),
    this.maxReconnectDelay = const Duration(seconds: 10),
    this.connectTimeout = const Duration(seconds: 8),
    Duration pingInterval = const Duration(seconds: 15),
    this.enableProtocolLogging = !kReleaseMode,
    CollabTransportLogSink? logSink,
  }) : _baseUri = _parseServerUri(serverUrl),
       _logSink = logSink ?? ((message) => debugPrint(message)),
       _connector =
           connector ??
           ((endpoint) => DartIoCollabSocketConnection.connect(
             endpoint,
             headers: headers,
             pingInterval: pingInterval,
           ));

  final String roomId;
  final CollabSyncFrameFactory syncFrameFactory;
  final CollabBinaryMessageHandler onBinaryMessage;
  final CollabTransportStateHandler onStateChanged;
  final Duration resyncInterval;
  final Duration staleTimeout;
  final Duration watchdogInterval;
  final Duration reconnectBaseDelay;
  final Duration maxReconnectDelay;
  final Duration connectTimeout;
  final bool enableProtocolLogging;
  final CollabTransportLogSink _logSink;
  final CollabSocketConnector _connector;

  Uri _baseUri;
  CollabSocketConnection? _connection;
  StreamSubscription<Object?>? _subscription;
  Timer? _reconnectTimer;
  Timer? _resyncTimer;
  Timer? _watchdogTimer;
  DateTime? _lastInboundAt;
  CollabTransportStatus _status = CollabTransportStatus.idle;
  int _generation = 0;
  int? _connectingGeneration;
  int _failedReconnects = 0;
  bool _shouldConnect = false;
  bool _disposed = false;

  CollabTransportStatus get status => _status;
  DateTime? get lastInboundAt => _lastInboundAt;
  bool get isOnline => _status == CollabTransportStatus.online;
  String get serverUrl => _baseUri.toString();

  Uri get endpoint {
    final pathSegments =
        _baseUri.pathSegments
            .where((segment) => segment.isNotEmpty)
            .toList(growable: true)
          ..add(roomId);
    return _baseUri.replace(pathSegments: pathSegments);
  }

  void updateServerUrl(String value) {
    _baseUri = _parseServerUri(value);
    _log('CONFIG', 'endpoint=$endpoint');
  }

  Future<void> start() async {
    if (_disposed) {
      return;
    }
    _shouldConnect = true;
    await _connect(event: 'socket-connecting');
  }

  Future<void> reconnect({String event = 'socket-reconnecting'}) async {
    if (_disposed) {
      return;
    }
    _shouldConnect = true;
    _failedReconnects = 0;
    _generation += 1;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _stopMaintenance();
    await _closeCurrentConnection();
    await _connect(event: event);
  }

  Future<void> onAppResumed() async {
    if (_disposed || !_shouldConnect) {
      return;
    }
    final lastInboundAt = _lastInboundAt;
    final isStale =
        lastInboundAt == null ||
        DateTime.now().difference(lastInboundAt) >= staleTimeout;
    if (isOnline && !isStale) {
      return;
    }
    await reconnect(event: 'foreground-reconnect');
  }

  bool send(Uint8List bytes) {
    final connection = _connection;
    if (bytes.isEmpty) {
      return false;
    }
    if (connection == null || !connection.isOpen) {
      _logFrame('DROP', bytes, suffix: 'reason=socket-not-open');
      return false;
    }
    try {
      connection.send(bytes);
      _logFrame('OUT', bytes);
      return true;
    } catch (error) {
      unawaited(
        _handleConnectionLost(
          connection,
          _generation,
          event: 'socket-send-failed',
          error: error,
        ),
      );
      return false;
    }
  }

  Future<void> stop({String event = 'socket-stopped'}) async {
    if (_disposed) {
      return;
    }
    _shouldConnect = false;
    _generation += 1;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _stopMaintenance();
    await _closeCurrentConnection();
    _emit(CollabTransportStatus.offline, event);
  }

  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _shouldConnect = false;
    _disposed = true;
    _generation += 1;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _stopMaintenance();
    await _closeCurrentConnection();
  }

  Future<void> _connect({required String event}) async {
    if (_disposed ||
        !_shouldConnect ||
        _connection != null ||
        _connectingGeneration == _generation) {
      return;
    }

    final generation = _generation;
    _connectingGeneration = generation;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _emit(CollabTransportStatus.connecting, event);
    _log('CONNECT', 'opening endpoint=$endpoint generation=$generation');

    try {
      final connection = await _openConnection();
      if (_disposed || !_shouldConnect || generation != _generation) {
        await connection.close();
        return;
      }

      _connection = connection;
      _failedReconnects = 0;
      _lastInboundAt = DateTime.now();
      _subscription = connection.messages.listen(
        (data) {
          if (!identical(_connection, connection) ||
              generation != _generation) {
            return;
          }
          _lastInboundAt = DateTime.now();
          if (data is List<int>) {
            final bytes = Uint8List.fromList(data);
            _logFrame('IN', bytes);
            onBinaryMessage(bytes);
          } else {
            _log('IN', 'ignored-non-binary type=${data.runtimeType}');
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          unawaited(
            _handleConnectionLost(
              connection,
              generation,
              event: 'socket-stream-error',
              error: error,
            ),
          );
        },
        onDone: () {
          unawaited(
            _handleConnectionLost(
              connection,
              generation,
              event: 'socket-closed',
            ),
          );
        },
        cancelOnError: false,
      );
      _startMaintenance();
      _emit(CollabTransportStatus.online, 'socket-connected');
      _sendSyncStep1();
    } catch (error) {
      if (_disposed || !_shouldConnect || generation != _generation) {
        return;
      }
      _emit(CollabTransportStatus.offline, 'socket-connect-failed', error);
      _scheduleReconnect();
    } finally {
      if (_connectingGeneration == generation) {
        _connectingGeneration = null;
      }
    }
  }

  void _startMaintenance() {
    _stopMaintenance();
    _resyncTimer = Timer.periodic(resyncInterval, (_) {
      _sendSyncStep1();
    });
    _watchdogTimer = Timer.periodic(watchdogInterval, (_) {
      final lastInboundAt = _lastInboundAt;
      if (!isOnline || lastInboundAt == null) {
        return;
      }
      if (DateTime.now().difference(lastInboundAt) >= staleTimeout) {
        unawaited(reconnect(event: 'socket-stale-reconnect'));
      }
    });
  }

  void _stopMaintenance() {
    _resyncTimer?.cancel();
    _resyncTimer = null;
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
  }

  void _sendSyncStep1() {
    if (!isOnline) {
      return;
    }
    try {
      send(syncFrameFactory());
    } catch (error) {
      _emit(CollabTransportStatus.online, 'sync-step1-build-failed', error);
    }
  }

  Future<CollabSocketConnection> _openConnection() async {
    var abandoned = false;
    CollabSocketConnection? completedConnection;
    final pendingConnection = _connector(endpoint);
    unawaited(
      pendingConnection.then<void>(
        (connection) async {
          completedConnection = connection;
          if (abandoned) {
            try {
              await connection.close();
            } catch (_) {
              // A late socket may already have been closed by the peer.
            }
          }
        },
        onError: (_) {
          // The primary await below reports connection failures.
        },
      ),
    );
    try {
      return await pendingConnection.timeout(connectTimeout);
    } on TimeoutException {
      // `Future.timeout` cannot cancel `WebSocket.connect`. Mark the pending
      // handshake so a socket that succeeds late is immediately closed.
      abandoned = true;
      final connection = completedConnection;
      if (connection != null) {
        try {
          await connection.close();
        } catch (_) {
          // A connection completing on the timeout boundary is best-effort.
        }
      }
      rethrow;
    }
  }

  Future<void> _handleConnectionLost(
    CollabSocketConnection connection,
    int generation, {
    required String event,
    Object? error,
  }) async {
    if (_disposed ||
        generation != _generation ||
        !identical(_connection, connection)) {
      return;
    }

    _connection = null;
    _subscription = null;
    _stopMaintenance();
    try {
      await connection.close();
    } catch (_) {
      // The peer may already have closed the underlying socket.
    }
    if (_disposed || generation != _generation || !_shouldConnect) {
      return;
    }
    _emit(CollabTransportStatus.offline, event, error);
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_disposed || !_shouldConnect || _reconnectTimer?.isActive == true) {
      return;
    }

    final exponent = math.min(_failedReconnects, 20);
    final delayMilliseconds = math.min(
      reconnectBaseDelay.inMilliseconds * (1 << exponent),
      maxReconnectDelay.inMilliseconds,
    );
    _failedReconnects += 1;
    _log(
      'RECONNECT',
      'scheduled attempt=$_failedReconnects delay=${delayMilliseconds}ms',
    );
    _reconnectTimer = Timer(Duration(milliseconds: delayMilliseconds), () {
      _reconnectTimer = null;
      unawaited(_connect(event: 'socket-reconnecting'));
    });
  }

  Future<void> _closeCurrentConnection() async {
    final subscription = _subscription;
    _subscription = null;
    await subscription?.cancel();

    final connection = _connection;
    _connection = null;
    if (connection == null) {
      return;
    }
    try {
      await connection.close();
    } catch (_) {
      // Closing is best-effort during reconnect/dispose.
    }
  }

  void _emit(CollabTransportStatus status, String event, [Object? error]) {
    if (_disposed) {
      return;
    }
    _status = status;
    _log(
      'STATE',
      'status=${status.name} event=$event endpoint=$endpoint'
          '${error == null ? '' : ' error=$error'}',
    );
    onStateChanged(status, event, error);
  }

  void _logFrame(String direction, Uint8List bytes, {String? suffix}) {
    final description = describeYWebSocketFrame(bytes);
    _log(
      direction,
      '$description bytes=${bytes.length} room=$roomId'
      '${suffix == null ? '' : ' $suffix'}',
    );
  }

  void _log(String category, String message) {
    if (!enableProtocolLogging) {
      return;
    }
    final timestamp = DateTime.now().toIso8601String();
    _logSink('[y-websocket][$timestamp][$category] $message');
  }

  static Uri _parseServerUri(String value) {
    final normalized = value.trim().replaceFirst(RegExp(r'/+$'), '');
    final uri = Uri.parse(normalized);
    if ((uri.scheme != 'ws' && uri.scheme != 'wss') || uri.host.isEmpty) {
      throw FormatException('WebSocket URL 必须是有效的 ws:// 或 wss:// 地址');
    }
    return uri;
  }
}

/// Returns a payload-free description of a y-websocket/Yjs binary frame.
///
/// Only protocol tags are decoded. Document updates and awareness payloads are
/// deliberately never printed.
String describeYWebSocketFrame(Uint8List bytes) {
  final messageTag = _readVarUint(bytes, 0);
  if (messageTag == null) {
    return 'malformed';
  }
  return switch (messageTag.value) {
    0 => _describeSyncFrame(bytes, messageTag.nextOffset),
    1 => 'awareness',
    2 => 'auth',
    3 => 'awareness-query',
    final tag => 'custom-$tag',
  };
}

String _describeSyncFrame(Uint8List bytes, int offset) {
  final syncTag = _readVarUint(bytes, offset);
  if (syncTag == null) {
    return 'sync-malformed';
  }
  return switch (syncTag.value) {
    0 => 'sync-step-1',
    1 => 'sync-step-2',
    2 => 'sync-update',
    final tag => 'sync-custom-$tag',
  };
}

({int value, int nextOffset})? _readVarUint(Uint8List bytes, int offset) {
  var value = 0;
  var shift = 0;
  var index = offset;
  while (index < bytes.length && shift <= 28) {
    final byte = bytes[index];
    value |= (byte & 0x7F) << shift;
    index += 1;
    if ((byte & 0x80) == 0) {
      return (value: value, nextOffset: index);
    }
    shift += 7;
  }
  return null;
}
