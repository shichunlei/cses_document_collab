import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cses_common/network/websocket/cses_websocket_client.dart';
import 'package:cses_mobile_collab_demo/src/collab/cses_collab_gateway.dart';
import 'package:cses_mobile_collab_demo/src/collab/cses_connection_settings.dart';
import 'package:cses_mobile_collab_demo/src/collab/cses_demo_host.dart';
import 'package:cses_mobile_collab_demo/src/collab/cses_doc_collaboration_session.dart';
import 'package:flutter_test/flutter_test.dart';

/// 在本机真实 Socket 上验证原 Common 接口和 PaaS JSON 路由，无真实会话凭证。
void main() {
  test(
    'unmodified Common connects, subscribes, joins and exchanges routed JSON',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <WebSocket>[];
      final received = <Map<String, dynamic>>[];
      final ready = Completer<void>();
      final updateReceived = Completer<void>();
      final left = Completer<void>();
      var remoteUpdates = 0;
      final serverSubscription = server
          .transform(WebSocketTransformer())
          .listen((socket) {
            sockets.add(socket);
            socket.add(
              jsonEncode({'action': 'hello', 'serverName': 'loopback'}),
            );
            socket.listen((raw) {
              final message = jsonDecode(raw as String) as Map<String, dynamic>;
              received.add(message);
              final route = message['subscription'] as Map<String, dynamic>?;
              final action = message['action'];
              if (action == 'subscribe') {
                socket.add(
                  jsonEncode({
                    'action': 'subscribe',
                    'subscription': route,
                    'body': {},
                  }),
                );
              }
              if (action == 'collabJoin') {
                socket.add(
                  jsonEncode({
                    'action': 'collabSync',
                    'subscription': route,
                    'body': {'data': 'AAA=', 'stateVector': 'AA=='},
                  }),
                );
              }
              if (action == 'collabUpdate' && !updateReceived.isCompleted) {
                updateReceived.complete();
              }
              if (action == 'unsubscribe' &&
                  route?['channel'] == 'Document' &&
                  !left.isCompleted) {
                left.complete();
              }
            });
          });
      const host = CsesDemoHost();
      CsesDocCollaborationSession? session;
      addTearDown(() async {
        await session?.dispose();
        host.close();
        await serverSubscription.cancel();
        for (final socket in sockets) {
          await socket.close();
        }
        await server.close(force: true);
      });
      host.configure(
        CsesConnectionSettings(
          websocketUrl: 'ws://127.0.0.1:${server.port}/deployment/ws',
          cookieId: 'loopback-cookie',
          deviceId: 'loopback-device',
          companyId: 'company',
          userId: 'user',
          documentId: 'doc',
        ),
      );
      session = CsesDocCollaborationSession(
        gateway: CommonCsesCollabGateway(),
        documentId: 'doc',
        instanceId: 'editor-one',
        stateVectorFactory: () => Uint8List.fromList([0]),
        onSync: (update, vector) {
          expect(update, [0, 0]);
          expect(vector, [0]);
          return Uint8List.fromList([0, 0]);
        },
        onUpdate: (_) => remoteUpdates++,
        onStateChanged: (state, event, error) {
          if (state == CsesCollabState.ready && !ready.isCompleted) {
            ready.complete();
          }
        },
      );
      expect(
        csesWebSocketClient.buildHeaders().values,
        everyElement(isNotNull),
      );
      await session.start();
      await host.connect();
      await ready.future.timeout(const Duration(seconds: 5));
      await updateReceived.future.timeout(const Duration(seconds: 5));
      final docMessages = received
          .where(
            (message) =>
                (message['subscription']
                    as Map<String, dynamic>?)?['channel'] ==
                'Document',
          )
          .toList();
      expect(docMessages.map((message) => message['action']), [
        'subscribe',
        'collabJoin',
        'collabUpdate',
      ]);
      expect(docMessages[1]['subscription'], {
        'channel': 'Document',
        'topic': 'doc',
        'instance': 'editor-one',
      });
      expect(docMessages[2]['body'], {'data': 'AAA='});
      expect(csesWebSocketClient.buildHeaders()['deviceId'], 'loopback-device');
      expect(csesWebSocketClient.buildUri().path, '/deployment/ws');
      expect(
        csesWebSocketClient.buildUri().queryParameters['cookieId'],
        'loopback-cookie',
      );
      sockets.single.add(
        jsonEncode({
          'action': 'collabUpdate',
          'subscription': {
            'channel': 'Document',
            'topic': 'doc',
            'instance': 'other-editor',
          },
          'body': {'data': 'AAA='},
        }),
      );
      sockets.single.add(
        jsonEncode({
          'action': 'collabUpdate',
          'subscription': {
            'channel': 'Document',
            'topic': 'doc',
            'instance': 'editor-one',
          },
          'body': {'data': 'AAA='},
        }),
      );
      final deadline = DateTime.now().add(const Duration(seconds: 3));
      while (remoteUpdates < 1 && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(remoteUpdates, 1);
      await session.dispose();
      await left.future.timeout(const Duration(seconds: 3));
      expect(csesWebSocketClient.isConnected, isTrue);
    },
  );
}
