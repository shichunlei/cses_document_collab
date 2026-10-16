import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/editor_shortcut_toolbar.dart';
import 'package:cses_document_collab/src/model/collab_table.dart';
import 'package:flutter/material.dart';

/// 为借用[context]及[state]中的[table]打开[area]的合并/拆分面板。
/// 面板期间暂停正文输入；退场后校验原表指纹和权限，过期结果不写入其他表格。
Future<void> showCollabTableSheet(
  BuildContext context,
  EditorState state,
  Node table,
  CollabTableRegion area,
) async {
  final id = collabTableNodeId(table);
  final expected = collabTableFingerprint(table);
  final hostContext = Navigator.of(context).context;
  await runEditorHeaderAction<void>(hostContext, state, () async {
    final route = ModalBottomSheetRoute<_TableRequest>(
      builder: (_) => _TableOptions(editor: state, table: table, area: area),
      isScrollControlled: true,
      capturedThemes: InheritedTheme.capture(
        from: context,
        to: Navigator.of(context).context,
      ),
    );
    final result = await Navigator.of(hostContext).push(route);
    await route.completed;
    if (result == null ||
        !hostContext.mounted ||
        state.isDisposed ||
        !state.editable) {
      return;
    }
    final applied = await applyCollabTableEdit(
      state,
      id,
      expected,
      result.action,
      row: result.row,
      column: result.column,
      endRow: result.endRow,
      endColumn: result.endColumn,
    );
    if (!applied && context.mounted) {
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(const SnackBar(content: Text('表格已更新或当前操作不可用，请重新选择')));
    }
  });
}

/// 面板退场后的值请求，不持有节点、回调或编辑器。
class _TableRequest {
  /// [action]为合并或拆分，[row]/[column]为主格索引；[endRow]/[endColumn]为合并终点。
  const _TableRequest(
    this.action,
    this.row,
    this.column, {
    this.endRow,
    this.endColumn,
  });

  /// 待执行动作。
  final CollabTableAction action;

  /// 0起始行索引。
  final int row;

  /// 0起始列索引。
  final int column;

  /// 合并终行，null表示不适用。
  final int? endRow;

  /// 合并终列，null表示不适用。
  final int? endColumn;
}

/// 借用表格快照展示操作选项；所有写入均在面板完全退场后执行。
class _TableOptions extends StatefulWidget {
  /// [editor]为借用编辑器，[table]为快照，[area]为点击的可见格区域。
  const _TableOptions({
    required this.editor,
    required this.table,
    required this.area,
  });

  /// 借用编辑器，面板不释放它。
  final EditorState editor;

  /// 面板创建时的表格；远端变化由提交指纹拒绝。
  final Node table;

  /// 所选可见矩形。
  final CollabTableRegion area;

  /// 创建局部选择状态，不拥有编辑器资源。
  @override
  State<_TableOptions> createState() => _TableOptionsState();
}

/// 持有合并范围与成对的借用节点监听，不创建连接或输入控制器。
class _TableOptionsState extends State<_TableOptions> {
  /// 创建时的完整表格指纹，远端变化不能悄悄更新草稿基线。
  late final String _original;

  /// 被借用的节点监听，面板关闭时成对移除。
  final Set<Node> _nodes = {};

  /// 权限曾撤销后本次草稿永久失效，重新授权需重新打开面板。
  bool _revoked = false;

  /// 仅原身份/指纹及权限均有效时允许返回操作请求。
  bool get _enabled {
    if (_revoked || widget.editor.isDisposed || !widget.editor.editable) {
      return false;
    }
    final current = findCollabTable(
      widget.editor,
      collabTableNodeId(widget.table),
    );
    return current != null && collabTableFingerprint(current) == _original;
  }

  /// 建立成对的权限/结构监听；所有资源仍由编辑器持有。
  @override
  void initState() {
    super.initState();
    // 固定基线必须早于第一次远端通知。
    _original = collabTableFingerprint(widget.table);
    widget.editor.editableNotifier.addListener(_onTree);
    _syncNodes();
  }

  /// 更新借用节点的监听集合，替换整个表格后仍能观察新身份树。
  void _syncNodes() {
    final next = <Node>{widget.editor.document.root};
    void collect(Node node) {
      next.add(node);
      for (final child in node.children) {
        collect(child);
      }
    }

    final table = findCollabTable(
      widget.editor,
      collabTableNodeId(widget.table),
    );
    if (table != null) collect(table);
    for (final node in _nodes.difference(next)) {
      node.removeListener(_onTree);
    }
    for (final node in next.difference(_nodes)) {
      node.addListener(_onTree);
    }
    _nodes
      ..clear()
      ..addAll(next);
  }

  /// 树或权限变化后重新计算可用性，不自动重载用户草稿。
  void _onTree() {
    if (!mounted || widget.editor.isDisposed) return;
    if (!widget.editor.editable) _revoked = true;
    _syncNodes();
    setState(() {});
  }

  /// 解除全部借用监听，不关闭编辑器或原生文档。
  @override
  void dispose() {
    widget.editor.editableNotifier.removeListener(_onTree);
    for (final node in _nodes) {
      node.removeListener(_onTree);
    }
    super.dispose();
  }

  /// 草稿终行，默认覆盖当前已合并区域。
  late int _endRow = widget.area.row + widget.area.rows - 1;

  /// 草稿终列，默认覆盖当前已合并区域。
  late int _endColumn = widget.area.column + widget.area.columns - 1;

  /// 为合并或拆分[action]构建[label]按钮；[enabled]控制可用性，[context]用于退场。
  Widget _button(
    BuildContext context,
    String label,
    CollabTableAction action, {
    bool enabled = true,
  }) => OutlinedButton(
    key: ValueKey('table-action-${action.name}-$label'),
    onPressed: enabled && _enabled
        ? () => Navigator.pop(
            context,
            _TableRequest(
              action,
              widget.area.row,
              widget.area.column,
              endRow: _endRow,
              endColumn: _endColumn,
            ),
          )
        : null,
    child: Text(label),
  );

  /// 在借用[context]中构建按内容收缩的合并/拆分面板，长内容仍可在屏幕高度内滚动。
  @override
  Widget build(BuildContext context) {
    final a = widget.area;
    final rows = widget.table.children.length;
    final columns = widget.table.children.first.children.length;
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.76,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text('单元格 ${a.row + 1} 行 · ${a.column + 1} 列'),
              trailing: IconButton(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close),
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (!_enabled)
                      const Padding(
                        padding: EdgeInsets.only(bottom: 12),
                        child: Text('表格或权限已更新，请关闭后重新打开'),
                      ),
                    const Text('合并范围（从当前格到）'),
                    Row(
                      children: [
                        Expanded(
                          child: DropdownButton<int>(
                            key: const ValueKey('table-merge-end-row'),
                            value: _endRow,
                            isExpanded: true,
                            items: [
                              for (var r = a.row; r < rows; r++)
                                DropdownMenuItem(
                                  value: r,
                                  child: Text('第${r + 1}行'),
                                ),
                            ],
                            onChanged: !_enabled
                                ? null
                                : (value) {
                                    if (value != null) {
                                      setState(() => _endRow = value);
                                    }
                                  },
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: DropdownButton<int>(
                            key: const ValueKey('table-merge-end-column'),
                            value: _endColumn,
                            isExpanded: true,
                            items: [
                              for (var c = a.column; c < columns; c++)
                                DropdownMenuItem(
                                  value: c,
                                  child: Text('第${c + 1}列'),
                                ),
                            ],
                            onChanged: !_enabled
                                ? null
                                : (value) {
                                    if (value != null) {
                                      setState(() => _endColumn = value);
                                    }
                                  },
                          ),
                        ),
                      ],
                    ),
                    Wrap(
                      spacing: 8,
                      children: [
                        _button(
                          context,
                          '合并所选区域',
                          CollabTableAction.merge,
                          enabled:
                              _endRow > a.row + a.rows - 1 ||
                              _endColumn > a.column + a.columns - 1,
                        ),
                        _button(
                          context,
                          '拆分单元格',
                          CollabTableAction.split,
                          enabled: a.rows * a.columns > 1,
                        ),
                      ],
                    ),
                    const Text(
                      '合并保留全部正文；拆分后正文留在左上格。',
                      style: TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
