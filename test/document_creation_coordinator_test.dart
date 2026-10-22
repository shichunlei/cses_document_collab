import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:cses_mobile_collab_demo/src/demo/document_creation/document_creation_api.dart';
import 'package:cses_mobile_collab_demo/src/demo/document_creation/document_creation_coordinator.dart';
import 'package:cses_mobile_collab_demo/src/demo/document_creation/document_creation_operation.dart';
import 'package:cses_mobile_collab_demo/src/demo/document_creation/document_creation_page.dart';
import 'package:cses_mobile_collab_demo/src/demo/document_creation/document_creation_store.dart';
import 'package:cses_mobile_collab_demo/src/demo/document_creation/document_list_page.dart';
import 'package:cses_mobile_collab_demo/src/demo/document_creation/document_space_list.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 验证真实创建状态机的中断恢复、账号隔离、持久化及页面交互，不连接外部服务。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Api api;
  late _Store store;
  late DocumentCreationCoordinator coordinator;
  late List<String> actions;
  var failPrepare = false;
  var failOpen = false;
  setUp(() {
    api = _Api();
    store = _Store();
    actions = [];
    failPrepare = false;
    failOpen = false;
    var sequence = 0;
    coordinator = DocumentCreationCoordinator(
      api: api,
      store: store,
      createId: () => 'id-${sequence++}',
      closeDocument: () async {
        actions.add('close');
      },
      prepare: (operation) async {
        actions.add('prepare');
        if (failPrepare) throw StateError('disk');
        return _prepared(operation.documentId!, operation.paragraphId);
      },
      openDocument: (id) async {
        actions.add('open:$id');
        if (failOpen) throw StateError('open');
      },
    );
  });
  tearDown(() async {
    await coordinator.close();
  });
  test('create persists stages before writes; one doc and one prepared paragraph', () async {
    await coordinator.restore();
    expect(await coordinator.start(_target), 'server-doc');
    expect(api.creates, 1);
    expect(api.writes, 1);
    expect(api.verifies, 1);
    expect(actions, ['close', 'prepare', 'close', 'open:server-doc']);
    expect(store.stages, [
      DocumentCreationStage.creating,
      DocumentCreationStage.shellCreated,
      DocumentCreationStage.shellCreated,
      DocumentCreationStage.bodyPrepared,
      DocumentCreationStage.snapshotSending,
      DocumentCreationStage.snapshotAccepted,
      DocumentCreationStage.completed,
    ]);
    expect(coordinator.pending, isFalse);
    expect(api.lastPrepared!.paragraphId, 'id-1');
  });
  test(
    'existing document open only verifies, releases and opens without changing a pending record',
    () async {
      store.value = _operation(DocumentCreationStage.createUnknown);
      await coordinator.restore();
      final record = store.value;
      final stages = List.of(store.stages);
      expect(await coordinator.openExistingDocument('existing-doc'), 'existing-doc');
      expect(api.openedDocuments, ['existing-doc']);
      expect(actions, ['close', 'open:existing-doc']);
      expect(identical(store.value, record), isTrue);
      expect(store.stages, stages);
      expect(coordinator.pending, isTrue);
      expect(api.creates, 0);
      expect(api.writes, 0);
    },
  );

  test('existing document access rejection preserves current document and allows retry', () async {
    await coordinator.restore();
    api.openFailure = const DocumentCreationRejected('文档已删除或无权访问');
    expect(await coordinator.openExistingDocument('existing-doc'), isNull);
    expect(actions, isEmpty);
    expect(coordinator.error, '文档已删除或无权访问');
    expect(coordinator.busy, isFalse);
    api.openFailure = null;
    expect(await coordinator.openExistingDocument('existing-doc'), 'existing-doc');
    expect(actions, ['close', 'open:existing-doc']);
  });

  test(
    'existing document open rejects another target and creation during a pending switch',
    () async {
      await coordinator.restore();
      final gate = api.openVerification = Completer<void>();
      final first = coordinator.openExistingDocument('first');
      expect(await coordinator.openExistingDocument('second'), isNull);
      final creation = coordinator.start(_target);
      await Future<void>.delayed(Duration.zero);
      expect(api.openedDocuments, ['first']);
      expect(api.creates, 0);
      gate.complete();
      expect(await first, 'first');
      expect(await creation, isNull);
      expect(actions, ['close', 'open:first']);
    },
  );

  test(
    'account change or close during access verification prevents releasing and opening',
    () async {
      await coordinator.restore();
      final gate = api.openVerification = Completer<void>();
      final opening = coordinator.openExistingDocument('first');
      await Future<void>.delayed(Duration.zero);
      api.valid = false;
      gate.complete();
      expect(await opening, isNull);
      expect(actions, isEmpty);
      api.valid = true;
      final next = api.openVerification = Completer<void>();
      final pending = coordinator.openExistingDocument('second');
      await Future<void>.delayed(Duration.zero);
      final closing = coordinator.close();
      next.complete();
      expect(await pending, isNull);
      await closing;
      expect(actions, isEmpty);
    },
  );

  test('failed existing open leaves journal unchanged and can retry without bootstrap', () async {
    await coordinator.restore();
    failOpen = true;
    expect(await coordinator.openExistingDocument('existing-doc'), isNull);
    expect(coordinator.error, '文档打开失败，请重试');
    expect(store.stages, isEmpty);
    failOpen = false;
    expect(await coordinator.openExistingDocument('existing-doc'), 'existing-doc');
    expect(actions, ['close', 'open:existing-doc', 'close', 'open:existing-doc']);
    expect(api.creates, 0);
    expect(api.writes, 0);
  });
  test('double click shares in-flight create and does not duplicate shell', () async {
    await coordinator.restore();
    final response = api.creation = Completer<String>();
    final first = coordinator.start(_target);
    final second = coordinator.start(_target);
    expect(identical(first, second), isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(api.creates, 1);
    response.complete('server-doc');
    expect(await first, 'server-doc');
    expect(api.creates, 1);
  });

  test('concurrent restore shares one read and does not overwrite an active create', () async {
    final first = coordinator.restore();
    final second = coordinator.restore();
    expect(identical(first, second), isTrue);
    await first;
    expect(store.reads, 1);
    final response = api.creation = Completer<String>();
    final creation = coordinator.start(_target);
    await Future<void>.delayed(Duration.zero);
    await expectLater(coordinator.restore(), throwsStateError);
    response.complete('server-doc');
    expect(await creation, 'server-doc');
    expect(store.reads, 1);
  });

  test('failed restore can retry after storage recovery', () async {
    store.readFailure = true;
    await expectLater(coordinator.restore(), throwsFormatException);
    store.readFailure = false;
    await coordinator.restore();
    expect(await coordinator.start(_target), 'server-doc');
    expect(store.reads, 2);
  });
  test('unknown create outcome never automatically creates again', () async {
    await coordinator.restore();
    api.createFailure = StateError('network timeout');
    expect(await coordinator.start(_target), isNull);
    expect(store.value!.stage, DocumentCreationStage.createUnknown);
    expect(await coordinator.resume(), isNull);
    expect(await coordinator.start(_target), isNull);
    expect(api.creates, 1);
    expect(actions, isEmpty);
  });
  test('journal failure before HTTP permits a fresh attempt after storage recovers', () async {
    await coordinator.restore();
    store.failStage = DocumentCreationStage.creating;
    expect(await coordinator.start(_target), isNull);
    expect(api.creates, 0);
    expect(coordinator.pending, isFalse);
    store.failStage = null;
    expect(await coordinator.start(_target), 'server-doc');
    expect(api.creates, 1);
  });
  test('reviewed unknown operation persists before allowing a separate new creation', () async {
    store.value = _operation(DocumentCreationStage.creating);
    await coordinator.restore();
    expect(coordinator.needsReview, isTrue);
    expect(await coordinator.finishReviewedOperation('stale-page-id'), isFalse);
    expect(coordinator.pending, isTrue);
    expect(coordinator.busy, isFalse);
    store.failStage = DocumentCreationStage.reviewed;
    expect(await coordinator.finishReviewedOperation('operation'), isFalse);
    expect(coordinator.needsReview, isTrue);
    expect(store.value!.stage, DocumentCreationStage.createUnknown);
    store.failStage = null;
    expect(await coordinator.finishReviewedOperation('operation'), isTrue);
    expect(coordinator.pending, isFalse);
    expect(store.value!.operationId, 'operation');
    expect(
      DocumentCreationOperation.fromJson(store.value!.toJson()).stage,
      DocumentCreationStage.reviewed,
    );
    expect(api.creates, 0);
    expect(api.writes, 0);
    expect(api.reads, 0);
    expect(actions, isEmpty);
    expect(await coordinator.start(_target), 'server-doc');
    expect(api.creates, 1);
  });

  test('account change cannot resolve an unknown operation or retain a busy lock', () async {
    store.value = _operation(DocumentCreationStage.createUnknown);
    await coordinator.restore();
    api.valid = false;
    expect(await coordinator.finishReviewedOperation('operation'), isFalse);
    expect(coordinator.busy, isFalse);
    expect(store.value!.stage, DocumentCreationStage.createUnknown);
    api.valid = true;
    expect(await coordinator.finishReviewedOperation('operation'), isTrue);
  });

  test('in-flight create cannot be ended as a reviewed unknown result', () async {
    await coordinator.restore();
    final response = api.creation = Completer<String>();
    final creation = coordinator.start(_target);
    await Future<void>.delayed(Duration.zero);
    expect(await coordinator.finishReviewedOperation(coordinator.operation!.operationId), isFalse);
    response.complete('server-doc');
    expect(await creation, 'server-doc');
    expect(store.value!.stage, DocumentCreationStage.completed);
  });
  test('explicit shell rejection allows a new operation', () async {
    await coordinator.restore();
    api.createFailure = const DocumentCreationRejected('拒绝');
    expect(await coordinator.start(_target), isNull);
    expect(store.value!.stage, DocumentCreationStage.rejected);
    api.createFailure = null;
    expect(await coordinator.start(_target), 'server-doc');
    expect(api.creates, 2);
  });
  test('native failure resumes the same doc and stable paragraph', () async {
    await coordinator.restore();
    failPrepare = true;
    expect(await coordinator.start(_target), isNull);
    final before = store.value!;
    expect(before.stage, DocumentCreationStage.shellCreated);
    failPrepare = false;
    expect(await coordinator.resume(), 'server-doc');
    expect(api.creates, 1);
    expect(api.lastPrepared!.paragraphId, before.paragraphId);
    expect(store.value!.createdAt, before.createdAt);
  });

  test(
    'receipt write failure retains known ID in memory and retries storage before native work',
    () async {
      await coordinator.restore();
      store.failStage = DocumentCreationStage.shellCreated;
      expect(await coordinator.start(_target), isNull);
      expect(coordinator.operation!.documentId, 'server-doc');
      expect(store.value!.stage, DocumentCreationStage.creating);
      expect(actions, isEmpty);
      store.failStage = null;
      expect(await coordinator.resume(), 'server-doc');
      expect(api.creates, 1);
    },
  );

  test(
    'account change during native preparation prevents initial HTTP write and navigation',
    () async {
      await coordinator.restore();
      api.writeFailure = StateError('will not be used');
      final nativeGate = Completer<PreparedDocument>();
      await coordinator.close();
      coordinator = DocumentCreationCoordinator(
        api: api,
        store: store,
        createId: () => 'stable-id',
        prepare: (_) => nativeGate.future,
        closeDocument: () async {},
        openDocument: (id) async {
          actions.add('unexpected open');
        },
      );
      await coordinator.restore();
      final task = coordinator.start(_target);
      await Future<void>.delayed(Duration.zero);
      api.valid = false;
      nativeGate.complete(_prepared('server-doc', 'stable-id'));
      expect(await task, isNull);
      expect(api.writes, 0);
      expect(actions, isEmpty);
      expect(coordinator.operation!.stage, DocumentCreationStage.shellCreated);
    },
  );
  test('uncertain snapshot reads first; missing never re-inserts', () async {
    await coordinator.restore();
    api.writeFailure = StateError('timeout');
    expect(await coordinator.start(_target), isNull);
    expect(store.value!.stage, DocumentCreationStage.snapshotSending);
    api.readState = InitialSnapshotState.missing;
    expect(await coordinator.resume(), isNull);
    expect(api.writes, 1);
    expect(api.reads, 1);
    api.readState = InitialSnapshotState.different;
    expect(await coordinator.resume(), isNull);
    expect(api.writes, 1);
    api.readState = InitialSnapshotState.matches;
    expect(await coordinator.resume(), 'server-doc');
    expect(api.writes, 1);
    expect(api.creates, 1);
    expect(actions.where((a) => a == 'prepare').length, 1);
  });
  test('explicit snapshot rejection remains safely retryable', () async {
    await coordinator.restore();
    api.writeFailure = const DocumentCreationRejected('无权限');
    expect(await coordinator.start(_target), isNull);
    expect(store.value!.stage, DocumentCreationStage.bodyPrepared);
    api.writeFailure = null;
    expect(await coordinator.resume(), 'server-doc');
    expect(api.creates, 1);
    expect(api.writes, 2);
    expect(api.reads, 0);
  });
  test('accepted snapshot survives editor failure without re-sending', () async {
    await coordinator.restore();
    failOpen = true;
    expect(await coordinator.start(_target), isNull);
    expect(store.value!.stage, DocumentCreationStage.snapshotAccepted);
    failOpen = false;
    expect(await coordinator.resume(), 'server-doc');
    expect(api.writes, 1);
    expect(actions.where((a) => a == 'prepare').length, 1);
  });
  test('late create after account switch preserves old receipt without preparing', () async {
    await coordinator.restore();
    final response = api.creation = Completer<String>();
    final task = coordinator.start(_target);
    await Future<void>.delayed(Duration.zero);
    api.valid = false;
    response.complete('old-account-doc');
    expect(await task, isNull);
    expect(store.value!.documentId, 'old-account-doc');
    expect(store.value!.stage, DocumentCreationStage.shellCreated);
    expect(actions, isEmpty);
    expect(api.writes, 0);
  });
  test('close joins in-flight create and only saves its late receipt', () async {
    await coordinator.restore();
    final response = api.creation = Completer<String>();
    final task = coordinator.start(_target);
    await Future<void>.delayed(Duration.zero);
    var closed = false;
    final closing = coordinator.close().then((_) => closed = true);
    await Future<void>.delayed(Duration.zero);
    expect(closed, isFalse);
    response.complete('late-doc');
    expect(await task, isNull);
    await closing;
    expect(store.value!.documentId, 'late-doc');
    expect(actions, isEmpty);
  });
  test('restore converts a crashed creating request to unknown', () async {
    store.value = _operation(DocumentCreationStage.creating);
    await coordinator.restore();
    expect(coordinator.operation!.stage, DocumentCreationStage.createUnknown);
    expect(await coordinator.resume(), isNull);
    expect(api.creates, 0);
  });
  test('corrupted records cannot silently become a fresh create', () async {
    store.readFailure = true;
    await expectLater(coordinator.restore(), throwsFormatException);
    expect(await coordinator.start(_target), isNull);
    expect(api.creates, 0);
    expect(
      () => DocumentCreationOperation.fromJson({'version': 1, 'stage': 'completed'}),
      throwsFormatException,
    );
  });
  test('atomic account files reopen; different scopes cannot see pending IDs', () async {
    final dir = await Directory.systemTemp.createTemp('creation-store-');
    try {
      final first = FileDocumentCreationStore(directory: dir, scope: 'first');
      await first.write(_operation(DocumentCreationStage.shellCreated, documentId: 'doc-a'));
      expect(
        (await FileDocumentCreationStore(directory: dir, scope: 'first').read())!.documentId,
        'doc-a',
      );
      expect(await FileDocumentCreationStore(directory: dir, scope: 'second').read(), isNull);
      final file = dir.listSync().whereType<File>().single;
      expect(await file.readAsString(), isNot(contains('cookie')));
      await file.writeAsString('{broken');
      await expectLater(first.read(), throwsFormatException);
      expect(
        () => FileDocumentCreationStore(directory: dir, scope: '../other'),
        throwsFormatException,
      );
    } finally {
      await dir.delete(recursive: true);
    }
  });
  testWidgets('real creation page selects a location and returns created doc ID', (tester) async {
    await coordinator.restore();
    String? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await Navigator.of(context).push<String>(
                MaterialPageRoute(
                  builder: (_) => DocumentCreationPage(
                    loadDocuments: _emptyDocuments,
                    coordinator: coordinator,
                    loadTargets: () async => [_target],
                  ),
                ),
              );
            },
            child: const Text('打开'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.text('文档列表'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('create-blank-document')));
    await tester.pumpAndSettle();
    expect(result, 'server-doc');
    expect(api.creates, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('new document opens above the list and back returns to the selected space', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    final opened = <String>[];
    var listLoads = 0;
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute(
                builder: (listContext) => DocumentCreationPage(
                  coordinator: coordinator,
                  loadTargets: () async => [_target],
                  loadDocuments: (target, page) async {
                    listLoads++;
                    return _emptyDocuments(target, page);
                  },
                  onOpenDocument: (id) async {
                    opened.add(id);
                    await Navigator.of(listContext).push<void>(
                      MaterialPageRoute(builder: (_) => Scaffold(body: Text('新建编辑:$id'))),
                    );
                  },
                ),
              ),
            ),
            child: const Text('文档列表入口'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('文档列表入口'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('create-blank-document')));
    await tester.pumpAndSettle();
    expect(find.text('新建编辑:server-doc'), findsOneWidget);
    expect(opened, ['server-doc']);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.byType(DocumentCreationPage), findsOneWidget);
    expect(find.byKey(const ValueKey('creation-target')), findsOneWidget);
    expect(find.text('文档列表入口'), findsNothing);
    expect(api.creates, 1);
    expect(listLoads, 2);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('app bar creates in the selected space even when its document list fails', (
    tester,
  ) async {
    const other = DocumentCreationTarget(id: 'other-space', name: '企业空间');
    final requests = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).push<String>(
              MaterialPageRoute(
                builder: (_) => DocumentCreationPage(
                  coordinator: coordinator,
                  loadTargets: () async => [_target, other],
                  loadDocuments: (target, page) async {
                    requests.add(target.id);
                    throw StateError('list offline');
                  },
                ),
              ),
            ),
            child: const Text('新建入口'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('新建入口'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('creation-target')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('企业空间').last);
    await tester.pumpAndSettle();
    expect(requests, ['space', 'other-space']);
    final action = find.byKey(const ValueKey('create-blank-document'));
    expect(find.ancestor(of: action, matching: find.byType(AppBar)), findsOneWidget);
    expect(
      tester.getCenter(action).dx,
      greaterThan(tester.view.physicalSize.width / tester.view.devicePixelRatio / 2),
    );
    expect(tester.widget<TextButton>(action).onPressed, isNotNull);
    await tester.tap(action);
    await tester.pumpAndSettle();
    expect(coordinator.operation!.target.id, other.id);
    expect(api.creates, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'list click opens one editor, retains list on back and blocks cached duplicate clicks',
    (tester) async {
      final navigator = GlobalKey<NavigatorState>();
      final verify = api.openVerification = Completer<void>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          home: DocumentCreationPage(
            coordinator: coordinator,
            loadTargets: () async => [_target],
            loadDocuments: (_, page) async => DocumentListPage(
              items: [
                DocumentListEntry.fromJson({'id': 'existing-doc', 'name': '已有文档'}),
              ],
              totalCount: 1,
              pageNumber: page,
              pageSize: 20,
            ),
            onOpenDocument: (id) async {
              if (await coordinator.openExistingDocument(id) != id) {
                throw FormatException(coordinator.error ?? '打开失败');
              }
              await navigator.currentState!.push<void>(
                MaterialPageRoute(
                  builder: (_) => Scaffold(
                    appBar: AppBar(title: const Text('编辑页')),
                    body: Text('编辑:$id'),
                  ),
                ),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      try {
        final row = find.byKey(const ValueKey('space-document-existing-doc'));
        final tap = tester
            .widget<InkWell>(find.descendant(of: row, matching: find.byType(InkWell)))
            .onTap!;
        tap();
        tap();
        await tester.pump(const Duration(milliseconds: 1));
        await tester.pump();
        expect(api.openedDocuments, ['existing-doc']);
        expect(
          tester.widget<TextButton>(find.byKey(const ValueKey('create-blank-document'))).onPressed,
          isNull,
        );
        verify.complete();
        await tester.pumpAndSettle();
        expect(find.text('编辑:existing-doc'), findsOneWidget);
        navigator.currentState!.pop();
        await tester.pumpAndSettle();
        expect(find.text('已有文档'), findsOneWidget);
        expect(
          tester
              .widget<DropdownButtonFormField<String>>(
                find.byKey(const ValueKey('creation-target')),
              )
              .initialValue,
          _target.id,
        );
        expect(
          tester.widget<TextButton>(find.byKey(const ValueKey('create-blank-document'))).onPressed,
          isNotNull,
        );
        expect(actions, ['close', 'open:existing-doc']);
        expect(api.creates, 0);
        expect(api.writes, 0);
      } finally {
        if (!verify.isCompleted) verify.complete();
        if (navigator.currentState?.canPop() == true) navigator.currentState!.pop();
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
  );

  testWidgets('list open failure is visible and another click retries the same document', (
    tester,
  ) async {
    api.openFailure = const DocumentCreationRejected('没有访问权限');
    final ready = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: DocumentCreationPage(
          coordinator: coordinator,
          loadTargets: () async => [_target],
          loadDocuments: (_, page) async => DocumentListPage(
            items: [
              DocumentListEntry.fromJson({'id': 'existing-doc', 'name': '已有文档'}),
            ],
            totalCount: 1,
            pageNumber: page,
            pageSize: 20,
          ),
          onOpenDocument: (id) async {
            if (await coordinator.openExistingDocument(id) != id) {
              throw FormatException(coordinator.error ?? '打开失败');
            }
            ready.add(id);
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('已有文档'));
    await tester.pumpAndSettle();
    expect(find.text('没有访问权限'), findsOneWidget);
    expect(actions, isEmpty);
    api.openFailure = null;
    await tester.tap(find.text('已有文档'));
    await tester.pumpAndSettle();
    expect(ready, ['existing-doc']);
    expect(find.byKey(const ValueKey('document-open-error')), findsNothing);
    expect(api.openedDocuments, ['existing-doc', 'existing-doc']);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('leaving a list while its open callback is pending handles a late failure', (
    tester,
  ) async {
    final open = Completer<void>();
    await tester.pumpWidget(
      MaterialApp(
        home: DocumentCreationPage(
          coordinator: coordinator,
          loadTargets: () async => [_target],
          loadDocuments: (_, page) async => DocumentListPage(
            items: [
              DocumentListEntry.fromJson({'id': 'existing-doc', 'name': '已有文档'}),
            ],
            totalCount: 1,
            pageNumber: page,
            pageSize: 20,
          ),
          onOpenDocument: (_) => open.future,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('已有文档'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    open.completeError(StateError('late failure'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  for (final retryFails in [false, true]) {
    testWidgets('position retries deduplicate cached callbacks and recover (failure=$retryFails)', (
      tester,
    ) async {
      final firstRetry = Completer<List<DocumentCreationTarget>>();
      final laterRetry = Completer<List<DocumentCreationTarget>>();
      var requests = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: DocumentCreationPage(
            coordinator: coordinator,
            loadDocuments: _emptyDocuments,
            loadTargets: () {
              requests++;
              if (requests == 1) return Future.error(StateError('initial failure'));
              return requests == 2 ? firstRetry.future : laterRetry.future;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      try {
        final retry = tester
            .widget<TextButton>(find.widgetWithText(TextButton, '重新加载位置'))
            .onPressed!;
        retry();
        retry();
        await tester.pump();
        expect(requests, 2);
        expect(find.byType(LinearProgressIndicator), findsOneWidget);
        expect(find.text('重新加载位置'), findsNothing);
        expect(
          tester.widget<TextButton>(find.byKey(const ValueKey('create-blank-document'))).onPressed,
          isNull,
        );
        if (retryFails) {
          firstRetry.completeError(StateError('retry failure'));
          await tester.pumpAndSettle();
          final again = tester
              .widget<TextButton>(find.widgetWithText(TextButton, '重新加载位置'))
              .onPressed!;
          again();
          again();
          await tester.pump();
          expect(requests, 3);
          laterRetry.complete([_target]);
        } else {
          firstRetry.complete([_target]);
        }
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('creation-target')), findsOneWidget);
        expect(find.text('位置加载失败，请重试'), findsNothing);
        expect(
          tester.widget<TextButton>(find.byKey(const ValueKey('create-blank-document'))).onPressed,
          isNotNull,
        );
        expect(api.creates, 0);
        expect(api.writes, 0);
      } finally {
        if (!firstRetry.isCompleted) firstRetry.complete([_target]);
        if (!laterRetry.isCompleted) laterRetry.complete([_target]);
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox.shrink());
      }
    });
  }

  for (final lateFailure in [false, true]) {
    testWidgets(
      'leaving during a position request ignores its late result (failure=$lateFailure)',
      (tester) async {
        final response = Completer<List<DocumentCreationTarget>>();
        await tester.pumpWidget(
          MaterialApp(
            home: DocumentCreationPage(
              coordinator: coordinator,
              loadDocuments: _emptyDocuments,
              loadTargets: () => response.future,
            ),
          ),
        );
        await tester.pump();
        await tester.pumpWidget(const SizedBox.shrink());
        if (lateFailure) {
          response.completeError(StateError('late failure'));
        } else {
          response.complete([_target]);
        }
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(api.creates, 0);
        expect(api.writes, 0);
      },
    );
  }

  for (final retrySpaces in [false, true]) {
    testWidgets('completed restoration retains its target after late spaces (retry=$retrySpaces)', (
      tester,
    ) async {
      const folder = DocumentCreationTarget(id: 'restored-folder', name: '恢复位置');
      store.value = DocumentCreationOperation(
        operationId: 'restored-operation',
        paragraphId: 'p',
        createdAt: 1792584000000,
        target: folder,
        stage: DocumentCreationStage.snapshotAccepted,
        documentId: 'restored-doc',
      );
      await coordinator.close();
      final opening = Completer<void>();
      final spaces = Completer<List<DocumentCreationTarget>>();
      final opened = <String>[];
      final listed = <String>[];
      var loads = 0;
      coordinator = DocumentCreationCoordinator(
        api: api,
        store: store,
        createId: () => 'unused',
        prepare: (operation) async => _prepared(operation.documentId!, operation.paragraphId),
        closeDocument: () async {},
        openDocument: (id) async {
          opened.add(id);
          await opening.future;
        },
      );
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          home: DocumentCreationPage(
            coordinator: coordinator,
            initialTarget: retrySpaces
                ? const DocumentCreationTarget(id: 'entry-hint', name: '入口位置')
                : null,
            loadTargets: () => ++loads == 1 ? spaces.future : Future.value([_target]),
            loadDocuments: (target, page) {
              listed.add(target.id);
              return _emptyDocuments(target, page);
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('create-blank-document')));
      await tester.pump();
      final overlay = navigator.currentState!.push<void>(
        MaterialPageRoute(builder: (_) => const Scaffold(body: Text('其他页面'))),
      );
      await tester.pumpAndSettle();
      opening.complete();
      await tester.pumpAndSettle();
      expect(coordinator.operation!.stage, DocumentCreationStage.completed);
      expect(find.text('其他页面'), findsOneWidget);
      if (retrySpaces) {
        spaces.completeError(StateError('spaces offline'));
      } else {
        spaces.complete([_target]);
      }
      await tester.pumpAndSettle();
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      await overlay;
      expect(find.text('打开文档'), findsOneWidget);
      expect(tester.widget<DocumentSpaceList>(find.byType(DocumentSpaceList)).target.id, folder.id);
      if (retrySpaces) {
        await tester.tap(find.text('重新加载位置'));
        await tester.pumpAndSettle();
        expect(loads, 2);
      }
      final selector = tester.widget<DropdownButtonFormField<String>>(
        find.byKey(const ValueKey('creation-target')),
      );
      expect(selector.initialValue, folder.id);
      expect(selector.onChanged, isNull);
      expect(listed, isNotEmpty);
      expect(listed, everyElement(folder.id));
      expect(opened, ['restored-doc']);
      expect(api.creates, 0);
      expect(api.writes, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('a previous completed operation does not override the next page creation target', (
    tester,
  ) async {
    const previous = DocumentCreationTarget(id: 'previous-folder', name: '上次位置');
    const fresh = DocumentCreationTarget(id: 'fresh-folder', name: '本次位置');
    store.value = DocumentCreationOperation(
      operationId: 'previous-operation',
      paragraphId: 'p',
      createdAt: 1792584000000,
      target: previous,
      stage: DocumentCreationStage.completed,
      documentId: 'previous-doc',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: DocumentCreationPage(
          coordinator: coordinator,
          initialTarget: fresh,
          loadTargets: () async => [_target, fresh],
          loadDocuments: _emptyDocuments,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.widget<DocumentSpaceList>(find.byType(DocumentSpaceList)).target.id, fresh.id);
    final selector = tester.widget<DropdownButtonFormField<String>>(
      find.byKey(const ValueKey('creation-target')),
    );
    expect(selector.initialValue, fresh.id);
    expect(selector.onChanged, isNotNull);
    expect(find.text('创建'), findsOneWidget);
    expect(api.creates, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('pending creation lists its fixed folder instead of the default personal space', (
    tester,
  ) async {
    const folder = DocumentCreationTarget(id: 'pending-folder', name: '待恢复位置');
    store.value = DocumentCreationOperation(
      operationId: 'pending',
      paragraphId: 'p',
      createdAt: 1792584000000,
      target: folder,
      stage: DocumentCreationStage.createUnknown,
    );
    final requests = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: DocumentCreationPage(
          coordinator: coordinator,
          loadTargets: () async => [_target],
          loadDocuments: (target, page) async {
            requests.add(target.id);
            return _emptyDocuments(target, page);
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.widget<DocumentSpaceList>(find.byType(DocumentSpaceList)).target.id, folder.id);
    expect(requests, everyElement(folder.id));
    expect(api.creates, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('leaving while create is pending saves progress without a late pop', (tester) async {
    await coordinator.restore();
    final response = api.creation = Completer<String>();
    await tester.pumpWidget(
      MaterialApp(
        home: DocumentCreationPage(
          loadDocuments: _emptyDocuments,
          coordinator: coordinator,
          loadTargets: () async => [_target],
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('create-blank-document')));
    await tester.pump();
    expect(
      (tester.widget<TextButton>(find.byKey(const ValueKey('create-blank-document')))).onPressed,
      isNull,
    );
    await tester.pumpWidget(const MaterialApp(home: Text('已离开')));
    response.complete('server-doc');
    await tester.pumpAndSettle();
    expect(find.text('已离开'), findsOneWidget);
    expect(coordinator.operation!.stage, DocumentCreationStage.completed);
    expect(tester.takeException(), isNull);
  });
  testWidgets('late creation keeps a newer route and offers opening the existing document', (
    tester,
  ) async {
    await coordinator.restore();
    final response = api.creation = Completer<String>();
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: DocumentCreationPage(
          loadDocuments: _emptyDocuments,
          coordinator: coordinator,
          loadTargets: () async => [_target],
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('create-blank-document')));
    await tester.pump();
    final overlay = navigator.currentState!.push<void>(
      MaterialPageRoute(builder: (_) => const Scaffold(body: Text('其他页面'))),
    );
    await tester.pumpAndSettle();
    response.complete('server-doc');
    await tester.pumpAndSettle();
    expect(find.text('其他页面'), findsOneWidget);
    expect(api.creates, 1);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    await overlay;
    expect(find.text('打开文档'), findsOneWidget);
    expect(
      (tester.widget<DropdownButtonFormField<String>>(
        find.byKey(const ValueKey('creation-target')),
      )).onChanged,
      isNull,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('320 width large text keeps creation action reachable', (tester) async {
    await coordinator.restore();
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(2)),
          child: child!,
        ),
        home: DocumentCreationPage(
          loadDocuments: _emptyDocuments,
          coordinator: coordinator,
          loadTargets: () async => [
            const DocumentCreationTarget(id: 'space', name: '个人空间名称较长用于窄屏验证'),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('create-blank-document')));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('unknown result requires explicit review and never creates when ending the record', (
    tester,
  ) async {
    store.value = _operation(DocumentCreationStage.createUnknown);
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(2)),
          child: child!,
        ),
        home: DocumentCreationPage(
          loadDocuments: _emptyDocuments,
          coordinator: coordinator,
          loadTargets: () async => [_target],
        ),
      ),
    );
    await tester.pumpAndSettle();
    final action = find.byKey(const ValueKey('create-blank-document'));
    expect(tester.widget<TextButton>(action).onPressed, isNull);
    final reviewed = find.byKey(const ValueKey('creation-result-reviewed'));
    await tester.ensureVisible(reviewed);
    await tester.pumpAndSettle();
    await tester.tap(reviewed);
    await tester.pumpAndSettle();
    final finish = find.byKey(const ValueKey('finish-reviewed-creation'));
    await tester.ensureVisible(finish);
    await tester.pumpAndSettle();
    await tester.tap(finish);
    await tester.pumpAndSettle();
    expect(coordinator.pending, isFalse);
    expect(api.creates, 0);
    expect(api.writes, 0);
    expect(find.byKey(const ValueKey('creation-target')), findsOneWidget);
    expect(find.text('文档列表'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

const _target = DocumentCreationTarget(id: 'space', name: '个人空间');

/// 使用[id]/[paragraph]生成协议快照，模拟原生边界，不替代原生互通回归。
PreparedDocument _prepared(String id, String paragraph) => PreparedDocument.fromSnapshotJson(
  jsonEncode({
    'id': id,
    'flavour': 'root',
    'nodeType': 'root',
    'props': <String, dynamic>{},
    'meta': {
      'createdTime': 1792584000000,
      'lastModified': {'time': 1792584000000, 'user': null},
    },
    'children': [
      {
        'id': paragraph,
        'flavour': 'paragraph',
        'nodeType': 'editable',
        'props': {'depth': 0},
        'meta': <String, dynamic>{},
        'children': <dynamic>[],
      },
    ],
  }),
);

/// 构造[stage]恢复记录，[documentId]为可选已知建档ID。
DocumentCreationOperation _operation(DocumentCreationStage stage, {String? documentId}) =>
    DocumentCreationOperation(
      operationId: 'operation',
      paragraphId: 'paragraph',
      createdAt: 1792584000000,
      target: _target,
      stage: stage,
      documentId: documentId,
    );

/// 记录持久化顺序并允许模拟损坏文件。
class _Store implements DocumentCreationStore {
  /// 最近真正写入的恢复记录，与协调器内存中的已知结果分开核对。
  DocumentCreationOperation? value;

  /// 读取损坏记录的故障开关。
  bool readFailure = false;

  /// 实际读取次数，用于验证并发恢复共享任务。
  int reads = 0;

  /// 在指定阶段提交前模拟磁盘失败，null表示正常写入。
  DocumentCreationStage? failStage;

  /// 已落盘阶段的顺序，用于验证先记录再发外部写入。
  final stages = <DocumentCreationStage>[];

  /// 读取保存值，故障时模拟JSON损坏。
  @override
  Future<DocumentCreationOperation?> read() async {
    reads++;
    if (readFailure) throw const FormatException('broken');
    return value;
  }

  /// 记录[operation]推进顺序，供检查外部写入前的durable阶段。
  @override
  Future<void> write(DocumentCreationOperation operation) async {
    if (operation.stage == failStage) throw FileSystemException('disk full');
    value = operation;
    stages.add(operation.stage);
  }
}

/// 可暂停请求的业务端口，用于验证真实协调器状态机。
class _Api implements DocumentCreationApi {
  /// 已核验的已有文档ID，普通打开不得触发建档或正文写入。
  final openedDocuments = <String>[];

  /// 可暂停访问核验，由测试负责完成。
  Completer<void>? openVerification;

  /// 模拟文档已删除、拒绝访问或传输失败。
  Object? openFailure;

  /// 验证[documentId]的访问结果；检查仍绑定同一测试账号。
  @override
  Future<void> verifyDocumentToOpen(String documentId) async {
    checkSession();
    openedDocuments.add(documentId);
    final gate = openVerification;
    if (gate != null) await gate.future;
    if (openFailure != null) throw openFailure!;
  }

  /// 当前模拟账号是否仍有效。
  bool valid = true;

  /// 业务建档请求次数。
  int creates = 0;

  /// 初始快照写入请求次数。
  int writes = 0;

  /// 快照回读次数。
  int reads = 0;

  /// 目标权限预检次数。
  int verifies = 0;

  /// 建档请求的可选模拟异常。
  Object? createFailure;

  /// 快照写入的可选模拟异常。
  Object? writeFailure;

  /// 由当前测试完成的暂停建档响应，不拥有真实网络连接。
  Completer<String>? creation;

  /// 最近一次待写入快照，用于核对稳定段落ID。
  PreparedDocument? lastPrepared;

  /// 模拟服务端回读结果，不隐式产生写入。
  InitialSnapshotState readState = InitialSnapshotState.matches;

  /// 模拟账号切换后的同步门禁。
  @override
  void checkSession() {
    if (!valid) throw const FormatException('账号变化');
  }

  /// 返回真实位置替身。
  @override
  Future<List<DocumentCreationTarget>> loadTargets() async => [_target];

  /// 记录[target]预检，账号变化拒绝后续操作。
  @override
  Future<void> verifyTarget(DocumentCreationTarget target) async {
    checkSession();
    verifies++;
  }

  /// 返回[target]的新ID，支持暂停和抛错模拟不确定结果。
  @override
  Future<String> createBlank(DocumentCreationTarget target) async {
    creates++;
    if (createFailure != null) throw createFailure!;
    return creation == null ? 'server-doc' : await creation!.future;
  }

  /// 保存[prepared]供断言；可模拟明确拒绝或网络中断。
  @override
  Future<void> writeInitial(PreparedDocument prepared) async {
    writes++;
    lastPrepared = prepared;
    if (writeFailure != null) throw writeFailure!;
  }

  /// 记录[prepared]回读，不隐式产生写入。
  @override
  Future<InitialSnapshotState> readInitial(PreparedDocument prepared) async {
    reads++;
    return readState;
  }
}

/// 为[target]的第[pageNumber]页提供隔离空列表，不伪造正式文档。
Future<DocumentListPage> _emptyDocuments(DocumentCreationTarget target, int pageNumber) async =>
    DocumentListPage(items: [], totalCount: 0, pageNumber: pageNumber, pageSize: 20);
