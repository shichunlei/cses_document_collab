import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/editor/collab_host_meeting_ui.dart';
import 'package:cses_document_collab/src/editor/collab_host_mention_ui.dart';
import 'package:cses_document_collab/src/native/api/collab.dart' as native;
import 'package:cses_document_collab/src/native/frb_generated.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

/// Exercise review regressions through real controllers, FRB and native SQLite.
/// The host library is required; an absent or stale build fails this gate.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Uint8List base;
  late Uint8List orderedBase;
  late Uint8List tableBase;
  late Map<String, dynamic> peer;
  late Map<String, dynamic> review;
  setUpAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockStreamHandler(
      const EventChannel('keyboardHeightEventChannel'),
      MockStreamHandler.inline(onListen: (_, events) => events.success(0.0)),
    );
    final suffix = Platform.isMacOS ? 'dylib' : 'so';
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(File('rust/target/debug/libcses_collab_core.$suffix').absolute.path),
    );
    base = await File('rust/tests/fixtures/blockcraft-basic.update').readAsBytes();
    peer =
        jsonDecode(await File('rust/tests/fixtures/native-history-peer.json').readAsString()) as Map<String, dynamic>;
    review =
        jsonDecode(await File('rust/tests/fixtures/native-history-review.json').readAsString()) as Map<String, dynamic>;
    orderedBase = await File(review['basePath'] as String).readAsBytes();
    tableBase = await File('rust/tests/fixtures/blockcraft-table.update').readAsBytes();
  });

  test('first input in a reopened empty draft paragraph creates reversible history', () async {
    final harness = await _ReviewHarness.create();
    CollabController? reopened;
    try {
      await harness.owner.initialize();
      final state = harness.owner.editorState;
      await state.apply(state.transaction..insertNodes([1], [paragraphNode()]));
      await _drainProjection();
      expect(native.currentBlocks(), hasLength(2));
      expect(native.currentBlocks().every((block) => block.text.isEmpty), isTrue);
      final ids = native.currentBlocks().map((block) => block.id).toList();
      await harness.owner.close();
      reopened = CollabController.localDraft(databasePath: harness.database);
      await reopened.initialize();
      expect(reopened.canUndo, isFalse);
      final node = reopened.editorState.document.first!;
      await _insert(reopened, node, 0, '你好😀');
      await _drainProjection();
      expect(
        reopened.canUndo,
        isTrue,
        reason: 'The first insertion into an existing empty native text must be tracked.',
      );
      await reopened.undo();
      expect(native.currentBlocks().map((block) => block.id), ids);
      expect(native.currentBlocks().every((block) => block.text.isEmpty), isTrue);
      expect(reopened.editorState.selection?.start.offset, 0);
      await reopened.redo();
      expect(native.currentBlocks().first.text, '你好😀');
      expect(reopened.editorState.selection?.start.offset, 4);
      expect(reopened.editorState.undoManager.undoStack.isEmpty, isTrue);
    } finally {
      await reopened?.close();
      await harness.close();
    }
  });

  for (final action in ['undo', 'redo', 'remote']) {
    testWidgets('$action preserves an active text input connection and resolved caret', (tester) async {
      final directory = (await tester.runAsync(() => Directory.systemTemp.createTemp('native-history-review-ui-')))!;
      final harness = _ReviewHarness.inDirectory(directory, formal: true);
      try {
        await harness.owner.initialize();
        harness.gateway.sync(base);
        await tester.pump();
        await tester.pumpWidget(MaterialApp(home: CollaborativeEditorPage(collab: harness.owner)));
        await tester.pump();
        final owner = harness.owner;
        final state = owner.editorState;
        await _insert(owner, harness.paragraph, 1, 'X');
        await tester.pump();
        if (action == 'redo') {
          await owner.undo();
          await tester.pump();
        }
        final offset = action == 'redo' ? 1 : 2;
        state.selection = Selection.single(path: harness.paragraph.path, startOffset: offset);
        await tester.pump();
        expect(tester.testTextInput.hasAnyClients, isTrue);
        tester.testTextInput.log.clear();
        switch (action) {
          case 'undo':
            await owner.undo();
          case 'redo':
            await owner.redo();
          case 'remote':
            harness.gateway.update(Uint8List.fromList((peer['updates']['prefix'] as List).cast<int>()));
        }
        await tester.pump();
        expect(harness.paragraph.delta!.toPlainText(), switch (action) {
          'undo' => '正文😀',
          'redo' => '正X文😀',
          _ => '远端-正X文😀',
        });
        expect(state.selection?.start.offset, switch (action) {
          'undo' => 1,
          'redo' => 2,
          _ => 5,
        });
        expect(owner.canEdit, isTrue);
        expect(state.editable, isTrue);
        expect(
          tester.testTextInput.hasAnyClients,
          isTrue,
          reason: 'A valid restored text caret must retain its input connection: ${tester.testTextInput.log}',
        );
        expect(tester.testTextInput.log.where((call) => call.method == 'TextInput.hide'), isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        await _closeWidgetHarness(tester, harness);
      }
    });
  }

  for (final action in ['undo', 'redo', 'remote']) {
    testWidgets('explicitly closed keyboard stays closed after $action with its resolved caret', (tester) async {
      final directory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('native-history-review-closed-'),
      ))!;
      final harness = _ReviewHarness.inDirectory(directory, formal: true);
      try {
        await harness.owner.initialize();
        harness.gateway.sync(base);
        await tester.pump();
        await tester.pumpWidget(MaterialApp(home: CollaborativeEditorPage(collab: harness.owner)));
        await tester.pump();
        final owner = harness.owner;
        final state = owner.editorState;
        await _insert(owner, harness.paragraph, 1, 'X');
        await tester.pump();
        if (action == 'redo') {
          await owner.undo();
          await tester.pump();
        }
        final before = Selection.single(path: harness.paragraph.path, startOffset: action == 'redo' ? 1 : 2);
        state.selection = before;
        await tester.pump();
        expect(tester.testTextInput.hasAnyClients, isTrue);
        state.service.keyboardService!.closeKeyboard();
        await tester.pump();
        expect(tester.testTextInput.hasAnyClients, isFalse);
        expect(state.selection, before, reason: "Closing the keyboard must keep the user's caret.");
        tester.testTextInput.log.clear();
        switch (action) {
          case 'undo':
            await owner.undo();
          case 'redo':
            await owner.redo();
          case 'remote':
            harness.gateway.update(Uint8List.fromList((peer['updates']['prefix'] as List).cast<int>()));
        }
        await tester.pump();
        expect(harness.paragraph.delta!.toPlainText(), switch (action) {
          'undo' => '正文😀',
          'redo' => '正X文😀',
          _ => '远端-正X文😀',
        });
        expect(
          state.selection,
          Selection.single(
            path: harness.paragraph.path,
            startOffset: switch (action) {
              'undo' => 1,
              'redo' => 2,
              _ => 5,
            },
          ),
        );
        expect(owner.canEdit, isTrue);
        expect(state.editable, isTrue);
        expect(tester.testTextInput.hasAnyClients, isFalse);
        expect(
          tester.testTextInput.log.where((call) => ['TextInput.setClient', 'TextInput.show'].contains(call.method)),
          isEmpty,
          reason: 'Restoring a native selection must not reopen an explicitly closed keyboard.',
        );
        expect(tester.takeException(), isNull);
      } finally {
        await _closeWidgetHarness(tester, harness);
      }
    });
  }

  testWidgets('table body input keeps its native selection and input connection across undo and redo', (tester) async {
    final directory = (await tester.runAsync(() => Directory.systemTemp.createTemp('native-history-review-table-')))!;
    final harness = _ReviewHarness.inDirectory(directory, formal: true);
    try {
      await harness.owner.initialize();
      harness.gateway.sync(tableBase);
      await tester.pump();
      await tester.pumpWidget(MaterialApp(home: CollaborativeEditorPage(collab: harness.owner)));
      await tester.pump();
      final owner = harness.owner;
      final state = owner.editorState;
      final body = harness.node('body-0-0');
      final source = body.delta!.toPlainText();
      state.selection = Selection.single(path: body.path, startOffset: 0);
      await tester.pump();
      expect(tester.testTextInput.hasAnyClients, isTrue);
      final platform = TextEditingValue.fromJSON(tester.testTextInput.editingState!);
      expect(platform.selection.isValid, isTrue);
      expect(platform.selection.isCollapsed, isTrue);
      tester.testTextInput.updateEditingValue(
        platform.copyWith(
          text: platform.text.replaceRange(platform.selection.start, platform.selection.end, '手机'),
          selection: TextSelection.collapsed(offset: platform.selection.start + 2),
          composing: TextRange.empty,
        ),
      );
      await tester.pump();
      expect(native.currentBlocks().firstWhere((block) => block.id == 'body-0-0').text, '手机$source');
      expect(owner.canUndo, isTrue);
      for (final redo in [false, true]) {
        expect(tester.testTextInput.hasAnyClients, isTrue);
        tester.testTextInput.log.clear();
        if (redo) {
          await owner.redo();
        } else {
          await owner.undo();
        }
        await tester.pump();
        final current = harness.node('body-0-0');
        expect(native.currentBlocks().firstWhere((block) => block.id == 'body-0-0').text, redo ? '手机$source' : source);
        expect(state.selection, Selection.single(path: current.path, startOffset: redo ? 2 : 0));
        expect(state.getNodeAtPath(state.selection!.start.path), same(current));
        expect(tester.testTextInput.hasAnyClients, isTrue);
        expect(
          tester.testTextInput.log.where((call) => ['TextInput.hide', 'TextInput.clearClient'].contains(call.method)),
          isEmpty,
          reason: 'Native history must publish only the final resolved cell selection.',
        );
        expect(owner.error, isNull);
      }
      expect(tester.takeException(), isNull);
    } finally {
      await _closeWidgetHarness(tester, harness);
    }
  });

  for (final kind in ['mention', 'meeting']) {
    for (final revoke in [false, true]) {
      testWidgets('$kind picker survives remote projection; real revocation=$revoke', (tester) async {
        final pending = Completer<Object?>();
        ValueListenable<bool>? permission;
        final services = CollabHostServices(
          pickMentionUser: (context, {required keyword, required canEdit}) {
            permission = canEdit;
            return pending.future.then((value) => value as CollabMentionUser?);
          },
          pickMeetingReference: (context, {required canEdit}) {
            permission = canEdit;
            return pending.future.then((value) => value as CollabMeetingReference?);
          },
        );
        final directory = (await tester.runAsync(
          () => Directory.systemTemp.createTemp('native-history-review-picker-'),
        ))!;
        final harness = _ReviewHarness.inDirectory(directory, formal: true, services: services);
        Future<Object?>? selected;
        try {
          await harness.owner.initialize();
          harness.gateway.sync(base);
          await tester.pump();
          late BuildContext pickerContext;
          await tester.pumpWidget(
            MaterialApp(
              home: Builder(
                builder: (context) {
                  pickerContext = context;
                  return CollaborativeEditorPage(collab: harness.owner);
                },
              ),
            ),
          );
          await tester.pump();
          selected = kind == 'mention'
              ? pickHostMentionUser(pickerContext, harness.owner.editorState)
              : pickHostMeetingReference(pickerContext, harness.owner.editorState);
          expect(permission?.value, isTrue);
          harness.gateway.update(Uint8List.fromList((peer['updates']['prefix'] as List).cast<int>()));
          await tester.pump();
          expect(permission!.value, isTrue, reason: 'A remote text update is not a revocation of host permission.');
          if (revoke) {
            final revoked = harness.owner.setEditable(false);
            expect(permission!.value, isFalse);
            await _completeWidgetOperation(tester, revoked);
            await _completeWidgetOperation(tester, harness.owner.setEditable(true));
            expect(harness.owner.editorState.editable, isTrue);
            expect(
              permission!.value,
              isFalse,
              reason: 'Restoring access must not revive a picker invalidated by real revocation.',
            );
          }
          final Object value = kind == 'mention'
              ? const CollabMentionUser(id: 'selected-user', name: '选择用户')
              : const CollabMeetingReference(meetingId: 'selected-meeting', title: '选择会议');
          pending.complete(value);
          expect(await selected, revoke ? isNull : same(value));
        } finally {
          if (!pending.isCompleted) pending.complete(null);
          await selected;
          await _closeWidgetHarness(tester, harness);
        }
      });
    }
  }

  test('headless first handshake restores editability, repairs numbering and supports selective undo', () async {
    final harness = await _ReviewHarness.create(formal: true);
    try {
      await harness.owner.initialize();
      expect(harness.owner.canEdit, isFalse, reason: 'The formal root has not been received yet.');
      expect(harness.owner.editorState.editable, isFalse);
      harness.gateway.sync(Uint8List.fromList((review['update'] as List).cast<int>()));
      await _drainProjection();
      final owner = harness.owner;
      expect(owner.canEdit, isTrue);
      expect(
        owner.editorState.editable,
        isTrue,
        reason: 'A headless controller must restore real document permissions.',
      );
      expect(
        native.currentBlocks().where((block) => block.ordered != null).every((block) => !block.ordered!.needsRepair),
        isTrue,
      );
      expect(owner.canUndo, isFalse, reason: 'System numbering repair must not become a personal edit.');
      final node = owner.editorState.document.root.children.firstWhere(
        (node) => node.attributes[AppFlowyBlockEditorAdapter.collabBlockIdAttribute] == 'a',
      );
      final before = native.currentBlocks().firstWhere((block) => block.id == 'a').text;
      await _insert(owner, node, 0, '本地');
      await _drainProjection();
      expect(native.currentBlocks().firstWhere((block) => block.id == 'a').text, '本地$before');
      expect(owner.canUndo, isTrue);
      await owner.undo();
      expect(native.currentBlocks().firstWhere((block) => block.id == 'a').text, before);
      expect(owner.editorState.editable, isTrue);
    } finally {
      await harness.close();
    }
  });

  testWidgets('initial writable handshake repairs missing numbering without creating personal history', (tester) async {
    final directory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('native-history-review-numbering-'),
    ))!;
    final harness = _ReviewHarness.inDirectory(directory, formal: true);
    try {
      await harness.owner.initialize();
      await tester.pumpWidget(MaterialApp(home: CollaborativeEditorPage(collab: harness.owner)));
      await tester.pump();
      harness.gateway.sync(Uint8List.fromList((review['update'] as List).cast<int>()));
      await tester.pump();
      final ordered = native.currentBlocks().where((block) => block.ordered != null).toList();
      expect(ordered, isNotEmpty);
      expect(ordered.every((block) => !block.ordered!.needsRepair), isTrue);
      expect(harness.gateway.localUpdates, isNotEmpty, reason: 'The handshake must send the derived numbering repair.');
      expect(harness.owner.canUndo, isFalse, reason: 'Derived numbering repair is a system update, not a local edit.');
      expect(native.encodeStateVector(), isNot((review['stateVector'] as List).cast<int>()));
    } finally {
      await _closeWidgetHarness(tester, harness);
    }
  });

  testWidgets('preview handshake projects missing numbering without writing derived order', (tester) async {
    final directory = (await tester.runAsync(() => Directory.systemTemp.createTemp('native-history-review-preview-')))!;
    final harness = _ReviewHarness.inDirectory(directory, formal: true);
    try {
      await harness.owner.initialize();
      harness.gateway.sync(orderedBase);
      await tester.pump();
      await tester.pumpWidget(MaterialApp(home: CollaborativeEditorPage(collab: harness.owner)));
      await tester.pump();
      expect(harness.owner.canEdit, isTrue);
      await tester.tap(find.byKey(const ValueKey('editor-mode-toggle')));
      await tester.pump();
      expect(harness.owner.editorState.editable, isFalse);
      await harness.owner.retry();
      harness.gateway.sync(Uint8List.fromList((review['update'] as List).cast<int>()));
      await tester.pump();
      final missing = native
          .currentBlocks()
          .where((block) => block.ordered?.needsRepair == true)
          .map((block) => block.id)
          .toList();
      expect(missing, unorderedEquals((review['missingOrderIds'] as List).cast<String>()));
      expect(
        native.encodeStateVector(),
        (review['stateVector'] as List).cast<int>(),
        reason: 'Preview may persist received updates but must not add native numbering writes.',
      );
      expect(harness.owner.editorState.editable, isFalse);
      expect(harness.owner.canUndo, isFalse);
      expect(harness.owner.blockCount, greaterThan(0));
      expect(tester.takeException(), isNull);
    } finally {
      await _closeWidgetHarness(tester, harness);
    }
  });
}

/// Insert UTF-16 [text] at [offset] in borrowed [node] through [owner]'s editor.
/// Completes after the local transaction; callers settle their own projection/UI.
Future<void> _insert(CollabController owner, Node node, int offset, String text) async {
  final state = owner.editorState;
  state.selection = Selection.single(path: node.path, startOffset: offset);
  final transaction = state.transaction..insertText(node, offset, text);
  transaction.afterSelection = Selection.single(path: node.path, startOffset: offset + text.length);
  await state.apply(transaction, skipHistoryDebounce: true);
}

/// Settle synchronous FRB projection and its queued microtasks outside Widget tests.
Future<void> _drainProjection() async {
  await Future<void>.delayed(Duration.zero);
}

/// Unmount [harness] from [tester] before closing native resources and its cache.
/// Session cancellation can cross real and Widget test async zones, so both are
/// drained in a bounded loop; a stuck close fails rather than leaking an owner.
Future<void> _closeWidgetHarness(WidgetTester tester, _ReviewHarness harness) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await _completeWidgetOperation(tester, harness.owner.close());
  await tester.pump(const Duration(milliseconds: 200));
  await tester.runAsync(harness.close);
}

/// Await borrowed [operation] while [tester] drains both real and fake async
/// tasks. Exceeding the bounded turn count fails instead of leaving native state
/// owned by a controller that later tests could accidentally reuse.
Future<void> _completeWidgetOperation(WidgetTester tester, Future<void> operation) async {
  var complete = false;
  Object? failure;
  final observed = operation.then<void>(
    (_) => complete = true,
    onError: (Object error, StackTrace stack) {
      failure = error;
      complete = true;
    },
  );
  for (var turn = 0; !complete && turn < 32; turn++) {
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  }
  expect(complete, isTrue, reason: 'Controller resource and access transitions must finish before continuing.');
  await observed;
  if (failure != null) throw failure!;
}

/// Visit borrowed [root] and all of its descendants without retaining old paths.
Iterable<Node> _descendants(Node root) sync* {
  yield root;
  for (final child in root.children) {
    yield* _descendants(child);
  }
}

/// Own a temporary controller and cache, with an in-memory borrowed transport.
class _ReviewHarness {
  /// Store owned [directory]/[owner] and borrowed [gateway] until [close].
  _ReviewHarness(this.directory, this.owner, this.gateway);

  /// Owned directory removed only after the controller has closed its database.
  final Directory directory;

  /// Owned controller using the production editor and native history binding.
  final CollabController owner;

  /// Transport carrying independent peer updates without a real socket.
  final _ReviewGateway gateway;

  /// Native cache belonging to this harness, retained across a deliberate reopen.
  String get database => '${directory.path}/updates.sqlite';

  /// Resolve the basic fixture's editable paragraph by stable identity.
  Node get paragraph => node('p1');

  /// Resolve the current nested node with stable [id], after any projection.
  Node node(String id) => _descendants(
    owner.editorState.document.root,
  ).firstWhere((node) => node.attributes[AppFlowyBlockEditorAdapter.collabBlockIdAttribute] == id);

  /// Create a cache with [formal] schema and borrowed [services], without opening
  /// native resources. Plain tests own this asynchronous directory creation.
  static Future<_ReviewHarness> create({
    bool formal = false,
    CollabHostServices services = const CollabHostServices(),
  }) async {
    final directory = await Directory.systemTemp.createTemp('native-history-review-');
    return _ReviewHarness.inDirectory(directory, formal: formal, services: services);
  }

  /// Transfer [directory] ownership to a controller with [formal] schema and
  /// borrowed [services]. Construction stays in the Widget test's own async zone.
  factory _ReviewHarness.inDirectory(
    Directory directory, {
    bool formal = false,
    CollabHostServices services = const CollabHostServices(),
  }) {
    final gateway = _ReviewGateway();
    final database = '${directory.path}/updates.sqlite';
    final owner = formal
        ? CollabController.cses(
            config: CollabDocumentConfig(
              documentId: 'fixture-doc',
              serverIdentity: 'wss://history-review.invalid/ws',
              companyId: 'company',
              userId: 'user',
              editable: true,
              databasePath: database,
            ),
            gateway: gateway,
            services: services,
          )
        : CollabController.localDraft(databasePath: database, services: services);
    return _ReviewHarness(directory, owner, gateway);
  }

  /// Close the native owner before removing its cache; repeated cleanup is safe.
  Future<void> close() async {
    await owner.close();
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}

/// Route real Yjs fixtures through production session callbacks without networking.
class _ReviewGateway implements CsesCollabGateway {
  /// Borrowed handlers belong to the currently registered controller session.
  Map<String, void Function(Map<String, dynamic>)> _callbacks = {};

  /// Captured document updates include handshake repair deltas and local edits.
  final List<Uint8List> localUpdates = [];

  /// Test transport is connected and owns no socket or asynchronous event stream.
  @override
  bool get isConnected => true;

  /// No transport connectivity changes occur during these deterministic cases.
  @override
  Stream<bool> get connectionStates => const Stream<bool>.empty();

  /// Borrow [callbacks] for [pageId]/[documentId]/[instanceId] until unregister.
  @override
  Future<void> register({
    required String pageId,
    required String documentId,
    required String instanceId,
    required Map<String, void Function(Map<String, dynamic>)> callbacks,
  }) async {
    _callbacks = callbacks;
  }

  /// Accept [action]/[body] for [pageId] without network I/O or simulated ACKs.
  @override
  bool send(String pageId, String action, Map<String, dynamic> body) {
    if (action == 'collabUpdate') localUpdates.add(base64Decode(body['data'] as String));
    return true;
  }

  /// Release borrowed callbacks for [pageId]; no external resource is closed.
  @override
  Future<void> unregister(String pageId) async {
    _callbacks = {};
  }

  /// Deliver [bytes] as the first complete server handshake snapshot.
  void sync(Uint8List bytes) => _callbacks['collabSync']!({
    'data': base64Encode(bytes),
    'stateVector': base64Encode([0]),
  });

  /// Deliver an independent peer's incremental [bytes] through the update route.
  void update(Uint8List bytes) => _callbacks['collabUpdate']!({'data': base64Encode(bytes)});
}
