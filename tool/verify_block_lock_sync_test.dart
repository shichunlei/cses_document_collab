import 'dart:io';

import 'package:cses_document_collab/src/native/api/collab.dart' as native;
import 'package:cses_document_collab/src/native/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

/// Run an actual published desktop lock manager against the mobile native Doc.
/// Paths are explicit inputs; no account, server or user's document is touched.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('published desktop and mobile exchange user/template locks and reopen SQLite', () async {
    const desktop = String.fromEnvironment('BLOCKCRAFT_DESKTOP_ROOT');
    const package = String.fromEnvironment('BLOCKCRAFT_PACKAGE_ROOT');
    expect(desktop, isNotEmpty, reason: 'Pass --dart-define=BLOCKCRAFT_DESKTOP_ROOT=...');
    expect(package, isNotEmpty, reason: 'Pass --dart-define=BLOCKCRAFT_PACKAGE_ROOT=...');
    final directory = await Directory.systemTemp.createTemp('block-lock-sync-');
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        File('rust/target/debug/libcses_collab_core.${Platform.isMacOS ? 'dylib' : 'so'}').absolute.path,
      ),
    );
    addTearDown(() async {
      native.closeDocument();
      await directory.delete(recursive: true);
    });

    /// Execute one desktop [phase], failing on any assertion or process error.
    Future<void> peer(String phase) async {
      final result = await Process.run('node', [
        'tool/block_lock_desktop_peer.mjs',
        desktop,
        package,
        directory.path,
        phase,
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      // Preserve concise, versioned evidence in the test report.
      // ignore: avoid_print
      print(result.stdout);
    }

    /// Open the same mobile cache partition after native teardown.
    void open() => native.openCsesDocument(
      documentId: 'fixture-doc',
      cacheDocumentId: 'phone-cache',
      databasePath: '${directory.path}/phone.sqlite',
    );

    await peer('prepare');
    open();
    native.applyDocumentUpdate(bytes: await File('${directory.path}/desktop-lock.update').readAsBytes());
    expect(native.documentReadOnlyReason(), isNull);
    expect(native.currentBlockLocks().firstWhere((s) => s.blockId == 'child').sourceId, 'callout');
    final before = native.encodeStateVector();
    expect(
      () => native.setBlockLock(
        blockId: 'p1',
        locked: false,
        userId: 'phone-user',
        grant: false,
        expectedOwner: 'desktop-user',
        expectedTemplate: false,
      ),
      throwsA(anything),
    );
    expect(native.encodeStateVector(), orderedEquals(before));
    final current = native.currentBlocks();
    final edited = current.map((block) => block.id == 'p2' ? _text(block, '${block.text}手机可编辑') : block).toList();
    native.applyBlockSnapshot(blocks: edited);
    final lockedEdit = native.currentBlocks().map((block) => block.id == 'child' ? _text(block, '禁止') : block).toList();
    final vector = native.encodeStateVector();
    expect(() => native.applyBlockSnapshot(blocks: lockedEdit), throwsA(anything));
    expect(native.encodeStateVector(), orderedEquals(vector));
    native.setBlockLock(
      blockId: 'p1',
      locked: false,
      userId: 'phone-user',
      grant: true,
      expectedOwner: 'desktop-user',
      expectedTemplate: false,
    );
    native.setBlockLock(blockId: 'p2', locked: true, userId: 'phone-user', grant: false, expectedTemplate: false);
    await File(
      '${directory.path}/phone.update',
    ).writeAsBytes(native.encodeDocumentDiff(stateVector: Uint8List.fromList([0])));
    native.closeDocument();
    open();
    expect(native.currentBlockLocks().firstWhere((s) => s.blockId == 'p2').ownerId, 'phone-user');
    expect(native.currentBlocks().firstWhere((b) => b.id == 'p2').text, contains('手机可编辑'));

    await peer('receive');
    native.applyDocumentUpdate(bytes: await File('${directory.path}/desktop-return.update').readAsBytes());
    expect(native.currentBlockLocks().firstWhere((s) => s.blockId == 'p1').template, isTrue);
    expect(native.currentBlockLocks().firstWhere((s) => s.blockId == 'p2').sourceId, isNull);
    expect(
      () => native.setBlockLock(
        blockId: 'p1',
        locked: false,
        userId: 'desktop-user',
        grant: false,
        expectedOwner: 'desktop-user',
        expectedTemplate: true,
      ),
      throwsA(anything),
    );
    native.setBlockLock(
      blockId: 'p1',
      locked: false,
      userId: 'desktop-user',
      grant: true,
      expectedOwner: 'desktop-user',
      expectedTemplate: true,
    );
    await File(
      '${directory.path}/phone-final.update',
    ).writeAsBytes(native.encodeDocumentDiff(stateVector: Uint8List.fromList([0])));
    await peer('final');
  });
}

/// Replace only [block]'s text with [text], preserving all projected fields.
native.CollabBlock _text(native.CollabBlock block, String text) => native.CollabBlock(
  id: block.id,
  blockType: block.blockType,
  text: text,
  segments: const [],
  checked: block.checked,
  alignment: block.alignment,
  indent: block.indent,
  image: block.image,
  ordered: block.ordered,
  code: block.code,
  resource: block.resource,
  paragraphStyle: block.paragraphStyle,
  replacesId: block.replacesId,
  blockBackgroundColor: block.blockBackgroundColor,
  blockBorderColor: block.blockBorderColor,
  parentId: block.parentId,
  calloutPrefix: block.calloutPrefix,
  blockTextColor: block.blockTextColor,
);
