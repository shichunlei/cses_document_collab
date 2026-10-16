import 'package:cses_document_collab/src/model/collab_table.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// 原生可变行高网格；按单元格正文自然高度计算跨度区域，不裁剪长正文。
/// ```dart
/// import 'package:cses_document_collab/src/editor/collab_table_grid.dart';
/// import 'package:cses_document_collab/src/model/collab_table.dart';
/// import 'package:flutter/widgets.dart';
/// final regions = collabTableRegions(createCollabTable(2, 2));
/// final grid = CollabTableGrid(widths: [120, 120], heights: [60, 60],
///   regions: regions, children: [for (final area in regions) Text('${area.row + 1}行')]);
/// ```
class CollabTableGrid extends MultiChildRenderObjectWidget {
  /// [key]控制身份；[widths]/[heights]为正的逻辑像素尺寸；[regions]与[children]按相同顺序排列。
  /// [columnHeaders]/[rowHeaders]为可选操作条；[selectedColumn]/[selectedRow]为本地高亮索引。
  /// 子组件、尺寸及区域由调用方持有，网格不释放编辑器资源。
  CollabTableGrid({
    super.key,
    required this.widths,
    required this.heights,
    required this.regions,
    required List<Widget> children,
    this.columnHeaders = const [],
    this.rowHeaders = const [],
    this.selectedColumn,
    this.selectedRow,
  }) : super(children: [...children, ...columnHeaders, ...rowHeaders]);

  /// 每列的实际显示宽度。
  final List<double> widths;

  /// 每行的最小显示高度，正文较长时自动增高。
  final List<double> heights;

  /// 可见格覆盖关系，不含隐藏格。
  final List<CollabTableRegion> regions;

  /// 顶部列操作条；为空时不预留顶部空间，由调用方持有交互状态。
  final List<Widget> columnHeaders;

  /// 左侧行操作条；为空时不预留左侧空间，数量须与行数一致。
  final List<Widget> rowHeaders;

  /// 选中整列的0起始索引；null不绘制列高亮。
  final int? selectedColumn;

  /// 选中整行的0起始索引；null不绘制行高亮。
  final int? selectedRow;

  /// 在借用[context]中创建只负责网格测量和绘制的渲染对象。
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _TableGridRender(widths, heights, regions)..setControls(
        columnHeaders.isNotEmpty,
        rowHeaders.isNotEmpty,
        selectedColumn,
        selectedRow,
      );

  /// 将当前布局输入同步给[renderObject]；[context]用于框架更新阶段，不持有资源。
  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderObject renderObject,
  ) {
    (renderObject as _TableGridRender)
      ..update(widths, heights, regions)
      ..setControls(
        columnHeaders.isNotEmpty,
        rowHeaders.isNotEmpty,
        selectedColumn,
        selectedRow,
      );
  }
}

/// 各可见单元格在网格中的绘制偏移，由父渲染对象持有。
class _GridParentData extends ContainerBoxParentData<RenderBox> {}

/// 使用正文自然高度分配行高，再按跨度提供完整命中与选择区域。
class _TableGridRender extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _GridParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _GridParentData> {
  /// 借用[widths]、[heights]和[regions]作为只读布局输入，不接管编辑器资源。
  _TableGridRender(this._widths, this._heights, this._regions);

  /// 每列显示宽度，与区域列索引对应。
  List<double> _widths;

  /// 正文布局前的最小行高。
  List<double> _heights;

  /// 与渲染子节点一一对应的逻辑区域。
  List<CollabTableRegion> _regions;

  /// 操作条存在时的布局留白，单位为逻辑像素。
  double _top = 0, _left = 0;

  /// 当前整行/列的本地选中索引，不写入共享属性。
  int? _selectedColumn, _selectedRow;

  /// 正文自然高度计算后的行高，用于命中与选择高亮。
  List<double> _actualHeights = [];

  /// 设置[columnHeaders]/[rowHeaders]是否存在及[column]/[row]的本地选中索引。
  void setControls(bool columnHeaders, bool rowHeaders, int? column, int? row) {
    final top = columnHeaders ? 32.0 : 0.0;
    final left = rowHeaders ? 24.0 : 0.0;
    if (_top != top || _left != left) markNeedsLayout();
    _top = top;
    _left = left;
    _selectedColumn = column;
    _selectedRow = row;
    markNeedsPaint();
  }

  /// 使用[widths]、[heights]、[regions]替换只读布局输入并请求重新布局。
  void update(
    List<double> widths,
    List<double> heights,
    List<CollabTableRegion> regions,
  ) {
    _widths = widths;
    _heights = heights;
    _regions = regions;
    markNeedsLayout();
  }

  /// 为借用[child]安装网格偏移数据，不修改子节点内容。
  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _GridParentData) {
      child.parentData = _GridParentData();
    }
  }

  /// 读取[values]中从[start]开始的[count]项总尺寸，单位逻辑像素。
  double _sum(List<double> values, int start, int count) =>
      values.skip(start).take(count).fold(0, (a, b) => a + b);

  /// 按单格、合并格的自然高度依次扩展行高；覆盖格共用同一组行边界。
  @override
  void performLayout() {
    final children = <RenderBox>[];
    RenderBox? child = firstChild;
    while (child != null) {
      children.add(child);
      child = childAfter(child);
    }
    final heights = List<double>.from(_heights);
    for (var i = 0; i < _regions.length; i++) {
      final area = _regions[i];
      children[i].layout(
        BoxConstraints.tightFor(
          width: _sum(_widths, area.column, area.columns),
        ),
        parentUsesSize: true,
      );
    }
    final order = List.generate(_regions.length, (i) => i)
      ..sort((a, b) => _regions[a].rows.compareTo(_regions[b].rows));
    for (final i in order) {
      final area = _regions[i];
      final extra =
          children[i].size.height - _sum(heights, area.row, area.rows);
      if (extra > 0) {
        for (var r = area.row; r < area.row + area.rows; r++) {
          heights[r] += extra / area.rows;
        }
      }
    }
    for (var i = 0; i < _regions.length; i++) {
      final area = _regions[i];
      final child = children[i];
      child.layout(
        BoxConstraints.tightFor(
          width: _sum(_widths, area.column, area.columns),
          height: _sum(heights, area.row, area.rows),
        ),
      );
      (child.parentData! as _GridParentData).offset = Offset(
        _left + _sum(_widths, 0, area.column),
        _top + _sum(heights, 0, area.row),
      );
    }
    _actualHeights = heights;
    var headerIndex = _regions.length;
    if (_top > 0) {
      for (var c = 0; c < _widths.length; c++) {
        final header = children[headerIndex++];
        header.layout(BoxConstraints.tight(Size(_widths[c], _top)));
        (header.parentData! as _GridParentData).offset = Offset(
          _left + _sum(_widths, 0, c),
          0,
        );
      }
    }
    if (_left > 0) {
      for (var r = 0; r < heights.length; r++) {
        final header = children[headerIndex++];
        header.layout(BoxConstraints.tight(Size(_left, heights[r])));
        (header.parentData! as _GridParentData).offset = Offset(
          0,
          _top + _sum(heights, 0, r),
        );
      }
    }
    size = constraints.constrain(
      Size(
        _left + _sum(_widths, 0, _widths.length),
        _top + _sum(heights, 0, heights.length),
      ),
    );
  }

  /// 为[constraints]提供最小网格尺寸；实际正文高度在正式布局时测量。
  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.constrain(
    Size(
      _left + _sum(_widths, 0, _widths.length),
      _top + _sum(_heights, 0, _heights.length),
    ),
  );

  /// 在[context]的[offset]处按网格顺序绘制子节点。
  @override
  void paint(PaintingContext context, Offset offset) {
    defaultPaint(context, offset);
    Rect? selected;
    final column = _selectedColumn;
    final row = _selectedRow;
    if (column != null && column < _widths.length) {
      selected = Rect.fromLTWH(
        _left + _sum(_widths, 0, column),
        _top,
        _widths[column],
        size.height - _top,
      );
    } else if (row != null && row < _actualHeights.length) {
      selected = Rect.fromLTWH(
        _left,
        _top + _sum(_actualHeights, 0, row),
        size.width - _left,
        _actualHeights[row],
      );
    }
    if (selected != null) {
      context.canvas.drawRect(
        selected.shift(offset),
        Paint()..color = const Color(0x291759EE),
      );
    }
  }

  /// 将[position]的命中结果写入[result]，使用合并格的完整布局范围。
  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}
