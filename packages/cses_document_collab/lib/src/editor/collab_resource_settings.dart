import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart' show csesEmbedUrlAttribute;
import 'package:cses_document_collab/src/model/collab_resource.dart';
import 'package:flutter/material.dart';

/// 为借用[context]中的资源[node]打开设置，等待弹窗完全退场。
/// [editor]由调用方持有，[label]为具体块的显示名称；节点和属性只取快照。
/// 字段控制器随弹窗创建/释放，关闭的宿主或只读编辑器不创建新弹窗；
/// 保存仍按稳定身份、类型和修改字段逐项拒绝过期数据，异步错误由调用方菜单处理。
Future<void> showCollabResourceSettings(
  BuildContext context, {
  required EditorState editor,
  required Node node,
  required String label,
}) async {
  if (!context.mounted || editor.isDisposed || !editor.editable) return;
  final route = DialogRoute<void>(
    context: context,
    builder: (_) => _ResourceSettings(
      editor: editor,
      id: node.attributes['cses_collab_block_id'] as String? ?? node.id,
      kind: node.type,
      url: node.attributes[csesEmbedUrlAttribute] as String? ?? '',
      props: CollabResource.fromAttributes(node.attributes),
      label: label,
    ),
  );
  await Navigator.of(context).push(route);
  await route.completed;
}

/// 共用资源设置视图；只借用编辑器与属性快照，字段控制器由其State持有。
class _ResourceSettings extends StatefulWidget {
  /// [editor]为借用编辑器，[id]为稳定块身份，[kind]为原资源类型；
  /// [url]及[props]用于检查保存时的远端冲突，[label]为弹窗显示名称。
  const _ResourceSettings({
    required this.label,
    required this.editor,
    required this.id,
    required this.kind,
    required this.url,
    required this.props,
  });

  /// 借用编辑器，由页面持有并释放。
  final EditorState editor;

  /// 必填稳定协同块身份，重排后仍定位同一块。
  final String id;

  /// 必填资源类型，保存时拒绝类型变化的目标。
  final String kind;

  /// 打开时的原地址快照，用于拒绝覆盖远端换链。
  final String url;

  /// 原属性快照，不拥有共享数据。
  final CollabResource props;

  /// 具体块提供的显示名称，不参与共享存储。
  final String label;

  /// 创建字段控制器的资源所有者，关闭视图时释放。
  @override
  createState() => _ResourceSettingsState();
}

/// Owns settings fields and serializes explicit, conflict-checked property edits.
class _ResourceSettingsState extends State<_ResourceSettings> {
  /// 由此State创建和释放的各设置字段。
  late final Map<String, TextEditingController> _fields;

  /// 当前校验或保存失败提示，null表示没有错误。
  String? _error;

  /// 保存期间禁止重复提交或取消。
  bool _saving = false;

  /// Creates owned text controllers from the borrowed settings snapshot.
  /// Embed width/aspect ratio can be edited; bookmarks use natural content height.
  @override
  void initState() {
    super.initState();
    _fields = {
      'url': TextEditingController(text: widget.url),
      if ({'attachment', 'audio'}.contains(widget.kind))
        'name': TextEditingController(text: widget.props.string('name')),
      if (widget.kind == 'bookmark') ...{
        'title': TextEditingController(text: widget.props.string('title')),
        'description': TextEditingController(text: widget.props.string('description')),
      },
      if ({'embed', 'figma-embed', 'juejin-embed'}.contains(widget.kind)) ...{
        'wr': TextEditingController(text: (widget.props.number('wr') ?? 100).toString()),
        'ar': TextEditingController(text: (widget.props.number('ar') ?? 16 / 9).toStringAsFixed(3)),
      },
    };
  }

  /// 同步释放本弹窗创建的所有输入控制器，不关闭借用编辑器。
  @override
  void dispose() {
    for (final c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// Validates URL, width and aspect ratio, then applies changed fields by block ID.
  /// Completes after property transactions and closes the dialog on success;
  /// conflicting remote edits or failures keep the dialog open with feedback.
  /// Does not mutate a disposed/read-only editor or overwrite unrelated fields.
  Future<void> _save() async {
    final url = _fields['url']!.text.trim();
    if (!isCollabResourceUrl(widget.kind, url)) {
      setState(
        () => _error = widget.kind == 'figma-embed'
            ? '请输入 Figma 链接'
            : widget.kind == 'juejin-embed'
            ? '请输入掘金链接'
            : '请输入完整的 HTTP(S) 地址',
      );
      return;
    }
    final changes = <String, Object?>{};
    for (final entry in _fields.entries) {
      final text = entry.value.text.trim();
      if (entry.key == 'url') {
        if (text != widget.url) changes['url'] = text;
        continue;
      }
      if (entry.key == 'wr' || entry.key == 'ar') {
        final initial = entry.key == 'wr'
            ? (widget.props.number('wr') ?? 100).toString()
            : (widget.props.number('ar') ?? 16 / 9).toStringAsFixed(3);
        if (text == initial) continue;
        final number = double.tryParse(text);
        if (number == null || !number.isFinite || number <= 0 || (entry.key == 'wr' && (number < 1 || number > 100))) {
          setState(() => _error = '宽度应为 1–100，宽高比应为正数');
          return;
        }
        changes[entry.key] = number;
      } else if (text != widget.props.string(entry.key)) {
        changes[entry.key] = text.isEmpty ? null : text;
      }
    }
    if (widget.editor.isDisposed || !widget.editor.editable) return;

    /// 在借用子树[n]中按稳定身份与原类型查找目标。
    Node? find(Node n) {
      if ((n.attributes['cses_collab_block_id'] ?? n.id) == widget.id && n.type == widget.kind) {
        return n;
      }
      for (final c in n.children) {
        final v = find(c);
        if (v != null) return v;
      }
      return null;
    }

    final node = find(widget.editor.document.root);
    if (node == null) {
      if (mounted) Navigator.pop(context);
      return;
    }
    final latest = CollabResource.fromAttributes(node.attributes);
    if (changes.keys.any(
      (key) => key == 'url' ? node.attributes['url'] != widget.url : latest.field(key) != widget.props.field(key),
    )) {
      setState(() => _error = '内容已被更新，请重新打开设置');
      return;
    }
    setState(() => _saving = true);
    try {
      for (final entry in changes.entries) {
        await changeCollabResourceProperty(widget.editor, widget.id, entry.key, entry.value);
      }
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = '保存失败，请重试';
          _saving = false;
        });
      }
    }
  }

  /// 在借用[context]中显示原字段和校验信息；保存完成后才关闭弹窗。
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('修改${widget.label}'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final entry in _fields.entries)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: TextField(
                key: ValueKey('resource-field-${entry.key}'),
                controller: entry.value,
                maxLines: entry.key == 'description' ? 3 : 1,
                decoration: InputDecoration(
                  labelText: switch (entry.key) {
                    'url' => '资源链接',
                    'name' => '名称',
                    'title' => '标题',
                    'description' => '摘要',
                    'wr' => '宽度（%）',
                    _ => '宽高比',
                  },
                ),
              ),
            ),
          if (_error != null) Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 12)),
        ],
      ),
    ),
    actions: [
      TextButton(onPressed: _saving ? null : () => Navigator.pop(context), child: const Text('取消')),
      FilledButton(onPressed: _saving ? null : _save, child: const Text('保存')),
    ],
  );
}
