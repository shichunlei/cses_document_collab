import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/model/collab_resource.dart';

/// 正式表格、行及单元格的容器类型；正文是其下独立的可编辑节点。
const collabTableTypes = {'table', 'table-row', 'table-cell'};

/// 表格布局属性的本地投影；写回时按与上一快照的差异生成字段补丁。
const collabTableLayoutAttribute = 'cses_table_layout';

/// 判断 [type] 是否拥有独立子块的已适配容器，不转移节点所有权。
bool isCollabContainerType(String type) =>
    type == 'callout' || collabTableTypes.contains(type);

/// 读取借用 [node] 的表格布局；null或缺失属性返回空Map，不生成默认值写回。
Map<String, dynamic> collabTableLayout(Node? node) {
  final raw = node?.attributes[collabTableLayoutAttribute];
  return raw is Map
      ? CollabResource.fromJson(Map<String, dynamic>.from(raw)).values
      : <String, dynamic>{};
}

/// 从 [attributes] 读取布局，以 [previous] 计算显式字段差异；未变字段不覆盖远端数据。
CollabResource readCollabTable(
  Map<String, dynamic> attributes,
  CollabResource? previous,
) {
  final raw = attributes[collabTableLayoutAttribute];
  final resource = raw is Map
      ? CollabResource.fromJson(Map<String, dynamic>.from(raw))
      : const CollabResource();
  final values = resource.values;
  final before = previous?.values ?? const <String, dynamic>{};
  final edits = <String, dynamic>{};
  if (previous != null) {
    for (final key in {...values.keys, ...before.keys}) {
      if (values.containsKey(key) != before.containsKey(key) ||
          jsonEncode(values[key]) != jsonEncode(before[key])) {
        edits[key] = values.containsKey(key)
            ? {'value': values[key]}
            : <String, dynamic>{};
      }
    }
  }
  return CollabResource.fromValues(
    values,
    edits: edits.isEmpty ? null : jsonEncode(edits),
  );
}

/// 返回借用 [node] 的稳定协同身份；新节点使用其原始ID。
String collabTableNodeId(Node node) =>
    node.attributes['cses_collab_block_id'] as String? ?? node.id;

/// 获取 [node] 的 [key] 跨度；缺失或null按桌面缺省值1解释。
int collabTableSpan(Node node, String key) =>
    (collabTableLayout(node)[key] as num?)?.toInt() ?? 1;

/// 一个可见单元格覆盖的逻辑矩形；不拥有[node]或编辑器。
/// ```dart
/// import 'package:cses_document_collab/src/model/collab_table.dart';
/// final table = createCollabTable(2, 2);
/// final firstCell = collabTableRegions(table).first;
/// print(firstCell.columns); // 1
/// ```
class CollabTableRegion {
  /// [node] 为借用单元格；[row]/[column]从0开始；[rows]/[columns]为正跨度。
  const CollabTableRegion(
    this.node,
    this.row,
    this.column,
    this.rows,
    this.columns,
  );

  /// 原始单元格，不转移所有权。
  final Node node;

  /// 首行索引。
  final int row;

  /// 首列索引。
  final int column;

  /// 纵向覆盖行数。
  final int rows;

  /// 横向覆盖列数。
  final int columns;
}

/// 按文档顺序读取借用 [table] 的可见矩形；隐藏格及其正文仍保留在模型中。
List<CollabTableRegion> collabTableRegions(Node table) => [
  for (var r = 0; r < table.children.length; r++)
    for (var c = 0; c < table.children[r].children.length; c++)
      if (collabTableLayout(table.children[r].children[c])['display'] != 'none')
        CollabTableRegion(
          table.children[r].children[c],
          r,
          c,
          collabTableSpan(table.children[r].children[c], 'rowspan'),
          collabTableSpan(table.children[r].children[c], 'colspan'),
        ),
];

/// 按稳定 [id] 在借用的 [state] 中查找表格；关闭或删除后返回null。
Node? findCollabTable(EditorState state, String id) {
  if (state.isDisposed) return null;
  Node? visit(Node node) {
    if (node.type == 'table' && collabTableNodeId(node) == id) return node;
    for (final child in node.children) {
      final found = visit(child);
      if (found != null) return found;
    }
    return null;
  }

  return visit(state.document.root);
}

/// 为借用 [node] 生成完整、稳定的内容指纹，面板提交前用于拒绝过期结构/正文。
String collabTableFingerprint(Node node) => jsonEncode(_tableSnapshot(node));

/// 将借用[node]映射为可序列化的树；只在顶层编码一次，避免嵌套容器反复转义。
Map<String, dynamic> _tableSnapshot(Node node) => {
  'id': collabTableNodeId(node),
  'type': node.type,
  'attributes': node.attributes,
  'children': node.children.map(_tableSnapshot).toList(),
};

/// 按原始身份复制借用 [node]；[children]提供替代子树，[layout]提供替代布局。
/// 返回脱离编辑器的快照，只有后续EditorState事务会写正文与协同。
Node _copyTableNode(
  Node node, {
  Iterable<Node>? children,
  Map<String, dynamic>? layout,
}) => Node(
  id: node.id,
  type: node.type,
  attributes: {
    ...node.attributes,
    'cses_collab_block_id': collabTableNodeId(node),
    if (layout != null)
      collabTableLayoutAttribute: CollabResource.fromValues(layout).toJson(),
  },
  children:
      children ?? node.children.map((child) => _copyTableNode(child)).toList(),
);

/// 创建拥有独立身份的[rows]×[columns]表格；每格包含一个空段落。
/// 行数1～100、列数1～50且总格数≤500；越界抛ArgumentError。
Node createCollabTable(int rows, int columns) {
  if (rows < 1 ||
      rows > 100 ||
      columns < 1 ||
      columns > 50 ||
      rows * columns > 500) {
    throw ArgumentError('表格最多100行、50列且不超过500个单元格');
  }
  return Node(
    type: 'table',
    attributes: {
      collabTableLayoutAttribute: CollabResource.fromValues({
        'colWidths': List.filled(columns, 120),
      }).toJson(),
    },
    children: List.generate(rows, (_) => _newTableRow(columns)),
  );
}

/// 创建[columns]个单元格的新行，行高采用桌面缺省60逻辑像素。
Node _newTableRow(int columns) => Node(
  type: 'table-row',
  attributes: {
    collabTableLayoutAttribute: const CollabResource(
      properties: '{"height":60}',
    ).toJson(),
  },
  children: List.generate(columns, (_) => _newTableCell()),
);

/// 创建带空段落的新单元格，默认顶部对齐。
Node _newTableCell() => Node(
  type: 'table-cell',
  attributes: {
    collabTableLayoutAttribute: const CollabResource(
      properties: '{"verticalAlign":"top"}',
    ).toJson(),
  },
  children: [paragraphNode()],
);

/// 表格编辑动作；均通过完整网格校验后进入单个可撤销事务。
enum CollabTableAction {
  /// 在指定行之前插入行，末尾索引等于行数。
  insertRow,

  /// 删除指定行；不允许删除最后一行。
  deleteRow,

  /// 在指定列之前插入列，末尾索引等于列数。
  insertColumn,

  /// 删除指定列；不允许删除最后一列。
  deleteColumn,

  /// 合并所选逻辑矩形，自动扩展到完整的已有合并区域。
  merge,

  /// 拆分指定可见单元格；正文留在原左上格。
  split,

  /// 修改一列的逻辑像素宽度。
  resizeColumn,
}

/// 为借用 [table] 计算[action]的脱离编辑器快照，不修改原节点。
/// [row]/[column]为0起始目标；[endRow]/[endColumn]为合并终点；[width]为48～480逻辑像素列宽。
/// 删除最后一行/列、空合并、非法索引或超限返回null；合并与删除覆盖区域的原数据由原生层保留以供撤销。
Node? buildCollabTableEdit(
  Node table,
  CollabTableAction action, {
  required int row,
  required int column,
  int? endRow,
  int? endColumn,
  double? width,
}) {
  final sourceRows = table.children;
  if (sourceRows.isEmpty) return null;
  final grid = [
    for (final r in sourceRows)
      r.children.map((c) => _copyTableNode(c)).toList(),
  ];
  final rowNodes = sourceRows
      .map((r) => _copyTableNode(r, children: []))
      .toList();
  final count = grid.first.length;
  if (row < 0 ||
      column < 0 ||
      row > grid.length ||
      column > count ||
      count == 0) {
    return null;
  }
  final tableLayout = collabTableLayout(table);
  final oldWidths = tableLayout['colWidths'];
  final widths = List<double>.generate(
    count,
    (i) => oldWidths is List && i < oldWidths.length && oldWidths[i] is num
        ? (oldWidths[i] as num).toDouble()
        : 120,
  );
  var regions = [
    for (final area in collabTableRegions(table))
      CollabTableRegion(
        grid[area.row][area.column],
        area.row,
        area.column,
        area.rows,
        area.columns,
      ),
  ];
  if (action == CollabTableAction.resizeColumn) {
    if (column >= count ||
        width == null ||
        !width.isFinite ||
        width < 48 ||
        width > 480 ||
        widths[column] == width) {
      return null;
    }
    widths[column] = width;
    return _copyTableNode(table, layout: {...tableLayout, 'colWidths': widths});
  }
  if (action == CollabTableAction.merge) {
    if (row >= grid.length || column >= count) return null;
    var top = row,
        left = column,
        bottom = endRow ?? row,
        right = endColumn ?? column;
    if (bottom < top ||
        right < left ||
        bottom >= grid.length ||
        right >= count) {
      return null;
    }
    var changed = true;
    while (changed) {
      changed = false;
      for (final area in regions) {
        if (area.row <= bottom &&
            area.row + area.rows > top &&
            area.column <= right &&
            area.column + area.columns > left) {
          final nt = area.row < top ? area.row : top;
          final nl = area.column < left ? area.column : left;
          final nb = area.row + area.rows - 1 > bottom
              ? area.row + area.rows - 1
              : bottom;
          final nr = area.column + area.columns - 1 > right
              ? area.column + area.columns - 1
              : right;
          if (nt != top || nl != left || nb != bottom || nr != right) {
            changed = true;
            top = nt;
            left = nl;
            bottom = nb;
            right = nr;
          }
        }
      }
    }
    final selected = regions
        .where(
          (a) =>
              a.row >= top &&
              a.row <= bottom &&
              a.column >= left &&
              a.column <= right,
        )
        .toList();
    if (selected.length < 2) return null;
    final master = grid[top][left];
    final content = master.children.map((n) => _copyTableNode(n)).toList();
    for (final area in selected.skip(1)) {
      final cell = grid[area.row][area.column];
      if (cell.children.any(_tableNodeHasContent)) {
        content.addAll(cell.children.map((n) => _copyTableNode(n)));
        grid[area.row][area.column] = _copyTableNode(cell, children: []);
      }
    }
    grid[top][left] = _copyTableNode(master, children: content);
    regions = [
      for (final a in regions)
        if (!selected.contains(a)) a,
      CollabTableRegion(
        grid[top][left],
        top,
        left,
        bottom - top + 1,
        right - left + 1,
      ),
    ];
  } else if (action == CollabTableAction.split) {
    final selected = regions
        .where((a) => a.row == row && a.column == column)
        .firstOrNull;
    if (selected == null || selected.rows * selected.columns == 1) return null;
    regions.remove(selected);
    for (var r = row; r < row + selected.rows; r++) {
      for (var c = column; c < column + selected.columns; c++) {
        var cell = grid[r][c];
        if (cell.children.isEmpty) {
          cell = _copyTableNode(cell, children: [paragraphNode()]);
        }
        grid[r][c] = cell;
        regions.add(CollabTableRegion(cell, r, c, 1, 1));
      }
    }
  } else {
    final vertical =
        action == CollabTableAction.insertRow ||
        action == CollabTableAction.deleteRow;
    final insert =
        action == CollabTableAction.insertRow ||
        action == CollabTableAction.insertColumn;
    final index = vertical ? row : column;
    final length = vertical ? grid.length : count;
    if ((!insert && (length == 1 || index >= length)) ||
        (insert && index > length)) {
      return null;
    }
    final nextRows = grid.length + (vertical ? (insert ? 1 : -1) : 0);
    final nextColumns = count + (!vertical ? (insert ? 1 : -1) : 0);
    if (nextRows > 100 || nextColumns > 50 || nextRows * nextColumns > 500) {
      return null;
    }
    final transformed = <CollabTableRegion>[];
    for (final a in regions) {
      var start = vertical ? a.row : a.column;
      var span = vertical ? a.rows : a.columns;
      if (insert) {
        if (start >= index) {
          start++;
        } else if (start + span > index) {
          span++;
        }
      } else {
        if (start > index) {
          start--;
        } else if (start + span > index) {
          span--;
        }
        if (span == 0) continue;
      }
      transformed.add(
        CollabTableRegion(
          a.node,
          vertical ? start : a.row,
          vertical ? a.column : start,
          vertical ? span : a.rows,
          vertical ? a.columns : span,
        ),
      );
    }
    if (vertical) {
      if (insert) {
        grid.insert(index, List.generate(count, (_) => _newTableCell()));
        rowNodes.insert(index, _newTableRow(0));
      } else {
        grid.removeAt(index);
        rowNodes.removeAt(index);
      }
    } else {
      for (final cells in grid) {
        if (insert) {
          cells.insert(index, _newTableCell());
        } else {
          cells.removeAt(index);
        }
      }
      if (insert) {
        widths.insert(index, 120);
      } else {
        widths.removeAt(index);
      }
    }
    // 删除合并主格所在的行/列时，把原主格身份移到仍存活的覆盖区域，保留正文。
    for (final a in transformed) {
      final displaced = grid[a.row][a.column];
      grid[a.row][a.column] =
          collabTableNodeId(displaced) != collabTableNodeId(a.node) &&
              displaced.children.any(_tableNodeHasContent)
          ? _copyTableNode(
              a.node,
              children: [
                ...a.node.children.map((n) => _copyTableNode(n)),
                ...displaced.children.map((n) => _copyTableNode(n)),
              ],
            )
          : a.node;
    }
    regions = transformed;
    // 新插入的未覆盖位置成为普通可见格。
    for (var r = 0; r < grid.length; r++) {
      for (var c = 0; c < grid[r].length; c++) {
        if (!regions.any(
          (a) =>
              r >= a.row &&
              r < a.row + a.rows &&
              c >= a.column &&
              c < a.column + a.columns,
        )) {
          regions.add(CollabTableRegion(grid[r][c], r, c, 1, 1));
        }
      }
    }
  }
  final masters = {for (final a in regions) '${a.row}:${a.column}': a};
  for (var r = 0; r < grid.length; r++) {
    for (var c = 0; c < grid[r].length; c++) {
      final cell = grid[r][c];
      final props = collabTableLayout(cell);
      final master = masters['$r:$c'];
      final hidden = master == null;
      if (hidden != (props['display'] == 'none')) {
        props['display'] = hidden ? 'none' : null;
      }
      for (final entry in {
        'rowspan': master?.rows ?? 1,
        'colspan': master?.columns ?? 1,
      }.entries) {
        if ((props[entry.key] as num?)?.toInt() != entry.value &&
            ((props[entry.key] as num?)?.toInt() ?? 1) != entry.value) {
          props[entry.key] = entry.value > 1 ? entry.value : null;
        }
      }
      grid[r][c] = _copyTableNode(cell, layout: props);
    }
  }
  return _copyTableNode(
    table,
    layout: {
      ...tableLayout,
      if (action == CollabTableAction.insertColumn ||
          action == CollabTableAction.deleteColumn)
        'colWidths': widths,
    },
    children: [
      for (var r = 0; r < grid.length; r++)
        _copyTableNode(rowNodes[r], children: grid[r]),
    ],
  );
}

/// 判断借用 [node] 是否有可见正文或非段落内容；纯空段落合并时留在隐藏格。
bool _tableNodeHasContent(Node node) =>
    node.type != 'paragraph' ||
    (node.delta?.toPlainText().isNotEmpty ?? false) ||
    node.children.any(_tableNodeHasContent);

/// 在借用 [state] 中按稳定[tableId]和[expected]指纹提交[action]。
/// [row]/[column]及[endRow]/[endColumn]/[width]语义同buildCollabTableEdit；过期、只读、非法或无变化返回false。
/// 成功为独立可撤销事务；原生层再次校验并保存/广播，不保留编辑器资源。
Future<bool> applyCollabTableEdit(
  EditorState state,
  String tableId,
  String expected,
  CollabTableAction action, {
  required int row,
  required int column,
  int? endRow,
  int? endColumn,
  double? width,
}) async {
  if (state.isDisposed || !state.editable) return false;
  final table = findCollabTable(state, tableId);
  if (table == null || collabTableFingerprint(table) != expected) return false;
  final next = buildCollabTableEdit(
    table,
    action,
    row: row,
    column: column,
    endRow: endRow,
    endColumn: endColumn,
    width: width,
  );
  if (next == null) return false;
  if (state.undoManager.undoStack.isNonEmpty) {
    state.undoManager.undoStack.last.seal();
  }
  final transaction = state.transaction..afterSelection = null;
  if (action == CollabTableAction.resizeColumn) {
    transaction.add(
      UpdateOperation(
        table.path,
        {
          collabTableLayoutAttribute:
              next.attributes[collabTableLayoutAttribute],
        },
        {
          collabTableLayoutAttribute:
              table.attributes[collabTableLayoutAttribute],
        },
      ),
    );
  } else {
    transaction
      ..deleteNode(table)
      ..add(
        InsertOperation(List<int>.from(table.path), [next]),
        transform: false,
      )
      ..afterSelection = null;
  }
  await state.apply(transaction, skipHistoryDebounce: true);
  final current = findCollabTable(state, tableId);
  return current != null && collabTableFingerprint(current) != expected;
}

/// 在借用 [state] 的正文[selection]后插入[rows]×[columns]表格并返回首格光标。
/// [rows]与[columns]默认均为2，数量边界沿用[createCollabTable]。
/// 空正文保留原身份；不支持在表格内嵌套，失效或只读返回null；原生写入由适配器完成。
Future<Selection?> insertCollabTable(
  EditorState state,
  Selection selection, {
  int rows = 2,
  int columns = 2,
}) async {
  if (state.isDisposed || !state.editable || !selection.isCollapsed) {
    return null;
  }
  final node = state.getNodeAtPath(selection.start.path);
  if (node == null || node.delta == null) return null;
  for (
    Node? ancestor = node.parent;
    ancestor != null;
    ancestor = ancestor.parent
  ) {
    if (collabTableTypes.contains(ancestor.type)) return null;
  }
  final table = createCollabTable(rows, columns);
  final path = node.path.next;
  if (state.undoManager.undoStack.isNonEmpty) {
    state.undoManager.undoStack.last.seal();
  }
  await state.apply(
    state.transaction
      ..insertNode(path, table, deepCopy: false)
      ..afterSelection = null,
    skipHistoryDebounce: true,
  );
  return Selection.single(path: path + [0, 0, 0], startOffset: 0);
}
