import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:cses_document_collab/src/native/api/collab.dart' as native;
import 'package:cses_document_collab/src/native/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

/// 使用真实FRB、临时SQLite和假网关验证初始化恢复与权限失败清理。
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
  test('failed controller retry must not send the next owner document', () async {
    final dir = await Directory.systemTemp.createTemp('review-owner-');
    final gateway = _ProbeGateway();
    final first = CollabController.cses(
      config: CollabDocumentConfig(
        documentId: 'fixture-doc',
        serverIdentity: 'wss://review.example/ws',
        companyId: 'company-a',
        userId: 'account-a',
        databasePath: '${dir.path}/first.sqlite',
        editable: true,
      ),
      gateway: gateway,
    );
    final next = CollabController.localDraft(
      databasePath: '${dir.path}/next.sqlite',
    );
    try {
      await expectLater(first.initialize(), throwsStateError);
      await next.initialize();
      final state = next.editorState;
      await state.apply(
        state.transaction
          ..insertText(state.document.first!, 0, 'PRIVATE_NEXT_OWNER'),
      );
      final nextOwnerDiff = native.encodeDocumentDiff(stateVector: [0]);
      gateway.registrationFails = false;
      await expectLater(
        first.retry(),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'reason',
            contains('COLLAB_DOCUMENT_IN_USE'),
          ),
        ),
      );
      expect(first.initialized, isFalse);
      expect(first.canEdit, isFalse);
      gateway.callbacks['collabSync']?.call({
        'data': base64Encode([0, 0]),
        'stateVector': base64Encode([0]),
      });
      expect(native.encodeDocumentDiff(stateVector: [0]), nextOwnerDiff);
      expect(next.canEdit, isTrue);
      expect(gateway.events.hasListener, isFalse);
      expect(
        gateway.updates,
        isEmpty,
        reason:
            'A controller whose initialization released ownership cannot publish another owner state; '
            'the observed payload equals next owner: ${gateway.updates.isNotEmpty && base64Encode(nextOwnerDiff) == gateway.updates.last}',
      );
      await next.close();
      await first.retry();
      expect(first.initialized, isTrue);
      gateway.callbacks['collabSync']?.call({
        'data': base64Encode(
          await File(
            'rust/tests/fixtures/blockcraft-basic.update',
          ).readAsBytes(),
        ),
        'stateVector': base64Encode([0]),
      });
      await Future<void>.delayed(Duration.zero);
      expect(first.status, ConnectionStatus.online);
      expect(
        native.currentBlocks().any(
          (block) => block.text.contains('PRIVATE_NEXT_OWNER'),
        ),
        isFalse,
      );
      expect(native.currentBlocks(), hasLength(3));
    } finally {
      await first.close();
      await next.close();
      await gateway.close();
      await dir.delete(recursive: true);
    }
  });

  test(
    'permission registration failure must not poison transitions or cleanup',
    () async {
      final dir = await Directory.systemTemp.createTemp('review-transition-');
      final gateway = _ProbeGateway()..registrationFails = false;
      final controller = CollabController.cses(
        config: CollabDocumentConfig(
          documentId: 'review-transition',
          serverIdentity: 'wss://review.example/ws',
          companyId: 'company-a',
          userId: 'account-a',
          databasePath: '${dir.path}/transition.sqlite',
          editable: true,
        ),
        gateway: gateway,
      );
      try {
        await controller.initialize();
        gateway.registrationFails = true;
        await expectLater(controller.setEditable(false), throwsStateError);
        expect(gateway.events.hasListener, isFalse);
        gateway.registrationFails = false;
        var restored = false;
        try {
          await controller.setEditable(true);
          restored = true;
        } on StateError {
          // 记录恢复结果，继续核对关闭后的订阅。
        }
        await controller.close();
        expect(
          {
            'restored': restored,
            'registrations': gateway.registrationCalls,
            'listenerAfterClose': gateway.events.hasListener,
          },
          {'restored': true, 'registrations': 3, 'listenerAfterClose': false},
        );
      } finally {
        await controller.close();
        await gateway.close();
        await dir.delete(recursive: true);
      }
    },
  );

  test(
    'close waits for pending registration and stale callbacks cannot mutate the next owner',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'collab-pending-close-',
      );
      final barrier = Completer<void>();
      final gateway = _ProbeGateway()
        ..registrationFails = false
        ..registrationBarrier = barrier;
      final first = CollabController.cses(
        config: CollabDocumentConfig(
          documentId: 'fixture-doc',
          serverIdentity: 'wss://test.example/ws',
          companyId: 'company',
          userId: 'user',
          databasePath: '${dir.path}/first.sqlite',
          editable: true,
        ),
        gateway: gateway,
      );
      final next = CollabController.localDraft(
        databasePath: '${dir.path}/next.sqlite',
      );
      try {
        final initialization = first.initialize();
        while (gateway.registrationCalls == 0) {
          await Future<void>.delayed(Duration.zero);
        }
        final closing = first.close();
        barrier.complete();
        await initialization;
        await closing;
        expect(gateway.events.hasListener, isFalse);
        expect(first.editor.closed, isTrue);
        final oldCallbacks = gateway.lastRegisteredCallbacks;
        await next.initialize();
        await next.editorState.apply(
          next.editorState.transaction
            ..insertText(next.editorState.document.first!, 0, 'keep'),
        );
        final before = native.encodeDocumentDiff(stateVector: [0]);
        oldCallbacks['collabSync']?.call({
          'data': base64Encode([0, 0]),
          'stateVector': base64Encode([0]),
        });
        expect(native.encodeDocumentDiff(stateVector: [0]), before);
        expect(gateway.updates, isEmpty);
        expect(next.canEdit, isTrue);
      } finally {
        if (!barrier.isCompleted) barrier.complete();
        await first.close();
        await next.close();
        await gateway.close();
        await dir.delete(recursive: true);
      }
    },
  );
}

/// 只记录隔离测试消息，首次注册失败后允许后续重试，不创建物理连接。
class _ProbeGateway implements CsesCollabGateway {
  /// 测试拥有并在结束时关闭的连接状态流。
  final events = StreamController<bool>.broadcast();

  /// true时模拟宿主注册失败。
  bool registrationFails = true;

  /// 宿主注册尝试次数，包含失败尝试。
  int registrationCalls = 0;

  /// 可选测试屏障，由测试拥有和完成，用于模拟迟到注册。
  Completer<void>? registrationBarrier;

  /// 保存最后一次注册回调以主动模拟注销后迟到消息，不持有真实连接。
  Map<String, void Function(Map<String, dynamic>)> lastRegisteredCallbacks = {};

  /// 当前测试注册的协议回调，由会话释放。
  Map<String, void Function(Map<String, dynamic>)> callbacks = {};

  /// 已提交的Base64正文增量，仅用于安全期望断言。
  final updates = <String>[];

  /// 测试结束时关闭自己创建的状态流，不持有物理连接。
  Future<void> close() => events.close();

  /// 模拟已完成hello的借用主连接。
  @override
  bool get isConnected => true;

  /// 返回测试拥有的流，消费方只注销自己的订阅。
  @override
  Stream<bool> get connectionStates => events.stream;

  /// 按[registrationFails]处理[pageId]的[documentId]/[instanceId]及[callbacks]注册。
  @override
  Future<void> register({
    required String pageId,
    required String documentId,
    required String instanceId,
    required Map<String, void Function(Map<String, dynamic>)> callbacks,
  }) async {
    registrationCalls++;
    await registrationBarrier?.future;
    if (registrationFails) throw StateError('fixture registration failure');
    this.callbacks = callbacks;
    lastRegisteredCallbacks = callbacks;
  }

  /// 记录[pageId]发出的[action]/[body]正文，不发送网络消息。
  @override
  bool send(String pageId, String action, Map<String, dynamic> body) {
    if (action == 'collabUpdate') updates.add(body['data'] as String);
    return true;
  }

  /// 注销[pageId]对应的测试回调，不关闭共享流。
  @override
  Future<void> unregister(String pageId) async => callbacks = {};
}
