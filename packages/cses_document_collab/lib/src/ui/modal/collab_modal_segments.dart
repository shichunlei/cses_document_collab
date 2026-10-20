import 'package:cses_document_collab/src/ui/modal/collab_modal_colors.dart';
import 'package:flutter/material.dart';

/// 共用的低矮分段选择器；选中状态及回调由业务持有。
///
/// ```dart
/// import 'package:cses_document_collab/src/ui/modal/collab_modal_segments.dart';
/// import 'package:flutter/material.dart';
/// Widget tabs(int value, ValueChanged<int> select) => CollabModalSegments<int>(
///   values: const {0: '链接', 1: '上传'}, selected: value, onSelected: select);
/// ```
class CollabModalSegments<T> extends StatelessWidget {
  /// [key] 控制身份；[values] 按插入顺序显示；[selected] 为当前值。
  /// [onSelected] 为 null 时禁用；[itemKeys] 可保留各业务入口标识。
  const CollabModalSegments({
    super.key,
    required this.values,
    required this.selected,
    required this.onSelected,
    this.itemKeys = const {},
  });

  /// 各选项的稳定值与显示标签。
  final Map<T, String> values;

  /// 当前选中值，由调用方持有。
  final T selected;

  /// 点击选项时同步回调，null 禁用。
  final ValueChanged<T>? onSelected;

  /// 可选的各选项身份。
  final Map<T, Key> itemKeys;

  /// 在 [context] 中构建4像素内边距、白底紫字的选中态。
  @override
  Widget build(BuildContext context) {
    final c = CollabModalColors.of(context);
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: c.field, borderRadius: BorderRadius.circular(11)),
      child: Row(
        children: [
          for (final entry in values.entries)
            Expanded(
              child: Semantics(
                selected: selected == entry.key,
                button: true,
                child: InkWell(
                  key: itemKeys[entry.key],
                  borderRadius: BorderRadius.circular(8),
                  onTap: onSelected == null ? null : () => onSelected!(entry.key),
                  child: Container(
                    constraints: const BoxConstraints(minHeight: 35),
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 7),
                    decoration: selected == entry.key
                        ? BoxDecoration(
                            color: c.surface,
                            borderRadius: BorderRadius.circular(8),
                            boxShadow: const [BoxShadow(color: Color(0x1F1C1834), blurRadius: 7, offset: Offset(0, 2))],
                          )
                        : null,
                    child: Text(
                      entry.value,
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12, height: 1.55, color: selected == entry.key ? c.accent : c.muted),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
