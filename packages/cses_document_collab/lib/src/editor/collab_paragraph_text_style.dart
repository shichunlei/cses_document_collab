import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/model/collab_block_colors.dart';
import 'package:cses_document_collab/src/model/collab_paragraph_style.dart';
import 'package:flutter/material.dart';

/// 按借用 [node] 的段落排版、[attributes] 的字符外观修饰 [base]。
/// 字号采用桌面像素/倍率，字距采用 em；字体由平台解析并回退，不下载字体。
/// [applyParagraph] 默认 true；行内修饰仅在 [base] 已保留段落/标题样式时传 false，
/// 避免标题级别和段落倍率被忽略或重复计算；行内固定字号仍只应用一次段落倍率。
/// 旧CSS字号忽略首尾空白和单位大小写，像素及倍率按发布版范围和精度校验；非法值继承。
/// 空段落默认格式只用于排版和光标高度，不向正文插入占位字符。
TextStyle collabParagraphTextStyle(
  Node node,
  TextStyle base,
  Map<String, dynamic> attributes, {
  bool applyParagraph = true,
}) {
  final props = readCollabParagraph(node).values;
  final level = node.attributes[HeadingBlockKeys.level];
  final semanticScale = node.type == HeadingBlockKeys.type
      ? switch (level) {
          1 => 2.0,
          2 => 1.8,
          3 => 1.6,
          4 => 1.4,
          _ => 1.0,
        }
      : 1.0;
  final paragraphScale = _boundedNumber(props['pfs'], .5, 3) ?? 1;
  final fixed = _boundedNumber(props['fs'], .1, 4096, precision: 1000000);
  final size = applyParagraph
      ? fixed == null
            ? (base.fontSize ?? 16) *
                  (semanticScale * paragraphScale * 1000).round() /
                  1000
            : fixed * paragraphScale
      : base.fontSize ?? 16;
  final normalized = normalizeParagraphTextDefaults(attributes);
  final compactScale = _number(normalized['t:fs']);
  final legacySize = attributes['s:fontSize'];
  final legacy = legacySize is String
      ? RegExp(
          r'^([+]?(?:\d+(?:\.\d+)?|\.\d+))(em|px)$',
          caseSensitive: false,
        ).firstMatch(legacySize.trim())
      : null;
  final px = legacy?[2]?.toLowerCase() == 'px'
      ? _boundedNumber(legacy![1], .1, 4096, precision: 1000000)
      : null;
  final em = legacy?[2]?.toLowerCase() == 'em'
      ? _boundedNumber(legacy![1], .5, 3)
      : null;
  final pixels =
      _number(normalized['t:px']) ?? (compactScale == null ? px : null);
  final actualSize =
      (pixels == null ? size : pixels * paragraphScale) *
      (compactScale ?? em ?? 1);
  final family = normalized['t:ff'];
  final legacySpacing = attributes['s:letterSpacing'];
  final spacing = legacySpacing is String
      ? RegExp(
          r'^([-+]?(?:\d+(?:\.\d+)?|\.\d+))(em|px)$',
          caseSensitive: false,
        ).firstMatch(legacySpacing.trim())
      : null;
  final oldSpacing = spacing == null
      ? null
      : double.parse(spacing[1]!) *
            (spacing[2]!.toLowerCase() == 'em' ? actualSize : 1);
  const families = {
    'sans': '',
    'arial': 'Arial',
    'calibri': 'Calibri',
    'verdana': 'Verdana',
    'tahoma': 'Tahoma',
    'hei': 'SimHei',
    'yahei': 'Microsoft YaHei',
    'pingfang': 'PingFang SC',
    'serif': 'serif',
    'times': 'Times New Roman',
    'georgia': 'Georgia',
    'simsun': 'SimSun',
    'kai': 'KaiTi',
    'xingkai': 'STXingkai',
    'fang': 'FangSong',
    'dengxian': 'DengXian',
    'lishu': 'LiSu',
    'youyuan': 'YouYuan',
    'cambria': 'Cambria',
    'palatino': 'Palatino',
    'trebuchet': 'Trebuchet MS',
    'mono': 'monospace',
    'courier': 'Courier New',
  };
  final decorations = <TextDecoration>[
    if (base.decoration != null) base.decoration!,
    if (attributes[AppFlowyRichTextKeys.underline] == true)
      TextDecoration.underline,
    if (attributes[AppFlowyRichTextKeys.strikethrough] == true)
      TextDecoration.lineThrough,
  ];
  return base.copyWith(
    fontSize: actualSize,
    fontFamily:
        families[family] ??
        attributes['s:fontFamily'] as String? ??
        (attributes[AppFlowyRichTextKeys.code] == true
            ? 'monospace'
            : base.fontFamily),
    fontWeight:
        attributes[AppFlowyRichTextKeys.bold] == true ||
            node.type == HeadingBlockKeys.type
        ? FontWeight.bold
        : base.fontWeight,
    fontStyle: attributes[AppFlowyRichTextKeys.italic] == true
        ? FontStyle.italic
        : base.fontStyle,
    decoration: decorations.isEmpty
        ? null
        : TextDecoration.combine(decorations),
    color:
        parseCollabBlockColor(
          attributes[AppFlowyRichTextKeys.textColor] as String?,
        ) ??
        base.color,
    backgroundColor:
        parseCollabBlockColor(
          attributes[AppFlowyRichTextKeys.backgroundColor] as String?,
        ) ??
        base.backgroundColor,
    letterSpacing: _number(normalized['t:ls']) == null
        ? oldSpacing ?? base.letterSpacing
        : _number(normalized['t:ls'])! * actualSize,
    height: _number(props['lh']) ?? base.height,
  );
}

/// 将借用的 [value] 解析为有限数字，非法值返回 null。
double? _number(Object? value) {
  final number = value is num
      ? value.toDouble()
      : value is String
      ? double.tryParse(value)
      : null;
  return number != null && number.isFinite ? number : null;
}

/// 将 [value] 按发布版闭区间 [min]～[max] 校验并以 [precision] 量化，默认保留三位小数。
/// 像素字号传1000000保留六位；非法、非有限或越界值返回null，不改写共享原值。
double? _boundedNumber(
  Object? value,
  double min,
  double max, {
  int precision = 1000,
}) {
  final number = _number(value);
  return number != null && number >= min && number <= max
      ? (number * precision + .5).floor() / precision
      : null;
}
