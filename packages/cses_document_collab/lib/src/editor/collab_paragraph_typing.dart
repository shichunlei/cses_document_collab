import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/model/collab_paragraph_style.dart';

/// 跟踪文档内输入格式，区分连续输入与光标导航；借用编辑器，创建者负责 dispose。
/// ```dart
/// import 'package:appflowy_editor/appflowy_editor.dart';
/// import 'package:cses_document_collab/src/editor/collab_paragraph_typing.dart';
/// final state = EditorState.blank();
/// final typing = CollabParagraphTyping(state);
/// // 本地事务前调用 typing.before(transaction, options)。
/// typing.dispose();
/// state.dispose();
/// ```
final class CollabParagraphTyping {
  /// 监听借用的 [state]；不释放编辑器，不持有网络或原生资源。
  CollabParagraphTyping(this.state) {
    _attached[state] = true;
    state.selectionNotifier.addListener(_selectionChanged);
    _selectionChanged();
    state.toggledStyleNotifier.addListener(_typingStyleChanged);
  }

  static final Expando<bool> _attached = Expando<bool>();

  /// 返回借用的 [state] 是否已有文档级输入监听，避免工具栏重复维护输入继承。
  static bool isAttached(EditorState state) => _attached[state] == true;

  /// 宿主持有的编辑器；生命周期长于该监听器。
  final EditorState state;

  /// 当前事务预期产生的光标；不匹配时按用户导航重新读取。
  Selection? _expected;

  /// 连续输入的原节点身份，跨块不延续临时格式。
  String? _source;

  /// 事务前显式输入状态，包括取消格式的 null 值。
  Attributes? _pending;

  /// 标记本监听器正在投影继承样式，避免把投影误认为用户的显式输入选择。
  bool _writingStyles = false;

  /// 用户显式输入格式所属的稳定块身份；远端移动光标时同块延续，主动导航时清除。
  String? _explicitNode;

  /// 本地工具栏选择的输入格式，包含取消属性的null；不写入协同数据。
  Attributes? _explicitStyles;

  /// 当前本地事务开始时的输入格式，用于记录撤销恢复。
  Attributes _before = {};

  /// 历史回放目标状态，仅在光标仍落于对应节点时恢复。
  ({Attributes attributes, String? nodeId})? _restore;

  /// 弱键跟随历史的属性/Delta 对象释放，不延长历史项生命周期。
  final _history = Expando<({Attributes attributes, String? nodeId})>();

  /// 插入节点列表对应的输入状态，与删除逆操作分开保存。
  final _insertHistory = Expando<({Attributes attributes, String? nodeId})>();

  /// 删除节点列表对应的输入状态，与插入逆操作分开保存。
  final _deleteHistory = Expando<({Attributes attributes, String? nodeId})>();

  /// 在借用 [transaction] 应用前保存当前输入格式，[options] 标识历史回放。
  /// 只有同段连续文字编辑延续显式临时格式；格式/历史/结构操作从落点重新读取。
  void before(Transaction transaction, ApplyOptions options) {
    _before = {...state.toggledStyle};
    _restore = null;
    if (options.recordRedo || options.isRedo) {
      for (final operation in transaction.operations) {
        final saved = switch (operation) {
          UpdateOperation() => _history[operation.attributes],
          UpdateTextOperation() => _history[operation.delta],
          InsertOperation() => _insertHistory[operation.nodes],
          DeleteOperation() => _deleteHistory[operation.nodes],
        };
        if (saved != null) _restore = saved;
      }
    }
    _expected = transaction.afterSelection;
    _source = state.selection == null
        ? null
        : state.getNodeAtPath(state.selection!.start.path)?.id;
    final edits = transaction.operations.map((op) {
      if (op is UpdateTextOperation) return op.delta;
      if (op is UpdateOperation &&
          op.attributes.containsKey(blockComponentDelta)) {
        final node = state.getNodeAtPath(op.path);
        return node?.delta?.diff(
          Delta.fromJson(op.attributes[blockComponentDelta]),
        );
      }
      return null;
    });
    _pending =
        options.recordUndo &&
            !options.isRedo &&
            edits.any(
              (delta) =>
                  delta?.any((run) => run is TextInsert || run is TextDelete) ==
                  true,
            )
        ? {...state.toggledStyle}
        : null;
  }

  /// 将 [original] 的弱键输入历史传给重定位后的 [relocated]，两者均由调用方持有。
  /// AppFlowy copyWith 会复制属性 Map，必须显式转移本地历史关联，不写入文档或原生协议。
  void transferHistory(UpdateOperation original, UpdateOperation relocated) {
    _history[relocated.attributes] = _history[original.attributes];
    _history[relocated.oldAttributes] = _history[original.oldAttributes];
  }

  /// 在借用 [transaction] 完成后记录字符输入历史；[options] 区分普通编辑及撤销/重做。
  /// 使用历史操作持有的对象作为弱键，不保留退出文档的历史或资源；同光标的空段落撤销立即回显。
  void after(Transaction transaction, ApplyOptions options) {
    _expected = transaction.afterSelection;
    final selection = transaction.afterSelection ?? state.selection;
    final node = selection == null
        ? null
        : state.getNodeAtPath(selection.start.path);
    if (node == null || !supportsCollabParagraph(node)) return;
    if (options.recordRedo || options.isRedo) {
      if (state.selection == selection) _selectionChanged();
      return;
    }
    final attrs = collabParagraphTypingAttributes(
      node,
      selection!.start.offset,
      pending: node.id == _source && node.delta?.isEmpty != true
          ? _pending ?? const {}
          : const {},
    );
    final before = (
      attributes: Map<String, dynamic>.from(_before),
      nodeId: _source,
    );
    final after = (attributes: attrs, nodeId: node.id);
    for (final operation in transaction.operations) {
      switch (operation) {
        case UpdateOperation():
          _history[operation.attributes] = after;
          _history[operation.oldAttributes] = before;
        case UpdateTextOperation():
          _history[operation.delta] = after;
          _history[operation.inverted] = before;
        case InsertOperation():
          _insertHistory[operation.nodes] = after;
          _deleteHistory[operation.nodes] = before;
        case DeleteOperation():
          _deleteHistory[operation.nodes] = after;
          _insertHistory[operation.nodes] = before;
      }
    }
  }

  /// 记录继承投影之外的本地输入样式选择，远端更新不能覆盖用户的明确选择。
  /// 非折叠选区和代码等专属块不保留该状态。
  void _typingStyleChanged() {
    if (_writingStyles || state.isDisposed) return;
    final selection = state.selection;
    if (selection == null || !selection.isCollapsed) return;
    final node = state.getNodeAtPath(selection.start.path);
    if (node == null || !supportsCollabParagraph(node)) return;
    _explicitNode =
        node.attributes['cses_collab_block_id'] as String? ?? node.id;
    _explicitStyles = {
      for (final entry in state.toggledStyle.entries)
        if (collabCharacterKeys.containsValue(entry.key) ||
            collabTypographyKeys.contains(entry.key))
          entry.key: entry.value,
    };
  }

  /// 导航及远端回放重读落点，缺失的字符外观显式清除；同段输入保留事务中的临时格式。
  /// 空段落使用当前共享默认值，清除或替换默认格式后不会继续输入旧字号、颜色或加粗。
  /// 用户明确选择的本地输入格式优先，主动导航后才重新继承文档。
  void _selectionChanged() {
    final selection = state.selection;
    if (selection == null || !selection.isCollapsed) {
      _explicitNode = null;
      _explicitStyles = null;
      return;
    }
    final node = state.getNodeAtPath(selection.start.path);
    if (node == null || !supportsCollabParagraph(node)) {
      _explicitNode = null;
      _explicitStyles = null;
      return;
    }
    final restored = selection == _expected && node.id == _restore?.nodeId
        ? _restore
        : null;
    final continuing =
        state.selectionUpdateReason != SelectionUpdateReason.remote &&
        selection == _expected &&
        node.id == _source;
    final remote =
        state.selectionUpdateReason == SelectionUpdateReason.remote &&
        (node.attributes['cses_collab_block_id'] ?? node.id) == _explicitNode;
    final pending =
        restored?.attributes ??
        (continuing
            ? _pending ?? const <String, dynamic>{}
            : remote
            ? _explicitStyles ?? const <String, dynamic>{}
            : const <String, dynamic>{});
    if (restored != null || (!continuing && !remote)) {
      _explicitNode = null;
      _explicitStyles = null;
    }
    _restore = null;
    _expected = null;
    _pending = null;
    final attrs = collabParagraphTypingAttributes(
      node,
      selection.start.offset,
      pending: pending,
    );
    _writingStyles = true;
    try {
      if (restored != null) {
        for (final key in state.toggledStyle.keys.toList()) {
          state.updateToggledStyle(key, null);
        }
      }
      for (final key in {
        ...attrs.keys,
        ...pending.keys,
        ...state.toggledStyle.keys.where(
          (key) =>
              collabCharacterKeys.containsValue(key) ||
              collabTypographyKeys.contains(key),
        ),
      }) {
        state.updateToggledStyle(key, attrs[key]);
      }
    } finally {
      _writingStyles = false;
    }
  }

  /// 注销监听，可重复调用；借用的编辑器仍由宿主释放。
  void dispose() {
    state.selectionNotifier.removeListener(_selectionChanged);
    state.toggledStyleNotifier.removeListener(_typingStyleChanged);
    _attached[state] = false;
  }
}
