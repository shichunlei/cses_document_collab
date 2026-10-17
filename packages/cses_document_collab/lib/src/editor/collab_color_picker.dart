import 'package:cses_document_collab/src/model/collab_block_colors.dart';
import 'package:cses_document_collab/src/model/collab_color_palette.dart';
import 'package:cses_document_collab/src/native/collab_runtime.dart';
import 'package:flutter/material.dart';

/// 正文、块背景、边框与线条共用的色板；只在点击时回调，不修改借用的颜色。
/// 父级持有权威选区和权限；本组件串行等待保存，捕获失败并显示提示。
///
/// ```dart
/// import 'package:flutter/material.dart';
/// import 'package:cses_document_collab/src/editor/collab_color_picker.dart';
/// import 'package:cses_document_collab/src/model/collab_color_palette.dart';
/// final picker = CollabColorPicker(
///   keyPrefix: 'example-color', selection: const CollabColorSelection('#123456'),
///   onSelected: (value) async { /* 交给所属文档事务保存 */ },
/// );
/// ```
class CollabColorPicker extends StatefulWidget {
  /// [key] 控制身份与状态复用；[keyPrefix] 为色块和菜单提供稳定标识。
  /// [selection] 是当前权威快照；[onSelected] 等待保存，null 表示清除覆盖。
  /// [textColors] 默认 false，文字/线条传 true，背景/边框使用浅色。
  /// [horizontal] 默认 false 使用自动换行；true 适配单行工具栏。
  /// [enabled] 默认 true；[onBack] 非空时显示返回按钮。
  /// [resetLabel] 指定恢复默认提示；[resetKey] 可保留既有入口标识。
  const CollabColorPicker({
    super.key,
    required this.keyPrefix,
    required this.selection,
    required this.onSelected,
    this.textColors = false,
    this.horizontal = false,
    this.enabled = true,
    this.onBack,
    this.resetLabel = '清除颜色',
    this.resetKey,
  });

  /// 必填稳定前缀；预设色的 key 为此前缀加色系 ID。
  final String keyPrefix;

  /// 必填只读颜色快照；组件不将自定义色替换为最近的预设。
  final CollabColorSelection selection;

  /// 必填保存回调；父级负责实时验证文档、权限和选区身份。
  final Future<void> Function(String? value) onSelected;

  /// 是否使用较深文字色，默认 false 使用背景/边框色。
  final bool textColors;

  /// 是否在工具栏内水平滚动，默认 false 自动换行。
  final bool horizontal;

  /// 是否允许选择，默认 true；保存期间也禁止重复点击。
  final bool enabled;

  /// 可选返回动作，不执行保存，由父级管理菜单。
  final VoidCallback? onBack;

  /// 恢复默认项的可访问名称，默认“清除颜色”。
  final String resetLabel;

  /// 可选恢复默认按钮标识，缺省为 keyPrefix-default。
  final Key? resetKey;

  /// 创建仅持有单次保存状态的组件，不拥有文档或订阅。
  @override
  createState() => _CollabColorPickerState();
}

/// 串行保存并在仍挂载时报告错误，关闭后不触发视图更新。
class _CollabColorPickerState extends State<CollabColorPicker> {
  bool _saving = false;

  /// 提交用户选择的 [value]；重复选择无操作，异常留在面板供重试。
  Future<void> _select(String? value) async {
    if (!widget.enabled || _saving) return;
    if (!widget.selection.isMixed &&
        sameCollabColor(widget.selection.value, value)) {
      return;
    }
    setState(() => _saving = true);
    try {
      await widget.onSelected(value);
    } catch (error, stack) {
      CollabDiagnostics.report(
        '颜色设置失败',
        error: error,
        stackTrace: stack,
        tag: 'DocCollab',
      );
      if (mounted) {
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(const SnackBar(content: Text('颜色设置失败，请重试')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 用 [context] 主题绘制默认、九色和已有自定义色；混合选区不选中默认。
  @override
  Widget build(BuildContext context) {
    final value = widget.selection.value;
    final isDefault =
        !widget.selection.isMixed &&
        (value == null ||
            value.trim().isEmpty ||
            (widget.textColors
                ? value.trim() == 'var(--bc-color)'
                : value.trim().toLowerCase() == 'transparent'));
    final custom =
        !isDefault &&
        !widget.selection.isMixed &&
        !collabColorPalette.any(
          (option) => sameCollabColor(
            value,
            widget.textColors ? option.text : option.fill,
          ),
        );
    final children = <Widget>[
      if (widget.onBack != null)
        IconButton(
          key: ValueKey('${widget.keyPrefix}-back'),
          tooltip: '返回',
          onPressed: _saving ? null : widget.onBack,
          icon: const Icon(Icons.arrow_back),
        ),
      _chip(
        widget.resetKey ?? ValueKey('${widget.keyPrefix}-default'),
        widget.resetLabel,
        null,
        isDefault,
      ),
      if (custom)
        _chip(
          ValueKey('${widget.keyPrefix}-custom'),
          '自定义颜色 $value',
          value,
          true,
        ),
      for (final option in collabColorPalette)
        _chip(
          ValueKey('${widget.keyPrefix}-${option.id}'),
          option.label,
          widget.textColors ? option.text : option.fill,
          !widget.selection.isMixed &&
              sameCollabColor(
                value,
                widget.textColors ? option.text : option.fill,
              ),
        ),
    ];
    if (widget.horizontal) {
      return SingleChildScrollView(
        key: ValueKey('${widget.keyPrefix}-menu'),
        scrollDirection: Axis.horizontal,
        child: Row(children: children),
      );
    }
    return Wrap(spacing: 4, runSpacing: 4, children: children);
  }

  /// 绘制 [key] 标识的 [label] 色块，[value] 为原始颜色，null 为恢复默认。
  /// [selected] 控制无障碍和选中边框，标记不依赖被选颜色的亮度。
  Widget _chip(Key key, String label, String? value, bool selected) {
    final colors = Theme.of(context).colorScheme;
    final color = parseCollabBlockColor(value);
    return Semantics(
      key: key,
      container: true,
      label: label,
      button: true,
      selected: selected,
      enabled: widget.enabled && !_saving,
      child: ExcludeSemantics(
        child: IconButton(
          tooltip: label,
          onPressed: widget.enabled && !_saving
              ? () async => _select(value)
              : null,
          style: IconButton.styleFrom(
            minimumSize: const Size(44, 44),
            side: BorderSide(
              color: selected ? colors.primary : Colors.transparent,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          icon: value == null
              ? const Icon(Icons.format_color_reset, size: 22)
              : DecoratedBox(
                  decoration: BoxDecoration(
                    color: widget.textColors ? colors.surface : color,
                    borderRadius: BorderRadius.circular(5),
                    border: Border.all(color: colors.outlineVariant),
                  ),
                  child: SizedBox.square(
                    dimension: 25,
                    child: Center(
                      child: widget.textColors
                          ? Text(
                              'A',
                              style: TextStyle(
                                color: color,
                                fontWeight: FontWeight.w600,
                              ),
                            )
                          : color == null
                          ? const Icon(Icons.palette_outlined, size: 18)
                          : null,
                    ),
                  ),
                ),
        ),
      ),
    );
  }
}
