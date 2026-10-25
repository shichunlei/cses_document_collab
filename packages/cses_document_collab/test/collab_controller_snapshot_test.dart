import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:cses_document_collab/src/editor/editor_shortcut_toolbar.dart';
import 'package:cses_document_collab/src/model/collab_inline_formula.dart';
import 'package:cses_document_collab/src/model/collab_paragraph_style.dart';
import 'package:cses_document_collab/src/native/api/collab.dart' as native;
import 'package:cses_document_collab/src/native/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';

/// 通过真实控制器、FRB及临时SQLite覆盖同文本/同分段的本地写入、间距及远端投影。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        File(
          'rust/target/debug/libcses_collab_core.${Platform.isMacOS ? 'dylib' : 'so'}',
        ).absolute.path,
      ),
    );
  });

  testWidgets('native spacing menus remain usable after projection and reset', (
    tester,
  ) async {
    final source = (await tester.runAsync(
      () => _SnapshotFixture.open('spacing'),
    ))!;
    final state = source.controller.editorState;
    state.selection = Selection.single(
      path: [0],
      startOffset: 0,
      endOffset: state.document.first!.delta!.length,
    );
    try {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: const [AppFlowyEditorLocalizations.delegate],
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async =>
                    showEditorSelectionFormats(context, state),
                child: const Text('Formats'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Formats'));
      await tester.pumpAndSettle();
      final lineButton = find.byKey(const ValueKey('editor-block-line-height'));
      await tester.ensureVisible(lineButton);
      await tester.tap(lineButton);
      await tester.pumpAndSettle();
      final lineValue = find.byKey(const ValueKey('editor-line-height-1.75'));
      await tester.ensureVisible(lineValue);
      await tester.tap(lineValue);
      await tester.runAsync(() async {
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pumpAndSettle();
      expect(
        jsonDecode(
          native.currentBlocks().first.paragraphStyle!.properties,
        )['lh'],
        1.75,
      );
      final lineDefault = find.byKey(
        const ValueKey('editor-line-height-default'),
      );
      expect(tester.widget<Semantics>(lineDefault).properties.enabled, isTrue);
      await tester.tap(find.byKey(const ValueKey('editor-line-height-back')));
      await tester.pumpAndSettle();
      final spacingButton = find.byKey(
        const ValueKey('editor-inline-letter-spacing'),
      );
      await tester.ensureVisible(spacingButton);
      await tester.tap(spacingButton);
      await tester.pumpAndSettle();
      final spacingValue = find.byKey(
        const ValueKey('editor-letter-spacing-0.1'),
      );
      await tester.ensureVisible(spacingValue);
      await tester.tap(spacingValue);
      await tester.runAsync(() async {
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pumpAndSettle();
      _expectNative('spacing');
      final spacingDefault = find.byKey(
        const ValueKey('editor-letter-spacing-default'),
      );
      expect(
        tester.widget<Semantics>(spacingDefault).properties.enabled,
        isTrue,
      );
      await tester.tap(spacingDefault);
      await tester.runAsync(() async {
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pumpAndSettle();
      expect(
        jsonDecode(
          native.currentBlocks().first.segments.first.typography!,
        )['t:ls'],
        isNull,
      );
      expect(
        tester.widget<Semantics>(spacingDefault).properties.selected,
        isTrue,
      );
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(source.close);
    }
  });

  for (final mode in [
    'paragraph',
    'typography',
    'typography-reset',
    'spacing',
    'spacing-reset',
    'href',
    'formula',
  ]) {
    test(
      '$mode-only changes persist, reopen and project remotely without echo',
      () async {
        final source = await _SnapshotFixture.open(mode);
        Uint8List update;
        try {
          final vector = native.encodeStateVector();
          final beforeText = native.currentBlocks().first.text;
          final beforeTypography = native
              .currentBlocks()
              .first
              .segments
              .map((segment) => segment.typography)
              .toList();
          await _editSnapshot(source.controller.editorState, mode);
          await Future<void>.delayed(Duration.zero);
          _expectNative(mode);
          expect(native.currentBlocks().first.text, beforeText);
          if (mode == 'spacing' || mode == 'spacing-reset') {
            expect(source.controller.canUndo, isTrue);
            await source.controller.undo();
            if (mode == 'spacing-reset') {
              expect(
                jsonDecode(
                  native.currentBlocks().first.segments.first.typography!,
                )['t:ls'],
                .1,
              );
            }
            await source.controller.redo();
            _expectNative(mode);
          } else if (mode == 'typography') {
            expect(source.controller.canUndo, isTrue);
            await source.controller.undo();
            expect(
              native.currentBlocks().first.segments.map(
                (segment) => segment.typography,
              ),
              beforeTypography,
            );
            await source.controller.redo();
            _expectNative(mode);
          } else if (mode == 'typography-reset') {
            expect(source.controller.canUndo, isTrue);
            await source.controller.undo();
            _expectNative('typography');
            await source.controller.redo();
            _expectNative(mode);
          }
          update = native.encodeDocumentDiff(stateVector: vector);
          expect(update, isNot([0, 0]));
          await source.reopen();
          _expectNative(mode);
          _expectEditor(source.controller.editorState, mode);
        } finally {
          await source.close();
        }

        final target = await _SnapshotFixture.open(mode);
        try {
          final sent = target.gateway.updates;
          target.gateway.receive('collabUpdate', {
            'data': base64Encode(update),
          });
          await Future<void>.delayed(Duration.zero);
          _expectNative(mode);
          _expectEditor(target.controller.editorState, mode);
          expect(
            target.gateway.updates,
            sent,
            reason: 'Remote projection must not echo a local write.',
          );
          target.gateway.receive('collabUpdate', {
            'data': base64Encode(update),
          });
          await Future<void>.delayed(Duration.zero);
          expect(target.gateway.updates, sent);
        } finally {
          await target.close();
        }
      },
    );
  }
}

/// 在借用的[state]中按[mode]修改元数据；字号/间距及恢复默认复用字段命令，保留文字和分段范围。
Future<void> _editSnapshot(EditorState state, String mode) async {
  final node = state.document.first!;
  state.selection = Selection.single(
    path: node.path,
    startOffset: 0,
    endOffset: node.delta!.length,
  );
  if (mode == 'spacing' || mode == 'spacing-reset') {
    await setCollabParagraphLineHeight(state, 1.75);
    await Future<void>.delayed(Duration.zero);
    await formatCollabParagraphSelection(state, state.selection!, {'t:ls': .1});
    if (mode == 'spacing-reset') {
      await Future<void>.delayed(Duration.zero);
      await setCollabParagraphLineHeight(state, null);
      await Future<void>.delayed(Duration.zero);
      if (state.undoManager.undoStack.isNonEmpty) {
        state.undoManager.undoStack.last.seal();
      }
      await formatCollabParagraphSelection(state, state.selection!, {
        't:ls': null,
        's:letterSpacing': null,
      });
    }
  } else if (mode == 'paragraph') {
    expect(await setCollabNextParagraphStyle(state, 'same'), isTrue);
  } else if (mode == 'formula') {
    final offset = node.delta!.toPlainText().indexOf(
      collabInlineFormulaCharacter,
    );
    final target = CollabInlineFormulaTarget.capture(node, offset)!;
    expect(
      await changeCollabInlineFormula(
        state,
        target,
        'y^2',
        expectedLatex: collabInlineLatexAt(node, offset)!,
      ),
      isTrue,
    );
  } else if (mode == 'typography-reset') {
    await formatCollabParagraphSelection(state, state.selection!, {
      't:px': 28,
      's:fontSize': '30px',
    });
    await Future<void>.delayed(Duration.zero);
    _expectNative('typography');
    if (state.undoManager.undoStack.isNonEmpty) {
      state.undoManager.undoStack.last.seal();
    }
    await formatCollabParagraphSelection(state, state.selection!, {
      't:px': null,
      's:fontSize': null,
    });
  } else if (mode == 'typography') {
    await formatCollabParagraphSelection(state, state.selection!, {'t:px': 28});
  } else {
    await state.apply(
      state.transaction..formatText(node, 0, node.delta!.length, {
        if (mode == 'href')
          AppFlowyRichTextKeys.href: 'https://review.example/',
      }),
    );
  }
}

/// 核对当前原生文档中[mode]对应的权威属性，避免只断言界面回显。
void _expectNative(String mode) {
  final block = native.currentBlocks().first;
  switch (mode) {
    case 'spacing':
    case 'spacing-reset':
      expect(
        jsonDecode(block.paragraphStyle?.properties ?? '{}')['lh'],
        mode == 'spacing' ? 1.75 : null,
      );
      expect(
        jsonDecode(block.segments.first.typography ?? '{}')['t:ls'],
        mode == 'spacing' ? .1 : null,
      );
    case 'paragraph':
      expect(
        jsonDecode(
          block.paragraphStyle?.properties ?? '{}',
        )['nextParagraphStyle'],
        'same',
      );
    case 'typography':
      expect(jsonDecode(block.segments.first.typography!)['t:px'], 28);
    case 'typography-reset':
      expect(
        block.segments.every((segment) {
          final attributes =
              jsonDecode(segment.typography ?? '{}') as Map<String, dynamic>;
          return attributes['t:px'] == null && attributes['s:fontSize'] == null;
        }),
        isTrue,
      );
    case 'href':
      expect(block.segments.first.href, 'https://review.example/');
    case 'formula':
      expect(
        block.segments.firstWhere((s) => s.inlineLatex != null).inlineLatex,
        'y^2',
      );
  }
}

/// 核对借用[state]中的[mode]属性，覆盖控制器去重之后的真实编辑器投影。
void _expectEditor(EditorState state, String mode) {
  final node = state.document.first!;
  switch (mode) {
    case 'spacing':
    case 'spacing-reset':
      expect(
        readCollabParagraph(node).values['lh'],
        mode == 'spacing' ? 1.75 : null,
      );
      expect(
        node.delta!.first.attributes?['t:ls'],
        mode == 'spacing' ? .1 : null,
      );
    case 'paragraph':
      expect(readCollabParagraph(node).values['nextParagraphStyle'], 'same');
    case 'typography':
      expect(node.delta!.first.attributes!['t:px'], 28);
    case 'typography-reset':
      expect(
        node.delta!.everyAttributes(
          (attributes) =>
              attributes['t:px'] == null && attributes['s:fontSize'] == null,
        ),
        isTrue,
      );
    case 'href':
      expect(
        node.delta!.first.attributes![AppFlowyRichTextKeys.href],
        'https://review.example/',
      );
    case 'formula':
      expect(
        collabInlineLatexAt(
          node,
          node.delta!.toPlainText().indexOf(collabInlineFormulaCharacter),
        ),
        'y^2',
      );
  }
}

/// 拥有临时数据库、控制器和测试网关；重开保留缓存，关闭统一释放。
class _SnapshotFixture {
  /// [directory]为自有临时目录，[gateway]为自有替身，[config]为固定缓存身份。
  _SnapshotFixture(this.directory, this.gateway, this.config);

  /// 本实例独占的临时目录，关闭后递归移除。
  final Directory directory;

  /// 本实例独占的网关替身，控制器仅借用它。
  final _SnapshotGateway gateway;

  /// 重开时保留的固定身份和SQLite路径。
  final CollabDocumentConfig config;

  /// 当前独占的控制器，重开前等待旧实例关闭。
  late CollabController controller;

  /// 创建[mode]对应样本文档；完成真实握手后返回，失败释放已创建资源。
  static Future<_SnapshotFixture> open(String mode) async {
    final directory = await Directory.systemTemp.createTemp(
      'snapshot-regression-',
    );
    final fixture = _SnapshotFixture(
      directory,
      _SnapshotGateway(),
      CollabDocumentConfig(
        documentId: 'fixture-doc',
        serverIdentity: 'wss://fixture.test/ws',
        companyId: 'company',
        userId: 'user',
        databasePath: '${directory.path}/updates.sqlite',
        editable: true,
      ),
    );
    fixture.controller = CollabController.cses(
      config: fixture.config,
      gateway: fixture.gateway,
    );
    try {
      await fixture.controller.initialize();
      final name = mode == 'formula' ? 'inline-formula' : 'basic';
      fixture.gateway.receive('collabSync', {
        'data': base64Encode(
          await File(
            'rust/tests/fixtures/blockcraft-$name.update',
          ).readAsBytes(),
        ),
        'stateVector': base64Encode([0]),
      });
      await Future<void>.delayed(Duration.zero);
      fixture.controller.editorState.editable = fixture.controller.canEdit;
      return fixture;
    } catch (_) {
      await fixture.close();
      rethrow;
    }
  }

  /// 等待旧控制器释放后从同一路径恢复，不重新注入服务器样本。
  Future<void> reopen() async {
    await controller.close();
    controller = CollabController.cses(config: config, gateway: gateway);
    await controller.initialize();
    controller.editorState.editable = controller.canEdit;
  }

  /// 等待控制器关闭后释放网关流并移除自有目录，不触碰宿主数据。
  Future<void> close() async {
    await controller.close();
    await gateway.close();
    await directory.delete(recursive: true);
  }
}

/// 本地同步路由替身，不创建Socket；拥有并关闭自己的事件流。
class _SnapshotGateway implements CsesCollabGateway {
  /// 自有连接事件流，由[close]统一关闭。
  final _events = StreamController<bool>.broadcast();

  /// 当前文档借出的回调，注销后清空。
  Map<String, void Function(Map<String, dynamic>)> _callbacks = {};

  /// 已提交的正文上行数量，不将握手或Awareness计入。
  int updates = 0;

  /// 测试传输始终可用。
  @override
  bool get isConnected => true;

  /// 借出连接流，订阅由会话自行释放。
  @override
  Stream<bool> get connectionStates => _events.stream;

  /// 借用[pageId]/[documentId]/[instanceId]对应的[callbacks]，不启动网络。
  @override
  Future<void> register({
    required String pageId,
    required String documentId,
    required String instanceId,
    required Map<String, void Function(Map<String, dynamic>)> callbacks,
  }) async {
    _callbacks = callbacks;
  }

  /// 记录[pageId]的[action]/[body]发送；测试中始终立即成功。
  @override
  bool send(String pageId, String action, Map<String, dynamic> body) {
    if (action == 'collabUpdate') updates++;
    return true;
  }

  /// 清除借给[pageId]的路由，不关闭共享连接。
  @override
  Future<void> unregister(String pageId) async => _callbacks = {};

  /// 按[action]向当前会话交付[body]，模拟精确路由事件。
  void receive(String action, Map<String, dynamic> body) =>
      _callbacks[action]!(body);

  /// 关闭自有事件流；允许控制器重开期间继续借用同一网关。
  Future<void> close() => _events.close();
}
