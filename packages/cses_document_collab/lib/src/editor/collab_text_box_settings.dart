import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/collab_block_locks.dart';
import 'package:cses_document_collab/src/editor/collab_block_actions.dart';
import 'package:cses_document_collab/src/editor/core/editor_command_context.dart';
import 'package:cses_document_collab/src/model/collab_text_box.dart';
import 'package:cses_document_collab/src/ui/modal/collab_bottom_sheet.dart';
import 'package:cses_document_collab/src/ui/modal/collab_modal.dart';
import 'package:cses_document_collab/src/ui/modal/collab_modal_field.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// 为借用 [context]/[editor] 中稳定 [id] 的文本框打开底部外观草稿面板。
/// 应由公共块菜单隔离正文输入后调用；应用一次提交修改字段，取消不写历史。
/// 锁、权限、节点或宿主变化后旧草稿永久失效；函数等待弹窗退场。
Future<void> showCollabTextBoxSettings(BuildContext context, EditorState editor, String id) async {
  final node = findCollabActionNode(editor, id);
  if (!context.mounted || node == null || node.type != collabTextBoxType || !canEditCollabNode(editor, node)) return;
  await showCollabBottomSheet<void>(
    context: context,
    useRootNavigator: false,
    builder: (_) => _TextBoxSettings(editor: editor, node: node, id: id),
  );
}

/// 借用稳定节点、编辑器及其会话；状态拥有监听和未提交的属性草稿。
class _TextBoxSettings extends StatefulWidget {
  /// [editor]由页面释放，[node]为打开时身份，[id]用于重排后定位。
  const _TextBoxSettings({required this.editor, required this.node, required this.id});

  /// 借用的原编辑器，不由设置面板关闭。
  final EditorState editor;

  /// 原节点引用，删除后同ID重建不能复用草稿。
  final Node node;

  /// 原稳定块身份，路径变化不改变此值。
  final String id;

  /// 创建本地草稿及权限监听的所有者。
  @override
  State<_TextBoxSettings> createState() => _TextBoxSettingsState();
}

/// 暂存外观；观察到撤权、锁代次变化或远端属性更新后禁止迟到应用。
class _TextBoxSettingsState extends State<_TextBoxSettings> {
  /// 本面板创建的草稿副本，确认前不回写模型。
  late final Map<String, dynamic> _draft;

  /// 打开时规范化属性串，用于阻止覆盖远端更新。
  late final String _original;

  /// 捕获原宿主和锁服务身份，防止跨文档结果回写。
  late final Object _services;

  /// 打开时借用的锁服务，dispose只解绑监听。
  late final CollabBlockLocks? _locks;

  /// 原块及其祖先锁的版本，变化后不恢复旧会话。
  late final int _epoch;

  /// 已经观察到权限、锁、目标或外部属性失效。
  bool _invalid = false;

  /// 应用期间阻止重复操作与关闭。
  bool _saving = false;

  /// 校验或保存失败的用户提示，null表示无错误。
  String? _error;

  /// 初始化草稿和借用对象监听，不创建网络或原生资源。
  @override
  void initState() {
    super.initState();
    final resource = readCollabTextBox(widget.node.attributes);
    _draft = resource.values;
    _original = resource.properties;
    _services = EditorCommandContext.of(widget.editor).services;
    _locks = CollabBlockLocks.of(widget.editor);
    _epoch = _locks?.epoch(widget.id) ?? 0;
    widget.editor.editableNotifier.addListener(_observe);
    widget.node.addListener(_observe);
    widget.editor.document.root.addListener(_observe);
    _locks?.addListener(_observe);
  }

  /// 同步核对原宿主、节点身份、全部外观快照、权限及锁代次。
  bool get _current =>
      !_invalid &&
      !widget.editor.isDisposed &&
      widget.editor.editable &&
      identical(EditorCommandContext.of(widget.editor).services, _services) &&
      identical(CollabBlockLocks.of(widget.editor), _locks) &&
      identical(findCollabActionNode(widget.editor, widget.id), widget.node) &&
      (_locks?.epoch(widget.id) ?? 0) == _epoch &&
      canEditCollabNode(widget.editor, widget.node) &&
      readCollabTextBox(widget.node.attributes).properties == _original;

  /// 外部变化永久失效；自身同步提交的节点通知不作为远端冲突处理。
  void _observe() {
    if (!mounted || _saving) return;
    if (!_current) _invalid = true;
    setState(() {});
  }

  /// 解绑全部借用监听，不释放编辑器、节点或锁服务。
  @override
  void dispose() {
    widget.editor.editableNotifier.removeListener(_observe);
    widget.node.removeListener(_observe);
    widget.editor.document.root.removeListener(_observe);
    _locks?.removeListener(_observe);
    super.dispose();
  }

  /// 保存当前草稿差异；应用期间不允许重入，失败保留草稿并显示错误。
  Future<void> _apply() async {
    if (!_current || _saving) return;
    final width = num.tryParse('${_draft['width'] ?? 240}');
    final height = num.tryParse('${_draft['height'] ?? 120}');
    if (width == null ||
        height == null ||
        !width.isFinite ||
        !height.isFinite ||
        width < 48 ||
        width > 2000 ||
        height < 32 ||
        height > 2000) {
      setState(() => _error = '宽度需为48～2000，高度需为32～2000');
      return;
    }
    final initial = jsonDecode(_original) as Map;
    final patch = <String, dynamic>{
      for (final e in _draft.entries)
        if (jsonEncode(e.value) != jsonEncode(initial[e.key])) e.key: e.value,
    };
    if (patch.containsKey('height')) {
      patch['textAutoFit'] = 'none';
      patch['textFit'] = null;
    }
    if (initial['lockRatio'] == true && (patch.containsKey('width') || patch.containsKey('height'))) {
      final oldWidth = (initial['width'] as num?) ?? 240;
      final oldHeight = (initial['height'] as num?) ?? 120;
      if ((width / height - oldWidth / oldHeight).abs() > .01) {
        setState(() => _error = '此文本框已锁定宽高比，请按原比例调整宽高');
        return;
      }
    }
    setState(() => _saving = true);
    try {
      if (patch.isNotEmpty) await updateCollabTextBox(widget.editor, widget.id, patch);
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '文本框保存失败，请重试';
        });
      }
    }
  }

  /// 在借用[context]中展示本地草稿；取消、关闭与下滑都不写入共享文档。
  @override
  Widget build(BuildContext context) => CollabBottomSheet(
    title: const Text('文本框设置'),
    icon: LucideIcons.textCursorInput,
    canClose: !_saving,
    actions: [
      TextButton(onPressed: _saving ? null : () => Navigator.pop(context), child: const Text('取消')),
      FilledButton(
        key: const ValueKey('text-box-apply'),
        onPressed: _current && !_saving ? _apply : null,
        child: const Text('应用'),
      ),
    ],
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!_current) const Text('文本框已变化或当前不可编辑，请关闭后重新打开。'),
        if (_error != null) Text(_error!),
        for (final field in [('width', '宽度（逻辑像素）', 240), ('height', '高度（逻辑像素）', 120)])
          CollabModalField(
            label: field.$2,
            child: TextFormField(
              key: ValueKey('text-box-${field.$1}'),
              initialValue: '${_draft[field.$1] ?? field.$3}',
              enabled: _current && !_saving,
              keyboardType: TextInputType.number,
              onChanged: (value) {
                _draft[field.$1] = num.tryParse(value) ?? value;
              },
            ),
          ),
        CollabModalField(
          label: '填充颜色',
          child: Wrap(
            spacing: 8,
            children: [
              for (final option in [('白色', '#FFFFFF'), ('浅黄', '#FFF3C4'), ('透明', 'none')])
                ChoiceChip(
                  label: Text(option.$1),
                  selected: (_draft['fill'] ?? '#FFFFFF') == option.$2,
                  onSelected: _current && !_saving ? (_) => setState(() => _draft['fill'] = option.$2) : null,
                ),
            ],
          ),
        ),
        CollabModalField(
          label: '边框',
          child: Wrap(
            spacing: 8,
            children: [
              for (final option in [('黑色', '1px solid #000000'), ('灰色', '1px solid #94A3B8'), ('无边框', 'none')])
                ChoiceChip(
                  label: Text(option.$1),
                  selected: (_draft['outline'] ?? '1px solid #000000') == option.$2,
                  onSelected: _current && !_saving ? (_) => setState(() => _draft['outline'] = option.$2) : null,
                ),
            ],
          ),
        ),
      ],
    ),
  );
}
