import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/collab_formula_visual.dart';
import 'package:cses_document_collab/src/editor/editor_shortcut_toolbar.dart';
import 'package:cses_document_collab/src/model/collab_formula.dart';
import 'package:cses_document_collab/src/model/collab_inline_formula.dart';
import 'package:cses_document_collab/src/native/collab_runtime.dart';
import 'package:flutter/material.dart';

/// 打开稳定 [id] 对应公式的编辑面板，借用 [context] 和 [editor]。
/// 隔离正文输入，完整退场后恢复稳定选区；失败上报诊断并显示重试提示。
Future<void> showCollabFormulaEditor(
  BuildContext context,
  EditorState editor,
  String id,
) async {
  if (!editor.editable || findCollabFormula(editor, id) == null) return;
  try {
    await runEditorHeaderAction<void>(context, editor, () async {
      await showCollabFormulaInput(context, editor, id: id);
    });
  } catch (error, stack) {
    CollabDiagnostics.report(
      '公式编辑失败',
      error: error,
      stackTrace: stack,
      tag: 'DocCollab',
    );
    if (context.mounted) {
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(const SnackBar(content: Text('公式编辑失败，请重试')));
    }
  }
}

/// 在借用 [context] 和 [editor] 中输入公式，等待退场动画后返回原文或取消的 null。
/// [id] 非 null 时编辑独立块；[inlineTarget] 非 null 时编辑单字符行内对象，两者互斥。
/// 两者均 null 时只返回插入草稿；既有目标拒绝覆盖远端变化。
/// 调用方须隔离正文输入，并在返回后重新核对权限与插入位置；面板拥有并释放输入控制器。
Future<String?> showCollabFormulaInput(
  BuildContext context,
  EditorState editor, {
  String? id,
  CollabInlineFormulaTarget? inlineTarget,
}) async {
  if (editor.isDisposed ||
      !editor.editable ||
      (id != null && inlineTarget != null)) {
    return null;
  }
  ModalRoute<String>? route;
  final result = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    useRootNavigator: false,
    showDragHandle: true,
    builder: (context) {
      route = ModalRoute.of<String>(context);
      return _FormulaSheet(editor: editor, id: id, inlineTarget: inlineTarget);
    },
  );
  await route?.completed;
  return result;
}

/// 借用编辑器，持有输入、预览及目标变化监听；确认前不写共享数据。
class _FormulaSheet extends StatefulWidget {
  /// [editor] 由页面持有，[id] 为独立块身份，[inlineTarget] 为行内位置，两者均 null 表示插入。
  const _FormulaSheet({required this.editor, this.id, this.inlineTarget});

  /// 必需的借用编辑器，面板不释放其资源。
  final EditorState editor;

  /// 可选的既有块身份，null 时为插入模式。
  final String? id;

  /// 可选的行内原子位置；null 时沿用独立块编辑或插入模式，与 id 互斥。
  final CollabInlineFormulaTarget? inlineTarget;

  /// 创建拥有输入控制器的局部状态。
  @override
  State<_FormulaSheet> createState() => _FormulaSheetState();
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
  String? _error;

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
      !_saving;

  /// 草稿是否基于过期的远端字段，独立于其他扩展属性变化。
  bool get _conflict => _editing && _target != null && _field != _original;

  /// 初始化原文并建立成对的权限/节点/草稿监听。
  @override
  void initState() {
    super.initState();
    _load();
    _input.addListener(_onDraft);
    widget.editor.editableNotifier.addListener(_onTree);
    _syncNodes();
  }

  /// 从当前权威字段重新加载，丢弃局部草稿但不写入共享文档。
  void _load() {
    final node = _target;
    _original = _field;
    _input.text = widget.inlineTarget != null
        ? (_field ?? '')
        : node == null
        ? ''
        : readCollabFormula(node.attributes).string('latex');
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
    _syncNodes();
    setState(() {});
  }

  /// 确认当前原文；创建返回草稿，编辑只提交 latex 单字段并封闭撤销记录。
  Future<void> _save() async {
    if (!_enabled || _conflict || _input.text.length > collabFormulaMaxLength) {
      return;
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
          return;
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
          return;
        }
      }
      if (mounted) Navigator.pop(context, latex);
    } catch (error, stack) {
      CollabDiagnostics.report(
        '保存公式失败',
        error: error,
        stackTrace: stack,
        tag: 'DocCollab',
      );
      if (mounted) setState(() => _error = '保存失败，请重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 保存后再次核对编辑器和目标，忽略本地忙碌标志。
  bool get _enabledAfterSave =>
      !widget.editor.isDisposed &&
      widget.editor.editable &&
      (!_editing || _target != null);

  /// 删除稳定目标：行内只移除一个原子；独立块的根或高亮容器最后一个子块补空段落；事务异常可见且允许重试。
  Future<void> _delete() async {
    if (!_enabled) return;
    final node = _target;
    if (node == null) return;
    setState(() => _saving = true);
    try {
      if (widget.inlineTarget != null) {
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
        return;
      }
      final transaction = widget.editor.transaction..deleteNode(node);
      if (node.parent!.children.length == 1) {
        transaction.insertNode(node.path, paragraphNode());
      }
      if (widget.editor.undoManager.undoStack.isNonEmpty) {
        widget.editor.undoManager.undoStack.last.seal();
      }
      await widget.editor.apply(
        transaction,
        withUpdateSelection: false,
        skipHistoryDebounce: true,
      );
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
    for (final node in _nodes) {
      node.removeListener(_onTree);
    }
    _input.removeListener(_onDraft);
    _input.dispose();
    super.dispose();
  }

  /// 在借用 [context] 中构建适应键盘、窄屏与大字的滚动面板，关闭入口保持可见。
  @override
  Widget build(BuildContext context) {
    final tooLong = _input.text.length > collabFormulaMaxLength;
    return SafeArea(
      child: Padding(
        key: const ValueKey('collab-formula-sheet'),
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * .78,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      widget.inlineTarget == null ? '数学公式' : '行内公式',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('formula-close'),
                    tooltip: '关闭',
                    onPressed: _saving ? null : () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              Flexible(
                child: SingleChildScrollView(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        TextField(
                          key: const ValueKey('formula-input'),
                          controller: _input,
                          enabled: _enabled,
                          minLines: 3,
                          maxLines: 6,
                          autocorrect: false,
                          enableSuggestions: false,
                          keyboardType: TextInputType.multiline,
                          decoration: const InputDecoration(
                            labelText: 'LaTeX',
                            hintText: r'\frac{a}{b}',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 12),
                        const Text('预览'),
                        CollabFormulaVisual(latex: _input.text),
                        if (tooLong)
                          const Text(
                            '公式不能超过 20000 个字符',
                            style: TextStyle(color: Colors.red),
                          ),
                        if (!_enabledAfterSave)
                          Text(
                            widget.inlineTarget == null
                                ? '公式已删除或当前不可编辑'
                                : '公式已删除、位置变化或当前不可编辑',
                          ),
                        if (_conflict) ...[
                          const Text('公式已由其他设备修改，请重新加载后编辑'),
                          TextButton(
                            key: const ValueKey('formula-reload'),
                            onPressed: _saving ? null : () => setState(_load),
                            child: const Text('重新加载'),
                          ),
                        ],
                        if (_error != null)
                          Text(
                            _error!,
                            style: const TextStyle(color: Colors.red),
                          ),
                        FilledButton(
                          key: const ValueKey('formula-save'),
                          onPressed: _enabled && !_conflict && !tooLong
                              ? _save
                              : null,
                          child: Text(_saving ? '保存中…' : '保存'),
                        ),
                        if (_editing)
                          TextButton(
                            key: const ValueKey('formula-delete'),
                            onPressed:
                                _enabled &&
                                    (widget.inlineTarget == null || !_conflict)
                                ? _delete
                                : null,
                            child: const Text('删除公式'),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
