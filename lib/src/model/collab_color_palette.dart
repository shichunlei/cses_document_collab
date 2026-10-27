import 'package:cses_document_collab/src/model/collab_block_colors.dart';

/// 桌面 BlockCraft 0.11.21 的九个色系；text 为字色，fill 为背景/边框色。
/// 默认色不在此表中，由调用方删除覆盖属性来恢复继承，不改写已有自定义颜色。
const collabColorPalette =
    <({String id, String label, String text, String fill})>[
      (id: 'gray', label: '灰色', text: '#9B9A97', fill: '#EBECED'),
      (id: 'brown', label: '棕色', text: '#64473A', fill: '#E9E5E3'),
      (id: 'orange', label: '橙色', text: '#D9730D', fill: '#FAEBDD'),
      (id: 'yellow', label: '黄色', text: '#DFAB01', fill: '#FBF3DB'),
      (id: 'green', label: '绿色', text: '#0F7B6C', fill: '#DDEDEA'),
      (id: 'blue', label: '蓝色', text: '#0B6E99', fill: '#DDEBF1'),
      (id: 'purple', label: '紫色', text: '#6940A5', fill: '#EAE4F2'),
      (id: 'pink', label: '粉色', text: '#AD1A72', fill: '#F4DFEB'),
      (id: 'red', label: '红色', text: '#E03E3E', fill: '#FBE4E4'),
    ];

/// 比较借用的 [first] 与 [second]，识别 CSS/ARGB 的等价颜色。
/// 未设置值（null 或空串）彼此等价；未知 CSS 表达式仅在原文相同时等价，
/// 不将解析失败的自定义色当作默认色，也不改写任何持久化值。
bool sameCollabColor(String? first, String? second) {
  final a = first?.trim() ?? '';
  final b = second?.trim() ?? '';
  if (a == b) return true;
  final left = parseCollabBlockColor(a);
  final right = parseCollabBlockColor(b);
  return left != null && right != null && left.toARGB32() == right.toARGB32();
}

/// 将用户新选的 CSS [value] 编码为 AppFlowy 行内颜色；null 清除覆盖。
/// 无法解析的既有 CSS 原文直接透传，不做预设色替换。
String? collabColorToEditor(String? value) {
  if (value == null) return null;
  final color = parseCollabBlockColor(value);
  return color == null
      ? value
      : '0x${color.toARGB32().toRadixString(16).padLeft(8, '0')}';
}

/// 颜色选择快照，显式区分混合选区和恢复默认，保留自定义色原文。
///
/// ```dart
/// import 'package:cses_document_collab/src/model/collab_color_palette.dart';
/// final selection = CollabColorSelection.fromValues(['#123456', '0xff123456']);
/// assert(!selection.isMixed && selection.value == '#123456');
/// ```
class CollabColorSelection {
  /// 创建单值快照；[value] 为借用的原始颜色，null 表示未设置。
  const CollabColorSelection(this.value) : isMixed = false;

  /// 创建混合快照，不以 null 冒充默认色。
  const CollabColorSelection.mixed() : value = null, isMixed = true;

  /// 汇总 [values] 中的颜色；空集合视为未设置，等价颜色保留首个原文。
  factory CollabColorSelection.fromValues(Iterable<String?> values) {
    final iterator = values.iterator;
    if (!iterator.moveNext()) return const CollabColorSelection(null);
    final first = iterator.current;
    while (iterator.moveNext()) {
      if (!sameCollabColor(first, iterator.current)) {
        return const CollabColorSelection.mixed();
      }
    }
    return CollabColorSelection(first);
  }

  /// 单色选区的原始值；混合时为 null，须结合 [isMixed] 判断。
  final String? value;

  /// 是否存在多个不同颜色；为 true 时所有色块均不显示选中标记。
  final bool isMixed;
}
