import 'dart:async';
import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:flutter_test/flutter_test.dart';

/// 根据测试名称 [name] 和权限 [editable] 创建固定文档快照；不使用网络或正文。
DocumentMetadata metadata({String name = '桌面标题', bool editable = true}) =>
    DocumentMetadata(
      id: 'doc',
      name: name,
      icon: {'type': 'emoji', 'value': '😘'},
      banner: {
        'url': 'https://example.test/cover.png',
        'y': 30,
        'x': 7,
        'title': '封面',
      },
      canRename: editable,
      canChangeAppearance: editable,
    );

/// 可控制读取/写入延迟的测试业务端口，记录命令但不拥有网络资源。
class _Service implements DocumentMetadataService {
  Future<DocumentMetadata> Function() read = () async => metadata();
  Future<void> Function() write = () async {};
  final patches = <DocumentMetadataPatch>[];
  int loads = 0;

  /// 记录 [id] 的读取次数并调用测试提供的读取行为；Future完成/异常由测试控制。
  @override
  Future<DocumentMetadata> load(String id) {
    loads++;
    return read();
  }

  /// 记录固定文档 [id] 的 [patch]，写入成功/失败或延迟由测试提供的行为控制。
  @override
  Future<void> update(String id, DocumentMetadataPatch patch) {
    patches.add(patch);
    return write();
  }
}

/// 注册业务控制器回归，逐例创建并关闭控制器；异步结果由测试框架验证。
void main() {
  late _Service service;
  late DocumentMetadataController controller;
  bool editable = true;
  setUp(() {
    editable = true;
    service = _Service();
    controller = DocumentMetadataController(
      documentId: 'doc',
      service: service,
      canEdit: () => editable,
      services: CollabHostServices(onError: (_, _, _, _) {}),
    );
  });
  tearDown(() => controller.close());
  for (final writeSucceeds in [true, false]) {
    for (final readSucceeds in [true, false]) {
      test(
        'conflict reload preserves write outcome (write=$writeSucceeds, read=$readSucceeds)',
        () async {
          await controller.refresh();
          final ack = Completer<void>();
          service.write = () => ack.future;
          service.read = () async {
            if (!readSucceeds) throw StateError('reload offline');
            return metadata(name: '权威名称');
          };
          final saving = controller.save(
            const DocumentMetadataPatch.rename('本地草稿'),
          );
          controller.applyRemotePatch(
            'doc',
            const DocumentMetadataPatch.rename('远端名称'),
          );
          if (writeSucceeds) {
            ack.complete();
          } else {
            ack.completeError(StateError('write rejected'));
          }
          expect(await saving, writeSucceeds);
          expect(
            controller.error,
            !writeSucceeds
                ? '头部保存失败，请重试'
                : readSucceeds
                ? isNull
                : '头部加载失败，请重试',
          );
          expect(controller.value!.name, readSucceeds ? '权威名称' : '远端名称');
          expect(controller.saving, isFalse);
          expect(controller.loading, isFalse);
          expect(service.loads, 2);
          service.read = () async => metadata(name: '重试读取');
          await controller.refresh();
          expect(controller.error, isNull);
        },
      );
    }
  }
  for (final initialLoad in [true, false]) {
    test(
      'failed read drops buffered patches before retry (initial=$initialLoad)',
      () async {
        if (!initialLoad) await controller.refresh();
        final pending = Completer<DocumentMetadata>();
        service.read = () => pending.future;
        final reading = controller.refresh();
        controller.applyRemotePatch(
          'doc',
          const DocumentMetadataPatch.rename('旧推送'),
        );
        controller.applyRemotePatch(
          'doc',
          const DocumentMetadataPatch.icon(null),
        );
        controller.applyRemotePatch(
          'doc',
          const DocumentMetadataPatch.banner(null),
        );
        pending.completeError(StateError('offline'));
        await reading;
        service.read = () async => metadata(name: '更新的HTTP');
        await controller.refresh();
        expect(controller.value!.name, '更新的HTTP');
        expect(controller.value!.icon, isNotNull);
        expect(controller.value!.banner, isNotNull);
      },
    );
  }
  for (final icon in [true, false]) {
    for (final remove in [true, false]) {
      test(
        'appearance conflict reloads after ACK (icon=$icon, remove=$remove)',
        () async {
          await controller.refresh();
          final ack = Completer<void>();
          service.write = () => ack.future;
          service.read = () async => metadata(name: '权威快照');
          final saving = controller.save(
            icon
                ? const DocumentMetadataPatch.icon({'value': '本地'})
                : const DocumentMetadataPatch.banner({'url': 'local'}),
          );
          controller.applyRemotePatch(
            'doc',
            icon
                ? DocumentMetadataPatch.icon(remove ? null : {'value': '远端'})
                : DocumentMetadataPatch.banner(
                    remove ? null : {'url': 'remote'},
                  ),
          );
          ack.complete();
          expect(await saving, isTrue);
          expect(controller.value!.name, '权威快照');
          expect(controller.value!.icon!['value'], '😘');
          expect(controller.value!.banner!['y'], 30);
          expect(service.loads, 2);
        },
      );
    }
  }
  test(
    'conflict read holds save lock and close waits for its response',
    () async {
      await controller.refresh();
      final ack = Completer<void>();
      final readStarted = Completer<void>();
      final reread = Completer<DocumentMetadata>();
      service.write = () => ack.future;
      service.read = () {
        readStarted.complete();
        return reread.future;
      };
      final saving = controller.save(const DocumentMetadataPatch.rename('本地'));
      controller.applyRemotePatch(
        'doc',
        const DocumentMetadataPatch.rename('远端'),
      );
      ack.complete();
      await readStarted.future;
      expect(controller.saving, isTrue);
      expect(
        await controller.save(const DocumentMetadataPatch.rename('第二次')),
        isFalse,
      );
      expect(service.patches, hasLength(1));
      var closed = false;
      final closing = controller.close().then((_) => closed = true);
      await Future<void>.delayed(Duration.zero);
      expect(closed, isFalse);
      reread.complete(metadata(name: '迟到快照'));
      expect(await saving, isFalse);
      await closing;
      expect(controller.value!.name, '远端');
    },
  );
  test('completion listener cannot lose tracking of the next write', () async {
    await controller.refresh();
    final secondAck = Completer<void>();
    Future<bool>? second;
    var started = false;

    /// 在首轮结束通知中提交下一轮，验证任务清理不会覆盖新写入的所有权。
    void onChanged() {
      if (!controller.saving && !started) {
        started = true;
        service.write = () => secondAck.future;
        second = controller.save(const DocumentMetadataPatch.rename('第二次'));
      }
    }

    controller.addListener(onChanged);
    await controller.save(const DocumentMetadataPatch.rename('第一次'));
    controller.removeListener(onChanged);
    var closed = false;
    final closing = controller.close().then((_) => closed = true);
    await Future<void>.delayed(Duration.zero);
    expect(closed, isFalse);
    secondAck.complete();
    expect(await second!, isFalse);
    await closing;
  });
  test(
    'remote patch wins over an older read without writing or granting permission',
    () async {
      await controller.refresh();
      final pending = Completer<DocumentMetadata>();
      service.read = () => pending.future;
      final reading = controller.refresh();
      controller.applyRemotePatch(
        'doc',
        const DocumentMetadataPatch.rename('远端新名'),
      );
      pending.complete(metadata(name: '旧HTTP标题'));
      await reading;
      expect(controller.value!.name, '远端新名');
      expect(service.patches, isEmpty);
      editable = false;
      controller.applyRemotePatch(
        'doc',
        const DocumentMetadataPatch.rename('只读也更新'),
      );
      expect(controller.value!.name, '只读也更新');
      controller.applyRemotePatch(
        'other',
        const DocumentMetadataPatch.rename('另一文档'),
      );
      expect(controller.value!.name, '只读也更新');
    },
  );
  test(
    'remote patch received during first load is replayed and close ignores updates',
    () async {
      final pending = Completer<DocumentMetadata>();
      service.read = () => pending.future;
      final reading = controller.refresh();
      controller.applyRemotePatch(
        'doc',
        const DocumentMetadataPatch.rename('首载期间改名'),
      );
      pending.complete(metadata());
      await reading;
      expect(controller.value!.name, '首载期间改名');
      await controller.close();
      controller.applyRemotePatch(
        'doc',
        const DocumentMetadataPatch.rename('关闭后'),
      );
      expect(controller.value!.name, '首载期间改名');
    },
  );
  test(
    'remote rename during write triggers one authoritative read after ACK',
    () async {
      await controller.refresh();
      final pending = Completer<void>();
      service.write = () => pending.future;
      service.read = () async => metadata(name: '服务端最终名');
      final saving = controller.save(
        const DocumentMetadataPatch.rename('本地提交'),
      );
      controller.applyRemotePatch(
        'doc',
        const DocumentMetadataPatch.rename('并发远端'),
      );
      pending.complete();
      expect(await saving, isTrue);
      expect(controller.value!.name, '服务端最终名');
      expect(service.loads, 2);
    },
  );
  test(
    'ACK updates only selected field; failure retains old value and permits retry',
    () async {
      await controller.refresh();
      final pending = Completer<void>();
      service.write = () => pending.future;
      final saving = controller.save(const DocumentMetadataPatch.rename('新标题'));
      expect(controller.value!.name, '桌面标题');
      expect(controller.saving, isTrue);
      expect(
        await controller.save(const DocumentMetadataPatch.icon(null)),
        isFalse,
      );
      pending.completeError(StateError('offline'));
      expect(await saving, isFalse);
      expect(controller.value!.name, '桌面标题');
      service.write = () async {};
      expect(
        await controller.save(const DocumentMetadataPatch.rename('新标题')),
        isTrue,
      );
      expect(controller.value!.name, '新标题');
      expect(controller.value!.banner!['x'], 7);
      expect(controller.value!.icon!['value'], '😘');
    },
  );
  test(
    'host and business permissions both gate commands and blank titles are rejected',
    () async {
      await controller.refresh();
      editable = false;
      expect(
        await controller.save(const DocumentMetadataPatch.icon(null)),
        isFalse,
      );
      editable = true;
      expect(
        await controller.save(const DocumentMetadataPatch.rename('   ')),
        isFalse,
      );
      service.read = () async => metadata(editable: false);
      await controller.refresh();
      expect(
        await controller.save(const DocumentMetadataPatch.banner(null)),
        isFalse,
      );
      expect(service.patches, isEmpty);
    },
  );
  test(
    'stale refresh cannot overwrite later ACK; refresh remains retryable',
    () async {
      await controller.refresh();
      final pending = Completer<DocumentMetadata>();
      service.read = () => pending.future;
      final reading = controller.refresh();
      expect(identical(reading, controller.refresh()), isTrue);
      expect(
        await controller.save(const DocumentMetadataPatch.rename('已保存')),
        isTrue,
      );
      pending.complete(metadata(name: '旧响应'));
      await reading;
      expect(controller.value!.name, '已保存');
      expect(controller.loading, isFalse);
      service.read = () async => metadata(name: '桌面再次修改');
      await controller.refresh();
      expect(controller.value!.name, '桌面再次修改');
    },
  );
  test('close waits for active write and ignores late response', () async {
    await controller.refresh();
    final pending = Completer<void>();
    service.write = () => pending.future;
    final saving = controller.save(const DocumentMetadataPatch.icon(null));
    var closed = false;
    final closing = controller.close().then((_) => closed = true);
    await Future<void>.delayed(Duration.zero);
    expect(closed, isFalse);
    pending.complete();
    expect(await saving, isFalse);
    await closing;
    expect(controller.value!.icon, isNotNull);
    expect(
      await controller.save(const DocumentMetadataPatch.banner(null)),
      isFalse,
    );
  });
  test(
    'failed load shows retry state and mismatched identity is rejected',
    () async {
      service.read = () async => throw StateError('network');
      await controller.refresh();
      expect(controller.value, isNull);
      expect(controller.error, isNotNull);
      service.read = () async => DocumentMetadata(id: 'other', name: 'other');
      await controller.refresh();
      expect(controller.value, isNull);
      service.read = () async => metadata();
      await controller.refresh();
      expect(controller.error, isNull);
      expect(controller.value!.name, '桌面标题');
    },
  );
}
