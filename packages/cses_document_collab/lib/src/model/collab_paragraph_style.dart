import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/model/collab_resource.dart';
import 'package:cses_document_collab/src/model/collab_block_colors.dart';

/// 段落属性事务的稳定身份，不写入原生 props。
const collabParagraphTargetAttribute = 'cses_paragraph_target';

/// 段落族持久化字段；颜色、对齐及缩进仍使用既有独立通道。
const collabParagraphKeys = {
  'textDefaults',
  'nextParagraphStyle',
  'heading',
  'depth',
  'fs',
  'pfs',
  'lh',
  'psb',
  'psa',
  'decoration',
};

/// 可延续到新文字的字体、字号、字距属性，使用桌面原始键避免重复协议。
const collabTypographyKeys = {
  't:ff',
  't:px',
  't:fs',
  't:ls',
  's:fontFamily',
  's:fontSize',
  's:letterSpacing',
};

/// 桌面字符外观键到编辑器键的映射；不包含链接、提及及修订身份。
final collabCharacterKeys = {
  'a:bold': AppFlowyRichTextKeys.bold,
  'a:italic': AppFlowyRichTextKeys.italic,
  'a:underline': AppFlowyRichTextKeys.underline,
  'a:strike': AppFlowyRichTextKeys.strikethrough,
  'a:code': AppFlowyRichTextKeys.code,
  'a:sup': 'cses_superscript',
  'a:sub': 'cses_subscript',
  's:color': AppFlowyRichTextKeys.textColor,
  's:background': AppFlowyRichTextKeys.backgroundColor,
};

/// 返回 [node] 是否为具有段落默认字符格式的编辑叶块，不接管代码及特殊块。
bool supportsCollabParagraph(Node node) => const {
  ParagraphBlockKeys.type,
  HeadingBlockKeys.type,
  QuoteBlockKeys.type,
  BulletedListBlockKeys.type,
  NumberedListBlockKeys.type,
  TodoListBlockKeys.type,
}.contains(node.type);

/// 返回 [key] 的独立属性名；包装值保留字段缺失与 null，供精确撤销。
String paragraphPropertyAttribute(String key) => 'cses_paragraph_$key';

/// 将借用的 [style] 投影为完整字段包装；null 清除旧投影，不产生写入意图。
Map<String, dynamic> paragraphNodeAttributes(CollabResource? style) => {
  for (final key in collabParagraphKeys)
    paragraphPropertyAttribute(key): jsonEncode(
      style?.values.containsKey(key) == true
          ? {'value': style!.values[key]}
          : {},
    ),
};

/// 读取 [node] 的段落字段，[edited] 仅列出当前事务明确修改的字段，默认无补丁。
/// 调用方借用节点；返回值不可作为覆盖全部原生 props 的命令。
CollabResource readCollabParagraph(Node node, {Set<String> edited = const {}}) {
  final values = <String, dynamic>{};
  final patches = <String, dynamic>{};
  for (final key in collabParagraphKeys) {
    final raw = node.attributes[paragraphPropertyAttribute(key)];
    final wrapper = raw is String ? jsonDecode(raw) as Map : const {};
    if (wrapper.containsKey('value')) values[key] = wrapper['value'];
    if (edited.contains(key)) patches[key] = wrapper;
  }
  return CollabResource.fromValues(
    values,
    edits: patches.isEmpty ? null : jsonEncode(patches),
  );
}

/// 按 0.11.20 白名单规范化借用 [value]；非法值被忽略，数值遵循桌面精度和范围。
/// 返回桌面属性，不包含链接、业务身份或修订元数据。
Map<String, dynamic> normalizeParagraphTextDefaults(Object? value) {
  if (value is! Map) return {};
  final result = <String, dynamic>{};
  for (final key in collabCharacterKeys.keys) {
    final v = value[key];
    if ((key.startsWith('a:') && v == true) ||
        (key.startsWith('s:') && v is String && v.isNotEmpty)) {
      result[key] = v;
    }
  }
  for (final key in const ['s:fontFamily', 's:fontSize', 's:letterSpacing']) {
    if (value[key] is String && (value[key] as String).isNotEmpty) {
      result[key] = value[key];
    }
  }
  if (const {
    'sans',
    'arial',
    'calibri',
    'verdana',
    'tahoma',
    'hei',
    'yahei',
    'pingfang',
    'serif',
    'times',
    'georgia',
    'simsun',
    'kai',
    'xingkai',
    'fang',
    'dengxian',
    'lishu',
    'youyuan',
    'cambria',
    'palatino',
    'trebuchet',
    'mono',
    'courier',
  }.contains(value['t:ff'])) {
    result['t:ff'] = value['t:ff'];
  }
  for (final range in const [
    ('t:px', .1, 4096.0, 1000000),
    ('t:fs', .5, 3.0, 1000),
    ('t:ls', -.1, .5, 1000),
  ]) {
    final raw = value[range.$1];
    final number = raw is num
        ? raw.toDouble()
        : raw is String
        ? num.tryParse(raw.trim())?.toDouble()
        : null;
    if (number != null &&
        number.isFinite &&
        number >= range.$2 &&
        number <= range.$3) {
      result[range.$1] = (number * range.$4 + .5).floor() / range.$4;
    }
  }
  return result;
}

/// 将编辑器 [attributes] 转为经过白名单校验的桌面字符外观。
Map<String, dynamic> paragraphDefaultsFromAttributes(
  Map<String, dynamic> attributes,
) => normalizeParagraphTextDefaults({
  for (final entry in collabCharacterKeys.entries)
    entry.key: const {'s:color', 's:background'}.contains(entry.key)
        ? _desktopCharacterColor(attributes[entry.value])
        : attributes[entry.value],
  for (final key in collabTypographyKeys) key: attributes[key],
});

/// 将桌面 [defaults] 转为编辑器字符外观；缺失字段保持继承。
Attributes paragraphDefaultsToAttributes(Object? defaults) => {
  for (final entry in normalizeParagraphTextDefaults(defaults).entries)
    collabCharacterKeys[entry.key] ??
        entry.key: const {'s:color', 's:background'}.contains(entry.key)
        ? parseCollabBlockColor(entry.value as String)?.toHex() ?? entry.value
        : entry.value,
};

/// 将编辑器的 ARGB [value] 转为桌面 CSS 颜色；已有 CSS 和非颜色值保持原样供白名单校验。
Object? _desktopCharacterColor(Object? value) {
  if (value is! String || !RegExp(r'^0[xX][0-9a-fA-F]{8}$').hasMatch(value)) {
    return value;
  }
  final argb = int.parse(value.substring(2), radix: 16);
  final alpha = argb >> 24;
  if (alpha == 255) {
    return '#${(argb & 0xffffff).toRadixString(16).padLeft(6, '0')}';
  }
  return 'rgba(${(argb >> 16) & 255}, ${(argb >> 8) & 255}, ${argb & 255}, ${alpha / 255})';
}

/// 读取借用 [node] 的 [offset]（UTF-16）处输入格式；空段落使用持久化默认格式。
/// [pending] 为显式临时输入格式，null 值表示取消，优先于正文或段落默认值。
Attributes collabParagraphTypingAttributes(
  Node node,
  int offset, {
  Map<String, dynamic> pending = const {},
}) {
  final delta = node.delta ?? Delta();
  Map<String, dynamic> source = {};
  if (delta.isEmpty) {
    source = paragraphDefaultsToAttributes(
      readCollabParagraph(node).values['textDefaults'],
    );
  } else {
    final probe = (offset <= 0 ? 0 : offset - 1).clamp(0, delta.length - 1);
    source = delta.slice(probe, probe + 1).first.attributes ?? {};
  }
  return paragraphDefaultsToAttributes(
    paragraphDefaultsFromAttributes({...source, ...pending}),
  );
}

/// 在借用 [state] 的折叠位置设置后续输入 [patch]，空段落同时持久化字符默认值。
/// 只读/销毁/无有效段落时返回；事务失败向调用方传播。空段落格式独立可撤销。
Future<void> setCollabTypingAttributes(
  EditorState state,
  Attributes patch,
) async {
  final selection = state.selection;
  if (state.isDisposed ||
      !state.editable ||
      selection == null ||
      !selection.isCollapsed) {
    return;
  }
  final node = state.getNodeAtPath(selection.start.path);
  if (node == null || !supportsCollabParagraph(node)) return;
  final next = collabParagraphTypingAttributes(
    node,
    selection.start.offset,
    pending: {...state.toggledStyle, ...patch},
  );
  if (node.delta?.isEmpty == true) {
    final defaults = paragraphDefaultsFromAttributes(next);
    final transaction = state.transaction;
    _updateParagraphProperties(transaction, node, {
      collabParagraphTargetAttribute:
          node.attributes['cses_collab_block_id'] ?? node.id,
      paragraphPropertyAttribute('textDefaults'): jsonEncode({
        'value': defaults.isEmpty ? null : defaults,
      }),
    });
    if (state.undoManager.undoStack.isNonEmpty) {
      state.undoManager.undoStack.last.seal();
    }
    await state.apply(
      transaction,
      withUpdateSelection: false,
      skipHistoryDebounce: true,
    );
  }
  if (!state.isDisposed &&
      state.editable &&
      state.selection == selection &&
      identical(state.getNodeAtPath(selection.start.path), node)) {
    for (final key in {
      ...collabCharacterKeys.values,
      ...collabTypographyKeys,
    }) {
      state.updateToggledStyle(key, next[key]);
    }
  }
}

/// 为 [state] 的本地 [transaction] 同步整段格式和删空后的字符默认值，追加到同一撤销事务。
/// 历史回放由调用方跳过；局部格式不改变段落默认值，原生远端字段仍由独立补丁维护。
void synchronizeParagraphDefaults(EditorState state, Transaction transaction) {
  transaction.operations = transaction.operations.map((operation) {
    if (operation is UpdateOperation &&
        operation.attributes.containsKey(blockComponentDelta) &&
        state.getNodeAtPath(operation.path) != null &&
        supportsCollabParagraph(state.getNodeAtPath(operation.path)!)) {
      return UpdateOperation(operation.path, operation.attributes, {
        for (final key in operation.attributes.keys)
          key: operation.oldAttributes[key],
      });
    }
    return operation;
  }).toList();
  for (final operation in transaction.operations.toList()) {
    if (operation is! UpdateTextOperation &&
        (operation is! UpdateOperation ||
            !operation.attributes.containsKey(blockComponentDelta))) {
      continue;
    }
    final node = state.getNodeAtPath(operation.path);
    if (node == null || !supportsCollabParagraph(node) || node.delta == null) {
      continue;
    }
    final before = node.delta!;
    final after = operation is UpdateTextOperation
        ? before.compose(operation.delta)
        : Delta.fromJson(
            (operation as UpdateOperation).attributes[blockComponentDelta],
          );
    final change = before.diff(after);
    final selection = transaction.beforeSelection?.normalized;
    final wholeTarget =
        selection != null &&
        !selection.isCollapsed &&
        state.getNodesInSelection(selection).contains(node) &&
        (!node.path.equals(selection.start.path) ||
            selection.start.offset == 0) &&
        (!node.path.equals(selection.end.path) ||
            selection.end.offset == before.length);
    Map<String, dynamic>? defaults;
    if (before.isNotEmpty && after.isEmpty) {
      defaults = paragraphDefaultsFromAttributes(
        selection != null && !selection.isCollapsed
            ? _commonSelectedAttributes(state, selection)
            : collabParagraphTypingAttributes(
                node,
                state.selection?.start.offset ?? before.length,
                pending: state.toggledStyle,
              ),
      );
    } else if (before.isNotEmpty &&
        change.any(
          (op) => (op.attributes ?? {}).keys.any(
            (key) =>
                collabCharacterKeys.containsValue(key) ||
                collabTypographyKeys.contains(key),
          ),
        ) &&
        change.every((op) => op is TextRetain) &&
        (wholeTarget ||
            change.every(
                  (op) => (op.attributes ?? {}).keys.any(
                    (key) =>
                        collabCharacterKeys.containsValue(key) ||
                        collabTypographyKeys.contains(key),
                  ),
                ) &&
                change.fold<int>(0, (length, op) => length + op.length) ==
                    before.length)) {
      final common = <String, dynamic>{...?after.first.attributes};
      for (final run in after.skip(1)) {
        common.removeWhere((key, value) => run.attributes?[key] != value);
      }
      defaults = paragraphDefaultsFromAttributes(common);
    }
    if (defaults == null) continue;
    final key = paragraphPropertyAttribute('textDefaults');
    if (transaction.operations.whereType<UpdateOperation>().any(
      (op) => op.path.equals(node.path) && op.attributes.containsKey(key),
    )) {
      continue;
    }
    _updateParagraphProperties(transaction, node, {
      collabParagraphTargetAttribute:
          node.attributes['cses_collab_block_id'] ?? node.id,
      key: jsonEncode({'value': defaults.isEmpty ? null : defaults}),
    });
  }
}

/// 对借用 [state] 的 [selection] 应用字符外观 [attributes]，复用 Delta 格式能力。
/// 覆盖整段时将默认格式与文字写入同一事务，空段落也更新；局部范围只修改文字。
/// 只读、销毁及失效选区时不执行；Future 完成代表事务完成，失败向菜单边界传播。
Future<void> formatCollabParagraphSelection(
  EditorState state,
  Selection selection,
  Attributes attributes,
) async {
  if (state.isDisposed || !state.editable || selection.isCollapsed) return;
  selection = selection.normalized;
  final transaction = state.transaction;
  for (final node in state.getNodesInSelection(selection)) {
    final delta = node.delta;
    if (delta == null || !supportsCollabParagraph(node)) continue;
    final start = node.path.equals(selection.start.path)
        ? selection.start.offset
        : 0;
    final end = node.path.equals(selection.end.path)
        ? selection.end.offset
        : delta.length;
    if (start < 0 || end > delta.length || start > end) return;
    transaction.formatText(node, start, end - start, attributes);
    if (start == 0 && end == delta.length) {
      final after = delta.compose(
        Delta()..retain(delta.length, attributes: attributes),
      );
      final defaults = delta.isEmpty
          ? paragraphDefaultsFromAttributes({
              ...paragraphDefaultsToAttributes(
                readCollabParagraph(node).values['textDefaults'],
              ),
              ...attributes,
            })
          : paragraphDefaultsFromAttributes(_commonDeltaAttributes(after));
      _updateParagraphProperties(transaction, node, {
        paragraphPropertyAttribute('textDefaults'): jsonEncode({
          'value': defaults.isEmpty ? null : defaults,
        }),
      });
    }
  }
  transaction.afterSelection = state.selection;
  await state.apply(transaction);
}

/// 返回借用 [delta] 所有区间共同具有的属性；空内容返回空集合，不继承对象身份。
Attributes _commonDeltaAttributes(Delta delta) {
  if (delta.isEmpty) return {};
  final common = <String, dynamic>{...?delta.first.attributes};
  for (final run in delta.skip(1)) {
    common.removeWhere((key, value) => run.attributes?[key] != value);
  }
  return common;
}

/// 返回借用 [state] 在规范化 [selection] 范围内的共同字符属性，不修改输入状态。
Attributes _commonSelectedAttributes(EditorState state, Selection selection) {
  final selected = Delta();
  for (final node in state.getNodesInSelection(selection)) {
    final delta = node.delta;
    if (delta == null) continue;
    final start = node.path.equals(selection.start.path)
        ? selection.start.offset
        : 0;
    final end = node.path.equals(selection.end.path)
        ? selection.end.offset
        : delta.length;
    selected.addAll(
      delta.slice(start.clamp(0, delta.length), end.clamp(0, delta.length)),
    );
  }
  return _commonDeltaAttributes(selected);
}

/// 将借用 [state] 中带原始缩进的空段落退一级；仅接管折叠光标和段落族。
/// 原始 depth 缺失、非正数、只读或销毁时返回 false；不裁剪已有深度，默认字符格式不变。
/// 与空段落 Enter 共用一个字段事务，可独立撤销；Future 完成代表事务完成，失败向调用边界传播。
Future<bool> outdentEmptyCollabParagraph(EditorState state) async {
  final selection = state.selection;
  if (state.isDisposed ||
      !state.editable ||
      selection == null ||
      !selection.isCollapsed) {
    return false;
  }
  final node = state.getNodeAtPath(selection.start.path);
  if (node == null ||
      !supportsCollabParagraph(node) ||
      node.delta?.isEmpty != true) {
    return false;
  }
  final raw = readCollabParagraph(node).values['depth'];
  final depth = raw is num
      ? raw.toDouble()
      : raw is String
      ? num.tryParse(raw)?.toDouble()
      : null;
  if (depth == null || !depth.isFinite || depth <= 0) return false;
  final transaction = state.transaction;
  _updateParagraphProperties(transaction, node, {
    paragraphPropertyAttribute('depth'): jsonEncode({'value': depth - 1}),
  });
  if (state.undoManager.undoStack.isNonEmpty) {
    state.undoManager.undoStack.last.seal();
  }
  await state.apply(
    transaction,
    withUpdateSelection: false,
    skipHistoryDebounce: true,
  );
  return true;
}

/// 为借用 [state] 当前选区设置 [style]：same 延续、body 转正文、null 恢复按块类型默认。
/// 每个段落使用稳定身份和独立字段补丁，一个事务可撤销；无有效选区或只读时返回 false。
/// Future 在事务完成后返回，不持有资源，失败向调用方传播。
Future<bool> setCollabNextParagraphStyle(
  EditorState state,
  String? style,
) async {
  if (state.isDisposed ||
      !state.editable ||
      state.selection == null ||
      (style != null && style != 'same' && style != 'body')) {
    return false;
  }
  final nodes = state
      .getNodesInSelection(state.selection!)
      .where(supportsCollabParagraph);
  final transaction = state.transaction;
  for (final node in nodes) {
    if (readCollabParagraph(node).values['nextParagraphStyle'] == style) {
      continue;
    }
    _updateParagraphProperties(transaction, node, {
      collabParagraphTargetAttribute:
          node.attributes['cses_collab_block_id'] ?? node.id,
      paragraphPropertyAttribute('nextParagraphStyle'): jsonEncode({
        'value': style,
      }),
    });
  }
  if (transaction.operations.isEmpty) return false;
  if (state.undoManager.undoStack.isNonEmpty) {
    state.undoManager.undoStack.last.seal();
  }
  await state.apply(
    transaction,
    withUpdateSelection: false,
    skipHistoryDebounce: true,
  );
  return true;
}

/// 向借用 [transaction] 添加 [node] 的精确 [patch] 和单字段逆操作；不快照正文或其他属性。
/// 稳定身份在正反操作中均保留，远端重排后不会写入邻居节点。
void _updateParagraphProperties(
  Transaction transaction,
  Node node,
  Attributes patch,
) {
  final target = node.attributes['cses_collab_block_id'] ?? node.id;
  final attributes = {...patch, collabParagraphTargetAttribute: target};
  transaction.add(
    UpdateOperation(node.path, attributes, {
      for (final key in patch.keys) key: node.attributes[key],
      collabParagraphTargetAttribute: target,
    }),
  );
}
