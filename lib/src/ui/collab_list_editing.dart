import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_mobile_collab_demo/src/collab/appflowy_block_editor_adapter.dart';
import 'package:cses_mobile_collab_demo/src/collab/collab_ordered.dart';
import 'package:flutter/services.dart';

/// 扁平协同有序/无序/Todo 列表的 Enter 入口，放在标准字符快捷键之前，供软键盘和硬件键盘共用。
/// 有正文时新增同级项，空项逐级退出，最外层空项转段落；借用编辑器，不持有资源。
/// 有序编号仍由 Rust 按 depth 计算，不复制前项的协同身份、起点或派生编号；新待办项未勾选。
///
/// ```dart
/// import 'package:appflowy_editor/appflowy_editor.dart';
/// import 'package:cses_mobile_collab_demo/src/ui/collab_list_editing.dart';
/// final state = EditorState.blank(); // 宿主负责 state.dispose()。
/// final editor = AppFlowyEditor(editorState: state, characterShortcutEvents: [
///   collabListEnter, ...standardCharacterShortcutEvents,
/// ]);
/// ```
final collabListEnter = CharacterShortcutEvent(
  key: 'cses-flat-list-enter',
  character: '\n',
  handler: handleCollabListEnter,
);

/// 在借用的 [state] 处理当前折叠光标的有序/无序/Todo 列表 Enter，成功完成事务返回 true。
/// 只接管根级或高亮容器内、无子节点的扁平列表；只读、销毁、Shift、无选区或其他类型返回 false，
/// 交由标准输入处理。文字拆分复用 insertNewLine，保留 Delta 格式和方向并继承层级/对齐。
/// 空项退级原位修改 depth；有序项若显式重开编号，同时用既有编号命令恢复接续父层。
/// 无序/待办项仅修改层级，不携带任何有序列表编号命令。待办拆分不改原项勾选，
/// 新项显式设为未勾选；空项退级保留勾选状态，转段落后不再作为待办展示或同步，撤销可恢复。
/// 显式 ms 样式与桌面相同保留；默认样式随 depth 显示。各次退级独立可撤销，逆操作
/// 只记录深度及必要的编号设置，不恢复旧正文或派生 order。最外层转换经现有身份链
/// 保留原生扩展属性。Future 在事务完成后结束；失败交给编辑器/宿主异常边界。
Future<bool> handleCollabListEnter(EditorState state) async {
  if (HardwareKeyboard.instance.isShiftPressed) {
    return false;
  }
  final node = _editableFlatList(state);
  if (node == null) {
    return false;
  }
  final delta = node.delta!;
  if (delta.isEmpty) {
    return outdentCollabListAtStart(state);
  }
  final depth = (node.attributes[csesBlockIndentAttribute] as int? ?? 0).clamp(
    0,
    6,
  );
  if (state.undoManager.undoStack.isNonEmpty) {
    state.undoManager.undoStack.last.seal();
  }

  final alignment = node.attributes[blockComponentAlign] ?? 'left';
  await state.insertNewLine(
    nodeBuilder: (inserted) => inserted.copyWith(
      type: node.type,
      attributes: {
        ...inserted.attributes,
        csesBlockIndentAttribute: depth,
        blockComponentAlign: alignment,
        if (node.type == TodoListBlockKeys.type)
          TodoListBlockKeys.checked: false,
      },
    ),
  );
  return true;
}

/// 返回借用的 [state] 是否可在列表项开头退级；只接管折叠光标偏移 0 的根级或高亮块内扁平列表。
/// 有正文和空项均支持；只读、销毁、范围选区、真正嵌套节点及非列表返回 false，无副作用。
bool canOutdentCollabListAtStart(EditorState state) =>
    _editableFlatList(state) != null && state.selection?.start.offset == 0;

/// 将借用的 [state] 中行首列表退一级，最外层转为普通段落；完成事务后返回 true。
/// 非可编辑根级或高亮块内列表、非折叠选区或偏移不为 0 时返回 false。复用 Enter 与 Backspace，
/// 不删除正文、行内格式或相邻块，退级保留 Todo 勾选及块身份；转换使用既有类型身份链。
/// 有序正起点通过既有编号命令接续目标层，逆操作恢复原始设置；每次操作独立可撤销。
/// 选区保持原路径偏移 0，清空临时选区信息以继续附着输入连接。宿主拥有编辑器生命周期；
/// 不创建监听、FocusNode 或网络资源。事务失败通过 Future 向调用边界传播。
Future<bool> outdentCollabListAtStart(EditorState state) =>
    canOutdentCollabListAtStart(state)
    ? _applyListIndent(state, -1, selectionType: SelectionType.inline)
    : Future.value(false);

/// 返回借用 [state] 当前选区是否可整体升降列表层级；[delta] 仅接受 -1 或 1。
/// 选区中每项必须是可编辑根级或高亮块内有序/无序/Todo 列表且无真实子节点。增加时任一项已到 6 级
/// 则整体返回 false；减少允许 0 级转段落。支持项内光标、正反向范围和块选区；不修改状态。
bool canChangeCollabListIndent(EditorState state, int delta) {
  if (delta != -1 && delta != 1) {
    return false;
  }
  final nodes = _selectedFlatLists(state);
  return nodes.isNotEmpty &&
      (delta < 0 || nodes.every((node) => _listDepth(node) < 6));
}

/// 在借用 [state] 当前选区整体增减一级；[delta] 仅接受 -1 或 1，不满足条件返回 false。
/// 项内光标和范围选区保持原路径、偏移、方向及选区类型；选区包含非列表/真实子节点、只读、
/// 销毁或增加时任一项到达 6 级均不执行部分操作。减少到 0 级后再次减少将对应项转为段落。
/// 正文、格式、对齐和 Todo 勾选在退级中保留；转段落后不再作为待办展示，Undo 可恢复。
/// 增加保留显式起点；减少沿用父层接续命令。有序计数由 Rust 按目标层级重算。
/// 整个选区一个事务/一个撤销步骤；逆属性操作只记录深度和必要编号设置，不覆盖其他属性。
/// Future 在事务应用后完成；异常向调用边界传播。宿主拥有编辑器，无新增监听或焦点资源。
Future<bool> changeCollabListIndent(EditorState state, int delta) =>
    _applyListIndent(
      state,
      delta,
      selectionType: state.selectionType ?? SelectionType.inline,
    );

/// 将借用 [state] 当前选区中的扁平列表切为 [targetType]，仅接受有序/无序/Todo 三种类型。
/// 保留每项的 depth、完整 Delta、对齐及选区路径/偏移/方向/类型；真正嵌套、非列表混选、
/// 无效选区、只读或销毁时返回 false。相同类型的项目不重建、不重置勾选或编号；全部相同
/// 返回 false 且不产生历史/协同消息。进入 Todo 默认未勾选，离开 Todo 删除勾选属性。
/// 实际转换移除旧编号投影/命令；Rust 依目标层级计算新的编号。逆结构操作保存原节点，
/// 可恢复旧勾选和显式编号；正式类型替换沿用适配器的新身份链与原生扩展属性克隆。
/// 整个选区一次事务、一个撤销步骤，清理临时手势元数据以保留输入连接。Future 在事务
/// 完成后返回 true，异常向宿主传播；无新增资源，编辑器生命周期仍归宿主所有。
Future<bool> changeCollabListType(EditorState state, String targetType) async {
  if (!_isListType(targetType)) {
    return false;
  }
  final nodes = _selectedFlatLists(state);
  final changed = nodes.where((node) => node.type != targetType).toList();
  if (changed.isEmpty) {
    return false;
  }
  final selection = state.selection!;
  final selectionType = state.selectionType ?? SelectionType.inline;
  if (state.undoManager.undoStack.isNonEmpty) {
    state.undoManager.undoStack.last.seal();
  }
  final transaction = state.transaction;
  for (final node in changed) {
    final attributes = Map<String, dynamic>.from(node.attributes)
      ..remove(TodoListBlockKeys.checked)
      ..remove(csesOrderedAttribute)
      ..remove(csesOrderedNumberingAttribute)
      ..remove(csesOrderedTargetAttribute)
      ..[csesBlockIndentAttribute] = _listDepth(node);
    if (targetType == TodoListBlockKeys.type) {
      attributes[TodoListBlockKeys.checked] = false;
    }
    // 各对操作净块数为零，原坐标不变；保留 Delete 的源节点供 Undo 恢复其原始设置。
    transaction.add(DeleteOperation(node.path, [node]), transform: false);
    transaction.add(
      InsertOperation(node.path, [
        node.copyWith(type: targetType, attributes: attributes),
      ]),
      transform: false,
    );
  }
  transaction
    ..afterSelection = selection
    ..selectionExtraInfo = {}
    ..customSelectionType = selectionType;
  await state.apply(transaction, skipHistoryDebounce: true);
  return true;
}

/// 判断 [type] 是否属于协同扁平列表支持的三种类型；无状态、无资源及副作用。
bool _isListType(String type) =>
    type == NumberedListBlockKeys.type ||
    type == BulletedListBlockKeys.type ||
    type == TodoListBlockKeys.type;

/// 向借用 [state] 应用 [delta] 指定的 -1/+1 层级事务；[selectionType] 决定恢复的选区展示类型。
/// 先完整校验当前选区，再构建属性更新和必要的逐项类型替换；结构替换的删除/插入净块数为 0，
/// 所有路径基于同一原文档，关闭重复路径变换以避免批量/反向选区错位。类型转换必须通过结构
/// 操作触发现有 Rust 身份链；深度变化使用最小属性逆操作。调用方负责异常与编辑器生命周期。
Future<bool> _applyListIndent(
  EditorState state,
  int delta, {
  required SelectionType selectionType,
}) async {
  if (delta != -1 && delta != 1) {
    return false;
  }
  final nodes = _selectedFlatLists(state);
  if (nodes.isEmpty ||
      (delta > 0 && nodes.any((node) => _listDepth(node) >= 6))) {
    return false;
  }
  final selection = state.selection!;
  if (state.undoManager.undoStack.isNonEmpty) {
    state.undoManager.undoStack.last.seal();
  }
  final transaction = state.transaction;
  for (final node in nodes) {
    final depth = _listDepth(node);
    if (delta < 0 && depth == 0) {
      // formatNode 会独立提交事务；批量操作使用相同的底层原语与深度更新一起提交。
      // 每对操作恢复相同根路径，保留相邻块与选区的路径/偏移；只替换实际改变类型的节点。
      transaction.add(DeleteOperation(node.path, [node]), transform: false);
      transaction.add(
        InsertOperation(node.path, [
          node.copyWith(
            type: ParagraphBlockKeys.type,
            attributes: {...node.attributes, csesBlockIndentAttribute: 0},
          ),
        ]),
        transform: false,
      );
      continue;
    }
    final attributes = <String, dynamic>{
      csesBlockIndentAttribute: depth + delta,
    };
    final previous = <String, dynamic>{csesBlockIndentAttribute: depth};
    final projection = node.attributes[csesOrderedAttribute];
    if (delta < 0 &&
        node.type == NumberedListBlockKeys.type &&
        projection is Map) {
      final ordered =
          CollabOrdered.fromJson(
            Map<String, dynamic>.from(projection),
          ).withNumbering(
            node.attributes[csesOrderedNumberingAttribute] as String? ??
                projection['numbering'] as String? ??
                '{}',
          );
      if (ordered.restarts) {
        final id =
            node.attributes[AppFlowyBlockEditorAdapter.collabBlockIdAttribute]
                as String? ??
            node.id;
        attributes.addAll({
          csesOrderedTargetAttribute: id,
          csesOrderedNumberingAttribute: '{"start":0,"continuePrevious":true}',
        });
        previous.addAll({
          csesOrderedTargetAttribute: id,
          csesOrderedNumberingAttribute: ordered.numbering,
        });
      }
    }

    transaction.add(
      UpdateOperation(node.path, attributes, previous),
      transform: false,
    );
  }
  transaction
    ..afterSelection = selection
    ..selectionExtraInfo = {}
    ..customSelectionType = selectionType;
  await state.apply(transaction, skipHistoryDebounce: true);
  return true;
}

/// 读取借用 [state] 当前选区中的全部扁平列表；只读/销毁、路径或偏移无效、包含非列表返回空。
/// 保留选区遍历顺序和节点引用，不复制正文、不转移所有权、不修改编辑器；调用方同步构建事务。
List<Node> _selectedFlatLists(EditorState state) {
  if (state.isDisposed || !state.editable) {
    return const [];
  }
  final selection = state.selection;
  if (selection == null ||
      selection.start.path.isEmpty ||
      selection.end.path.isEmpty) {
    return const [];
  }
  final nodes = state.getNodesInSelection(selection);
  if (nodes.isEmpty ||
      nodes.any(
        (node) =>
            node.delta == null ||
            node.children.isNotEmpty ||
            !_isFlatListParent(node) ||
            (node.type != NumberedListBlockKeys.type &&
                node.type != BulletedListBlockKeys.type &&
                node.type != TodoListBlockKeys.type),
      )) {
    return const [];
  }
  for (final position in [selection.start, selection.end]) {
    final node = state.getNodeAtPath(position.path)!;
    if (position.offset < 0 || position.offset > node.delta!.length) {
      return const [];
    }
  }
  return nodes;
}

/// 从借用 [node] 读取有效视觉层级；缺失/非整数回退 0，整数限制在既有 0～6 范围，无副作用。
int _listDepth(Node node) {
  final value = node.attributes[csesBlockIndentAttribute];
  return value is int ? value.clamp(0, 6) : 0;
}

/// 从借用的 [state] 读取可编辑的扁平列表；返回原节点供事务使用，不转移所有权。
/// 无选区、只读、销毁、非折叠/非支持父节点路径、无 Delta、有子节点或非三种列表返回 null。
Node? _editableFlatList(EditorState state) {
  if (state.isDisposed || !state.editable) {
    return null;
  }
  final selection = state.selection;
  if (selection == null ||
      !selection.isCollapsed ||
      selection.start.path.isEmpty) {
    return null;
  }
  final node = state.getNodeAtPath(selection.start.path);
  if (node == null ||
      !_isFlatListParent(node) ||
      node.delta == null ||
      node.children.isNotEmpty ||
      (node.type != NumberedListBlockKeys.type &&
          node.type != BulletedListBlockKeys.type &&
          node.type != TodoListBlockKeys.type)) {
    return null;
  }
  return node;
}

// Depth is a prop within each sibling list, including lists inside a callout.
bool _isFlatListParent(Node node) =>
    node.path.length == 1 || node.parent?.type == csesCalloutBlockType;
