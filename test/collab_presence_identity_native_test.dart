import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:cses_document_collab/src/native/api/collab.dart' as native;
import 'package:cses_document_collab/src/native/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

/// 真实原生引擎配合保留旧归属的网关，复现服务端在线身份排他校验。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final suffix = Platform.isMacOS ? 'dylib' : 'so';
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        File('rust/target/debug/libcses_collab_core.$suffix').absolute.path,
      ),
    );
  });

  for (final mode in [0, 1, 2, 3]) {
    final reconnect = mode != 0;
    test(
      'old presence ownership cannot reject ${mode == 3
          ? 'explicit retry after terminal error and new hello'
          : mode == 2
          ? 'new hello without a disconnected notification'
          : reconnect
          ? 'physical reconnect'
          : 'permission session replacement'}',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'presence-owner-',
        );
        final gateway = _OwnershipGateway(
          await File(
            'rust/tests/fixtures/blockcraft-basic.update',
          ).readAsBytes(),
        );
        final controller = CollabController.cses(
          config: CollabDocumentConfig(
            documentId: 'fixture-doc',
            serverIdentity: 'wss://test.invalid/ws',
            companyId: 'company',
            userId: 'user',
            databasePath: '${directory.path}/doc.sqlite',
            editable: true,
          ),
          gateway: gateway,
          services: CollabHostServices(
            onError: (message, error, stack, _) =>
                fail('$message: $error\n$stack'),
          ),
        );
        try {
          await controller.initialize();
          await _flush();
          expect(controller.status, ConnectionStatus.online);
          final body = native.encodeDocumentDiff(
            stateVector: Uint8List.fromList([0]),
          );
          final firstPresence = gateway.activeIds.last;
          if (reconnect) {
            if (mode == 3) {
              gateway.callbacks.values.single['collabError']?.call({
                'code': 'ACCESS_DENIED',
              });
              expect(controller.status, ConnectionStatus.error);
            }
            if (mode == 1) {
              gateway.connected = false;
              gateway.events.add(false);
              await _flush();
            }
            gateway.epoch++;
            gateway.connected = true;
            gateway.events.add(true);
            await _flush();
            if (mode == 3) {
              expect(
                controller.status,
                ConnectionStatus.error,
                reason:
                    'New hello must not automatically bypass a terminal rejection',
              );
              await controller.retry();
              await _flush();
            }
          } else {
            await controller.setEditable(false);
            await _flush();
            await controller.setEditable(true);
            await _flush();
          }
          expect(
            gateway.rejected,
            isEmpty,
            reason:
                'A new server owner must not reuse a still-active presence clientId',
          );
          expect(controller.status, ConnectionStatus.online);
          expect(gateway.activeIds.last, isNot(firstPresence));
          expect(
            native.encodeDocumentDiff(stateVector: Uint8List.fromList([0])),
            body,
            reason:
                'Presence rotation must not change body CRDT identity or persisted content',
          );
          final stable = gateway.activeIds.last;
          controller.resync();
          await _flush();
          expect(
            gateway.activeIds.last,
            stable,
            reason: 'Same-connection resync keeps presence identity stable',
          );
        } finally {
          await controller.close();
          await gateway.close();
          await directory.delete(recursive: true);
        }
      },
    );
  }
}

/// 等待协议回调及原生投影排队完成，不模拟服务端保存确认。
Future<void> _flush() async {
  for (var i = 0; i < 12; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// 只解析测试所需的标准 Awareness 头部；[bytes] 必须为一个本机条目。
/// 返回 clientId、时钟及是否删除，不解读或记录用户资料。
({int clientId, int clock, bool removed}) _presence(Uint8List bytes) {
  var offset = 0;

  /// 读取一个标准 varUint 并推进当前缓冲区位置，截断数据由测试直接失败。
  int read() {
    var value = 0;
    var shift = 0;
    while (true) {
      final byte = bytes[offset++];
      value |= (byte & 127) << shift;
      if (byte < 128) return value;
      shift += 7;
    }
  }

  expect(read(), 1);
  final id = read();
  final clock = read();
  final length = read();
  return (
    clientId: id,
    clock: clock,
    removed: utf8.decode(bytes.sublist(offset, offset + length)) == 'null',
  );
}

/// 模拟旧连接清理延迟；故意不执行离开/删除，按服务端排他归属拒绝身份复用。
final class _OwnershipGateway implements CsesCollabGateway {
  /// [fixture] 是真实桌面初始 update，由网关借用且不修改。
  _OwnershipGateway(this.fixture);

  /// 借用的完整初始正文，仅在首次握手交付。
  final Uint8List fixture;

  /// 测试创建并在 close 等待关闭的连接事件流。
  final events = StreamController<bool>.broadcast(sync: true);

  /// 服务端仍保留的 clientId -> 连接/实例归属。
  final owners = <int, String>{};

  /// 实际上行的在线 clientId，顺序用于稳定性断言。
  final activeIds = <int>[];

  /// 按排他归属规则被拒绝的在线 clientId。
  final rejected = <int>[];

  /// 每个页面当前拥有的接收回调，注销后移除。
  final callbacks =
      <String, Map<String, void Function(Map<String, dynamic>)>>{};

  /// 是否模拟 hello-ready，false 时发送必须失败。
  bool connected = true;

  /// 模拟服务端物理连接身份，不参与正文版本或页面生命周期。
  int epoch = 1;

  /// 是否已交付过初始正文，之后只回复标准空 update。
  bool seeded = false;

  /// 由测试创建者等待状态流关闭，不释放任何被借用的网络资源。
  Future<void> close() => events.close();

  /// 返回测试可控的 hello-ready 状态。
  @override
  bool get isConnected => connected;

  /// 借出连接事件流，消费者只取消自己的订阅。
  @override
  Stream<bool> get connectionStates => events.stream;

  /// 为 [pageId]/[documentId]/[instanceId] 安装 [callbacks]；不访问真实网络。
  @override
  Future<void> register({
    required String pageId,
    required String documentId,
    required String instanceId,
    required Map<String, void Function(Map<String, dynamic>)> callbacks,
  }) async {
    this.callbacks[pageId] = callbacks;
  }

  /// 处理 [pageId] 的 [action]/[body]，保留旧归属模拟清理与重连跨队列竞态。
  @override
  bool send(String pageId, String action, Map<String, dynamic> body) {
    if (!connected) return false;
    final receiver = callbacks[pageId];
    if (action == 'collabJoin' || action == 'collabSync') {
      final update = seeded ? Uint8List.fromList([0, 0]) : fixture;
      seeded = true;
      scheduleMicrotask(
        () => receiver?['collabSync']?.call({
          'data': base64Encode(update),
          'stateVector': base64Encode([0]),
        }),
      );
    } else if (action == 'collabAwareness') {
      final presence = _presence(base64Decode(body['data'] as String));
      if (presence.removed) return true;
      activeIds.add(presence.clientId);
      final owner = '$epoch:$pageId';
      if (owners[presence.clientId] case final previous?
          when previous != owner) {
        rejected.add(presence.clientId);
        scheduleMicrotask(
          () => receiver?['collabError']?.call({
            'code': 'INVALID_REQUEST',
            'message': '协同请求参数错误',
          }),
        );
      } else {
        owners[presence.clientId] = owner;
      }
    }
    return true;
  }

  /// 移除 [pageId] 的客户端监听；服务端残留归属继续保留供回归断言。
  @override
  Future<void> unregister(String pageId) async {
    callbacks.remove(pageId);
  }
}
