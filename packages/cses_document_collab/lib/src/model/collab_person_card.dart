import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/model/collab_resource.dart';

/// 正式桌面无正文人员卡片类型。
const collabPersonCardType = 'person-card';

/// 三种桌面排版样式；未知样式仅在展示时回落横排。
const collabPersonCardStyles = {'row': '横排', 'rowPinyin': '横排拼音', 'column': '竖排'};

/// 可逐字段同步和撤销的属性，未知远端字段由原共享树保留。
const collabPersonCardKeys = {
  'person',
  'style',
  'avatar',
  'avatarSize',
  'dept',
  'color',
  'bw',
  'bc',
  'width',
  'height',
  'sc',
  'fsr',
  'fsp',
  'fsc',
};

/// 部门职务显示位置；on按当前样式跟随排版。
const collabPersonCardDepartments = {'off': '隐藏', 'on': '跟随排版', 'below': '下方', 'right': '右侧', 'above': '上方'};

/// 桌面支持的边框外观。
const collabPersonCardBorders = {
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

/// 计算[style]在[scale]倍内容尺度下含4px内边距的桌面默认外框，宽高取整。
({double width, double height}) personCardSize(String style, {double scale = 1}) {
  final spec = switch (style) {
    'rowPinyin' => (230.0, 5.75),
    'column' => (70.0, .84),
    _ => (175.0, 5.48),
  };
  return (
    width: ((spec.$1 + 8) * scale).roundToDouble(),
    height: ((spec.$1 / spec.$2 + 8) * scale).roundToDouble(),
  );
}

/// [property]对应独立历史字段，不将全部props打包覆盖。
String personCardPropertyAttribute(String property) => 'cses_person_card_$property';

/// 宿主提供新建时定格的人员资料；不持有账号、目录或图片资源。
/// ```dart
/// import 'package:cses_document_collab/cses_document_collab.dart';
/// final services = CollabHostServices(
///   loadPersonCardCreator: () => const CollabPersonCardData(name: '张三', pinyin: 'ZHANG SAN', description: '研发部'),
/// );
/// // 将services注入由宿主持有的CollabController。
/// ```
final class CollabPersonCardData {
  /// [name]为必需姓名；[avatar]为可选公开图片URL，[pinyin]和[description]为空时不展示。
  /// 所有值在新建时复制保存，后续资料变化不自动覆盖。
  const CollabPersonCardData({required this.name, this.avatar, this.pinyin, this.description});

  /// 必需姓名，保存时必须非空。
  final String name;

  /// 可选公开头像地址，不携带认证凭证。
  final String? avatar;

  /// 可选姓名拼音，仅横排拼音样式显示。
  final String? pinyin;

  /// 可选部门/职务描述，显隐和位置由卡片dept控制。
  final String? description;

  /// 编码为桌面person属性使用的JSON字符串，未知旧数据不通过此方法重写。
  String encode() => jsonEncode({
    'name': name,
    if (avatar != null) 'avatar': avatar,
    if (pinyin != null) 'pinyin': pinyin,
    if (description != null) 'description': description,
  });

  /// 从[raw]读取桌面JSON字符串；缺失、结构错误或空姓名返回null，不发网络请求。
  static CollabPersonCardData? read(Object? raw) {
    if (raw is! String || raw.isEmpty) return null;
    try {
      final value = jsonDecode(raw);
      if (value is! Map || value['name'] is! String || (value['name'] as String).isEmpty) return null;
      return CollabPersonCardData(
        name: value['name'] as String,
        avatar: value['avatar'] is String ? value['avatar'] as String : null,
        pinyin: value['pinyin'] is String ? value['pinyin'] as String : null,
        description: value['description'] is String ? value['description'] as String : null,
      );
    } on FormatException {
      return null;
    }
  }
}

/// 校验显式写入的[key]/[value]；null删除，旧远端值只读保留，不自动迁移。
bool isValidPersonCardProperty(String key, Object? value) {
  if (!collabPersonCardKeys.contains(key)) return false;
  if (value == null) return true;
  return switch (key) {
    'person' =>
      value is String && utf8.encode(value).length <= 16384 && CollabPersonCardData.read(value) != null,
    'style' => collabPersonCardStyles.containsKey(value),
    'dept' => collabPersonCardDepartments.containsKey(value),
    'avatar' => value == 'circle' || value == 'rounded',
    'avatarSize' => const {'small', 'medium', 'large'}.contains(value),
    'bw' => value == '' || collabPersonCardBorders.containsKey(value),
    'width' ||
    'height' ||
    'sc' => value is num && value.isFinite && value > 0 && value <= (key == 'sc' ? 100 : 100000),
    _ => value is String && value.length <= 256,
  };
}

/// 人员卡片只读属性视图；读取回落不回写协同文档。
/// ```dart
/// import 'package:cses_document_collab/src/model/collab_person_card.dart';
/// final card = CollabPersonCard({'style': 'rowPinyin', 'sc': 1});
/// print(card.style); // rowPinyin
/// ```
final class CollabPersonCard {
  /// 借用[values]，调用方不得在使用期间修改。
  const CollabPersonCard(this.values);

  /// 未补默认值的桌面原始props副本。
  final Map<String, dynamic> values;

  /// 未知样式仅展示横排。
  String get style => collabPersonCardStyles.containsKey(values['style']) ? values['style'] as String : 'row';

  /// 定格人员；缺失或错误时使用文档创建人占位。
  CollabPersonCardData? get person => CollabPersonCardData.read(values['person']);

  /// 旧版缺少sc时按宽度推导；sc:1具有格式标记意义，不能删去。
  double get contentScale {
    final raw = values['sc'];
    final parsed = raw is num ? raw.toDouble() : double.tryParse('$raw');
    if (parsed != null && parsed.isFinite && parsed > 0) return parsed;
    final width = values['width'];
    return width is num && width.isFinite && width > 0 ? width / personCardSize(style).width : 1;
  }

  /// 当前样式的独立字号字段。
  String get fontKey => switch (style) {
    'rowPinyin' => 'fsp',
    'column' => 'fsc',
    _ => 'fsr',
  };

  /// 当前样式的设计字号；实际绘制时乘contentScale。
  List<double> get fonts {
    final defaults = switch (style) {
      'rowPinyin' => [15.0, 9.5, 11.0],
      'column' => [14.0, 11.0],
      _ => [15.0, 12.0],
    };
    final raw = values[fontKey];
    final parts = raw is String ? raw.trim().split(RegExp(r'\s+')) : <String>[];
    return List.generate(defaults.length, (index) {
      final value = index < parts.length ? double.tryParse(parts[index]) : null;
      return value != null && value.isFinite && value > 0 ? value : defaults[index];
    });
  }

  /// 部门位置；on在竖排下方、横排右侧，缺失或未知值关闭。
  String get departmentPosition {
    final raw = values['dept'];
    if (raw == 'on') return style == 'column' ? 'below' : 'right';
    return const {'below', 'right', 'above'}.contains(raw) ? raw as String : 'off';
  }

  /// [attributes]中的独立历史字段覆盖基础投影；[edited]仅标记本事务显式改动。
  /// 空wrapper删除字段，value:null保留显式null，返回值用于原生字段级补丁。
  static CollabResource readAttributes(Map<String, dynamic> attributes, {Set<String> edited = const {}}) {
    final raw = attributes[collabResourceAttribute];
    final base = raw is Map
        ? CollabResource.fromJson(Map<String, dynamic>.from(raw))
        : const CollabResource();
    final values = base.values;
    final edits = <String, dynamic>{};
    for (final key in collabPersonCardKeys) {
      final field = attributes[personCardPropertyAttribute(key)];
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
    for (final key in collabPersonCardKeys) personCardPropertyAttribute(key): resource.field(key),
  };
}

/// 在借用的 [state] 内按稳定 [id] 修改人员卡片的单一 [property]。
/// [value] 为新的桌面属性；null 清除该属性。只读、已删除或非法值返回 false。
/// 逐项封闭历史，撤销可跨远端重排重新定位，不释放编辑器资源；事务失败透传。
Future<bool> changeCollabPersonCardProperty(
  EditorState state,
  String id,
  String property,
  Object? value,
) async {
  if (state.isDisposed || !state.editable || !collabPersonCardKeys.contains(property)) {
    return false;
  }
  final valid = isValidPersonCardProperty(property, value);
  if (!valid) {
    return false;
  }
  return await changeCollabPersonCardProperties(state, id, {property: value});
}

/// 原子更新借用 [state] 中稳定 [id] 的 [changes] 属性补丁。
/// null 删除字段；逐字段历史可在重排后撤销，未触及的远端属性保持。
/// 无效字段、锁定、只读、目标已删除时返回false，失败通过Future传播。
Future<bool> changeCollabPersonCardProperties(
  EditorState state,
  String id,
  Map<String, Object?> changes,
) async {
  if (state.isDisposed ||
      !state.editable ||
      changes.entries.any((e) => !isValidPersonCardProperty(e.key, e.value))) {
    return false;
  }
  final node = findCollabPersonCard(state, id);
  if (node == null || !state.canInputAt(Selection.single(path: node.path, startOffset: 0))) return false;
  final next = <String, dynamic>{};
  final previous = <String, dynamic>{};
  for (final entry in changes.entries) {
    final key = personCardPropertyAttribute(entry.key);
    final value = jsonEncode(entry.value == null ? {} : {'value': entry.value});
    if (node.attributes[key] != value) {
      next[key] = value;
      previous[key] = node.attributes[key];
    }
  }
  if (next.isEmpty) return false;
  for (final attributes in [next, previous]) {
    attributes[collabResourceTargetAttribute] = id;
    attributes[collabResourceKindAttribute] = collabPersonCardType;
  }
  if (state.undoManager.undoStack.isNonEmpty) state.undoManager.undoStack.last.seal();
  await state.apply(
    state.transaction..add(UpdateOperation(node.path, next, previous)),
    withUpdateSelection: false,
    skipHistoryDebounce: true,
  );
  return true;
}

/// 在借用 [state] 的完整树中按稳定 [id] 找人员卡片，删除/销毁返回 null。
Node? findCollabPersonCard(EditorState state, String id) {
  if (state.isDisposed) {
    return null;
  }

  /// 递归读取借用 [node]，不修改属性或保存节点引用。
  Node? visit(Node node) {
    if ((node.attributes['cses_collab_block_id'] ?? node.id) == id && node.type == collabPersonCardType) {
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

/// 在借用 [state] 的保存 [selection] 起点插入正式人员卡片并返回后置段落光标。
/// 空正文被替换，非空正文保留；新块使用独立身份，可插在根、高亮或单列容器内。
/// [values] 为可选的已校验定格人员/外观属性；默认采用横排固定尺寸，缺少person时显示文档创建人占位。
/// 复制属性值后与插入合为一次历史，不在读取或重新打开时刷新定格资料。
/// 只读/已失效位置返回 null；不恢复输入焦点，调用方须等待添加面板退出。
Future<Selection?> insertCollabPersonCard(
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
  if (source == null || !const {'page', 'callout', 'column'}.contains(source.parent?.type)) {
    return null;
  }
  if (values.entries.any((e) => !isValidPersonCardProperty(e.key, e.value))) return null;
  final personCard = Node(
    type: collabPersonCardType,
    attributes: CollabPersonCard.nodeAttributes(
      CollabResource.fromValues({
        'width': personCardSize('${values['style'] ?? 'row'}').width,
        'height': personCardSize('${values['style'] ?? 'row'}').height,
        'sc': 1,
        ...values,
      }),
    ),
  );
  personCard.updateAttributes({'cses_collab_block_id': personCard.id});
  final empty = source.type == ParagraphBlockKeys.type && source.delta?.toPlainText().isEmpty == true;
  final path = empty ? source.path : source.path.next;
  final transaction = state.transaction..insertNodes(path, [personCard, paragraphNode()], deepCopy: false);
  if (empty) {
    transaction.deleteNode(source);
  }
  if (state.undoManager.undoStack.isNonEmpty) {
    state.undoManager.undoStack.last.seal();
  }
  await state.apply(transaction, skipHistoryDebounce: true);
  return Selection.single(path: path.next, startOffset: 0);
}
