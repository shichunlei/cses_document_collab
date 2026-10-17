import 'package:cses_document_collab/src/ui/modal/collab_modal.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/model/collab_table.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'collab_table_grid.dart';
import 'editor_shortcut_toolbar.dart';

/// 表格边缘操作条：整行/列选中、浮动插入/删除菜单及拖动列边界。
///
/// 表格与编辑器由调用方持有，控件仅持有可失效的本地选区和列宽草稿。
/// ```dart
/// import 'package:appflowy_editor/appflowy_editor.dart';
/// import 'package:cses_document_collab/src/editor/collab_table_controls.dart';
/// import 'package:flutter/widgets.dart';
/// Widget buildTable(EditorState editor, Node node) => CollabTableControls(
///   editor: editor, table: node,
///   cellBuilder: (context, cell) => editor.renderer.build(context, cell));
/// ```
class CollabTableControls extends StatefulWidget {
  /// [key]控制身份；[editor]/[table]为借用资源；[cellBuilder]构建可见格正文。
  const CollabTableControls({
    super.key,
    required this.editor,
    required this.table,
    required this.cellBuilder,
  });

  /// 借用编辑器，释放控件时不关闭它。
  final EditorState editor;

  /// 当前正式表格节点；替换或远端变更会取消旧草稿。
  final Node table;

  /// 可见单元格构建回调，沿用原正文输入组件。
  final Widget Function(BuildContext context, Node cell) cellBuilder;

  /// 创建拥有节点监听与本地草稿的状态。
  @override
  State<CollabTableControls> createState() => _CollabTableControlsState();
}

/// 只在松手或明确菜单动作时提交数据；树变化、权限变化与卸载均使会话失效。
class _CollabTableControlsState extends State<CollabTableControls> {
  /// 已注册的借用节点，销毁或换表时逐一解除监听。
  final Set<Node> _nodes = {};

  /// 每次菜单会话创建的通知器；弹窗借用，退场后由打开者释放，控件销毁时只使其失效。
  ValueNotifier<bool>? _menuValid;

  /// 表格及浮动菜单共用的点击区域，菜单点击不会被视为离开表格。
  final Object _tapGroup = Object();

  /// 操作条只在表格被点击后展示；正文之外的点击会解除激活。
  bool _active = false;

  /// 最近指针是否来自表格，避免编辑器将外部空白点击映射到本表时误激活。
  bool _pointerInside = false;

  /// 本地选中轴，true为列，false为行，null表示未选中。
  bool? _column;

  /// 所选轴的0起始位置。
  int? _index;

  /// 当前拖动或菜单会话的内容基线，变化后不得重新激活。
  String? _expected;

  /// 拖动的本地预览尺寸、起始尺寸及全局逻辑像素横坐标。
  double? _draftWidth;
  double _startWidth = 0, _startX = 0;

  /// 菜单或保存中的互斥标志，避免连续点击发起重复请求。
  bool _busy = false;

  /// 监听当前权限与全部表格后代，资源仍由编辑器持有。
  @override
  void initState() {
    super.initState();
    widget.editor.editableNotifier.addListener(_onTree);
    widget.editor.selectionNotifier.addListener(_onSelection);
    _active = _selectionInside;
    _syncNodes();
  }

  /// [oldWidget]换表后更新借用节点，旧表草稿不能应用到新表。
  @override
  void didUpdateWidget(covariant CollabTableControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.editor != widget.editor) {
      oldWidget.editor.editableNotifier.removeListener(_onTree);
      oldWidget.editor.selectionNotifier.removeListener(_onSelection);
      widget.editor.editableNotifier.addListener(_onTree);
      widget.editor.selectionNotifier.addListener(_onSelection);
    }
    if (oldWidget.table != widget.table) _cancel();
    _syncNodes();
  }

  /// 递归收集借用[node]及后代的监听目标到[output]。
  void _collect(Node node, Set<Node> output) {
    output.add(node);
    for (final child in node.children) {
      _collect(child, output);
    }
  }

  /// 对当前树增量绑定监听，根节点用于捕获表格移除或替换。
  void _syncNodes() {
    final next = <Node>{widget.editor.document.root};
    // 只有菜单/拖动草稿需要逐格内容失效监听；正文输入期间由原块组件局部更新。
    if (_expected != null) {
      _collect(widget.table, next);
    } else {
      next.add(widget.table);
    }
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

  /// 是否仍为原会话、原内容且可编辑；纯本地拖动预览不改变指纹。
  bool get _valid =>
      mounted &&
      !widget.editor.isDisposed &&
      widget.editor.editable &&
      _expected != null &&
      findCollabTable(widget.editor, collabTableNodeId(widget.table)) ==
          widget.table &&
      collabTableFingerprint(widget.table) == _expected;

  /// 清除本地选择和草稿，失效的旧菜单不因权限恢复重新启用。
  void _cancel() {
    _column = null;
    _index = null;
    _draftWidth = null;
    _expected = null;
    _menuValid?.value = false;
    _syncNodes();
  }

  /// 安排局部刷新，避开编辑器父级构建期间的权限通知。
  void _refresh() {
    if (!mounted) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    } else {
      setState(() {});
    }
  }

  /// 正文选区是否位于本表内；只读取编辑器选区，不修改光标。
  bool get _selectionInside {
    final selection = widget.editor.selection;
    if (selection == null) return false;
    Node? node = widget.editor.getNodeAtPath(selection.start.path);
    while (node != null) {
      if (node == widget.table) return true;
      node = node.parent;
    }
    return false;
  }

  /// 正文重新取得光标时退出整轴选中；外部正文则收起本表操作条。
  void _onSelection() {
    if (widget.editor.selection == null) return;
    final wasActive = _active;
    final hadAxis = _index != null;
    if (!_selectionInside) {
      _active = false;
      _cancel();
    } else {
      if (_pointerInside) _active = true;
      if (_index != null) _cancel();
    }
    if (wasActive != _active || hadAxis) _refresh();
  }

  /// 来自表格的[event]激活边缘操作条，正文手势及原光标定位继续由编辑器处理。
  void _onTablePointer(PointerUpEvent event) {
    _pointerInside = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_pointerInside || _busy || !widget.editor.editable) {
        return;
      }
      if (!_active) {
        _active = true;
        _refresh();
      }
    });
  }

  /// 点击表格及菜单区域以外的[event]时收起操作条并丢弃未提交的选中草稿。
  void _onOutside(PointerDownEvent event) {
    _pointerInside = false;
    if (!_active && _index == null) return;
    _active = false;
    _cancel();
    _refresh();
  }

  /// 表格或权限变化即取消草稿；不会自动用新指纹覆盖旧基线。
  void _onTree() {
    if (!_valid) _cancel();
    _syncNodes();
    _refresh();
  }

  /// 为[column]轴的[index]建立本地会话并收起正文键盘；无写数据副作用。
  void _select(bool column, int index) {
    widget.editor.selection = null;
    widget.editor.service.keyboardService?.closeKeyboard();
    FocusManager.instance.primaryFocus?.unfocus();
    _active = true;
    _column = column;
    _index = index;
    _expected = collabTableFingerprint(widget.table);
    _syncNodes();
    _refresh();
  }

  /// 返回当前列宽，缺省120；仅显示钳制到48～480，不隐式回写。
  List<double> get _widths {
    final raw = collabTableLayout(widget.table)['colWidths'];
    return [
      for (var c = 0; c < widget.table.children.first.children.length; c++)
        _draftWidth != null && _column == true && _index == c
            ? _draftWidth!
            : raw is List &&
                  c < raw.length &&
                  raw[c] is num &&
                  (raw[c] as num).isFinite
            ? (raw[c] as num).toDouble().clamp(48, 480)
            : 120,
    ];
  }

  /// 提交[action]到选中轴的[position]，可选[width]为逻辑像素列宽；过期返回false。
  Future<bool> _apply(
    CollabTableAction action,
    int position, {
    double? width,
  }) async {
    if (!_valid || _index == null) return false;
    final expected = _expected!;
    final tableId = collabTableNodeId(widget.table);
    final column = _column == true;
    return applyCollabTableEdit(
      widget.editor,
      tableId,
      expected,
      action,
      row: column ? 0 : position,
      column: column ? position : 0,
      width: width,
    );
  }

  /// 为[column]轴的[index]在[anchorContext]对应边缘打开浮动菜单。
  Future<void> _open(bool column, int index, BuildContext anchorContext) async {
    if (_busy || !widget.editor.editable || widget.editor.isDisposed) return;
    _select(column, index);
    final host = Navigator.of(context).context;
    _busy = true;
    final valid = ValueNotifier(true);
    _menuValid = valid;
    try {
      await runEditorHeaderAction<void>(host, widget.editor, () async {
        final action = await showCollabPopover<_AxisAction>(
          context: anchorContext,
          title: column ? '列操作' : '行操作',
          builder: (_) => _AxisMenu(
            group: _tapGroup,
            column: column,
            canDelete:
                (column ? _widths.length : widget.table.children.length) > 1,
            valid: valid,
          ),
        );
        if (action == null || !_valid) return;
        final actual = action == _AxisAction.delete
            ? (column
                  ? CollabTableAction.deleteColumn
                  : CollabTableAction.deleteRow)
            : (column
                  ? CollabTableAction.insertColumn
                  : CollabTableAction.insertRow);
        final applied = await _apply(
          actual,
          index + (action == _AxisAction.after ? 1 : 0),
        );
        if (!applied && host.mounted) {
          ScaffoldMessenger.maybeOf(
            host,
          )?.showSnackBar(const SnackBar(content: Text('表格已更新，请重新选择')));
        }
      });
    } finally {
      _menuValid = null;
      valid.dispose();
      _busy = false;
      if (mounted) _refresh();
    }
  }

  /// 开始第[index]列边界的拖动；[details]提供全局逻辑像素起点。
  void _startResize(int index, DragStartDetails details) {
    if (_busy || !widget.editor.editable || widget.editor.isDisposed) return;
    _select(true, index);
    _startWidth = _widths[index];
    _startX = details.globalPosition.dx;
    _draftWidth = _startWidth;
    _refresh();
  }

  /// 按[details]的全局位移更新本地预览，拖动期间不写共享树。
  void _resize(DragUpdateDetails details) {
    if (!_valid || _draftWidth == null) return;
    _draftWidth = (_startWidth + details.globalPosition.dx - _startX).clamp(
      48,
      480,
    );
    _refresh();
  }

  /// 松手后一次提交当前预览；取消或远端更新已失效的拖动不会写入。
  Future<void> _endResize() async {
    if (!_valid || _draftWidth == null || _index == null) return;
    final width = _draftWidth!;
    if ((width - _startWidth).abs() < 0.01) {
      _draftWidth = null;
      _refresh();
      return;
    }
    _busy = true;
    try {
      await _apply(CollabTableAction.resizeColumn, _index!, width: width);
    } finally {
      _busy = false;
      if (mounted) {
        _draftWidth = null;
        _refresh();
      }
    }
  }

  /// 构建[column]轴的[index]操作条，蓝色表示本地选中，列右端可直接拖宽。
  Widget _header(bool column, int index) {
    final selected = _column == column && _index == index;
    return Builder(
      builder: (anchor) => Material(
        color: selected ? const Color(0xFF1759EE) : const Color(0xFFF0F1F3),
        child: Stack(
          children: [
            Positioned.fill(
              child: InkWell(
                key: ValueKey(
                  'table-${column ? 'column' : 'row'}-header-$index',
                ),
                onTap: () async => await _open(column, index, anchor),
                child: Semantics(
                  label: '选择第${index + 1}${column ? '列' : '行'}',
                  button: true,
                  selected: selected,
                  child: Icon(
                    column
                        ? LucideIcons.ellipsis
                        : LucideIcons.ellipsisVertical,
                    size: 18,
                    color: selected ? Colors.white : const Color(0xFFB6BBC4),
                  ),
                ),
              ),
            ),
            if (column)
              Positioned(
                top: 0,
                bottom: 0,
                right: 0,
                width: 24,
                child: GestureDetector(
                  key: ValueKey('table-column-resize-$index'),
                  behavior: HitTestBehavior.opaque,
                  onHorizontalDragStart: (details) =>
                      _startResize(index, details),
                  onHorizontalDragUpdate: _resize,
                  onHorizontalDragEnd: (_) async => await _endResize(),
                  onHorizontalDragCancel: () {
                    _cancel();
                    _refresh();
                  },
                  child: Semantics(
                    label: '拖动调整第${index + 1}列宽度',
                    child: RotatedBox(
                      quarterTurns: 1,
                      child: Icon(
                        LucideIcons.gripHorizontal,
                        size: 16,
                        color: selected
                            ? Colors.white
                            : const Color(0xFFB6BBC4),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 读取[row]的最小显示行高；缺失或非法尺寸回落60逻辑像素，不写回共享属性。
  double _rowHeight(Node row) {
    final raw = collabTableLayout(row)['height'];
    return raw is num && raw.isFinite && raw > 0
        ? raw.toDouble().clamp(48, 480)
        : 60;
  }

  /// 在借用[context]中靠左组合可变高度网格与边缘操作条；窄表与正文左边缘对齐。
  /// 超宽表格保留横向滚动；只读时隐藏所有调整控件。
  @override
  Widget build(BuildContext context) {
    final widths = _widths;
    final editable = widget.editor.editable && _active;
    final regions = collabTableRegions(widget.table);
    return TapRegion(
      groupId: _tapGroup,
      onTapOutside: _onOutside,
      child: Listener(
        onPointerUp: _onTablePointer,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Align(
            alignment: Alignment.topLeft,
            child: SingleChildScrollView(
              key: PageStorageKey('collab-table-${widget.table.id}'),
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width:
                    widths.fold<double>(0, (a, b) => a + b) +
                    (editable ? 24 : 0),
                child: CollabTableGrid(
                  widths: widths,
                  heights: [
                    for (final row in widget.table.children) _rowHeight(row),
                  ],
                  regions: regions,
                  columnHeaders: editable
                      ? [
                          for (var c = 0; c < widths.length; c++)
                            _header(true, c),
                        ]
                      : const [],
                  rowHeaders: editable
                      ? [
                          for (var r = 0; r < widget.table.children.length; r++)
                            _header(false, r),
                        ]
                      : const [],
                  selectedColumn: _column == true ? _index : null,
                  selectedRow: _column == false ? _index : null,
                  children: [
                    for (final area in regions)
                      widget.cellBuilder(context, area.node),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 解除全部借用监听并使已打开菜单失效；不释放编辑器或表格。
  @override
  void dispose() {
    widget.editor.editableNotifier.removeListener(_onTree);
    widget.editor.selectionNotifier.removeListener(_onSelection);
    for (final node in _nodes) {
      node.removeListener(_onTree);
    }
    _menuValid?.value = false;
    super.dispose();
  }
}

/// 浮动菜单返回的方向请求，不与具体共享数据动作混用。
enum _AxisAction {
  /// 在所选行列之前插入。
  before,

  /// 在所选行列之后插入。
  after,

  /// 删除当前整行或整列。
  delete,
}

/// 浮动的两级行列菜单；只返回动作请求，不持有或修改共享表格。
class _AxisMenu extends StatefulWidget {
  /// [group]为表格点击分组；[column]区分行列；[canDelete]保护最后行列；[valid]由父控件持有。
  const _AxisMenu({
    required this.group,
    required this.column,
    required this.canDelete,
    required this.valid,
  });

  /// 与表格共用的点击分组，外部点击才退出表格激活状态。
  final Object group;

  /// true为列菜单，false为行菜单。
  final bool column;

  /// 是否存在可删除的其他行或列。
  final bool canDelete;

  /// 借用会话可用性，旧表或旧权限失效后永久禁用。
  final ValueListenable<bool> valid;

  /// 创建仅持有菜单层级的状态。
  @override
  State<_AxisMenu> createState() => _AxisMenuState();
}

/// 直接显示前插、后插与删除，保留权限和最后行列保护。
class _AxisMenuState extends State<_AxisMenu> {
  /// 为借用 [context] 构建 [label] 对应的 [action]；[icon] 为装饰图标。
  Widget _item(
    BuildContext context,
    String label,
    _AxisAction action,
    IconData icon,
  ) => ListTile(
    leading: Icon(
      icon,
      color: action == _AxisAction.delete
          ? CollabModalColors.of(context).danger
          : null,
    ),
    title: Text(
      label,
      style: action == _AxisAction.delete
          ? TextStyle(color: CollabModalColors.of(context).danger)
          : null,
    ),
    enabled:
        widget.valid.value &&
        (action != _AxisAction.delete || widget.canDelete),
    onTap: () => Navigator.pop(context, action),
  );

  /// 在借用 [context] 中显示仍有效的行列动作，定位和退场由共用浮层负责。
  @override
  Widget build(BuildContext context) => TapRegion(
    groupId: widget.group,
    child: ValueListenableBuilder<bool>(
      valueListenable: widget.valid,
      builder: (context, valid, _) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _item(
            context,
            widget.column ? '向左插入列' : '向上插入行',
            _AxisAction.before,
            LucideIcons.panelLeftOpen,
          ),
          _item(
            context,
            widget.column ? '向右插入列' : '向下插入行',
            _AxisAction.after,
            LucideIcons.panelRightOpen,
          ),
          const Divider(height: 15),
          _item(
            context,
            widget.column ? '删除列' : '删除行',
            _AxisAction.delete,
            LucideIcons.trash2,
          ),
        ],
      ),
    ),
  );
}
