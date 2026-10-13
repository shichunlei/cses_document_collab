import 'dart:convert';
import 'dart:io';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_mobile_collab_demo/src/collab/appflowy_block_editor_adapter.dart';
import 'package:cses_mobile_collab_demo/src/collab/collab_ordered.dart';
import 'package:cses_mobile_collab_demo/src/rust/api/collab.dart' as native;
import 'package:cses_mobile_collab_demo/src/rust/frb_generated.dart';
import 'package:cses_mobile_collab_demo/src/ui/collab_list_editing.dart';
import 'package:cses_mobile_collab_demo/src/ui/collab_block_delete.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

/// 将原生 [blocks] 转为列表投影，保留勾选、对齐及全部受支持行内格式；
/// 不连接真实文档或修改输入集合，返回无资源的测试数据。
List<CollabEditorBlock> _editorBlocks(List<native.CollabBlock> blocks) => [
  for (final block in blocks)
    CollabEditorBlock(
      id: block.id,
      blockType: block.blockType,
      text: block.text,
      checked: block.checked,
      alignment: block.alignment,
      segments: [
        for (final segment in block.segments)
          CollabEditorTextSegment(
            text: segment.text,
            bold: segment.bold,
            italic: segment.italic,
            underline: segment.underline,
            strikethrough: segment.strikethrough,
            code: segment.code,
            textColor: segment.textColor,
            backgroundColor: segment.backgroundColor,
            superscript: segment.superscript,
            subscript: segment.subscript,
          ),
      ],
      indent: block.indent,
      ordered: block.ordered == null
          ? null
          : CollabOrdered(
              order: block.ordered!.order,
              start: block.ordered!.start,
              heading: block.ordered!.heading,
              markerStyle: block.ordered!.markerStyle,
              needsRepair: block.ordered!.needsRepair,
              numbering: block.ordered!.numbering,
            ),
    ),
];

/// 将本地 [blocks] 的显式设置意图和类型转换来源传入实际 FRB；
/// 不模拟原生方法或 WS 编码，保留全部受支持行内格式；fixture 无媒体。
List<native.CollabBlock> _nativeBlocks(List<CollabEditorBlock> blocks) => [
  for (final block in blocks)
    native.CollabBlock(
      id: block.id,
      blockType: block.blockType,
      text: block.text,
      segments: [
        for (final segment in block.segments)
          native.CollabTextSegment(
            text: segment.text,
            bold: segment.bold,
            italic: segment.italic,
            underline: segment.underline,
            strikethrough: segment.strikethrough,
            code: segment.code,
            textColor: segment.textColor,
            backgroundColor: segment.backgroundColor,
            superscript: segment.superscript,
            subscript: segment.subscript,
          ),
      ],
      checked: block.checked,
      alignment: block.alignment,
      indent: block.indent,
      replacesId: block.replacesId,
      ordered: block.ordered == null
          ? null
          : native.CollabOrdered(
              order: block.ordered!.order,
              start: block.ordered!.start,
              heading: block.ordered!.heading,
              markerStyle: block.ordered!.markerStyle,
              needsRepair: block.ordered!.needsRepair,
              numbering: block.ordered!.numbering,
              numberingEdit: block.ordered!.numberingEdit,
            ),
    ),
];

/// 使用真实桥接和临时 SQLite 验证三种列表键盘事务、编号命令、撤销重做与持久化；
/// 没有宿主库时显式跳过，各测试不连接真实文档。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final path = Platform.isMacOS
      ? 'rust/target/debug/libcses_collab_core.dylib'
      : 'rust/target/debug/libcses_collab_core.so';
  final available = File(path).existsSync();
  setUpAll(() async {
    if (available) {
      await RustLib.init(
        externalLibrary: ExternalLibrary.open(File(path).absolute.path),
      );
    }
  });
  for (final source in ['numbered_list', 'bulleted_list', 'todo_list']) {
    for (final target in ['numbered_list', 'bulleted_list', 'todo_list']) {
      if (source == target) continue;
      test(
        'native type switch $source to $target preserves formats and restores settings',
        () async {
          final directory = await Directory.systemTemp.createTemp('list-type-');
          AppFlowyBlockEditorAdapter? adapter;
          try {
            final database = '${directory.path}/updates.sqlite';
            native.openCsesDocument(
              documentId: 'fixture-doc',
              cacheDocumentId: 'type-switch',
              databasePath: database,
            );
            native.applyDocumentUpdate(
              bytes: await File(
                'rust/tests/fixtures/blockcraft-ordered.update',
              ).readAsBytes(),
            );
            final fixture = _editorBlocks(native.currentBlocks());
            final original = fixture.singleWhere((b) => b.id == 'restart');
            native.applyBlockSnapshot(
              blocks: _nativeBlocks([
                fixture.first,
                const CollabEditorBlock(
                  id: 'same-depth-parent',
                  blockType: 'numbered_list',
                  text: 'parent',
                  indent: 3,
                ),
                CollabEditorBlock(
                  id: source == 'numbered_list' ? original.id : 'source-list',
                  replacesId: source == 'numbered_list' ? null : original.id,
                  blockType: source,
                  text: '正文🙂测试',
                  indent: 3,
                  alignment: 'right',
                  checked: source == 'todo_list',
                  ordered: source == 'numbered_list' ? original.ordered : null,
                  segments: const [
                    CollabEditorTextSegment(
                      text: '正文🙂测试',
                      bold: true,
                      italic: true,
                      underline: true,
                    ),
                  ],
                ),
              ]),
            );
            final before = _editorBlocks(native.currentBlocks()).last;
            final changes = <native.BlockChangeResult>[];
            adapter = AppFlowyBlockEditorAdapter(
              initialBlocks: _editorBlocks(native.currentBlocks()),
              onLocalBlocksChanged: (blocks) => changes.add(
                native.applyBlockSnapshot(blocks: _nativeBlocks(blocks)),
              ),
            );
            final state = adapter.editorState;
            final selection = Selection.single(path: [2], startOffset: 2);
            state.selection = selection;
            expect(await changeCollabListType(state, target), isTrue);
            await adapter.replaceFromRemote(
              _editorBlocks(native.currentBlocks()),
            );
            expect(changes, hasLength(1));
            expect(changes.last.v1Update, isNotEmpty);
            var converted = _editorBlocks(native.currentBlocks()).last;
            expect(converted.blockType, target);
            expect(converted.indent, 3);
            expect(converted.alignment, 'right');
            expect(converted.segments, before.segments);
            expect(converted.checked, isFalse);
            if (target == 'numbered_list') {
              expect(converted.ordered!.order, 1);
              expect(converted.ordered!.numbering, '{}');
            }
            expect(state.selection, selection);
            state.undoManager.undo();
            await Future<void>.delayed(Duration.zero);
            await adapter.replaceFromRemote(
              _editorBlocks(native.currentBlocks()),
            );
            final undone = _editorBlocks(native.currentBlocks()).last;
            expect(undone.blockType, source);
            expect(undone.indent, 3);
            expect(undone.checked, source == 'todo_list');
            expect(undone.segments, before.segments);
            expect(undone.ordered?.numbering, before.ordered?.numbering);
            expect(undone.ordered?.order, before.ordered?.order);
            state.undoManager.redo();
            await Future<void>.delayed(Duration.zero);
            await adapter.replaceFromRemote(
              _editorBlocks(native.currentBlocks()),
            );
            expect(changes, hasLength(3));
            converted = _editorBlocks(native.currentBlocks()).last;
            expect(converted.blockType, target);
            expect(converted.checked, isFalse);
            expect(state.selection, selection);
            // 继续正向切回源类型仍是新转换，不应复活先前的起点或完成状态。
            expect(await changeCollabListType(state, source), isTrue);
            await adapter.replaceFromRemote(
              _editorBlocks(native.currentBlocks()),
            );
            final switchedBack = _editorBlocks(native.currentBlocks()).last;
            expect(switchedBack.checked, isFalse);
            if (source == 'numbered_list') {
              expect(switchedBack.ordered!.order, 1);
              expect(switchedBack.ordered!.numbering, '{}');
            }
            final saved = _editorBlocks(native.currentBlocks());
            native.closeDocument();
            expect(
              _editorBlocks(
                native
                    .openCsesDocument(
                      documentId: 'fixture-doc',
                      cacheDocumentId: 'type-switch',
                      databasePath: database,
                    )
                    .blocks,
              ),
              saved,
            );
          } finally {
            adapter?.dispose();
            native.closeDocument();
            await directory.delete(recursive: true);
          }
        },
        skip: available ? false : '先构建宿主 Rust 库',
      );
    }
  }
  for (final type in [
    NumberedListBlockKeys.type,
    BulletedListBlockKeys.type,
    TodoListBlockKeys.type,
  ]) {
    test(
      '$type multi-level Enter keeps Rust projection, undo and SQLite restoration consistent',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'list-depth-enter-',
        );
        AppFlowyBlockEditorAdapter? adapter;
        try {
          final database = '${directory.path}/updates.sqlite';
          native.openCsesDocument(
            documentId: 'fixture-doc',
            cacheDocumentId: 'depth-enter',
            databasePath: database,
          );
          native.applyDocumentUpdate(
            bytes: await File(
              'rust/tests/fixtures/blockcraft-ordered.update',
            ).readAsBytes(),
          );
          final fixture = _editorBlocks(native.currentBlocks());
          final restart = type == NumberedListBlockKeys.type
              ? fixture.singleWhere((block) => block.id == 'restart')
              : CollabEditorBlock(
                  id: '$type-leaf',
                  blockType: type,
                  text: '',
                  indent: 3,
                );
          native.applyBlockSnapshot(
            blocks: _nativeBlocks([
              fixture.first,
              CollabEditorBlock(
                id: 'level-1',
                blockType: type,
                text: 'parent',
                indent: 1,
              ),
              CollabEditorBlock(
                id: 'level-2',
                blockType: type,
                text: 'parent',
                indent: 2,
              ),
              CollabEditorBlock(
                id: restart.id,
                blockType: restart.blockType,
                text: 'leaf',
                checked: type == TodoListBlockKeys.type,
                indent: 3,
                ordered: restart.ordered,
              ),
            ]),
          );
          final changes = <native.BlockChangeResult>[];
          adapter = AppFlowyBlockEditorAdapter(
            initialBlocks: _editorBlocks(native.currentBlocks()),
            onLocalBlocksChanged: (blocks) {
              changes.add(
                native.applyBlockSnapshot(blocks: _nativeBlocks(blocks)),
              );
            },
          );
          final state = adapter.editorState;
          state.selection = Selection.single(path: [3], startOffset: 4);
          await collabListEnter.handler(state);
          await adapter.replaceFromRemote(
            _editorBlocks(native.currentBlocks()),
          );
          final entered = state.getNodeAtPath([4]);
          expect(native.currentBlocks().last.indent, 3);
          expect(
            native.currentBlocks()[3].checked,
            type == TodoListBlockKeys.type,
          );
          expect(native.currentBlocks().last.checked, isFalse);
          if (type == NumberedListBlockKeys.type) {
            expect(native.currentBlocks().last.ordered!.order, 5);
            expect(native.currentBlocks().last.ordered!.start, isNull);
          } else {
            expect(native.currentBlocks().last.ordered, isNull);
          }
          for (final depth in [2, 1, 0]) {
            await collabListEnter.handler(state);
            await adapter.replaceFromRemote(
              _editorBlocks(native.currentBlocks()),
            );
            expect(native.currentBlocks().last.indent, depth);
            expect(native.currentBlocks().last.checked, isFalse);
            if (type == NumberedListBlockKeys.type) {
              expect(native.currentBlocks().last.ordered!.order, 1);
            } else {
              expect(native.currentBlocks().last.ordered, isNull);
            }
            expect(state.getNodeAtPath([4]), same(entered));
            expect(
              state.selection,
              Selection.single(path: [4], startOffset: 0),
            );
          }
          await collabListEnter.handler(state);
          await adapter.replaceFromRemote(
            _editorBlocks(native.currentBlocks()),
          );
          expect(native.currentBlocks().last.blockType, 'paragraph');
          expect(native.currentBlocks(), hasLength(5));
          expect(changes, hasLength(5));
          expect(changes.every((change) => change.v1Update.isNotEmpty), isTrue);
          state.undoManager.undo();
          await Future<void>.delayed(Duration.zero);
          await adapter.replaceFromRemote(
            _editorBlocks(native.currentBlocks()),
          );
          expect(native.currentBlocks().last.blockType, type);
          expect(native.currentBlocks().last.indent, 0);
          state.undoManager.redo();
          await Future<void>.delayed(Duration.zero);
          await adapter.replaceFromRemote(
            _editorBlocks(native.currentBlocks()),
          );
          expect(native.currentBlocks().last.blockType, 'paragraph');

          if (type == NumberedListBlockKeys.type) {
            // 已有显式起点的空项退级必须接续目标层；Undo 同时恢复深度和原始起点。
            final next = adapter.blocks
                .map(
                  (block) => block.id == 'restart'
                      ? CollabEditorBlock(
                          id: block.id,
                          blockType: block.blockType,
                          text: '',
                          indent: block.indent,
                          ordered: block.ordered,
                        )
                      : block,
                )
                .toList();
            native.applyBlockSnapshot(blocks: _nativeBlocks(next));
            await adapter.replaceFromRemote(
              _editorBlocks(native.currentBlocks()),
            );
            state.selection = Selection.single(path: [3], startOffset: 0);
            await collabListEnter.handler(state);
            await adapter.replaceFromRemote(
              _editorBlocks(native.currentBlocks()),
            );
            expect(native.currentBlocks()[3].indent, 2);
            expect(native.currentBlocks()[3].ordered!.order, 1);
            expect(native.currentBlocks()[3].ordered!.start, isNull);
            state.undoManager.undo();
            await Future<void>.delayed(Duration.zero);
            await adapter.replaceFromRemote(
              _editorBlocks(native.currentBlocks()),
            );
            expect(native.currentBlocks()[3].indent, 3);
            expect(native.currentBlocks()[3].ordered!.start, 5);
          } else if (type == TodoListBlockKeys.type) {
            // 完成状态属于原项：空项退级不清除勾选，转段落后 Undo 恢复类型、层级和勾选。
            native.applyBlockSnapshot(
              blocks: _nativeBlocks([
                for (final block in adapter.blocks)
                  if (block.id == restart.id)
                    CollabEditorBlock(
                      id: block.id,
                      blockType: block.blockType,
                      text: '',
                      checked: true,
                      indent: block.indent,
                    )
                  else
                    block,
              ]),
            );
            await adapter.replaceFromRemote(
              _editorBlocks(native.currentBlocks()),
            );
            state.selection = Selection.single(path: [3], startOffset: 0);
            for (final depth in [2, 1, 0]) {
              await collabListEnter.handler(state);
              await adapter.replaceFromRemote(
                _editorBlocks(native.currentBlocks()),
              );
              expect(native.currentBlocks()[3].indent, depth);
              expect(native.currentBlocks()[3].checked, isTrue);
              expect(native.currentBlocks()[3].ordered, isNull);
            }
            await collabListEnter.handler(state);
            await adapter.replaceFromRemote(
              _editorBlocks(native.currentBlocks()),
            );
            expect(native.currentBlocks()[3].blockType, 'paragraph');
            expect(native.currentBlocks()[3].checked, isFalse);
            for (final depth in [0, 1, 2, 3]) {
              state.undoManager.undo();
              await Future<void>.delayed(Duration.zero);
              await adapter.replaceFromRemote(
                _editorBlocks(native.currentBlocks()),
              );
              expect(native.currentBlocks()[3].blockType, type);
              expect(native.currentBlocks()[3].indent, depth);
              expect(native.currentBlocks()[3].checked, isTrue);
            }
            for (final depth in [2, 1, 0, -1]) {
              state.undoManager.redo();
              await Future<void>.delayed(Duration.zero);
              await adapter.replaceFromRemote(
                _editorBlocks(native.currentBlocks()),
              );
              expect(
                native.currentBlocks()[3].blockType,
                depth < 0 ? 'paragraph' : type,
              );
              expect(native.currentBlocks()[3].indent, depth < 0 ? 0 : depth);
              expect(native.currentBlocks()[3].checked, depth >= 0);
            }
            state.undoManager.undo();
            await Future<void>.delayed(Duration.zero);
            await adapter.replaceFromRemote(
              _editorBlocks(native.currentBlocks()),
            );
            expect(native.currentBlocks()[3].checked, isTrue);
          }
          final saved = _editorBlocks(native.currentBlocks());
          native.closeDocument();
          final restored = native.openCsesDocument(
            documentId: 'fixture-doc',
            cacheDocumentId: 'depth-enter',
            databasePath: database,
          );
          expect(_editorBlocks(restored.blocks), saved);
        } finally {
          adapter?.dispose();
          native.closeDocument();
          await directory.delete(recursive: true);
        }
      },
      skip: available ? false : '先构建宿主 Rust 库',
    );
    test(
      '$type Backspace preserves Rust content, settings, history and SQLite',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'list-backspace-',
        );
        AppFlowyBlockEditorAdapter? adapter;
        try {
          final database = '${directory.path}/updates.sqlite';
          native.openCsesDocument(
            documentId: 'fixture-doc',
            cacheDocumentId: 'backspace',
            databasePath: database,
          );
          native.applyDocumentUpdate(
            bytes: await File(
              'rust/tests/fixtures/blockcraft-ordered.update',
            ).readAsBytes(),
          );
          final fixture = _editorBlocks(native.currentBlocks());
          final leaf = type == NumberedListBlockKeys.type
              ? fixture.singleWhere((b) => b.id == 'restart')
              : CollabEditorBlock(
                  id: '$type-leaf',
                  blockType: type,
                  text: '',
                  indent: 3,
                );
          native.applyBlockSnapshot(
            blocks: _nativeBlocks([
              fixture.first,
              CollabEditorBlock(
                id: 'parent-1',
                blockType: type,
                text: 'parent-1',
                indent: 1,
              ),
              CollabEditorBlock(
                id: 'parent-2',
                blockType: type,
                text: 'parent-2',
                indent: 2,
              ),
              CollabEditorBlock(
                id: leaf.id,
                blockType: type,
                text: 'leaf',
                indent: 3,
                checked: type == TodoListBlockKeys.type,
                ordered: leaf.ordered,
              ),
            ]),
          );
          final changes = <native.BlockChangeResult>[];
          adapter = AppFlowyBlockEditorAdapter(
            initialBlocks: _editorBlocks(native.currentBlocks()),
            onLocalBlocksChanged: (blocks) {
              changes.add(
                native.applyBlockSnapshot(blocks: _nativeBlocks(blocks)),
              );
            },
          );
          final state = adapter.editorState;
          state.selection = Selection.single(path: [3], startOffset: 0);
          final original = state.getNodeAtPath([3]);
          for (final depth in [2, 1, 0, -1]) {
            expect(
              collabBlockBackspaceCommand.execute(state),
              KeyEventResult.handled,
            );
            await Future<void>.delayed(Duration.zero);
            await adapter.replaceFromRemote(
              _editorBlocks(native.currentBlocks()),
            );
            final current = native.currentBlocks();
            expect(current, hasLength(4));
            expect(current[2].text, 'parent-2');
            expect(current.last.text, 'leaf');
            expect(current.last.blockType, depth < 0 ? 'paragraph' : type);
            expect(current.last.indent, depth < 0 ? 0 : depth);
            expect(
              current.last.checked,
              depth >= 0 && type == TodoListBlockKeys.type,
            );
            expect(
              state.selection,
              Selection.single(path: [3], startOffset: 0),
            );
            if (depth >= 0) {
              expect(state.getNodeAtPath([3]), same(original));
              if (type == NumberedListBlockKeys.type) {
                expect(current.last.ordered!.order, 1);
                expect(current.last.ordered!.start, isNull);
              }
            }
          }
          expect(changes, hasLength(4));
          expect(changes.every((c) => c.v1Update.isNotEmpty), isTrue);
          for (final depth in [0, 1, 2, 3]) {
            state.undoManager.undo();
            await Future<void>.delayed(Duration.zero);
            await adapter.replaceFromRemote(
              _editorBlocks(native.currentBlocks()),
            );
            expect(native.currentBlocks().last.blockType, type);
            expect(native.currentBlocks().last.indent, depth);
            expect(native.currentBlocks().last.text, 'leaf');
            expect(
              native.currentBlocks().last.checked,
              type == TodoListBlockKeys.type,
            );
          }
          if (type == NumberedListBlockKeys.type) {
            expect(native.currentBlocks().last.ordered!.start, 5);
            expect(native.currentBlocks().last.ordered!.order, 4);
            expect(
              native.currentBlocks().last.ordered!.markerStyle,
              leaf.ordered!.markerStyle,
            );
          }
          for (final depth in [2, 1, 0, -1]) {
            state.undoManager.redo();
            await Future<void>.delayed(Duration.zero);
            await adapter.replaceFromRemote(
              _editorBlocks(native.currentBlocks()),
            );
            expect(
              native.currentBlocks().last.blockType,
              depth < 0 ? 'paragraph' : type,
            );
            expect(native.currentBlocks().last.indent, depth < 0 ? 0 : depth);
            expect(native.currentBlocks().last.text, 'leaf');
            expect(
              native.currentBlocks().last.checked,
              depth >= 0 && type == TodoListBlockKeys.type,
            );
          }
          state.undoManager.undo();
          await Future<void>.delayed(Duration.zero);
          await adapter.replaceFromRemote(
            _editorBlocks(native.currentBlocks()),
          );
          final saved = _editorBlocks(native.currentBlocks());
          native.closeDocument();
          final restored = native.openCsesDocument(
            documentId: 'fixture-doc',
            cacheDocumentId: 'backspace',
            databasePath: database,
          );
          expect(_editorBlocks(restored.blocks), saved);
        } finally {
          adapter?.dispose();
          native.closeDocument();
          await directory.delete(recursive: true);
        }
      },
      skip: available ? false : '先构建宿主 Rust 库',
    );
    test(
      '$type toolbar indent preserves native numbering, checked and mid-item caret',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'list-toolbar-',
        );
        AppFlowyBlockEditorAdapter? adapter;
        try {
          final database = '${directory.path}/updates.sqlite';
          native.openCsesDocument(
            documentId: 'fixture-doc',
            cacheDocumentId: 'toolbar',
            databasePath: database,
          );
          native.applyDocumentUpdate(
            bytes: await File(
              'rust/tests/fixtures/blockcraft-ordered.update',
            ).readAsBytes(),
          );
          final fixture = _editorBlocks(native.currentBlocks());
          final leaf = type == NumberedListBlockKeys.type
              ? fixture.singleWhere((b) => b.id == 'restart')
              : CollabEditorBlock(
                  id: '$type-leaf',
                  blockType: type,
                  text: '',
                  indent: 3,
                );
          native.applyBlockSnapshot(
            blocks: _nativeBlocks([
              fixture.first,
              CollabEditorBlock(
                id: 'parent-1',
                blockType: type,
                text: 'parent-1',
                indent: 1,
              ),
              CollabEditorBlock(
                id: 'parent-2',
                blockType: type,
                text: 'parent-2',
                indent: 2,
              ),
              CollabEditorBlock(
                id: leaf.id,
                blockType: type,
                text: 'leaf',
                indent: 3,
                checked: type == TodoListBlockKeys.type,
                ordered: leaf.ordered,
              ),
            ]),
          );
          final changes = <native.BlockChangeResult>[];
          adapter = AppFlowyBlockEditorAdapter(
            initialBlocks: _editorBlocks(native.currentBlocks()),
            onLocalBlocksChanged: (blocks) => changes.add(
              native.applyBlockSnapshot(blocks: _nativeBlocks(blocks)),
            ),
          );
          final state = adapter.editorState;
          final selection = Selection.single(path: [3], startOffset: 2);
          state.selection = selection;
          for (final depth in [4, 3, 2, 1, 0, -1]) {
            expect(
              await changeCollabListIndent(state, depth == 4 ? 1 : -1),
              isTrue,
            );
            await adapter.replaceFromRemote(
              _editorBlocks(native.currentBlocks()),
            );
            final current = native.currentBlocks().last;
            expect(native.currentBlocks(), hasLength(4));
            expect(current.text, 'leaf');
            expect(current.blockType, depth < 0 ? 'paragraph' : type);
            expect(current.indent, depth < 0 ? 0 : depth);
            expect(
              current.checked,
              depth >= 0 && type == TodoListBlockKeys.type,
            );
            expect(state.selection, selection);
            if (type == NumberedListBlockKeys.type && depth >= 0) {
              expect(
                current.ordered!.order,
                depth == 4 ? 4 : (depth == 3 ? 0 : 1),
              );
              expect(current.ordered!.start, depth == 4 ? 5 : null);
            }
          }
          expect(changes, hasLength(6));
          expect(changes.every((c) => c.v1Update.isNotEmpty), isTrue);
          for (final depth in [0, 1, 2, 3, 4, 3]) {
            state.undoManager.undo();
            await Future<void>.delayed(Duration.zero);
            await adapter.replaceFromRemote(
              _editorBlocks(native.currentBlocks()),
            );
            expect(native.currentBlocks().last.blockType, type);
            expect(native.currentBlocks().last.indent, depth);
            expect(
              native.currentBlocks().last.checked,
              type == TodoListBlockKeys.type,
            );
            expect(native.currentBlocks().last.text, 'leaf');
            expect(state.selection, selection);
          }
          if (type == NumberedListBlockKeys.type) {
            expect(native.currentBlocks().last.ordered!.start, 5);
            expect(
              native.currentBlocks().last.ordered!.markerStyle,
              leaf.ordered!.markerStyle,
            );
          }
          for (final depth in [4, 3, 2, 1, 0, -1]) {
            state.undoManager.redo();
            await Future<void>.delayed(Duration.zero);
            await adapter.replaceFromRemote(
              _editorBlocks(native.currentBlocks()),
            );
            expect(
              native.currentBlocks().last.blockType,
              depth < 0 ? 'paragraph' : type,
            );
            expect(native.currentBlocks().last.indent, depth < 0 ? 0 : depth);
            expect(
              native.currentBlocks().last.checked,
              depth >= 0 && type == TodoListBlockKeys.type,
            );
            expect(state.selection, selection);
          }
          state.undoManager.undo();
          await Future<void>.delayed(Duration.zero);
          await adapter.replaceFromRemote(
            _editorBlocks(native.currentBlocks()),
          );
          final saved = _editorBlocks(native.currentBlocks());
          native.closeDocument();
          expect(
            _editorBlocks(
              native
                  .openCsesDocument(
                    documentId: 'fixture-doc',
                    cacheDocumentId: 'toolbar',
                    databasePath: database,
                  )
                  .blocks,
            ),
            saved,
          );
        } finally {
          adapter?.dispose();
          native.closeDocument();
          await directory.delete(recursive: true);
        }
      },
      skip: available ? false : '先构建宿主 Rust 库',
    );
  }
  test(
    'ordinary ordered toolbar increase starts target depth and decrease continues its parent',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'ordinary-toolbar-',
      );
      AppFlowyBlockEditorAdapter? adapter;
      try {
        final database = '${directory.path}/updates.sqlite';
        native.openCsesDocument(
          documentId: 'fixture-doc',
          cacheDocumentId: 'ordinary-toolbar',
          databasePath: database,
        );
        native.applyDocumentUpdate(
          bytes: await File(
            'rust/tests/fixtures/blockcraft-ordered.update',
          ).readAsBytes(),
        );
        final fixture = _editorBlocks(native.currentBlocks());
        native.applyBlockSnapshot(
          blocks: _nativeBlocks([
            fixture.first,
            const CollabEditorBlock(
              id: 'parent',
              blockType: 'numbered_list',
              text: 'parent',
              indent: 1,
            ),
            const CollabEditorBlock(
              id: 'ordinary',
              blockType: 'numbered_list',
              text: 'leaf',
              indent: 1,
            ),
          ]),
        );
        adapter = AppFlowyBlockEditorAdapter(
          initialBlocks: _editorBlocks(native.currentBlocks()),
          onLocalBlocksChanged: (blocks) {
            native.applyBlockSnapshot(blocks: _nativeBlocks(blocks));
          },
        );
        final state = adapter.editorState;
        state.selection = Selection.single(path: [2], startOffset: 2);
        expect(native.currentBlocks().last.ordered!.order, 1);
        await changeCollabListIndent(state, 1);
        await adapter.replaceFromRemote(_editorBlocks(native.currentBlocks()));
        expect(native.currentBlocks().last.indent, 2);
        expect(native.currentBlocks().last.ordered!.order, 0);
        expect(native.currentBlocks().last.ordered!.start, isNull);
        await changeCollabListIndent(state, -1);
        await adapter.replaceFromRemote(_editorBlocks(native.currentBlocks()));
        expect(native.currentBlocks().last.indent, 1);
        expect(native.currentBlocks().last.ordered!.order, 1);
        state.undoManager.undo();
        await Future<void>.delayed(Duration.zero);
        await adapter.replaceFromRemote(_editorBlocks(native.currentBlocks()));
        expect(native.currentBlocks().last.ordered!.order, 0);
        state.undoManager.redo();
        await Future<void>.delayed(Duration.zero);
        await adapter.replaceFromRemote(_editorBlocks(native.currentBlocks()));
        expect(native.currentBlocks().last.ordered!.order, 1);
        expect(state.selection, Selection.single(path: [2], startOffset: 2));
      } finally {
        adapter?.dispose();
        native.closeDocument();
        await directory.delete(recursive: true);
      }
    },
    skip: available ? false : '先构建宿主 Rust 库',
  );
  for (final reverse in [false, true]) {
    test(
      'mixed native toolbar range reverse=$reverse converts and outdents atomically',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'mixed-toolbar-',
        );
        AppFlowyBlockEditorAdapter? adapter;
        try {
          final database = '${directory.path}/updates.sqlite';
          native.openCsesDocument(
            documentId: 'fixture-doc',
            cacheDocumentId: 'mixed-toolbar',
            databasePath: database,
          );
          native.applyDocumentUpdate(
            bytes: await File(
              'rust/tests/fixtures/blockcraft-ordered.update',
            ).readAsBytes(),
          );
          native.applyBlockSnapshot(
            blocks: _nativeBlocks([
              _editorBlocks(native.currentBlocks()).first,
              const CollabEditorBlock(
                id: 'a-list',
                blockType: 'numbered_list',
                text: 'one two',
              ),
              const CollabEditorBlock(
                id: 'b-list',
                blockType: 'todo_list',
                text: 'one two',
                indent: 1,
                checked: true,
              ),
              const CollabEditorBlock(
                id: 'c-list',
                blockType: 'bulleted_list',
                text: 'one two',
              ),
            ]),
          );
          final changes = <native.BlockChangeResult>[];
          adapter = AppFlowyBlockEditorAdapter(
            initialBlocks: _editorBlocks(native.currentBlocks()),
            onLocalBlocksChanged: (blocks) => changes.add(
              native.applyBlockSnapshot(blocks: _nativeBlocks(blocks)),
            ),
          );
          final state = adapter.editorState;
          final selection = Selection(
            start: Position(path: reverse ? [3] : [1], offset: reverse ? 5 : 1),
            end: Position(path: reverse ? [1] : [3], offset: reverse ? 1 : 5),
          );
          state.selection = selection;
          expect(await changeCollabListIndent(state, -1), isTrue);
          await adapter.replaceFromRemote(
            _editorBlocks(native.currentBlocks()),
          );
          expect(changes, hasLength(1));
          expect(changes.single.v1Update, isNotEmpty);
          expect(native.currentBlocks().skip(1).map((b) => b.blockType), [
            'paragraph',
            'todo_list',
            'paragraph',
          ]);
          expect(native.currentBlocks().skip(1).map((b) => b.indent), [
            0,
            0,
            0,
          ]);
          expect(native.currentBlocks()[2].checked, isTrue);
          expect(
            native.currentBlocks().map((b) => b.id),
            isNot(contains('a-list')),
          );
          expect(
            native.currentBlocks().map((b) => b.id),
            isNot(contains('c-list')),
          );
          expect(state.selection, selection);
          state.undoManager.undo();
          await Future<void>.delayed(Duration.zero);
          await adapter.replaceFromRemote(
            _editorBlocks(native.currentBlocks()),
          );
          expect(native.currentBlocks().skip(1).map((b) => b.blockType), [
            'numbered_list',
            'todo_list',
            'bulleted_list',
          ]);
          expect(native.currentBlocks().skip(1).map((b) => b.indent), [
            0,
            1,
            0,
          ]);
          expect(native.currentBlocks()[2].checked, isTrue);
          state.undoManager.redo();
          await Future<void>.delayed(Duration.zero);
          await adapter.replaceFromRemote(
            _editorBlocks(native.currentBlocks()),
          );
          expect(native.currentBlocks().skip(1).map((b) => b.blockType), [
            'paragraph',
            'todo_list',
            'paragraph',
          ]);
          expect(
            native.currentBlocks().skip(1).every((b) => b.text == 'one two'),
            isTrue,
          );
          expect(state.selection, selection);
          expect(changes, hasLength(3));
          final saved = _editorBlocks(native.currentBlocks());
          native.closeDocument();
          expect(
            _editorBlocks(
              native
                  .openCsesDocument(
                    documentId: 'fixture-doc',
                    cacheDocumentId: 'mixed-toolbar',
                    databasePath: database,
                  )
                  .blocks,
            ),
            saved,
          );
        } finally {
          adapter?.dispose();
          native.closeDocument();
          await directory.delete(recursive: true);
        }
      },
      skip: available ? false : '先构建宿主 Rust 库',
    );
  }
  test(
    'numbering actions and undo redo survive FRB and SQLite restoration',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'ordered-numbering-',
      );
      AppFlowyBlockEditorAdapter? adapter;
      try {
        final database = '${directory.path}/updates.sqlite';
        native.openCsesDocument(
          documentId: 'fixture-doc',
          cacheDocumentId: 'numbering-test',
          databasePath: database,
        );
        native.applyDocumentUpdate(
          bytes: await File(
            'rust/tests/fixtures/blockcraft-ordered.update',
          ).readAsBytes(),
        );
        final changes = <native.BlockChangeResult>[];
        adapter = AppFlowyBlockEditorAdapter(
          initialBlocks: _editorBlocks(native.currentBlocks()),
          onLocalBlocksChanged: (blocks) {
            changes.add(
              native.applyBlockSnapshot(blocks: _nativeBlocks(blocks)),
            );
          },
        );
        final state = adapter.editorState;
        await changeCollabOrderedNumbering(state, 'b', restart: true);
        expect(
          changes.last.blocks.firstWhere((b) => b.id == 'b').ordered!.order,
          0,
        );
        expect(
          changes.last.blocks.firstWhere((b) => b.id == 'e').ordered!.order,
          1,
        );
        await adapter.replaceFromRemote(_editorBlocks(native.currentBlocks()));
        state.undoManager.undo();
        await Future<void>.delayed(Duration.zero);
        expect(
          native
              .currentBlocks()
              .firstWhere((b) => b.id == 'b')
              .ordered!
              .numbering,
          '{}',
        );
        expect(
          native.currentBlocks().firstWhere((b) => b.id == 'b').ordered!.order,
          1,
        );
        await adapter.replaceFromRemote(_editorBlocks(native.currentBlocks()));
        state.undoManager.redo();
        await Future<void>.delayed(Duration.zero);
        expect(
          native.currentBlocks().firstWhere((b) => b.id == 'b').ordered!.start,
          1,
        );
        await adapter.replaceFromRemote(_editorBlocks(native.currentBlocks()));
        await changeCollabOrderedNumbering(state, 'b', restart: false);
        expect(
          native.currentBlocks().firstWhere((b) => b.id == 'b').ordered!.order,
          1,
        );
        await adapter.replaceFromRemote(_editorBlocks(native.currentBlocks()));
        state.undoManager.undo();
        await Future<void>.delayed(Duration.zero);
        expect(
          native.currentBlocks().firstWhere((b) => b.id == 'b').ordered!.start,
          1,
        );
        await adapter.replaceFromRemote(_editorBlocks(native.currentBlocks()));
        state.undoManager.redo();
        await Future<void>.delayed(Duration.zero);
        await adapter.replaceFromRemote(_editorBlocks(native.currentBlocks()));
        // 原始自定义起点 5 必须可以改成 1，并在撤销时恢复属性缺失而非写入 false/null。
        await changeCollabOrderedNumbering(state, 'restart', restart: true);
        expect(
          native
              .currentBlocks()
              .firstWhere((b) => b.id == 'restart')
              .ordered!
              .start,
          1,
        );
        await adapter.replaceFromRemote(_editorBlocks(native.currentBlocks()));
        state.undoManager.undo();
        await Future<void>.delayed(Duration.zero);
        expect(
          jsonDecode(
            native
                .currentBlocks()
                .firstWhere((b) => b.id == 'restart')
                .ordered!
                .numbering,
          ),
          {'start': 5},
        );
        await adapter.replaceFromRemote(_editorBlocks(native.currentBlocks()));
        state.undoManager.redo();
        await Future<void>.delayed(Duration.zero);
        final beforeClose = _editorBlocks(native.currentBlocks());
        final output =
            Platform.environment['CSES_BLOCKCRAFT_NUMBERING_INTEROP_OUTPUT'];
        if (output != null) {
          await File(
            output,
          ).writeAsBytes(native.encodeDocumentDiff(stateVector: [0]));
        }
        native.closeDocument();
        final reopened = native.openCsesDocument(
          documentId: 'fixture-doc',
          cacheDocumentId: 'numbering-test',
          databasePath: database,
        );
        expect(_editorBlocks(reopened.blocks), beforeClose);
        expect(
          reopened.blocks.every((b) => b.ordered?.numberingEdit == null),
          isTrue,
        );
        expect(changes.every((result) => result.v1Update.isNotEmpty), isTrue);
      } finally {
        adapter?.dispose();
        native.closeDocument();
        await directory.delete(recursive: true);
      }
    },
    skip: available ? false : '先构建宿主 Rust 库',
  );
}
