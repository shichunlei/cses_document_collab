import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/model/collab_block_colors.dart';
import 'package:cses_document_collab/src/model/collab_paragraph_style.dart';
import 'package:cses_document_collab/src/editor/collab_paragraph_indent.dart';
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

/// 每个 builder 仅配置一次，避免多个编辑器重复乘算段落字号。
final _paragraphPresentationBuilders = Expando<BlockComponentBuilder>();

/// 包装借用 [builder] 的文字与缩进配置；[type] 为编辑器节点类型。
/// 普通文本段按桌面depth每级偏移32，标题统一最终字符样式优先级。
/// 返回的 builder 与输入共享配置，不创建监听或可释放资源；宿主仍负责编辑器生命周期。
BlockComponentBuilder configureCollabParagraphPresentation(
  BlockComponentBuilder builder,
  String type,
) {
  final configured = _paragraphPresentationBuilders[builder];
  if (configured != null) return configured;
  final original = builder.configuration.textStyle;
  final originalPadding = builder.configuration.padding;
  final originalPlaceholder = builder.configuration.placeholderTextStyle;
  builder.configuration = builder.configuration.copyWith(
    padding: (node) {
      final padding = originalPadding(node);
      return supportsCollabTextIndent(node)
          ? padding.copyWith(
              left: padding.left + collabParagraphDepth(node) * 32,
            )
          : padding;
    },
    placeholderTextStyle: (node, {textSpan}) => collabParagraphTextStyle(
      node,
      originalPlaceholder(node, textSpan: textSpan),
      paragraphDefaultsToAttributes(
        readCollabParagraph(node).values['textDefaults'],
      ),
    ),
    textStyle: (node, {textSpan}) {
      if (node.delta?.isEmpty != true && textSpan?.children != null) {
        return const TextStyle();
      }
      final attrs = node.delta?.isEmpty == true
          ? paragraphDefaultsToAttributes(
              readCollabParagraph(node).values['textDefaults'],
            )
          : const <String, dynamic>{};
      return collabParagraphTextStyle(
        node,
        original(node, textSpan: textSpan),
        attrs,
      );
    },
  );
  final result = type == HeadingBlockKeys.type
      ? ParagraphBlockComponentBuilder(configuration: builder.configuration)
      : builder;
  _paragraphPresentationBuilders[builder] = result;
  return result;
}
