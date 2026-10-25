import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/model/collab_resource.dart';

/// 桌面正式无正文天气卡片。
const collabWeatherType = 'weather';

/// 桌面七种天气布局与名称；宽高为不含4像素框内边距的设计尺寸。
const collabWeatherLayouts = <String, ({String label, double width, double height})>{
  'classic': (label: '经典紧凑', width: 152, height: 34),
  'inline': (label: '行内组合', width: 272, height: 72),
  'ruled': (label: '双线横栏', width: 262, height: 90),
  'sidebar': (label: '侧线标记', width: 256, height: 96),
  'card': (label: '基础信息卡', width: 256, height: 144),
  'stack': (label: '纵向组合', width: 148, height: 156),
  'ledger': (label: '气象分栏', width: 280, height: 104),
};

/// 桌面同源色调，依次为字色、强调色、线条色、背景色；空串继承文档。
const collabWeatherPalettes = <String, (String, List<String>)>{
  'document': ('跟随文档', ['', '', '', 'transparent']),
  'ink': ('中性灰', ['#30353b', '#59626b', '#c9cdd1', '#f0f1f2']),
  'blue': ('雾蓝', ['#2b4054', '#42769d', '#b6c6d5', '#eaf0f6']),
  'green': ('苔绿', ['#314b3c', '#56806a', '#b6c8bc', '#edf2eb']),
  'clay': ('陶土', ['#583f38', '#a16b55', '#d6bbb0', '#f5ece6']),
  'dark': ('深色', ['#edf2f6', '#afc9df', '#697b8b', '#293b4a']),
};

/// 天气形态；未知旧值只在显示端回落晴天。
const collabWeatherTones = {'sunny', 'cloudy', 'rainy', 'snowy', 'stormy', 'foggy'};

/// 天气定格和外观同步字段，其他未知共享字段仍保留在权威树中。
const collabWeatherKeys = {
  'date',
  'frozen',
  'style',
  'palette',
  'fg',
  'accent',
  'line',
  'bg',
  'bw',
  'bc',
  'iconMode',
  'range',
  'width',
  'height',
};

/// 桌面外框可用线型。
const collabWeatherBorders = {
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

/// 将本地 [date] 编为不含时区的文档日锚点。
String weatherDay(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

/// 按 [style] 返回含框内边距的默认尺寸；未知样式只回落展示。
({double width, double height}) weatherSize(String style) {
  final layout = collabWeatherLayouts[style] ?? collabWeatherLayouts['classic']!;
  return (width: layout.width + 8, height: layout.height + 8);
}

/// [property] 对应本地独立历史字段，不进入桌面属性命名空间。
String weatherPropertyAttribute(String property) => 'cses_weather_$property';

/// 验证显式 [key]/[value] 写入；null删除，不规范化旧远端数据。
bool isValidWeatherProperty(String key, Object? value) {
  if (!collabWeatherKeys.contains(key)) return false;
  if (value == null) return true;
  return switch (key) {
    'style' => collabWeatherLayouts.containsKey(value),
    'palette' => collabWeatherPalettes.containsKey(value),
    'iconMode' => value == 'mono' || value == 'original',
    'range' => value == 'on' || value == 'off',
    'bw' => value == '' || collabWeatherBorders.containsKey(value),
    'width' || 'height' => value is num && value.isFinite && value > 0 && value <= 100000,
    'frozen' => CollabWeatherData.read(value) != null && jsonEncode(value).length <= 8192,
    'date' => value is String && (value == 'live' || RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)),
    _ => value is String && value.length <= 256,
  };
}

/// 天气属性只读视图，默认值只影响展示，不回写共享树。
/// ```dart
/// import 'package:cses_document_collab/src/model/collab_weather.dart';
/// final card = CollabWeather({'date': 'live'});
/// print(card.style); // classic
/// ```
final class CollabWeather {
  /// 借用 [values]；调用方在使用期间不得改动映射。
  const CollabWeather(this.values);

  /// 保存的原始属性。
  final Map<String, dynamic> values;

  /// 有效布局，旧值缺省为经典紧凑。
  String get style =>
      collabWeatherLayouts.containsKey(values['style']) ? values['style'] as String : 'classic';

  /// 有效固定日期；live、缺失和旧非法日期按实时展示。
  String? get date => values['date'] is String && RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(values['date'])
      ? values['date'] as String
      : null;

  /// 固定日期才读取定格值；实时模式始终忽略旧frozen。
  CollabWeatherData? get frozen => date == null ? null : CollabWeatherData.read(values['frozen']);

  /// 复原 [attributes] 的独立历史字段；[edited]标记本次显式改动以形成原生字段补丁。
  static CollabResource readAttributes(Map<String, dynamic> attributes, {Set<String> edited = const {}}) {
    final raw = attributes[collabResourceAttribute];
    final base = raw is Map
        ? CollabResource.fromJson(Map<String, dynamic>.from(raw))
        : const CollabResource();
    final values = base.values;
    final edits = <String, dynamic>{};
    for (final key in collabWeatherKeys) {
      final field = attributes[weatherPropertyAttribute(key)];
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

  /// 将借用 [resource] 拆为可按稳定身份撤销的独立字段。
  static Map<String, dynamic> nodeAttributes(CollabResource resource) => {
    collabResourceAttribute: resource.toJson(),
    for (final key in collabWeatherKeys) weatherPropertyAttribute(key): resource.field(key),
  };
}

/// 中立天气快照，不持有位置服务、网络或账号。
/// ```dart
/// import 'package:cses_document_collab/cses_document_collab.dart';
/// const weather = CollabWeatherData(temp: 20, condition: '晴', location: '北京');
/// print(weather.toJson());
/// ```
final class CollabWeatherData {
  /// [temp]为摄氏温度，[condition]为天气文案，[location]为城市；[tone]默认晴天。
  /// [high]/[low]为摄氏日高低温，null时跟随temp；对象由调用方持有。
  const CollabWeatherData({
    required this.temp,
    required this.condition,
    required this.location,
    this.tone = 'sunny',
    this.high,
    this.low,
  });

  /// 当前或历史日均温，单位摄氏度，须为有限值。
  final double temp;

  /// 中文天气名称。
  final String condition;

  /// 城市或地区名称，不含精确位置。
  final String location;

  /// 六种图标形态，未知值显示晴天。
  final String tone;

  /// 日最高温，缺省按当前温度展示。
  final double? high;

  /// 日最低温，缺省按当前温度展示。
  final double? low;

  /// 生成与桌面frozen兼容的独立映射。
  Map<String, dynamic> toJson() => {
    'temp': temp,
    'condition': condition,
    'location': location,
    'tone': tone,
    'high': high ?? temp,
    'low': low ?? temp,
  };

  /// 从借用 [raw] 解析定格值；缺失/非法返回null，旧缺失高低温按当前温度回落。
  static CollabWeatherData? read(Object? raw) {
    if (raw is! Map || raw['temp'] is! num || !(raw['temp'] as num).isFinite || raw['condition'] is! String) {
      return null;
    }
    if ((raw['condition'] as String).length > 1024 ||
        (raw['location'] is String && (raw['location'] as String).length > 1024)) {
      return null;
    }
    for (final key in ['high', 'low']) {
      if (raw[key] != null && (raw[key] is! num || !(raw[key] as num).isFinite)) return null;
    }
    return CollabWeatherData(
      temp: (raw['temp'] as num).toDouble(),
      condition: raw['condition'] as String,
      location: raw['location'] is String ? raw['location'] as String : '',
      tone: collabWeatherTones.contains(raw['tone']) ? raw['tone'] as String : 'sunny',
      high: (raw['high'] as num?)?.toDouble(),
      low: (raw['low'] as num?)?.toDouble(),
    );
  }
}

/// 宿主天气查询端口；[date]为YYYY-MM-DD，null查询实时；[refresh]为true须绕过缓存。
/// [cancelled]由编辑会话拥有，失效时变为true；宿主可停止等待但不得关闭共享客户端。
/// 成功返回真实快照，失败抛错；不得用虚构值降级，编辑器负责迟到结果隔离。
typedef CollabWeatherLoader =
    Future<CollabWeatherData> Function({
      String? date,
      required bool refresh,
      required bool Function() cancelled,
    });

/// 在借用的 [state] 内按稳定 [id] 修改天气卡片的单一 [property]。
/// [value] 为新的桌面属性；null 清除该属性。只读、已删除或非法值返回 false。
/// 逐项封闭历史，撤销可跨远端重排重新定位，不释放编辑器资源；事务失败透传。
Future<bool> changeCollabWeatherProperty(EditorState state, String id, String property, Object? value) async {
  if (state.isDisposed || !state.editable || !collabWeatherKeys.contains(property)) {
    return false;
  }
  final valid = isValidWeatherProperty(property, value);
  if (!valid) {
    return false;
  }
  return await changeCollabWeatherProperties(state, id, {property: value});
}

/// 原子更新借用 [state] 中稳定 [id] 的 [changes] 属性补丁。
/// null 删除字段；逐字段历史可在重排后撤销，未触及的远端属性保持。
/// 无效字段、锁定、只读、目标已删除时返回false，失败通过Future传播。
Future<bool> changeCollabWeatherProperties(EditorState state, String id, Map<String, Object?> changes) async {
  if (state.isDisposed ||
      !state.editable ||
      changes.entries.any((e) => !isValidWeatherProperty(e.key, e.value))) {
    return false;
  }
  final node = findCollabWeather(state, id);
  if (node == null || !state.canInputAt(Selection.single(path: node.path, startOffset: 0))) return false;
  final next = <String, dynamic>{};
  final previous = <String, dynamic>{};
  for (final entry in changes.entries) {
    final key = weatherPropertyAttribute(entry.key);
    final value = jsonEncode(entry.value == null ? {} : {'value': entry.value});
    if (node.attributes[key] != value) {
      next[key] = value;
      previous[key] = node.attributes[key];
    }
  }
  if (next.isEmpty) return false;
  for (final attributes in [next, previous]) {
    attributes[collabResourceTargetAttribute] = id;
    attributes[collabResourceKindAttribute] = collabWeatherType;
  }
  if (state.undoManager.undoStack.isNonEmpty) state.undoManager.undoStack.last.seal();
  await state.apply(
    state.transaction..add(UpdateOperation(node.path, next, previous)),
    withUpdateSelection: false,
    skipHistoryDebounce: true,
  );
  return true;
}

/// 在借用 [state] 的完整树中按稳定 [id] 找天气卡片，删除/销毁返回 null。
Node? findCollabWeather(EditorState state, String id) {
  if (state.isDisposed) {
    return null;
  }

  /// 递归读取借用 [node]，不修改属性或保存节点引用。
  Node? visit(Node node) {
    if ((node.attributes['cses_collab_block_id'] ?? node.id) == id && node.type == collabWeatherType) {
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

/// 在借用 [state] 的保存 [selection] 起点插入正式天气卡片并返回后置段落光标。
/// 空正文被替换，非空正文保留；新块使用独立身份，可插在根或高亮容器内。
/// [values] 为可选的已校验天气/外观属性；默认锚定当前本地日期并采用经典固定尺寸。
/// 复制属性值后与插入合为一次历史，不在读取或重新打开时刷新日期。
/// 只读/已失效位置返回 null；不恢复输入焦点，调用方须等待添加面板退出。
Future<Selection?> insertCollabWeather(
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
  if (values.entries.any((e) => !isValidWeatherProperty(e.key, e.value))) return null;
  final weather = Node(
    type: collabWeatherType,
    attributes: CollabWeather.nodeAttributes(
      CollabResource.fromValues({
        'width': weatherSize('${values['style'] ?? 'classic'}').width,
        'height': weatherSize('${values['style'] ?? 'classic'}').height,
        'date': weatherDay(DateTime.now()),
        ...values,
      }),
    ),
  );
  weather.updateAttributes({'cses_collab_block_id': weather.id});
  final empty = source.type == ParagraphBlockKeys.type && source.delta?.toPlainText().isEmpty == true;
  final path = empty ? source.path : source.path.next;
  final transaction = state.transaction..insertNodes(path, [weather, paragraphNode()], deepCopy: false);
  if (empty) {
    transaction.deleteNode(source);
  }
  if (state.undoManager.undoStack.isNonEmpty) {
    state.undoManager.undoStack.last.seal();
  }
  await state.apply(transaction, skipHistoryDebounce: true);
  return Selection.single(path: path.next, startOffset: 0);
}
