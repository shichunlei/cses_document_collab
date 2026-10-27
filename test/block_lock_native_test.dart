import 'package:appflowy_editor/appflowy_editor.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:cses_document_collab/src/native/api/collab.dart' as native;
import 'package:cses_document_collab/src/native/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

/// Native/controller regressions include pure metadata remote updates and reopening.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        File('rust/target/debug/libcses_collab_core.${Platform.isMacOS ? 'dylib' : 'so'}').absolute.path,
      ),
    );
  });

  test(
    'controller projects locks without making the whole document readonly; metadata updates invalidate drafts',
    () async {
      final directory = await Directory.systemTemp.createTemp('locks-controller-');
      final gateway = _LockGateway();
      var grant = false;
      final controller = CollabController.cses(
        config: CollabDocumentConfig(
          documentId: 'fixture-doc',
          serverIdentity: 'wss://test.example/ws',
          companyId: 'company',
          userId: 'desktop-user',
          databasePath: '${directory.path}/cache.sqlite',
          editable: true,
        ),
        gateway: gateway,
        services: CollabHostServices(canUnlockBlock: (_) => grant),
      );
      try {
        await controller.initialize();
        gateway.sync(await File('rust/tests/fixtures/blockcraft-lock-baseline.update').readAsBytes());
        await Future<void>.delayed(Duration.zero);
        final beforeLockNode = controller.editorState.document.root.children.first;
        final beforeLockText = beforeLockNode.delta!.toPlainText();
        gateway.update(await File('rust/tests/fixtures/blockcraft-locks.update').readAsBytes());
        await Future<void>.delayed(Duration.zero);
        expect(controller.canEdit, isTrue);
        expect(identical(controller.editorState.document.root.children.first, beforeLockNode), isTrue);
        expect(beforeLockNode.delta!.toPlainText(), beforeLockText);
        expect(controller.blockLock('child').sourceId, 'callout');
        final editor = controller.editorState..editable = controller.canEdit;
        final sibling = editor.document.root.children[1];
        await editor.apply(editor.transaction..insertText(sibling, 0, '手机'));
        expect(native.currentBlocks().firstWhere((b) => b.id == 'p2').text, startsWith('手机'));
        final before = gateway.updates;
        await controller.setBlockLocked('p1', false);
        expect(controller.blockLock('p1').locked, isFalse);
        expect(gateway.updates, greaterThan(before));
        await controller.setBlockLocked('p1', true);
        expect(controller.blockLock('p1').ownerId, 'desktop-user');
        final first = editor.document.root.children.first;
        await editor.apply(editor.transaction..insertText(first, 0, '不能写'));
        expect(first.delta!.toPlainText(), '桌面定稿');
        expect(native.currentBlocks().first.text, '桌面定稿');
        await expectLater(controller.setBlockLocked('child', false), throwsA(anything));
        await controller.setEditable(false);
        await expectLater(controller.setBlockLocked('p1', false), throwsA(anything));
        expect(controller.blockLock('p1').locked, isTrue);
        grant = true;
        await controller.setEditable(true);
      } finally {
        await controller.close();
        await gateway.close();
        await directory.delete(recursive: true);
      }
    },
  );
}

/// In-memory transport uses the real session protocol without owning a socket.
class _LockGateway implements CsesCollabGateway {
  final events = StreamController<bool>.broadcast();
  Map<String, void Function(Map<String, dynamic>)> callbacks = {};
  int updates = 0;

  /// This isolated peer is always connected.
  @override
  bool get isConnected => true;

  /// Borrowers unsubscribe before the test closes its event controller.
  @override
  Stream<bool> get connectionStates => events.stream;

  /// Register borrowed [callbacks] for [pageId], [documentId], [instanceId].
  @override
  Future<void> register({
    required String pageId,
    required String documentId,
    required String instanceId,
    required Map<String, void Function(Map<String, dynamic>)> callbacks,
  }) async {
    this.callbacks = callbacks;
  }

  /// Count updates sent for [pageId], [action] and [body]; no network is used.
  @override
  bool send(String pageId, String action, Map<String, dynamic> body) {
    if (action == 'collabUpdate') updates++;
    return true;
  }

  /// Remove borrowed routing for [pageId].
  @override
  Future<void> unregister(String pageId) async {
    callbacks = {};
  }

  /// Release the test-owned transport stream after its controller unsubscribes.
  Future<void> close() => events.close();

  /// Deliver an incremental desktop [fixture] after the handshake is ready.
  void update(List<int> fixture) => callbacks['collabUpdate']!({'data': base64Encode(fixture)});

  /// Deliver desktop-encoded [fixture] through the real sync callback.
  void sync(List<int> fixture) => callbacks['collabSync']!({
    'data': base64Encode(fixture),
    'stateVector': base64Encode([0]),
  });
}
