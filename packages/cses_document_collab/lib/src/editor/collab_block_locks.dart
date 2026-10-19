import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/model/collab_block_lock.dart';
import 'package:flutter/foundation.dart';

/// 一个编辑器的块权限投影及打开中的弹窗租约；创建方负责dispose。
///
/// ```dart
/// import 'package:appflowy_editor/appflowy_editor.dart';
/// import 'package:cses_document_collab/src/editor/collab_block_locks.dart';
/// final editor = EditorState.blank();
/// final locks = CollabBlockLocks(editor: editor, userId: 'u1',
///   canUnlock: (_) => false, commit: (id, locked, expected) async {});
/// locks.dispose();
/// editor.dispose();
/// ```
final class CollabBlockLocks extends ChangeNotifier {
  /// [editor]为借用编辑器，[userId]为空禁用锁控制；[canUnlock]同步查询额外授权，
  /// [commit]执行原生锁命令且完成投影，失败向调用方传播；不拥有宿主资源。
  CollabBlockLocks({required this.editor, required this.userId, required this.canUnlock, required this.commit}) {
    _attached[editor] = this;
    editor.transactionGuard = allows;
    editor.selectionInputGuard = allowsSelection;
  }

  /// 借用编辑器，必须晚于本管理器释放。
  final EditorState editor;

  /// 当前正式账号；草稿为空。
  final String userId;

  /// 额外解锁授权，不替代文档编辑权限。
  final bool Function(CollabBlockLockState state) canUnlock;

  /// 原生提交与同步回调；expected为打开菜单时的明确状态。
  final Future<void> Function(String id, bool locked, CollabBlockLockState expected) commit;
  final Map<String, CollabBlockLockState> _states = {};
  final Map<String, int> _epochs = {};

  /// 无显式锁时跳过每次输入的块树遍历。
  bool _hasLocks = false;
  final List<Map<String, int>> _leases = [];
  static final _attached = Expando<CollabBlockLocks>('collab-block-locks');

  /// 查询借用[editor]的管理器；独立编辑器没有注册时返回null。
  static CollabBlockLocks? of(EditorState editor) => _attached[editor];

  /// 读取[id]的有效状态；不存在的本地新块按未锁处理，原生仍会校验父结构。
  CollabBlockLockState state(String id) => _states[id] ?? CollabBlockLockState(blockId: id);

  /// 读取借用[node]的稳定协同身份，尚未提交的新块使用AppFlowy身份。
  static String idOf(Node node) => node.attributes['cses_collab_block_id'] as String? ?? node.id;

  /// 判断[id]是否可写，包括所有祖先锁及当前弹窗租约失效状态。
  bool writable(String id) =>
      !state(id).locked && _leases.every((lease) => !lease.containsKey(id) || lease[id] == (_epochs[id] ?? 0));

  /// 是否可对[id]开启或关闭显式锁；文档只读、继承锁、未知身份均拒绝。
  bool canToggle(String id) {
    final value = state(id);
    if (!editor.editable || userId.isEmpty || !_states.containsKey(id)) return false;
    if (value.locked && !value.explicit) return false;
    return !value.explicit || (!value.template && value.ownerId == userId) || canUnlock(value);
  }

  /// 读取[id]的权限代次，用于跨异步范围拒绝锁后解锁的旧操作。
  int epoch(String id) => _epochs[id] ?? 0;

  /// 开始一段弹窗会话，返回创建者必须通过[endLease]归还的权限代次快照。
  Map<String, int> beginLease() {
    final lease = Map<String, int>.from(_epochs);
    _leases.add(lease);
    return lease;
  }

  /// 结束借用[lease]的会话；重复归还安全，不恢复任何旧权限。
  void endLease(Map<String, int> lease) => _leases.remove(lease);

  /// 安装原生[next]权限；即使正文相同也刷新，锁后解锁仍使旧弹窗失效。
  void update(Iterable<CollabBlockLockState> next) {
    final incoming = {for (final value in next) value.blockId: value};
    final changed = {..._states.keys, ...incoming.keys}.where((id) => _states[id] != incoming[id]).toSet();
    if (changed.isEmpty) return;
    for (final id in changed) {
      _epochs[id] = (_epochs[id] ?? 0) + 1;
    }
    _states
      ..clear()
      ..addAll(incoming);
    _hasLocks = incoming.values.any((state) => state.locked || state.containsLock);
    void refresh(Node node) {
      if (changed.contains(idOf(node))) node.notify();
      for (final child in node.children) {
        refresh(child);
      }
    }

    refresh(editor.document.root);
    if (editor.selection != null && !allowsSelection(editor.selection!)) {
      editor.service.keyboardService?.closeKeyboard();
    }
    notifyListeners();
  }

  /// 在借用[selection]上只允许全部目标均未锁且租约有效时连接输入。
  bool allowsSelection(Selection selection) =>
      editor.getNodesInSelection(selection).every((node) => writable(idOf(node)));

  /// 在借用[transaction]的任何操作执行前检查完整批次，并跟踪前序插入/删除引起的路径偏移。
  /// 拒绝整次受保护修改，不能部分执行；不修改事务、正文或历史。
  bool allows(Transaction transaction) {
    if (!_hasLocks && _leases.isEmpty) return true;
    final nodes = <Node>[];
    void visit(Node node) {
      nodes.add(node);
      for (final child in node.children) {
        visit(child);
      }
    }

    visit(editor.document.root);
    final paths = {for (final node in nodes) idOf(node): List<int>.of(node.path)};
    bool prefix(Path a, Path b) => a.length <= b.length && List.generate(a.length, (i) => a[i] == b[i]).every((v) => v);
    for (final operation in transaction.operations) {
      final path = operation.path;
      if (operation is InsertOperation) {
        for (final entry in paths.entries) {
          if (prefix(entry.value, path) &&
              entry.value.length < path.length &&
              (state(entry.key).locked || (entry.value.equals(path.parent) && !writable(entry.key)))) {
            return false;
          }
        }
        bool protected(Node node) =>
            state(idOf(node)).locked || state(idOf(node)).containsLock || node.children.any(protected);
        if (operation.nodes.any(protected)) return false;
      } else if (operation is DeleteOperation) {
        if (path.isEmpty) return false;
        for (final entry in paths.entries) {
          final p = entry.value;
          if (p.length >= path.length &&
              prefix(path.parent, p) &&
              p[path.length - 1] >= path.last &&
              p[path.length - 1] < path.last + operation.nodes.length &&
              (!writable(entry.key) || state(entry.key).containsLock)) {
            return false;
          }
        }
      } else {
        for (final entry in paths.entries) {
          if (prefix(entry.value, path) &&
              (state(entry.key).locked || (entry.value.equals(path) && !writable(entry.key)))) {
            return false;
          }
        }
      }
      if (path.isNotEmpty && (operation is InsertOperation || operation is DeleteOperation)) {
        final count = operation is InsertOperation
            ? operation.nodes.length
            : -(operation as DeleteOperation).nodes.length;
        for (final p in paths.values) {
          if (p.length >= path.length && prefix(path.parent, p) && p[path.length - 1] >= path.last) {
            p[path.length - 1] += count;
          }
        }
      }
    }
    return true;
  }

  /// 注销自有策略与关联，清理会话；不关闭借用编辑器和宿主资源。
  @override
  void dispose() {
    if (identical(_attached[editor], this)) {
      _attached[editor] = null;
      editor.transactionGuard = null;
      editor.selectionInputGuard = null;
    }
    _leases.clear();
    super.dispose();
  }
}

/// 判断借用[editor]中的[node]可否修改；未注册块锁时沿用文档权限。
bool canEditCollabNode(EditorState editor, Node node) =>
    !editor.isDisposed &&
    editor.editable &&
    (CollabBlockLocks.of(editor)?.writable(CollabBlockLocks.idOf(node)) ?? true);
