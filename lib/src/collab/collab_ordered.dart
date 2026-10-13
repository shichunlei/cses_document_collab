import 'dart:convert';

/// BlockCraft 有序列表的不可变编号投影与显式设置动作；序号由 Rust 按正式兄弟结构计算。
///
/// ```dart
/// import 'package:cses_mobile_collab_demo/src/collab/collab_ordered.dart';
/// const item = CollabOrdered(order: 1);
/// final marker = item.marker(0); // 2.
/// ```
final class CollabOrdered {
  /// [order] 为零基序号；[start] 为显式一基起始值，null 表示续号。
  /// [heading] 为计数器标题级别，默认 0；[markerStyle] 为桌面 ms 预设，null 使用层级样式。
  /// [needsRepair] 表示原生共享 order 缺失或过期，供握手后补齐；本对象不持有资源。
  /// [numbering] 是仅含 start/continuePrevious 的原始 JSON 对象，默认空对象；
  /// 保留缺失、null、0 和自定义起点的区别，供撤销恢复。[numberingEdit] 仅在本地
  /// 编号设置事务发布时非 null，普通快照和远端回放不会将设置当作命令写回。
  /// 新身份转换恢复有序历史时，Rust 使用 [numbering] 初始化原设置，派生序号重新计算。
  const CollabOrdered({
    required this.order,
    this.start,
    this.heading = 0,
    this.markerStyle,
    this.needsRepair = false,
    this.numbering = '{}',
    this.numberingEdit,
  });

  /// 零基结构序号，0 显示为 1。
  final int order;

  /// 用户显式设置的一基起始编号；null 不重开计数器。
  final int? start;

  /// 与缩进共同划分计数器的标题级别，0 表示普通列表。
  final int heading;

  /// 桌面 ms 预设；未知值保留并按层级回退。
  final String? markerStyle;

  /// 是否需要在完整握手后补写原生 order；不会在 build 中触发写入。
  final bool needsRepair;

  /// 原生编号设置的 JSON 对象，仅含 start/continuePrevious，不包含派生 order 或 ms。
  final String numbering;

  /// 待消费的完整编号设置 JSON；null 表示只读投影，不允许覆盖原生编号设置。
  final String? numberingEdit;

  /// 桌面是否显式选择继续模式；正起点优先，非法原始值仅保留供撤销而不激活菜单项。
  bool get continuesPrevious =>
      !restarts && jsonDecode(numbering)['continuePrevious'] == true;

  /// 桌面是否存在正起点；按桌面数值转换处理历史字符串和布尔值。
  bool get restarts {
    final raw = jsonDecode(numbering)['start'];
    final value = raw == true ? 1 : num.tryParse('$raw');
    return value != null && value.isFinite && value >= 1;
  }

  /// 返回带 [value] 原始编号设置的新投影；[edited] 默认 false，只有显式本地
  /// 设置事务传 true 生成一次性写入意图。保留样式、标题和派生序号，不持有资源。
  CollabOrdered withNumbering(String value, {bool edited = false}) =>
      CollabOrdered(
        order: order,
        start: start,
        heading: heading,
        markerStyle: markerStyle,
        needsRepair: needsRepair,
        numbering: value,
        numberingEdit: edited ? value : null,
      );

  /// 从 AppFlowy 节点内的 [json] 恢复投影；缺失值使用无资源的默认编号。
  factory CollabOrdered.fromJson(Map<String, dynamic> json) => CollabOrdered(
    order: (json['order'] as num?)?.toInt() ?? 0,
    start: (json['start'] as num?)?.toInt(),
    heading: (json['heading'] as num?)?.toInt() ?? 0,
    markerStyle: json['ms'] as String?,
    needsRepair: json['needsRepair'] == true,
    numbering: json['numbering'] as String? ?? '{}',
  );

  /// 返回仅供 AppFlowy 内存属性使用的 Map，不直接作为 WS 协议或原生 props 写入。
  Map<String, dynamic> toJson() => {
    'order': order,
    'start': start,
    'heading': heading,
    'ms': markerStyle,
    'needsRepair': needsRepair,
    'numbering': numbering,
  };

  /// 按桌面的 [depth] 层级与 ms 预设格式化标记；圆圈边框由 Widget 绘制。
  /// [depth] 默认调用方提供 0～6；未知样式回退数字/字母/罗马数字循环。
  String marker(int depth) {
    final value = order + 1;
    return switch (markerStyle) {
      'n1' => '$value.',
      'n2' => '$value)',
      'n3' => '（$value）',
      'n4' => '$value、',
      'n5' => '${value.toString().padLeft(2, '0')}.',
      'a1' => '${_letters(value)}.',
      'a2' => '${_letters(value).toUpperCase()}.',
      'r1' => '${_roman(value).toLowerCase()}.',
      'r2' => '${_roman(value)}.',
      'c1' => '${_chinese(value, false)}、',
      'c2' => '${_chinese(value, true)}、',
      'o1' => '$value',
      _ => switch (depth % 3) {
        1 => '${_letters(value)}.',
        2 => '${_roman(value, limit: false)}.',
        _ => '$value.',
      },
    };
  }

  /// 将一基正整数 [value] 转为桌面使用的小写字母序列。
  static String _letters(int value) {
    var text = '';
    while (value > 0) {
      value--;
      text = String.fromCharCode(97 + value % 26) + text;
      value ~/= 26;
    }
    return text;
  }

  /// 将一基 [value] 转为罗马数字；[limit] 默认 true，与桌面 ms 预设的 3999 上限一致。
  /// 层级默认样式传 false，保留桌面的连续 M 表示法。
  static String _roman(int value, {bool limit = true}) {
    if ((limit && value > 3999) || value < 1) return '$value';
    final text = StringBuffer();
    for (final entry in const {
      'M': 1000,
      'CM': 900,
      'D': 500,
      'CD': 400,
      'C': 100,
      'XC': 90,
      'L': 50,
      'XL': 40,
      'X': 10,
      'IX': 9,
      'V': 5,
      'IV': 4,
      'I': 1,
    }.entries) {
      while (value >= entry.value) {
        text.write(entry.key);
        value -= entry.value;
      }
    }
    return text.toString();
  }

  /// 按桌面的 1～9999 范围格式化 [value]；[formal] 选择中文大写，越界回退十进制。
  static String _chinese(int value, bool formal) {
    if (value < 1 || value > 9999) return '$value';
    final digits = formal ? '零壹贰叁肆伍陆柒捌玖' : '零一二三四五六七八九';
    final units = formal ? ['', '拾', '佰', '仟'] : ['', '十', '百', '千'];
    final source = '$value';
    var text = '';
    var zero = false;
    for (var i = 0; i < source.length; i++) {
      final digit = int.parse(source[i]);
      final unit = source.length - i - 1;
      if (digit == 0) {
        zero = true;
        continue;
      }
      if (zero && text.isNotEmpty) text += digits[0];
      zero = false;
      text += digit == 1 && unit == 1 && i == 0
          ? units[unit]
          : '${digits[digit]}${units[unit]}';
    }
    return text;
  }

  /// 比较 [other] 的全部编号投影字段，用于发布去重与远端刷新。
  @override
  bool operator ==(Object other) =>
      other is CollabOrdered &&
      order == other.order &&
      start == other.start &&
      heading == other.heading &&
      markerStyle == other.markerStyle &&
      needsRepair == other.needsRepair &&
      numbering == other.numbering &&
      numberingEdit == other.numberingEdit;

  /// 返回与完整投影相同的哈希，不持有节点或编辑器引用。
  @override
  int get hashCode => Object.hash(
    order,
    start,
    heading,
    markerStyle,
    needsRepair,
    numbering,
    numberingEdit,
  );
}
