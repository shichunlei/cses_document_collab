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
