import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/collab_block_locks.dart';
import 'package:cses_document_collab/src/editor/collab_block_actions.dart';
import 'package:cses_document_collab/src/editor/collab_paragraph_links.dart';
import 'package:cses_document_collab/src/model/collab_block_lock.dart';
import 'package:cses_document_collab/src/model/collab_host_services.dart';
import 'package:cses_document_collab/src/editor/editor_shortcut_toolbar.dart';
import 'package:cses_document_collab/src/model/collab_formula.dart';
import 'package:cses_document_collab/src/model/collab_inline_formula.dart';
import 'package:cses_document_collab/src/native/collab_runtime.dart';
import 'package:cses_document_collab/src/ui/modal/collab_bottom_sheet.dart';
import 'package:cses_document_collab/src/ui/modal/collab_dialog.dart';
import 'package:cses_document_collab/src/ui/modal/collab_menu_row.dart';
import 'package:cses_document_collab/src/ui/modal/collab_switch_row.dart';
import 'package:cses_document_collab/src/ui/modal/collab_formula_visual.dart';
import 'package:cses_document_collab/src/ui/modal/collab_modal.dart';
import 'package:cses_document_collab/src/ui/modal/collab_modal_colors.dart';
import 'package:cses_document_collab/src/ui/modal/collab_modal_field.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// 打开稳定 [id] 对应独立公式的统一面板，借用 [context] 和 [editor]。
/// 点击已锁定卡片仍可查看/复制及执行授权解锁；文档预览模式不打开。
/// 隔离正文输入，等待退场后执行块命令，插入恢复新段落光标，锁/删除/定位不恢复键盘。
/// 同一编辑器拒绝重复打开；失败在存活宿主提示，旧会话的迟到结果不会写入新身份。
Future<void> showCollabFormulaEditor(
  BuildContext context,
  EditorState editor,
  String id,
) async {
  if (editor.isDisposed ||
      !editor.editable ||
      findCollabFormula(editor, id) == null ||
      _formulaOpen[editor] != null) {
    return;
  }
  final host = collabBlockActionContext(context);
  final session = _FormulaSession(editor, id);
  _formulaOpen[editor] = session;
  try {
    await runEditorHeaderAction<void>(
      host,
      editor,
      () async {
        try {
          await _presentFormulaInput(host, editor, id: id, session: session);
        } finally {
          if (identical(_formulaOpen[editor], session)) {
            _formulaOpen[editor] = null;
          }
        }
      },
      canRestore: () =>
          session.current &&
          (session.action == null || session.action == _FormulaAction.insert),
      selectionAfterAction: () {
        final node = session.insertedId == null
            ? null
            : findCollabActionNode(editor, session.insertedId!);
        return node == null
            ? null
            : Selection.single(path: node.path, startOffset: 0);
      },
    );
  } catch (error, stack) {
    CollabDiagnostics.report(
      '公式操作失败',
      error: error,
      stackTrace: stack,
      tag: 'DocCollab',
    );
    if (host.mounted && !editor.isDisposed && session.sameHost) {
      ScaffoldMessenger.maybeOf(
        host,
      )?.showSnackBar(const SnackBar(content: Text('公式操作失败，请重试')));
    }
  } finally {
    session.dispose();
    if (identical(_formulaOpen[editor], session)) {
      _formulaOpen[editor] = null;
    }
  }
}

/// 在借用 [context] 和 [editor] 中输入公式，完整退场后返回原文，取消或块命令返回null。
/// [id]非null编辑独立块，展示块操作；[inlineTarget]非null编辑行内对象，两者互斥。
/// [initialLatex]为插入草稿，默认空，既有对象忽略；[creatingBlock]默认false，
/// true将无目标的面板标为新建独立公式并显示“创建”，行内调用保持原交互。
/// 调用方负责隔离正文输入；面板拥有输入控制器，独立块会话成对释放权限监听。
Future<String?> showCollabFormulaInput(
  BuildContext context,
  EditorState editor, {
  String? id,
  CollabInlineFormulaTarget? inlineTarget,
  String initialLatex = '',
  bool creatingBlock = false,
}) async {
  if (editor.isDisposed ||
      !editor.editable ||
      (id != null && inlineTarget != null)) {
    return null;
  }
  final session = id == null ? null : _FormulaSession(editor, id);
  try {
    return await _presentFormulaInput(
      context,
      editor,
      id: id,
      inlineTarget: inlineTarget,
      initialLatex: initialLatex,
      creatingBlock: creatingBlock,
      session: session,
    );
  } finally {
    session?.dispose();
  }
}

/// 在借用 [context]/[editor] 中展示面板；[id]/[inlineTarget]为互斥目标，
/// [initialLatex]为创建草稿，[creatingBlock]区分独立块创建，[session]为独立块的借用会话。
/// 路由完整退出后核对动作快照并执行命令；面板保存仍仅提交latex，结果原文不会自动写入创建目标。
Future<String?> _presentFormulaInput(
  BuildContext context,
  EditorState editor, {
  String? id,
  CollabInlineFormulaTarget? inlineTarget,
  String initialLatex = '',
  bool creatingBlock = false,
  _FormulaSession? session,
}) async {
  final result = await showCollabBottomSheet<_FormulaResult>(
    context: context,
    builder: (_) => _FormulaSheet(
      editor: editor,
      id: id,
      inlineTarget: inlineTarget,
      initialLatex: initialLatex,
      creatingBlock: creatingBlock,
      session: session,
    ),
  );
  if (result?.action != null && context.mounted && session != null) {
    await session.execute(context, result!.action!, result.snapshot!);
  }
  return result?.latex;
}

/// 按编辑器隔离重复点击，不延长编辑器资源生命周期。
final _formulaOpen = Expando<_FormulaSession>('formula-panel');

/// 借用编辑器，持有输入、预览及目标变化监听；确认前不写共享数据。
class _FormulaSheet extends StatefulWidget {
  /// [editor] 由页面持有，[id] 为独立块身份，[inlineTarget] 为行内位置，两者均 null 表示插入。
  /// [initialLatex]为插入草稿；[creatingBlock]控制新建文案，[session]为独立块借用会话；默认均不启用。
  const _FormulaSheet({
    required this.editor,
    this.id,
    this.inlineTarget,
    this.initialLatex = '',
    this.creatingBlock = false,
    this.session,
  });

  /// 是否为独立块创建；默认false，行内创建沿用原有文案。
  final bool creatingBlock;

  /// 由展示入口持有和释放的独立块会话；行内及创建时为null。
  final _FormulaSession? session;

  /// 插入模式的初始 LaTeX，不直接写入正文。
  final String initialLatex;

  /// 必需的借用编辑器，面板不释放其资源。
  final EditorState editor;

  /// 可选的既有块身份，null 时为插入模式。
  final String? id;

  /// 可选的行内原子位置；null 时沿用独立块编辑或插入模式，与 id 互斥。
  final CollabInlineFormulaTarget? inlineTarget;

  /// 创建拥有输入控制器的局部状态。
  @override
  createState() => _FormulaSheetState();
}

/// 持有草稿、权限及祖先监听；保存串行且不覆盖变化的远端原文。
class _FormulaSheetState extends State<_FormulaSheet> {
  /// 本面板创建、监听并释放的输入控制器。
  final _input = TextEditingController();

  /// 当前目标和祖先的借用监听，关闭时逐一解除。
  final Set<Node> _nodes = {};

  /// 打开或重新加载时的独立字段 wrapper 或行内原文，用于拒绝陈旧草稿。
  String? _original;

  /// 提交期间禁止重复保存与删除。
  bool _saving = false;

  /// 当前可见失败，不覆盖正在编辑的草稿。
  String? _error;

  /// 草稿处置确认期间阻止重复命令，由本面板持有。
  bool _choosing = false;

  /// 打开或重载时的原文，用于判断尚未保存的草稿。
  String _loadedLatex = '';

  /// 仅独立公式编辑显示整块操作；行内与创建保持各自表单。
  _FormulaSession? get _session => widget.session;

  /// 获取当前稳定目标，创建模式或失效目标返回 null。
  Node? get _target => widget.inlineTarget != null
      ? widget.inlineTarget!.resolve(widget.editor)
      : widget.id == null
      ? null
      : findCollabFormula(widget.editor, widget.id!);

  /// 本面板是否编辑已存在对象，而非收集新公式草稿。
  bool get _editing => widget.id != null || widget.inlineTarget != null;

  /// 当前权威原文或独立块字段 wrapper；删除或定位失效返回 null。
  String? get _field => widget.inlineTarget != null
      ? (_target == null
            ? null
            : collabInlineLatexAt(_target!, widget.inlineTarget!.offset))
      : _target?.attributes[collabFormulaAttribute] as String?;

  /// 仅权限与目标均有效时允许编辑。
  bool get _enabled =>
      !widget.editor.isDisposed &&
      widget.editor.editable &&
      (!_editing || _target != null) &&
      (_target == null || canEditCollabNode(widget.editor, _target!)) &&
      !_saving &&
      !_choosing &&
      (_session?.current ?? true);

  /// 草稿是否基于过期的远端字段，独立于其他扩展属性变化。
  bool get _conflict => _editing && _target != null && _field != _original;

  /// 初始化原文并建立成对的权限/节点/草稿监听。
  @override
  void initState() {
    super.initState();
    _load();
    _input.addListener(_onDraft);
    widget.editor.editableNotifier.addListener(_onTree);
    _session?.addListener(_onTree);
    _syncNodes();
  }

  /// 从当前权威字段重新加载，丢弃局部草稿但不写入共享文档。
  void _load() {
    final node = _target;
    _original = _field;
    _input.text = widget.inlineTarget != null
        ? (_field ?? '')
        : node == null
        ? widget.initialLatex
        : readCollabFormula(node.attributes).string('latex');
    _loadedLatex = _input.text;
    _error = null;
  }

  /// 根据稳定目标重新建立祖先监听，不持有已被替换的旧节点。
  void _syncNodes() {
    final next = <Node>{widget.editor.document.root};
    var node = _target;
    while (node != null) {
      next.add(node);
      node = node.parent;
    }
    for (final old in _nodes.difference(next)) {
      old.removeListener(_onTree);
    }
    for (final added in next.difference(_nodes)) {
      added.addListener(_onTree);
    }
    _nodes
      ..clear()
      ..addAll(next);
  }

  /// 草稿改变只刷新本面板预览，输入结束前不产生协同补丁。
  void _onDraft() {
    if (mounted) setState(() => _error = null);
  }

  /// 远端属性、删除、重排和权限变更刷新状态，不改写正在输入的草稿。
  void _onTree() {
    if (!mounted || widget.editor.isDisposed) return;
    _session?.observeTarget();
    _syncNodes();
    setState(() {});
  }

  /// 提交当前草稿但不关闭面板；创建只校验，编辑写入单字段独立历史。
  /// 返回false表示失效、冲突、过长或提交失败；失败显示原面板并保留草稿。
  Future<bool> _commitDraft() async {
    if (!_enabled || _conflict || _input.text.length > collabFormulaMaxLength) {
      return false;
    }
    final latex = _input.text;
    setState(() => _saving = true);
    try {
      if (widget.inlineTarget != null) {
        final changed = await changeCollabInlineFormula(
          widget.editor,
          widget.inlineTarget!,
          latex,
          expectedLatex: _original ?? '',
        );
        if (!changed && (!_enabledAfterSave || _conflict)) {
          if (mounted) setState(() => _error = '公式位置已变化或当前不可编辑，请重新打开');
          return false;
        }
      } else if (widget.id != null) {
        final changed = await changeCollabFormula(
          widget.editor,
          widget.id!,
          latex,
          expectedField: _original,
        );
        if (!changed && (!_enabledAfterSave || _conflict)) {
          if (mounted) setState(() => _error = '公式已变化或当前不可编辑，请重新加载');
          return false;
        }
      }
      if (!mounted ||
          widget.editor.isDisposed ||
          !widget.editor.editable ||
          (_session?.current == false)) {
        return false;
      }
      _original = _field;
      _loadedLatex = latex;
      return true;
    } catch (error, stack) {
      CollabDiagnostics.report(
        '保存公式失败',
        error: error,
        stackTrace: stack,
        tag: 'DocCollab',
      );
      if (mounted) setState(() => _error = '保存失败，请重试');
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 保存成功后返回原文；创建者在路由退出后执行插入，行内调用保持原结果。
  Future<void> _save() async {
    if (await _commitDraft() && mounted) {
      Navigator.pop(context, _FormulaResult(latex: _input.text));
    }
  }

  /// 处理独立块[action]；未保存草稿在锁定/插入前可保存、放弃或取消，删除直接丢弃草稿。
  /// 确认期间和面板退场后均验证原文、权限代次及身份；执行由入口等待路由退出后负责。
  Future<void> _chooseAction(_FormulaAction action) async {
    try {
      await _chooseActionChecked(action);
    } catch (error, stack) {
      CollabDiagnostics.report(
        '公式操作失败',
        error: error,
        stackTrace: stack,
        tag: 'DocCollab',
      );
      if (mounted) setState(() => _error = '操作失败，请重试');
    }
  }

  /// 校验并收集独立块[action]，确认等待及路由错误由外层回调报告。
  Future<void> _chooseActionChecked(_FormulaAction action) async {
    final session = _session;
    if (session == null ||
        !session.current ||
        _saving ||
        _choosing ||
        _conflict) {
      return;
    }
    if (action == _FormulaAction.toggle && !session.canToggle) return;
    if ((action == _FormulaAction.insert || action == _FormulaAction.delete) &&
        !session.writable) {
      return;
    }
    final originalSnapshot = session.snapshot;
    if ((action == _FormulaAction.toggle || action == _FormulaAction.insert) &&
        _input.text != _loadedLatex) {
      setState(() => _choosing = true);
      bool? save;
      try {
        save = await showCollabDialog<bool>(
          context: context,
          useRootNavigator: false,
          builder: (dialog) => CollabDialog(
            title: const Text('保存当前修改？'),
            content: const Text('继续操作前，可以保存或放弃尚未保存的公式修改。'),
            actions: [
              TextButton(
                key: const ValueKey('formula-draft-cancel'),
                onPressed: () => Navigator.pop(dialog),
                child: const Text('取消'),
              ),
              TextButton(
                key: const ValueKey('formula-draft-discard'),
                onPressed: () => Navigator.pop(dialog, false),
                child: const Text('放弃修改'),
              ),
              FilledButton(
                key: const ValueKey('formula-draft-save'),
                onPressed: () => Navigator.pop(dialog, true),
                child: const Text('保存并继续'),
              ),
            ],
          ),
        );
      } finally {
        if (mounted) setState(() => _choosing = false);
      }
      if (!mounted ||
          save == null ||
          !session.current ||
          _conflict ||
          session.snapshot != originalSnapshot) {
        return;
      }
      if (save && !await _commitDraft()) return;
    }
    if (!mounted || !session.current || _conflict) return;
    final snapshot = session.snapshot;
    if (snapshot == null) return;
    Navigator.pop(context, _FormulaResult(action: action, snapshot: snapshot));
  }

  /// 在面板内复制段落链接，保留草稿与正文失焦；失败显示提示，不结束当前会话。
  Future<void> _copyLink() async {
    final session = _session;
    final node = session?.target;
    if (session == null ||
        !session.current ||
        node == null ||
        _saving ||
        _choosing) {
      return;
    }
    setState(() => _saving = true);
    try {
      FocusScope.of(context).unfocus();
      await session.links?.copy(
        context,
        node,
        isCurrent: () => mounted && session.current,
      );
    } catch (error, stack) {
      CollabDiagnostics.report(
        '复制段落链接失败',
        error: error,
        stackTrace: stack,
        tag: 'DocCollab',
      );
      if (mounted) setState(() => _error = '复制失败，请重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 保存后再次核对编辑器和目标，忽略本地忙碌标志。
  bool get _enabledAfterSave =>
      !widget.editor.isDisposed &&
      widget.editor.editable &&
      (!_editing || _target != null) &&
      (_session?.current ?? true);

  /// 删除一个行内原子；独立公式交给统一块命令在退场后删除。
  /// 行内目标变化时拒绝删除，错误保留面板并可重试。
  Future<void> _delete() async {
    if (_session != null) {
      await _chooseAction(_FormulaAction.delete);
      return;
    }
    if (!_enabled || _target == null) return;
    setState(() => _saving = true);
    try {
      final changed = await changeCollabInlineFormula(
        widget.editor,
        widget.inlineTarget!,
        '',
        expectedLatex: _original ?? '',
      );
      if (!changed) {
        if (mounted) setState(() => _error = '公式已变化，请重新加载或打开');
        return;
      }
      if (mounted) Navigator.pop(context);
    } catch (error, stack) {
      CollabDiagnostics.report(
        '删除公式失败',
        error: error,
        stackTrace: stack,
        tag: 'DocCollab',
      );
      if (mounted) setState(() => _error = '删除失败，请重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 解除借用监听并释放本面板拥有的输入控制器。
  @override
  void dispose() {
    widget.editor.editableNotifier.removeListener(_onTree);
    _session?.removeListener(_onTree);
    for (final node in _nodes) {
      node.removeListener(_onTree);
    }
    _input.removeListener(_onDraft);
    _input.dispose();
    super.dispose();
  }

  /// 构造已有独立块的直接操作行；创建/行内不调用。
  /// 锁、链接与插入条件沿用公共块操作；删除由固定底部操作区提供。
  List<Widget> _blockActions() {
    final session = _session!;
    final node = session.target;
    final active = session.current && !_saving && !_choosing;
    final mutable = active && session.writable && !_conflict;
    return [
      const Divider(height: 16),
      if (session.locks != null && session.locks!.userId.isNotEmpty)
        CollabSwitchRow(
          key: const ValueKey('formula-lock'),
          leading: const Icon(LucideIcons.lockKeyhole),
          title: const Text('锁定内容块'),
          subtitle: Text(
            session.lock.locked
                ? !session.lock.explicit
                      ? '由上级内容块锁定'
                      : session.lock.template
                      ? '模板内容已锁定'
                      : '解锁后可以编辑'
                : '锁定后保护此块',
          ),
          value: session.lock.locked,
          onChanged: active && !_conflict && session.canToggle
              ? (_) async {
                  await _chooseAction(_FormulaAction.toggle);
                }
              : null,
        ),
      if (session.lock.locked && !session.lock.explicit)
        CollabMenuRow(
          key: const ValueKey('formula-locate-lock'),
          leading: const Icon(LucideIcons.cornerUpLeft),
          title: const Text('定位上级锁定块'),
          onTap: active
              ? () async {
                  await _chooseAction(_FormulaAction.locate);
                }
              : null,
        ),
      if (node != null && session.links?.supports(node) == true)
        CollabMenuRow(
          key: const ValueKey('formula-copy-link'),
          leading: const Icon(LucideIcons.link),
          title: const Text('复制段落链接'),
          onTap: active ? _copyLink : null,
        ),
      if (!session.lock.locked) ...[
        if (node != null &&
            const {'page', 'callout'}.contains(node.parent?.type))
          CollabMenuRow(
            key: const ValueKey('formula-insert-below'),
            leading: const Icon(LucideIcons.listEnd),
            title: const Text('在下方插入'),
            onTap: mutable
                ? () async {
                    await _chooseAction(_FormulaAction.insert);
                  }
                : null,
          ),
      ],
    ];
  }

  /// 在借用 [context] 中显示独立滚动的公式草稿/预览，操作区始终可达。
  /// 删除图标与文字固定在左下；保存期间禁止关闭，失效、冲突和长度限制保持原有提交门禁。
  @override
  Widget build(BuildContext context) {
    final tooLong = _input.text.length > collabFormulaMaxLength;
    final colors = CollabModalColors.of(context);
    return CollabBottomSheet(
      key: const ValueKey('collab-formula-sheet'),
      title: Text(
        _session != null
            ? '编辑公式'
            : widget.inlineTarget != null
            ? '行内公式'
            : widget.creatingBlock
            ? '新建公式'
            : '数学公式',
      ),
      subtitle: '编辑 LaTeX，实时预览',
      icon: LucideIcons.sigma,
      canClose: !_saving && !_choosing,
      closeKey: const ValueKey('formula-close'),
      leadingAction: _editing && _session?.lock.locked != true
          ? TextButton.icon(
              key: const ValueKey('formula-delete'),
              style: TextButton.styleFrom(foregroundColor: colors.danger),
              onPressed: _enabled && !_conflict && (_session?.writable ?? true)
                  ? _delete
                  : null,
              icon: const Icon(LucideIcons.trash2),
              label: const Text('删除公式'),
            )
          : null,
      actions: [
        TextButton(
          onPressed: _saving || _choosing ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        if (_session?.lock.locked != true)
          FilledButton(
            key: const ValueKey('formula-save'),
            onPressed: _enabled && !_conflict && !tooLong ? _save : null,
            child: Text(
              _saving
                  ? '保存中…'
                  : widget.creatingBlock
                  ? '创建'
                  : '保存',
            ),
          ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CollabModalField(
            label: 'LaTeX 源码',
            child: TextField(
              key: const ValueKey('formula-input'),
              controller: _input,
              enabled: _enabled,
              minLines: _session != null || widget.creatingBlock ? 2 : 3,
              maxLines: 6,
              autocorrect: false,
              enableSuggestions: false,
              keyboardType: TextInputType.multiline,
              decoration: const InputDecoration(hintText: r'\frac{a}{b}'),
            ),
          ),
          const Text(
            '公式预览',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 10),
          Container(
            padding: EdgeInsets.all(
              _session != null || widget.creatingBlock ? 8 : 25,
            ),
            decoration: BoxDecoration(
              color: colors.field,
              borderRadius: BorderRadius.circular(10),
            ),
            child: CollabFormulaVisual(latex: _input.text),
          ),
          const SizedBox(height: 12),
          if (_session != null) ..._blockActions(),
          if (tooLong)
            Text('公式不能超过 20000 个字符', style: TextStyle(color: colors.danger)),
          if (!_enabledAfterSave)
            Text(
              widget.inlineTarget == null
                  ? '公式已删除或当前不可编辑'
                  : '公式已删除、位置变化或当前不可编辑',
            ),
          if (_session != null && !_session!.current)
            const Text('锁状态或权限已更新，请关闭后重新打开'),
          if (_conflict) ...[
            const Text('公式已由其他设备修改，请重新加载后编辑'),
            TextButton(
              key: const ValueKey('formula-reload'),
              onPressed: _saving ? null : () => setState(_load),
              child: const Text('重新加载'),
            ),
          ],
          if (_error != null)
            Text(_error!, style: TextStyle(color: colors.danger)),
        ],
      ),
    );
  }
}

/// 独立公式面板退出后执行的命令；复制链接在面板内完成。
enum _FormulaAction {
  /// 开启或关闭授权的显式锁。
  toggle,

  /// 创建紧随公式的空段落。
  insert,

  /// 删除公式，末块时补空段落。
  delete,

  /// 滚动到继承锁来源。
  locate,
}

/// 面板结果，原文与块命令互斥；不持有节点或编辑器资源。
class _FormulaResult {
  /// [latex]为保存原文；[action]与[snapshot]共同记录退场后命令及其目标属性快照。
  const _FormulaResult({this.latex, this.action, this.snapshot});

  /// 保存的原文；取消及块命令为null。
  final String? latex;

  /// 退场后命令，保存时为null。
  final _FormulaAction? action;

  /// 选择命令时的JSON属性快照，拒绝动画期间的远端变更。
  final String? snapshot;
}

/// 单次独立块面板的身份/权限租约；展示入口创建并释放，不持有原生连接。
class _FormulaSession extends ChangeNotifier {
  /// 借用[editor]与稳定[id]；捕获锁服务、链接绑定、宿主和权限代次，成对注册监听。
  _FormulaSession(this.editor, this.id)
    : locks = CollabBlockLocks.of(editor),
      links = CollabParagraphLinks.of(editor),
      _services = CollabRuntime.services,
      _editable = editor.editable {
    lock = locks?.state(id) ?? CollabBlockLockState(blockId: id);
    _epoch = locks?.epoch(id);
    editor.editableNotifier.addListener(_track);
    locks?.addListener(_track);
  }

  /// 借用编辑器，必须晚于本会话释放。
  final EditorState editor;

  /// 原始独立公式稳定身份。
  final String id;

  /// 打开时借用的块锁管理器，可能未配置。
  final CollabBlockLocks? locks;

  /// 打开时借用的正式文档链接绑定，可能未配置。
  final CollabParagraphLinks? links;

  /// 打开时权限状态；命令执行使用此expected状态。
  late final CollabBlockLockState lock;

  /// 打开时锁代次，锁后解锁也不能恢复旧面板。
  late final int? _epoch;

  /// 宿主服务身份，不接管其生命周期。
  final CollabHostServices _services;

  /// 打开时文档权限，任何切换均使旧会话失效。
  final bool _editable;

  /// 本会话自身是否已释放或观察到权限切换。
  bool _invalid = false;

  /// 已选择的命令，用于控制退出后的焦点恢复。
  _FormulaAction? action;

  /// 下方插入后的稳定段落身份，供关闭后恢复输入。
  String? insertedId;

  /// 当前仍存在的公式；读取不保存会随协同重排失效的Node引用。
  Node? get target => findCollabFormula(editor, id);

  /// 宿主服务仍是打开时对象。
  bool get sameHost => identical(CollabRuntime.services, _services);

  /// 当前目标属性JSON，命令退出后验证它未变化。
  String? get snapshot =>
      target == null ? null : jsonEncode(target!.attributes);

  /// 权限/宿主/绑定及稳定目标仍有效；失效不因权限恢复而复活。
  bool get current =>
      !_invalid &&
      !editor.isDisposed &&
      editor.editable == _editable &&
      sameHost &&
      identical(CollabBlockLocks.of(editor), locks) &&
      identical(CollabParagraphLinks.of(editor), links) &&
      locks?.epoch(id) == _epoch &&
      target != null;

  /// 当前目标可写且没有受保护子树。
  bool get writable =>
      current &&
      target != null &&
      canEditCollabNode(editor, target!) &&
      !lock.containsLock;

  /// 当前账号可执行显式锁命令；继承锁仍须定位父块。
  bool get canToggle => current && (locks?.canToggle(id) ?? false);

  /// 观察正文树变化；原目标删除后即使同身份重建也不恢复旧面板的写入权限。
  void observeTarget() {
    if (target == null) _invalid = true;
  }

  /// 观察权限切换并永久失效，通知借用此会话的面板刷新。
  void _track() {
    if (editor.isDisposed ||
        editor.editable != _editable ||
        locks?.epoch(id) != _epoch) {
      _invalid = true;
    }
    notifyListeners();
  }

  /// 等待面板完整退场后在借用[context]执行[command]。
  /// [expectedSnapshot]记录选中时的属性；迟到、换源或权限变化拒绝，事务/平台错误透传到入口。
  Future<void> execute(
    BuildContext context,
    _FormulaAction command,
    String expectedSnapshot,
  ) async {
    if (!context.mounted || !current || snapshot != expectedSnapshot) {
      if (context.mounted) {
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(const SnackBar(content: Text('内容或权限已更新，请重新打开')));
      }
      return;
    }
    final node = target!;
    action = command;
    switch (command) {
      case _FormulaAction.toggle:
        if (canToggle) await locks!.commit(id, !lock.explicit, lock);
      case _FormulaAction.insert:
        if (!writable) return;
        final paragraph = await insertCollabParagraphBelow(editor, node);
        insertedId = paragraph == null
            ? null
            : CollabBlockLocks.idOf(paragraph);
      case _FormulaAction.delete:
        if (!writable) return;
        final transaction = editor.transaction..deleteNode(node);
        if (node.parent!.children.length == 1) {
          transaction.insertNode(node.path, paragraphNode());
        }
        if (editor.undoManager.undoStack.isNonEmpty) {
          editor.undoManager.undoStack.last.seal();
        }
        await editor.apply(
          transaction,
          withUpdateSelection: false,
          skipHistoryDebounce: true,
        );
      case _FormulaAction.locate:
        final ancestor = lock.sourceId == null
            ? null
            : findCollabActionNode(editor, lock.sourceId!);
        final anchor = ancestor?.key.currentContext;
        if (anchor != null && anchor.mounted) {
          await Scrollable.ensureVisible(
            anchor,
            duration: const Duration(milliseconds: 250),
          );
        }
    }
  }

  /// 注销自有监听并终止会话；不释放借用编辑器、锁管理器或宿主。
  @override
  void dispose() {
    _invalid = true;
    editor.editableNotifier.removeListener(_track);
    locks?.removeListener(_track);
    super.dispose();
  }
}
