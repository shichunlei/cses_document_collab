import 'package:cses_document_collab/src/editor/collab_block_locks.dart';
import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/model/collab_inline_formula.dart';

/// 划词操作的稳定块身份及正文快照，不持有编辑器或节点资源。
/// 弹窗期间允许整组选区重排，正文变化、跨单元格或删除时拒绝旧操作。
/// ```dart
/// import 'package:appflowy_editor/appflowy_editor.dart';
/// import 'package:cses_document_collab/src/model/collab_text_range.dart';
/// final state = EditorState.blank();
/// final range = CollabTextRange.capture(state);
/// final selection = range?.resolve(state);
/// state.dispose();
/// ```
final class CollabTextRange {
  /// [_nodes] 保存文档顺序的目标，[_start]/[_end] 是 UTF-16 偏移，[text] 为引用原文。
  CollabTextRange._(this._nodes, this._start, this._end, this.text);

  final List<_TextRangeNode> _nodes;
  final int _start;
  final int _end;

  /// 按段落换行拼接的选中文字；仅供复制和公式输入预填，不含格式。
  final String text;

  /// 是否为单段选区；链接和公式转换仅允许单段非空普通文字。
  bool get isSingle => _nodes.length == 1;

  /// 是否含普通文字，纯行内对象不提供文字格式操作。
  bool get hasText =>
      text.replaceAll(collabInlineFormulaCharacter, '').trim().isNotEmpty;

  /// 是否为可转换为链接或公式的非空单段文字；不把行内对象转成普通字符。
  bool get canConvert =>
      isSingle && hasText && !text.contains(collabInlineFormulaCharacter);

  /// 捕获借用 [state] 的当前选区；[allowCollapsed] 默认 false，仅粘贴允许光标位置。
  /// 仅支持普通正文及同一单元格内正文；未知占位、代码和跨容器选区返回 null。
  static CollabTextRange? capture(
    EditorState state, {
    bool allowCollapsed = false,
  }) {
    if (state.isDisposed || state.selectionType == SelectionType.block) {
      return null;
    }
    final selection = state.selection?.normalized;
    if (selection == null || (!allowCollapsed && selection.isCollapsed)) {
      return null;
    }
    final nodes = state.getNodesInSelection(selection);
    if (nodes.isEmpty || nodes.any((node) => !_isText(node))) return null;
    // 跨容器剪切会改写父结构，第一阶段只开放同级正文范围。
    if (nodes.any((node) => node.parent != nodes.first.parent)) return null;
    if (selection.start.offset < 0 ||
        selection.end.offset < 0 ||
        selection.start.offset > nodes.first.delta!.length ||
        selection.end.offset > nodes.last.delta!.length) {
      return null;
    }
    final text = <String>[];
    for (var i = 0; i < nodes.length; i++) {
      text.add(
        nodes[i].delta!.toPlainText().substring(
          i == 0 ? selection.start.offset : 0,
          i == nodes.length - 1 ? selection.end.offset : nodes[i].delta!.length,
        ),
      );
    }
    return CollabTextRange._(
      nodes.map((node) => _TextRangeNode(node, state)).toList(),
      selection.start.offset,
      selection.end.offset,
      text.join('\n'),
    );
  }

  /// 按稳定身份在借用 [state] 中重定位；[checkFormatting] 默认 true，连格式变化也拒绝。
  /// 格式面板传 false 允许自身连续改格式；正文、类型、范围顺序或父容器变化仍失效。
  /// 只读允许解析供复制；写入方必须再次核对 editable。
  Selection? resolve(EditorState state, {bool checkFormatting = true}) {
    if (state.isDisposed) return null;
    final nodes = <Node>[];
    for (final saved in _nodes) {
      final node = findCollabInlineTextNode(state, saved.id);
      if (node == null ||
          !_isText(node) ||
          (CollabBlockLocks.of(state)?.epoch(saved.id) ?? 0) !=
              saved.lockEpoch ||
          (node.parent?.attributes['cses_collab_block_id'] ??
                  node.parent?.id) !=
              saved.parentId ||
          node.type != saved.type ||
          node.delta!.toPlainText() != saved.text ||
          (checkFormatting &&
              jsonEncode(node.delta!.toJson()) != saved.delta)) {
        return null;
      }
      nodes.add(node);
    }
    final range = Selection(
      start: Position(path: nodes.first.path, offset: _start),
      end: Position(path: nodes.last.path, offset: _end),
    );
    final current = state.getNodesInSelection(range);
    if (current.length != nodes.length ||
        nodes.any((node) => node.parent != nodes.first.parent)) {
      return null;
    }
    for (var i = 0; i < nodes.length; i++) {
      if (!identical(current[i], nodes[i])) return null;
    }
    return range;
  }

  /// 判断借用 [node] 是否属于当前已适配的普通正文，且不会剪切其子结构。
  static bool _isText(Node node) =>
      node.delta != null &&
      node.children.isEmpty &&
      const {
        'paragraph',
        'heading',
        'bulleted_list',
        'numbered_list',
        'todo_list',
        'quote',
      }.contains(node.type);
}

/// 一个块的不可变定位快照，完整 Delta 用于拒绝陈旧的链接和替换操作。
final class _TextRangeNode {
  /// 从借用[node]、[state]复制身份、权限代次、类型及正文，不持有资源。
  _TextRangeNode(Node node, EditorState state)
    : lockEpoch =
          CollabBlockLocks.of(state)?.epoch(CollabBlockLocks.idOf(node)) ?? 0,
      id = node.attributes['cses_collab_block_id'] as String? ?? node.id,
      type = node.type,
      text = node.delta!.toPlainText(),
      delta = jsonEncode(node.delta!.toJson()),
      parentId =
          node.parent?.attributes['cses_collab_block_id'] as String? ??
          node.parent?.id;

  /// 捕获时的权限代次，锁后解锁仍拒绝旧范围。
  final int lockEpoch;

  final String id;
  final String type;
  final String text;
  final String delta;
  final String? parentId;
}
