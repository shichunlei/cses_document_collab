import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/collab_mermaid_visual.dart';
import 'package:cses_document_collab/src/editor/editor_shortcut_toolbar.dart';
import 'package:cses_document_collab/src/model/collab_mermaid.dart';
import 'package:cses_document_collab/src/model/collab_mermaid_options.dart';
import 'package:cses_document_collab/src/native/collab_runtime.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 源码面板确认结果；source 为草稿全文，view 为用户选择的共享显示模式。
typedef CollabMermaidDraft = ({String source, CollabMermaidView view});

/// 借用 [context] 和 [editor] 打开稳定 [id] 的源码面板。
/// 暂停正文输入，等待退场后恢复原选区；异常上报并在原页面显示重试提示。
Future<void> showCollabMermaidEditor(
  BuildContext context,
  EditorState editor,
  String id,
) async {
  if (editor.isDisposed || !editor.editable) return;
  try {
    await runEditorHeaderAction<void>(context, editor, () async {
      await showCollabMermaidInput(context, editor, id: id);
    });
  } catch (error, stack) {
    CollabDiagnostics.report(
      '绘图编辑失败',
      error: error,
      stackTrace: stack,
      tag: 'DocCollab',
    );
    if (context.mounted) {
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(const SnackBar(content: Text('绘图编辑失败，请重试')));
    }
  }
}

/// 在借用 [context]/[editor] 中收集草稿；[id] 为 null 时插入，否则编辑已有绘图。
/// 取消返回 null，保存返回源码及共享视图；既有块在退出前提交独立事务，新块由调用方核对落点后插入。
/// 调用方负责暂停正文输入。面板拥有并释放输入控制器及节点监听，Future 等待退场结束。
Future<CollabMermaidDraft?> showCollabMermaidInput(
  BuildContext context,
  EditorState editor, {
  String? id,
}) async {
  if (editor.isDisposed || !editor.editable) return null;
  if (id != null &&
      collabMermaidSource(findCollabMermaid(editor, id)) == null) {
    return null;
  }
  ModalRoute<CollabMermaidDraft>? route;
  final result = await showModalBottomSheet<CollabMermaidDraft>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) {
      route = ModalRoute.of<CollabMermaidDraft>(context);
      return _MermaidSheet(editor: editor, id: id);
    },
  );
  await route?.completed;
  return result;
}

/// 草稿只在确认时写入共享源码；编辑器由页面持有。
class _MermaidSheet extends StatefulWidget {
  /// [editor] 是借用编辑器；[id] 为可选绘图身份，null 表示新建草稿。
  const _MermaidSheet({required this.editor, this.id});

  /// 必需编辑器，面板不得释放。
  final EditorState editor;

  /// 可选既有容器身份；新建时为 null。
  final String? id;

  /// 创建拥有输入控制器和监听的局部状态。
  @override
  State<_MermaidSheet> createState() => _MermaidSheetState();
}

/// 以源码身份和完整 Delta 检测冲突，权限撤销后当前会话永久失效。
class _MermaidSheetState extends State<_MermaidSheet> {
  /// 本面板创建并释放的草稿控制器。
  final _input = TextEditingController();

  /// 成对订阅的借用节点，重排时重新解析。
  final Set<Node> _nodes = {};
  String? _original;

  /// 当前草稿视图；主动选择前保留原始未知 mode，不将显示回落写回。
  CollabMermaidView _view = CollabMermaidView.both;
  bool _viewChanged = false;

  /// 打开时原始 mode wrapper，远端变化后与源码相同地拒绝覆盖。
  String? _originalMode;
  String? _sourceId;
  String? _error;
  bool _saving = false;
  bool _revoked = false;

  /// 当前借用的源码节点；插入模式或目标失效返回 null。
  Node? get _source => widget.id == null
      ? null
      : collabMermaidSource(findCollabMermaid(widget.editor, widget.id!));

  /// 当前源身份、正文或格式与打开时不同，必须重新加载。
  bool get _conflict =>
      widget.id != null &&
      (_source?.id != _sourceId ||
          jsonEncode(_source?.delta?.toJson()) != _original ||
          findCollabMermaid(
                widget.editor,
                widget.id!,
              )?.attributes[collabMermaidModeAttribute] !=
              _originalMode);

  /// 当前会话有效；忙碌和冲突另外控制确认。
  bool get _valid =>
      !widget.editor.isDisposed &&
      widget.editor.editable &&
      !_revoked &&
      (widget.id == null || _source != null);

  /// 加载权威源码并注册权限、文档树与草稿监听。
  @override
  void initState() {
    super.initState();
    _load();
    _input.addListener(_onDraft);
    widget.editor.editableNotifier.addListener(_onTree);
    _syncNodes();
  }

  /// 丢弃本地草稿并重新加载当前权威值，不写共享文档。
  void _load() {
    final source = _source;
    _sourceId = source?.id;
    _original = jsonEncode(source?.delta?.toJson());
    final container = widget.id == null
        ? null
        : findCollabMermaid(widget.editor, widget.id!);
    _originalMode =
        container?.attributes[collabMermaidModeAttribute] as String?;
    _view = container == null
        ? CollabMermaidView.both
        : collabMermaidView(container);
    _viewChanged = false;
    _input.text = source?.delta?.toPlainText() ?? collabMermaidTemplate;
    _error = null;
  }

  /// 监听当前源码及完整祖先链，解除已被远端替换的旧节点。
  void _syncNodes() {
    final next = <Node>{widget.editor.document.root};
    var node = _source;
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

  /// 草稿变更仅刷新本面板，预览自身去抖。
  void _onDraft() {
    if (mounted) setState(() => _error = null);
  }

  /// 权限、删除或远端变化刷新状态；不覆盖未保存草稿。
  void _onTree() {
    if (!mounted) return;
    if (!widget.editor.editable || widget.editor.isDisposed) _revoked = true;
    if (!widget.editor.isDisposed) _syncNodes();
    setState(() {});
  }

  /// 确认有效草稿；编辑前再次按稳定身份与原文拒绝陈旧写入。
  Future<void> _save() async {
    if (!_valid ||
        _conflict ||
        _saving ||
        _input.text.length > collabMermaidMaxLength) {
      return;
    }
    setState(() => _saving = true);
    try {
      final source = _input.text;
      if (widget.id != null) {
        final changed = await changeCollabMermaid(
          widget.editor,
          widget.id!,
          source,
          expectedSourceId: _sourceId!,
          expectedDelta: _original!,
          view: _viewChanged ? _view : null,
          expectedModeField: _originalMode,
        );
        if (!changed && (!_valid || _conflict)) {
          if (mounted) setState(() => _error = '源码已变化，请重新加载');
          return;
        }
      }
      if (mounted) Navigator.pop(context, (source: source, view: _view));
    } catch (error, stack) {
      CollabDiagnostics.report(
        '保存绘图失败',
        error: error,
        stackTrace: stack,
        tag: 'DocCollab',
      );
      if (mounted) setState(() => _error = '保存失败，请重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 将 [example] 前缀插入草稿开头；[replace] 为 true 时替换为完整模板。
  /// 只改本地草稿，超过长度上限或会话失效时不修改。
  void _applyExample(CollabMermaidExample example, {required bool replace}) {
    if (!_valid || _saving || _conflict) return;
    final next = replace ? example.source : example.prefix + _input.text;
    if (next.length > collabMermaidMaxLength) {
      setState(() => _error = '源码超过长度上限，无法插入类型');
      return;
    }
    _input.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(
        offset: replace ? next.length : example.prefix.length,
      ),
    );
  }

  /// 选择本地草稿 [view]；隐藏源码前关闭输入法，保存时与源码原子提交。
  void _selectView(CollabMermaidView view) {
    if (!_valid || _saving || _conflict) return;
    if (view == CollabMermaidView.graph) FocusScope.of(context).unfocus();
    setState(() {
      _view = view;
      _viewChanged = true;
    });
  }

  /// [replace] 区分模板替换与类型前缀插入；菜单选择只影响当前草稿。
  Widget _exampleMenu({required bool replace}) =>
      PopupMenuButton<CollabMermaidExample>(
        key: ValueKey(replace ? 'mermaid-template-menu' : 'mermaid-type-menu'),
        tooltip: replace ? '用模板替换草稿' : '插入类型前缀',
        enabled: _valid && !_saving && !_conflict,
        onSelected: (example) => _applyExample(example, replace: replace),
        itemBuilder: (_) => [
          for (final example in collabMermaidExamples)
            PopupMenuItem(
              key: ValueKey(
                'mermaid-${replace ? 'template' : 'type'}-${example.id}',
              ),
              value: example,
              child: Text(example.label),
            ),
        ],
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(replace ? '模板' : '类型'),
              const Icon(Icons.expand_more, size: 18),
            ],
          ),
        ),
      );

  /// 使用可换行菜单排列五类类型/模板和三种视图，适应窄屏与大字体。
  Widget _buildControls() => Wrap(
    spacing: 4,
    children: [
      _exampleMenu(replace: false),
      _exampleMenu(replace: true),
      PopupMenuButton<CollabMermaidView>(
        key: const ValueKey('mermaid-sheet-view'),
        tooltip: '切换视图',
        enabled: _valid && !_saving && !_conflict,
        initialValue: _view,
        onSelected: _selectView,
        itemBuilder: (_) => [
          for (final view in CollabMermaidView.values)
            PopupMenuItem(value: view, child: Text(view.label)),
        ],
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_view.label),
              const Icon(Icons.expand_more, size: 18),
            ],
          ),
        ),
      ),
    ],
  );

  /// 解除所有借用监听并释放本面板创建的控制器。
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

  /// 在借用 [context] 中按草稿视图显示源码与预览，固定取消/保存按钮适应键盘和窄屏。
  @override
  Widget build(BuildContext context) => SafeArea(
    child: SizedBox(
      height: MediaQuery.sizeOf(context).height * .85,
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          children: [
            const Padding(padding: EdgeInsets.all(8), child: Text('代码绘图')),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildControls(),
                    if (_view != CollabMermaidView.graph)
                      TextField(
                        key: const ValueKey('mermaid-input'),
                        controller: _input,
                        enabled: _valid && !_saving,
                        minLines: 5,
                        maxLines: 12,
                        maxLength: collabMermaidMaxLength,
                        maxLengthEnforcement: MaxLengthEnforcement.none,
                        autocorrect: false,
                        enableSuggestions: false,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 14,
                        ),
                        decoration: const InputDecoration(
                          labelText: 'Mermaid 源码',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    if (_view != CollabMermaidView.text)
                      CollabMermaidVisual(source: _input.text),
                    if (!_valid) const Text('当前不可编辑，请关闭后重新打开'),
                    if (_conflict && _valid)
                      Row(
                        children: [
                          const Expanded(child: Text('源码已被更新，草稿未覆盖远端内容')),
                          TextButton(
                            key: const ValueKey('mermaid-reload'),
                            onPressed: _saving ? null : () => setState(_load),
                            child: const Text('重新加载'),
                          ),
                        ],
                      ),
                    if (_error != null) Text(_error!),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  TextButton(
                    onPressed: _saving ? null : () => Navigator.pop(context),
                    child: const Text('取消'),
                  ),
                  const Spacer(),
                  FilledButton(
                    key: const ValueKey('mermaid-save'),
                    onPressed:
                        _valid &&
                            !_conflict &&
                            !_saving &&
                            _input.text.length <= collabMermaidMaxLength
                        ? _save
                        : null,
                    child: Text(_saving ? '保存中…' : '保存'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
