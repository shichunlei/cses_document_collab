import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/model/collab_resource.dart';

/// 正式桌面日期卡片，无正文和子块。
const collabDateCardType = 'date-card';

/// 桌面样式持久键与中文名称；未知远端样式只读回落台历。
const collabDateCardStyles = {
  'calendar': '台历',
  'square': '方牌',
  'banner': '长卷',
  'minibar': '行签',
  'ticket': '票根',
  'stamp': '邮戳',
  'flip': '翻页牌',
  'masthead': '报头',
  'bookmark': '页边签',
  'split': '对开日期',
  'pill': '胶囊',
  'rail': '双轨',
};

/// full含星期，noWeek隐藏星期，min同时隐藏年份。
const collabDateCardFormats = {'full': '完整日期与星期', 'noWeek': '不含星期', 'min': '仅月日'};

/// 日期外观和定格值的同步字段；未知props仍由桌面共享树保留。
const collabDateCardKeys = {
  'date',
  'style',
  'format',
  'bg',
  'fg',
  'bc',
  'bw',
  'ff',
  'width',
  'height',
  'fsCalendar',
  'fsSquare',
  'fsBanner',
  'fsMinibar',
  'fsTicket',
  'fsStamp',
  'fsFlip',
  'fsMasthead',
  'fsBookmark',
  'fsSplit',
  'fsPill',
  'fsRail',
};

/// 桌面边框外观值；空字符串按无外框展示。
const collabDateCardBorders = {
  '0px solid': '无',
  '1px solid': '细实线',
  '2px solid': '中实线',
  '3px solid': '粗实线',
  '1px dashed': '细虚线',
  '2px dashed': '虚线',
  '1px dotted': '细点线',
  '2px dotted': '点线',
  '3px double': '双线',
};

/// 设计宽高、分样式字号键与默认值，来自桌面0.11.30日期目录。
const collabDateCardDesigns = <String, ({double width, double height, String fontKey, List<double> fonts})>{
  'calendar': (width: 160, height: 137, fontKey: 'fsCalendar', fonts: [48, 16, 13.8]),
  'square': (width: 140, height: 140, fontKey: 'fsSquare', fonts: [47.6, 15.4, 15.4]),
  'banner': (width: 184, height: 45, fontKey: 'fsBanner', fonts: [45, 12, 12.7]),
  'minibar': (width: 129, height: 30, fontKey: 'fsMinibar', fonts: [27, 11, 11]),
  'ticket': (width: 190, height: 64, fontKey: 'fsTicket', fonts: [43.7, 17.1, 14.3]),
  'stamp': (width: 132, height: 132, fontKey: 'fsStamp', fonts: [39.6, 12.5, 10.6]),
  'flip': (width: 136, height: 109, fontKey: 'fsFlip', fonts: [51.7, 12.2, 11.6]),
  'masthead': (width: 206, height: 136, fontKey: 'fsMasthead', fonts: [65, 16, 11]),
  'bookmark': (width: 81, height: 157, fontKey: 'fsBookmark', fonts: [47, 10, 10]),
  'split': (width: 210, height: 128, fontKey: 'fsSplit', fonts: [49, 49, 10]),
  'pill': (width: 214, height: 74, fontKey: 'fsPill', fonts: [30, 11, 10]),
  'rail': (width: 221, height: 96, fontKey: 'fsRail', fonts: [37, 11, 10]),
};

/// 按桌面 [style]/[format] 计算含4像素内边距的默认固定框，不改写属性。
({double width, double height}) dateCardSize(String style, String format) {
  final spec = collabDateCardDesigns[style] ?? collabDateCardDesigns['calendar']!;
  final ratio = switch ((style, format)) {
    ('calendar', 'min') => 1.38,
    ('minibar', 'noWeek' || 'min') => 4.76,
    ('flip', 'noWeek' || 'min') => 1.61,
    _ => switch (style) {
      'calendar' => 1.17,
      'square' || 'stamp' => 1.0,
      'banner' => 4.10,
      'minibar' => 4.31,
      'ticket' => 2.96,
      'flip' => 1.25,
      _ => spec.width / spec.height,
    },
  };
  return (width: spec.width + 8, height: ((spec.width / ratio + 8) * 1000).round() / 1000);
}

/// [property] 在本地编辑器中对应独立历史字段。
String dateCardPropertyAttribute(String property) => 'cses_date_card_$property';

/// 将本地日历 [date] 定格为桌面使用的YYYY-MM-DDTHH:mm，不做时区换算。
String dateCardIsoDate(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}T${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';

/// 校验显式写入的 [key]/[value]，null表示删除；不规范化已有远端数据。
bool isValidDateCardProperty(String key, Object? value) {
  if (!collabDateCardKeys.contains(key)) return false;
  if (value == null) return true;
  return switch (key) {
    'style' => collabDateCardStyles.containsKey(value),
    'format' => collabDateCardFormats.containsKey(value),
    'bw' => value == '' || collabDateCardBorders.containsKey(value),
    'width' || 'height' => value is num && value.isFinite && value > 0 && value <= 100000,
    _ => value is String && value.length <= (key == 'date' ? 128 : 256),
  };
}

/// 日期卡片的只读属性视图，缺省外观仅在展示时回落，不回写共享数据。
/// ```dart
/// import 'package:cses_document_collab/src/model/collab_date_card.dart';
/// final card = CollabDateCard({'date': '2026-10-25T09:30'});
/// print(card.date.day); // 25
/// ```
final class CollabDateCard {
  /// 借用 [values]；调用方不得在使用期间修改映射。
  const CollabDateCard(this.values);

  /// 桌面属性值；读取不改写也不补默认字段。
  final Map<String, dynamic> values;

  /// 当前样式，缺省或未知时展示台历。
  String get style => collabDateCardStyles.containsKey(values['style']) ? values['style'] as String : 'calendar';

  /// 当前显示档，缺省或未知时展示完整日期。
  String get format => collabDateCardFormats.containsKey(values['format']) ? values['format'] as String : 'full';

  /// 固定宽度相对于当前样式默认框的内容倍率，不包含手机视口缩放。
  /// 缺失、非有限或非正宽度按默认尺寸显示，倍率为1，不改写原属性。
  double get contentScale {
    final width = values['width'];
    if (width is! num || !width.isFinite || width <= 0) return 1;
    final scale = width / dateCardSize(style, format).width;
    return scale.isFinite && scale > 0 ? scale : 1;
  }

  /// 可安全绘制的边框外观；兼容旧版0～3px实线，未知值仅展示为无边框。
  /// 原始CSS字段保持不变，防止读取历史或导入数据时产生属性迁移。
  String get border {
    final raw = values['bw'];
    if (collabDateCardBorders.containsKey(raw)) return raw as String;
    if (const {'0px', '1px', '2px', '3px'}.contains(raw)) return '$raw solid';
    return '0px solid';
  }

  /// 只按保存串的年月日读取，不随UTC后缀跨日；无效值沿用桌面当天回落。
  DateTime get date {
    final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})(?:T|$)').firstMatch('${values['date'] ?? ''}');
    if (match != null) {
      final year = int.parse(match[1]!);
      final month = int.parse(match[2]!);
      final day = int.parse(match[3]!);
      final parsed = DateTime(year, month, day);
      if (parsed.year == year && parsed.month == month && parsed.day == day) return parsed;
    }
    return DateTime.now();
  }

  /// [attributes]中的独立历史字段覆盖基础投影；[edited]仅标记本事务显式改动。
  /// 空wrapper删除字段，value:null保留显式null，返回值用于原生字段级补丁。
  static CollabResource readAttributes(Map<String, dynamic> attributes, {Set<String> edited = const {}}) {
    final raw = attributes[collabResourceAttribute];
    final base = raw is Map ? CollabResource.fromJson(Map<String, dynamic>.from(raw)) : const CollabResource();
    final values = base.values;
    final edits = <String, dynamic>{};
    for (final key in collabDateCardKeys) {
      final field = attributes[dateCardPropertyAttribute(key)];
      if (field is! String) continue;
      final wrapper = jsonDecode(field) as Map;
      if (wrapper.containsKey('value')) {
        values[key] = wrapper['value'];
      } else {
        values.remove(key);
      }
      if (edited.contains(key)) edits[key] = wrapper;
    }
    return CollabResource.fromValues(values, edits: edits.isEmpty ? null : jsonEncode(edits));
  }

  /// 将借用的 [resource] 拆为可单独撤销的本地字段，不修改权威树。
  static Map<String, dynamic> nodeAttributes(CollabResource resource) => {
    collabResourceAttribute: resource.toJson(),
    for (final key in collabDateCardKeys) dateCardPropertyAttribute(key): resource.field(key),
  };
}

/// 在借用的 [state] 内按稳定 [id] 修改日期卡片的单一 [property]。
/// [value] 为新的桌面属性；null 清除该属性。只读、已删除或非法值返回 false。
/// 逐项封闭历史，撤销可跨远端重排重新定位，不释放编辑器资源；事务失败透传。
Future<bool> changeCollabDateCardProperty(EditorState state, String id, String property, Object? value) async {
  if (state.isDisposed || !state.editable || !collabDateCardKeys.contains(property)) {
    return false;
  }
  final valid = isValidDateCardProperty(property, value);
  if (!valid) {
    return false;
  }
  return await changeCollabDateCardProperties(state, id, {property: value});
}

/// 原子更新借用 [state] 中稳定 [id] 的 [changes] 属性补丁。
/// null 删除字段；逐字段历史可在重排后撤销，未触及的远端属性保持。
/// 无效字段、锁定、只读、目标已删除时返回false，失败通过Future传播。
Future<bool> changeCollabDateCardProperties(EditorState state, String id, Map<String, Object?> changes) async {
  if (state.isDisposed || !state.editable || changes.entries.any((e) => !isValidDateCardProperty(e.key, e.value))) {
    return false;
  }
  final node = findCollabDateCard(state, id);
  if (node == null || !state.canInputAt(Selection.single(path: node.path, startOffset: 0))) return false;
  final next = <String, dynamic>{};
  final previous = <String, dynamic>{};
  for (final entry in changes.entries) {
    final key = dateCardPropertyAttribute(entry.key);
    final value = jsonEncode(entry.value == null ? {} : {'value': entry.value});
    if (node.attributes[key] != value) {
      next[key] = value;
      previous[key] = node.attributes[key];
    }
  }
  if (next.isEmpty) return false;
  for (final attributes in [next, previous]) {
    attributes[collabResourceTargetAttribute] = id;
    attributes[collabResourceKindAttribute] = collabDateCardType;
  }
  if (state.undoManager.undoStack.isNonEmpty) state.undoManager.undoStack.last.seal();
  await state.apply(
    state.transaction..add(UpdateOperation(node.path, next, previous)),
    withUpdateSelection: false,
    skipHistoryDebounce: true,
  );
  return true;
}

/// 在借用 [state] 的完整树中按稳定 [id] 找日期卡片，删除/销毁返回 null。
Node? findCollabDateCard(EditorState state, String id) {
  if (state.isDisposed) {
    return null;
  }

  /// 递归读取借用 [node]，不修改属性或保存节点引用。
  Node? visit(Node node) {
    if ((node.attributes['cses_collab_block_id'] ?? node.id) == id && node.type == collabDateCardType) {
      return node;
    }
    for (final child in node.children) {
      final found = visit(child);
      if (found != null) {
        return found;
      }
    }
    return null;
  }

  return visit(state.document.root);
}

/// 在借用 [state] 的保存 [selection] 起点插入正式日期卡片并返回后置段落光标。
/// 空正文被替换，非空正文保留；新块使用独立身份，可插在根或高亮容器内。
/// [values] 为可选的已校验日期/外观属性；默认定格当前本地日期并采用台历固定尺寸。
/// 复制属性值后与插入合为一次历史，不在读取或重新打开时刷新日期。
/// 只读/已失效位置返回 null；不恢复输入焦点，调用方须等待添加面板退出。
Future<Selection?> insertCollabDateCard(
  EditorState state,
  Selection selection, {
  Map<String, dynamic> values = const {},
}) async {
  if (state.isDisposed ||
      !state.editable ||
      !selection.isCollapsed ||
      selection.start.path.isEmpty ||
      !state.canInputAt(selection)) {
    return null;
  }
  final source = state.getNodeAtPath(selection.start.path);
  if (source == null || !const {'page', 'callout'}.contains(source.parent?.type)) {
    return null;
  }
  if (values.entries.any((e) => !isValidDateCardProperty(e.key, e.value))) return null;
  final dateCard = Node(
    type: collabDateCardType,
    attributes: CollabDateCard.nodeAttributes(
      CollabResource.fromValues({
        'width': dateCardSize('${values['style'] ?? 'calendar'}', '${values['format'] ?? 'full'}').width,
        'height': dateCardSize('${values['style'] ?? 'calendar'}', '${values['format'] ?? 'full'}').height,
        'date': dateCardIsoDate(DateTime.now()),
        ...values,
      }),
    ),
  );
  dateCard.updateAttributes({'cses_collab_block_id': dateCard.id});
  final empty = source.type == ParagraphBlockKeys.type && source.delta?.toPlainText().isEmpty == true;
  final path = empty ? source.path : source.path.next;
  final transaction = state.transaction..insertNodes(path, [dateCard, paragraphNode()], deepCopy: false);
  if (empty) {
    transaction.deleteNode(source);
  }
  if (state.undoManager.undoStack.isNonEmpty) {
    state.undoManager.undoStack.last.seal();
  }
  await state.apply(transaction, skipHistoryDebounce: true);
  return Selection.single(path: path.next, startOffset: 0);
}
