import 'dart:convert';
import 'dart:math' as math;

import 'package:appflowy_editor/appflowy_editor.dart' hide Path;
import 'package:cses_document_collab/src/editor/blockcraft_json_codec.dart';
import 'package:cses_document_collab/src/editor/blockcraft_snapshot_presets.g.dart';
import 'package:cses_document_collab/src/model/collab_block_colors.dart';
import 'package:cses_document_collab/src/model/collab_date_card.dart';
import 'package:cses_document_collab/src/ui/modal/collab_date_card_visual.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

/// 将借用[root]的文档字号、行高及颜色应用到[fallback]，不应用系统缩放或写回模型。
TextStyle blockCraftSnapshotRootStyle(Node root, TextStyle fallback) {
  final props = BlockCraftJsonCodec.properties(root);
  if (props.isEmpty) {
    return fallback;
  }
  return fallback.copyWith(
    fontSize: props['fs'] == null ? fallback.fontSize : _number(props['fs'], fallback.fontSize ?? 16).clamp(.1, 4096),
    height: props['lh'] == null ? fallback.height : _number(props['lh'], fallback.height ?? 1.5).clamp(.5, 6),
    color: parseCollabBlockColor(props['color'] as String?) ?? fallback.color,
  );
}

/// 为已转换的桌面对象创建原生容器、几何及卡片渲染器；每个视图独占返回的builder。
/// [builders]是借用的基础文档渲染器，不修改输入Map；已有资源/表格/代码沿用正式组件。
///
/// ```dart
/// import 'package:cses_document_collab/cses_document_collab.dart';
/// import 'package:flutter/widgets.dart';
/// Widget body(DocumentEditorController editor) => DocumentEditorView(
///   editorState: editor.editorState,
///   configuration: EditorViewConfiguration(blockBuilders: blockCraftSnapshotBuilders),
/// );
/// // 页面卸载body后由创建者await editor.close()。
/// ```
Map<String, BlockComponentBuilder> blockCraftSnapshotBuilders(Map<String, BlockComponentBuilder> builders) => {
  ...builders,
  for (final kind in BlockCraftJsonCodec.objectFlavours) 'snapshot-$kind': _SnapshotObjectBuilder(kind),
  if (builders['image'] != null) 'image': _SnapshotChildrenBuilder(builders['image']!),
};

/// 合成借用[node]/[text]的桌面字重及艺术字外观到[span]，保留原子对象供后续装饰器渲染。
/// 返回不改变原节点的TextSpan；不消费提及/公式或创建编辑会话。
TextSpan blockCraftSnapshotTextStyle(Node node, TextInsert text, TextSpan span) {
  final attrs = text.attributes ?? {};
  final weight = int.tryParse('${attrs['bc.a:s:fontWeight']}');
  var style = span.style ?? const TextStyle();
  if (weight != null) style = style.copyWith(fontWeight: FontWeight.values[(weight ~/ 100 - 1).clamp(0, 8)]);
  if (BlockCraftJsonCodec.flavour(node) == 'word-art') {
    final props = BlockCraftJsonCodec.properties(node);
    style = style.copyWith(
      fontSize: _number(props['fontSize'] ?? props['fs'], 32),
      color: parseCollabBlockColor('${props['fill'] ?? props['color'] ?? '#224c91'}'),
    );
  }
  return span.copyWith(style: style);
}

/// 为已转换的[text]绘制桌面行内对象；[node]为借用节点，[span]已合成文字外观。
/// 无对象返回null继续通用人员/实体/公式装饰；不保存原始JSON或创建网络会话。
InlineSpan? decorateBlockCraftSnapshotText(Node node, TextInsert text, TextSpan span) {
  final attrs = text.attributes ?? {};
  final style = span.style ?? const TextStyle();
  if (attrs['cses_mention_type'] == 'department') {
    return TextSpan(
      text: text.text.replaceAll('\uFFFC', '@${attrs['cses_inline_mention']}'),
      style: style.copyWith(color: const Color(0xff367cc0)),
    );
  }
  final embedded = {
    for (final entry in attrs.entries)
      if (entry.key.startsWith('bc.e:')) entry.key.substring(5): entry.value,
  };
  if (embedded.isEmpty) {
    return null;
  }
  final key = embedded.keys.single;
  final raw = embedded[key];
  Object? value = raw;
  if (raw is String && raw.trimLeft().startsWith('{')) value = jsonDecode(raw);
  final payload = value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};
  final props = payload['props'] is Map ? Map<String, dynamic>.from(payload['props'] as Map) : payload;
  Widget content;
  if (key == 'image') {
    final url = value is String ? value : '${props['src'] ?? props['url'] ?? ''}';
    content = Image.network(
      url,
      width: _number(attrs['bc.a:width'] ?? props['width'], 100).clamp(1, 1000),
      height: _number(attrs['bc.a:height'] ?? props['height'], 60).clamp(1, 1000),
    );
  } else if (key == 'word-art') {
    content = _inlineObjectText(payload['text'] ?? '', style.copyWith(fontSize: _number(props['fontSize'], 24)));
  } else if (key == 'date') {
    final date = DateTime.tryParse('$value');
    final pattern = '${attrs['bc.a:format'] ?? 'YYYY-MM-DD'}';
    final tokens = date == null
        ? <String, String>{}
        : {
            'YYYY': '${date.year}',
            'MM': '${date.month}'.padLeft(2, '0'),
            'M': '${date.month}',
            'DD': '${date.day}'.padLeft(2, '0'),
            'D': '${date.day}',
            'HH': '${date.hour}'.padLeft(2, '0'),
            'mm': '${date.minute}'.padLeft(2, '0'),
            'dddd': ['周一', '周二', '周三', '周四', '周五', '周六', '周日'][date.weekday - 1],
          };
    content = Text(
      date == null
          ? '$value'
          : pattern.replaceAllMapped(RegExp(r'YYYY|dddd|MM|DD|HH|mm|M|D'), (match) => tokens[match[0]]!),
      style: style,
    );
  } else {
    final kind = key == 'person'
        ? 'person-card'
        : key == 'date'
        ? 'date-card'
        : key;
    if (!BlockCraftJsonCodec.objectFlavours.contains(kind)) throw FormatException('未注册的行内对象：$key');
    if (key == 'date' && value is String) props['date'] = value;
    if (key == 'person' && value is String) props['name'] = value;
    final object = BlockCraftJsonCodec.decodeBlock({
      'id': 'inline-${node.id}',
      'flavour': kind,
      'nodeType': 'void',
      'props': props,
      'meta': <String, Object>{},
      'children': <Object>[],
    });
    content = SizedBox(
      width: _number(props['width'], 160).clamp(1, 1000),
      child: _SnapshotObject(
        node: object,
        kind: kind,
        configuration: const BlockComponentConfiguration(),
        inlineText: payload['text'] is List ? _inlineObjectText(payload['text'], style) : null,
      ),
    );
  }
  return TextSpan(
    style: style,
    children: [
      for (final rune in text.text.runes)
        rune == 0xfffc
            ? WidgetSpan(alignment: PlaceholderAlignment.middle, child: content)
            : TextSpan(text: String.fromCharCode(rune), style: style),
    ],
  );
}

/// 包装图片等资源的原生内容，并渲染实际题注子节点，保留题注富文本和独立编辑。
class _SnapshotChildrenBuilder extends BlockComponentBuilder {
  /// [base]为借用的资源渲染器，由当前视图持有。
  _SnapshotChildrenBuilder(this.base);

  /// 当前视图借用的基础资源构建器。
  final BlockComponentBuilder base;

  /// 复用基础节点校验，不扩大资源协议。
  @override
  BlockComponentValidate get validate => base.validate;

  /// 在[context]保留基础内容及实际子节点。
  @override
  BlockComponentWidget build(BlockComponentContext context) =>
      _SnapshotChildren(node: context.node, configuration: configuration, body: base.build(context));
}

/// 资源内容与题注的组合，不额外持有node.key。
class _SnapshotChildren extends BlockComponentStatelessWidget {
  /// [node]/[configuration]为借用块上下文，[body]负责原资源的生命周期。
  const _SnapshotChildren({required super.node, required super.configuration, required this.body});

  /// 基础资源内容，资源释放仍由对应Widget负责。
  final Widget body;

  /// 在[context]借用当前编辑器递归渲染题注。
  @override
  Widget build(BuildContext context) {
    final state = context.read<EditorState>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [body, for (final child in node.children) state.renderer.build(context, child)],
    );
  }
}

/// 桌面对象已转换节点的builder，不读取原始快照或创建WebView占位。
class _SnapshotObjectBuilder extends BlockComponentBuilder {
  /// [kind]是已注册的桌面对象类型。
  _SnapshotObjectBuilder(this.kind);

  /// 当前组件显式转换的桌面对象类型。
  final String kind;

  /// 只接受与本builder匹配且已转换的节点。
  @override
  BlockComponentValidate get validate =>
      (node) => node.type == 'snapshot-$kind';

  /// 在[context]为实际模型创建原生对象组件。
  @override
  BlockComponentWidget build(BlockComponentContext context) =>
      _SnapshotObject(key: context.node.key, node: context.node, configuration: configuration, kind: kind);
}

/// 拥有子节点布局的原生对象；所有文字叶子仍由正式编辑组件处理。
class _SnapshotObject extends BlockComponentStatelessWidget {
  /// [key]控制身份，[node]/[configuration]借用编辑上下文，[kind]确定对象呈现。
  /// [inlineText]是行内对象独立文字外观，null使用真实块后代，不创建嵌套编辑会话。
  const _SnapshotObject({
    super.key,
    required super.node,
    required super.configuration,
    required this.kind,
    this.inlineText,
  });

  /// 当前组件显式转换的桌面对象类型。
  final String kind;

  /// 行内对象的静态富文本，不获取外层编辑器或对象位置的所有权。
  final Widget? inlineText;

  /// 在[context]渲染已转换的独立属性、几何及可编辑后代。
  @override
  Widget build(BuildContext context) {
    final editor = context.read<EditorState>();
    final props = BlockCraftJsonCodec.properties(node);
    final children = [for (final child in node.children) editor.renderer.build(context, child), ?inlineText];
    final fill =
        parseCollabBlockColor(
          '${props['fill'] ?? props['fillColor'] ?? props['bg'] ?? props['backColor'] ?? (kind == 'shape' ? '#93C5FD' : 'transparent')}',
        ) ??
        Colors.transparent;
    final border =
        parseCollabBlockColor(
          '${props['lineColor'] ?? props['strokeColor'] ?? props['bc'] ?? props['borderColor'] ?? '#b8c4d1'}',
        ) ??
        const Color(0xffb8c4d1);
    if (kind == 'columns') {
      return LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: math.max(constraints.maxWidth, children.length * 180.0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final child in children)
                  Expanded(
                    child: Padding(padding: const EdgeInsets.all(6), child: child),
                  ),
              ],
            ),
          ),
        ),
      );
    }
    if (kind == 'placement-layout' || kind == 'object-group') {
      return LayoutBuilder(
        builder: (context, constraints) {
          final width = _number(props['width'], constraints.maxWidth).clamp(1.0, 4096.0);
          var height = _number(props['height'], 1).clamp(1.0, 4096.0);
          final positioned = <Widget>[];
          for (var i = 0; i < children.length; i++) {
            final childProps = BlockCraftJsonCodec.properties(node.children.elementAt(i));
            final position = '${childProps['position'] ?? '0 0'}'.split(RegExp(r'\s+'));
            final x = _number(position.firstOrNull, 0).clamp(0.0, 4096.0);
            final y = _number(position.elementAtOrNull(1), 0).clamp(0.0, 4096.0);
            final w = _number(childProps['width'], 200).clamp(1.0, 4096.0);
            final h = _number(childProps['height'], 100).clamp(1.0, 4096.0);
            height = math.max(height, y + h);
            positioned.add(Positioned(left: x, top: y, width: w, child: children[i]));
          }
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: width,
              height: height,
              child: Stack(children: positioned),
            ),
          );
        },
      );
    }
    if (kind == 'date-card') {
      return CollabDateCardVisual(card: CollabDateCard(props));
    }
    if (kind == 'person-card') {
      final person = props['frozen'] is Map ? props['frozen'] as Map : props;
      return _card(
        Row(
          children: [
            const Icon(LucideIcons.userRound, size: 36),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${person['name'] ?? person['userName'] ?? person['userId'] ?? ''}',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  if (person['department'] != null || person['dept'] != null)
                    Text('${person['department'] ?? person['dept']}'),
                ],
              ),
            ),
          ],
        ),
        fill,
        border,
      );
    }
    if (kind == 'weather') {
      final weather = props['frozen'] is Map ? props['frozen'] as Map : props;
      return _card(
        Row(
          children: [
            Icon(switch (weather['tone']) {
              'rainy' => LucideIcons.umbrella,
              'snowy' => LucideIcons.snowflake,
              _ => LucideIcons.sun,
            }),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                [
                  weather['location'],
                  if (weather['temp'] != null) '${weather['temp']}°',
                  weather['condition'],
                  if (weather['high'] != null) '${weather['low']}° / ${weather['high']}°',
                ].where((value) => value != null).join('  '),
              ),
            ),
          ],
        ),
        fill,
        border,
      );
    }
    if (kind == 'task-list') {
      final raw = props['items'] ?? props['itemsJson'];
      final parsed = raw is String ? jsonDecode(raw) : raw;
      final items = parsed is List ? parsed : const [];
      return _card(
        Column(
          children: [
            for (final item in items.whereType<Map>())
              Row(
                children: [
                  Icon(
                    item['checked'] == true || item['status'] == 'done' ? LucideIcons.squareCheck : LucideIcons.square,
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: Text('${item['title'] ?? item['name'] ?? item['id'] ?? ''}')),
                ],
              ),
          ],
        ),
        fill,
        border,
      );
    }
    if (kind == 'mind-map') {
      final raw = props['data'] ?? props['root'] ?? props['content'];
      final tree = raw is String ? jsonDecode(raw) : raw;
      if (tree is! Map) {
        return _card(
          Row(
            children: [
              const Icon(LucideIcons.network),
              const SizedBox(width: 8),
              Expanded(
                child: Text('${props['title'] ?? '思维导图'}\n${props['referenceDocumentId'] ?? props['graphId'] ?? ''}'),
              ),
            ],
          ),
          fill,
          border,
        );
      }
      return _card(_mindMap(tree, 0), fill, border);
    }
    if (kind == 'shape' || kind == 'sticker') {
      final width = _number(props['width'], 240).clamp(1.0, 4096.0);
      final height = _number(props['height'], 120).clamp(1.0, 4096.0);
      return Align(
        alignment: Alignment.centerLeft,
        child: SizedBox(
          width: width,
          height: height,
          child: Stack(
            fit: StackFit.expand,
            children: [
              SvgPicture.string(
                kind == 'sticker'
                    ? _stickerSvg(props)
                    : props['customGeometry'] is String
                    ? _customShapeSvg(props['customGeometry'] as String, fill, border)
                    : _presetShapeSvg('${props['shape'] ?? 'rectangle'}', fill, border),
                fit: BoxFit.fill,
              ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: Column(mainAxisAlignment: MainAxisAlignment.center, children: children),
              ),
            ],
          ),
        ),
      );
    }
    Widget content = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
    if (kind == 'text-box') {
      content = _card(content, fill, border);
    } else if (kind == 'render-unit') {
      content = _card(content, fill, border);
    }
    final rotation = _number(props['rotation'], 0);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Transform.rotate(angle: rotation * math.pi / 180, child: content),
    );
  }
}

/// 将[child]放入实际对象外框；[fill]/[border]为已解析的颜色。
Widget _card(Widget child, Color fill, Color border) => Container(
  margin: const EdgeInsets.symmetric(vertical: 6),
  padding: const EdgeInsets.all(12),
  decoration: BoxDecoration(
    color: fill,
    border: Border.all(color: border),
    borderRadius: BorderRadius.circular(8),
  ),
  child: child,
);

/// 将行内对象的[content]转为原生静态富文本，使用[base]作为缺省样式；不把数据结构直接显示为文本。
Widget _inlineObjectText(Object? content, TextStyle base) {
  if (content is! List) return Text(content is String ? content : '', style: base);
  final delta = BlockCraftJsonCodec.decodeInline(content);
  return Text.rich(
    TextSpan(
      style: base,
      children: [
        for (final run in delta.whereType<TextInsert>())
          TextSpan(
            text: run.text.replaceAll(
              '\uFFFC',
              '${run.attributes?['cses_inline_mention'] ?? run.attributes?['cses_inline_latex'] ?? ''}',
            ),
            style: base.copyWith(
              fontWeight: run.attributes?['bold'] == true ? FontWeight.bold : base.fontWeight,
              fontStyle: run.attributes?['italic'] == true ? FontStyle.italic : base.fontStyle,
              color: parseCollabBlockColor(run.attributes?['font_color'] as String?) ?? base.color,
              backgroundColor: parseCollabBlockColor(run.attributes?['bg_color'] as String?),
              fontSize: run.attributes?['t:px'] is num ? (run.attributes!['t:px'] as num).toDouble() : base.fontSize,
              decoration: TextDecoration.combine([
                if (run.attributes?['underline'] == true) TextDecoration.underline,
                if (run.attributes?['strikethrough'] == true) TextDecoration.lineThrough,
              ]),
            ),
          ),
      ],
    ),
  );
}

/// 读取有限数值[value]，非法或缺省使用[fallback]，不修改模型。
double _number(Object? value, double fallback) {
  final number = value is num ? value.toDouble() : double.tryParse('$value');
  return number != null && number.isFinite ? number : fallback;
}

/// 将思维导图[tree]转为原生缩进树；[depth]限制显示递归，不生成原始JSON文本。
Widget _mindMap(Object? tree, int depth) {
  if (depth > 32 || tree is! Map) return const SizedBox.shrink();
  final data = tree['data'] is Map ? tree['data'] as Map : tree;
  return Padding(
    padding: EdgeInsets.only(left: depth == 0 ? 0 : 20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('${data['text'] ?? data['topic'] ?? data['title'] ?? ''}'),
        for (final child in tree['children'] as List? ?? []) _mindMap(child, depth + 1),
      ],
    ),
  );
}

/// 将已转换的紧凑路径[geometry]绘制为SVG；[fill]/[stroke]为原生颜色。
String _customShapeSvg(String geometry, Color fill, Color stroke) {
  final parts = geometry.split('|');
  final size = parts.elementAtOrNull(1)?.split(' ') ?? ['100', '100'];
  final paths = parts.where((part) => part.startsWith('f:') || part.startsWith('s:'));
  return '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${size.first} ${size.elementAtOrNull(1) ?? 100}">${paths.map((part) => '<path d="${const HtmlEscape().convert(part.substring(2))}" fill="${part.startsWith('f:') ? '#${fill.toARGB32().toRadixString(16).substring(2)}' : 'none'}" stroke="#${stroke.toARGB32().toRadixString(16).substring(2)}"/>').join()}</svg>';
}

/// 将形状[type]的同源矢量路径与[fill]/[stroke]组合为可缩放图形。
String _presetShapeSvg(String type, Color fill, Color stroke) {
  final path = snapshotShapePaths[type];
  if (path == null) throw FormatException('未注册的形状：$type');
  return '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1000 1000"><path d="$path" fill="${_svgColor(fill)}" stroke="${_svgColor(stroke)}" stroke-width="5"/></svg>';
}

/// 按已转换的[props]恢复同源贴纸的色槽覆盖，未知预设报错，不用其他图形冒充。
String _stickerSvg(Map<String, dynamic> props) {
  final preset = snapshotStickerPresets[props['presetId']];
  if (preset == null) throw FormatException('未注册的贴纸：${props['presetId']}');
  var svg = preset['svg'] as String;
  final defaults = preset['colors'] as Map;
  final colors = props['colors'] as Map? ?? {};
  for (final key in colors.keys) {
    final color = parseCollabBlockColor('${colors[key]}');
    if (defaults[key] is String && color != null) svg = svg.replaceAll(defaults[key] as String, _svgColor(color));
  }
  return svg;
}

/// 将原生[color]转为保留透明度的SVG颜色，不产生平台资源。
String _svgColor(Color color) =>
    'rgba(${(color.r * 255).round()},${(color.g * 255).round()},${(color.b * 255).round()},${color.a})';
