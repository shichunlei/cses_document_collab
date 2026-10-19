import 'dart:async';

import 'package:cses_document_collab/src/controller/collab_controller.dart';
import 'package:cses_document_collab/src/model/collab_document_config.dart';
import 'package:cses_document_collab/src/model/collab_host_services.dart';
import 'package:cses_document_collab/src/sync/cses_collab_gateway.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/editor/collab_block_actions.dart';
import 'package:cses_document_collab/src/editor/collab_paragraph_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 不连接网络的借用网关；构造/关闭未初始化控制器不应调用任何网关能力。
class _UnusedGateway implements CsesCollabGateway {
  /// 对借用[invocation]保留默认失败行为，暴露意外网络访问。
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 验证正式文档身份、过期菜单、块锁和平台失败，不写入协同正文或历史。
void main() {
  test(
    'controller binds formal identity and invalidates on close; draft has no share link',
    () async {
      final services = CollabHostServices(
        buildParagraphLink: (doc, block) => '$doc/$block',
      );
      final formal = CollabController.cses(
        config: const CollabDocumentConfig(
          documentId: 'formal',
          serverIdentity: 'wss://example.test',
          companyId: 'company',
          userId: 'user',
          databasePath: '/unused',
        ),
        gateway: _UnusedGateway(),
        services: services,
      );
      expect(CollabParagraphLinks.of(formal.editorState)?.documentId, 'formal');
      final close = formal.close();
      expect(CollabParagraphLinks.of(formal.editorState), isNull);
      await close;
      final draft = CollabController.localDraft(
        databasePath: '/unused',
        services: services,
      );
      expect(CollabParagraphLinks.of(draft.editorState), isNull);
      await draft.close();
    },
  );

  for (final invalidate in ['close', 'revokeRestore']) {
    testWidgets(
      'late clipboard completion after $invalidate has no success feedback',
      (tester) async {
        final write = Completer<void>();
        var started = false;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              started = true;
              await write.future;
            }
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        final adapter = AppFlowyBlockEditorAdapter(
          initialBlocks: const [
            CollabEditorBlock(id: 'a', blockType: 'code', text: 'original'),
          ],
          onLocalBlocksChanged: (_) => fail('copy wrote content'),
        );
        addTearDown(adapter.dispose);
        final editor = adapter.editorState;
        final links = CollabParagraphLinks(
          editor: editor,
          documentId: 'formal',
          buildLink: (doc, block) =>
              'https://example.test/doc/$doc?blockId=$block',
        );
        addTearDown(links.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: CollabBlockMoreButton(
                editor: editor,
                node: editor.document.first!,
              ),
            ),
          ),
        );
        await tester.tap(find.byTooltip('更多操作'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('block-copy-paragraph-link-a')),
        );
        await tester.pumpAndSettle();
        expect(started, isTrue);
        if (invalidate == 'close') {
          links.dispose();
        } else {
          editor.editable = false;
          editor.editable = true;
        }
        write.complete();
        await tester.pumpAndSettle();
        expect(find.text('段落链接已复制'), findsNothing);
        expect(editor.undoManager.undoStack, isEmpty);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final scenario in [
    'normal',
    'nested',
    'preview',
    'reorder',
    'delete',
    'changed',
    'revokeRestore',
    'closed',
    'cancel',
    'failure',
    'unconfigured',
  ]) {
    testWidgets('paragraph link respects $scenario lifetime', (tester) async {
      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            if (scenario == 'failure') throw PlatformException(code: 'denied');
            copied.add((call.arguments as Map)['text'] as String);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final blocks = [
        if (scenario == 'nested')
          const CollabEditorBlock(id: 'outer', blockType: 'callout', text: ''),
        CollabEditorBlock(
          id: 'block-1',
          parentId: scenario == 'nested' ? 'outer' : null,
          blockType: 'code',
          text: '原内容',
        ),
        const CollabEditorBlock(
          id: 'tail',
          blockType: 'paragraph',
          text: '后续正文',
        ),
      ];
      final adapter = AppFlowyBlockEditorAdapter(
        initialBlocks: blocks,
        onLocalBlocksChanged: (_) => fail('copy wrote content'),
      );
      addTearDown(adapter.dispose);
      final editor = adapter.editorState;
      final links = scenario == 'unconfigured'
          ? null
          : CollabParagraphLinks(
              editor: editor,
              documentId: 'formal-doc',
              buildLink: (doc, block) => Uri.http(
                'doc-pre.cses7.com',
                '/doc/$doc',
                {'blockId': block},
              ).toString(),
            );
      addTearDown(() => links?.dispose());
      if (scenario == 'preview') editor.editable = false;
      final node = findCollabActionNode(editor, 'block-1')!;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CollabBlockMoreButton(
              editor: editor,
              node: node,
              readOnlyActions: [(label: '只读操作', key: null, run: () async {})],
            ),
          ),
        ),
      );
      await tester.tap(find.byTooltip('更多操作'));
      await tester.pumpAndSettle();
      final copy = find.byKey(
        const ValueKey('block-copy-paragraph-link-block-1'),
      );
      if (scenario == 'unconfigured') {
        expect(copy, findsNothing);
        await tester.tap(find.byTooltip('关闭'));
      } else {
        expect(copy, findsOneWidget);
        if (scenario == 'reorder') {
          await adapter.replaceFromRemote(blocks.reversed.toList());
        }
        if (scenario == 'delete') {
          await adapter.replaceFromRemote([blocks.last]);
        }
        if (scenario == 'changed') {
          await adapter.replaceFromRemote([
            const CollabEditorBlock(
              id: 'block-1',
              blockType: 'code',
              text: '远端变化',
            ),
            blocks.last,
          ]);
        }
        if (scenario == 'revokeRestore') {
          editor.editable = false;
          editor.editable = true;
        }
        if (scenario == 'closed') links!.dispose();
        await tester.pumpAndSettle();
        await tester.tap(scenario == 'cancel' ? find.byTooltip('关闭') : copy);
      }
      await tester.pumpAndSettle();
      final succeeds = [
        'normal',
        'nested',
        'preview',
        'reorder',
      ].contains(scenario);
      expect(
        copied,
        succeeds
            ? ['http://doc-pre.cses7.com/doc/formal-doc?blockId=block-1']
            : isEmpty,
      );
      expect(editor.undoManager.undoStack, isEmpty);
      if (succeeds) expect(find.text('段落链接已复制'), findsOneWidget);
      if (scenario == 'failure') expect(find.text('操作失败，请重试'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    });
  }
}
