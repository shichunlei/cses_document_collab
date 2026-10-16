import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/collab_formula_sheet.dart';
import 'package:cses_document_collab/src/editor/editor_shortcut_toolbar.dart';
import 'package:cses_document_collab/src/model/collab_inline_formula.dart';
import 'package:cses_document_collab/src/model/collab_text_range.dart';
import 'package:cses_document_collab/src/native/collab_runtime.dart';
import 'package:flutter/material.dart';

/// 在借用 [context]/[editor] 中编辑单段文字链接；取消不写入。
/// 仅修改 href，保留原文和其他格式；弹窗完整退场后重新核对稳定身份、原文及权限。
/// 错误由此边界报告，失败保留原文并显示提示，不拥有编辑器。
Future<void> showEditorTextLink(
  BuildContext context,
  EditorState editor,
) async {
  final range = CollabTextRange.capture(editor);
  if (!editor.editable || range == null || !range.canConvert) return;
  final selection = range.resolve(editor)!;
  final node = editor.getNodeAtPath(selection.start.path)!;
  final selected = node.delta!.slice(
    selection.start.offset,
    selection.end.offset,
  );
  final links = selected
      .map((op) => op.attributes?[AppFlowyRichTextKeys.href])
      .toList();
  final initial =
      links.every((link) => link == links.first) && links.first is String
      ? links.first as String
      : '';
  try {
    await runEditorHeaderAction<void>(context, editor, () async {
      ModalRoute<String>? route;
      final result = await showDialog<String>(
        context: context,
        builder: (dialogContext) {
          route = ModalRoute.of<String>(dialogContext);
          return _TextLinkDialog(
            initial: initial,
            canRemove: links.any((link) => link is String),
          );
        },
      );
      await route?.completed;
      if (result == null ||
          !context.mounted ||
          editor.isDisposed ||
          !editor.editable) {
        return;
      }
      final current = range.resolve(editor);
      if (current == null) {
        _selectionMessage(context, '选中文字已变化，请重新选择');
        return;
      }
      if (editor.undoManager.undoStack.isNonEmpty) {
        editor.undoManager.undoStack.last.seal();
      }
      final target = editor.getNodeAtPath(current.start.path)!;
      await editor.apply(
        editor.transaction..formatText(
          target,
          current.start.offset,
          current.end.offset - current.start.offset,
          {AppFlowyRichTextKeys.href: result.isEmpty ? null : result},
        ),
        withUpdateSelection: false,
        skipHistoryDebounce: true,
      );
    });
  } catch (error, stack) {
    CollabDiagnostics.report(
      '文字链接修改失败',
      error: error,
      stackTrace: stack,
      tag: 'DocCollab',
    );
    if (context.mounted) _selectionMessage(context, '链接修改失败，请重试');
  }
}

/// 在借用 [context]/[editor] 中预填选中文字并预览 LaTeX，确认后复用行内公式原子命令。
/// 仅支持单段非空普通文字；取消、权限撤销及原文或格式变化均不替换。
/// 成功作为独立历史项，撤销恢复原文字及格式；面板退场后恢复公式后的光标。
Future<void> showEditorSelectionFormula(
  BuildContext context,
  EditorState editor,
) async {
  final range = CollabTextRange.capture(editor);
  if (!editor.editable || range == null || !range.canConvert) return;
  Selection? landing;
  try {
    await runEditorHeaderAction<void>(context, editor, () async {
      final latex = await showCollabFormulaInput(
        context,
        editor,
        initialLatex: range.text,
      );
      if (latex == null ||
          !context.mounted ||
          editor.isDisposed ||
          !editor.editable) {
        return;
      }
      final current = range.resolve(editor);
      if (current == null) {
        _selectionMessage(context, '选中文字已变化，请重新选择');
        return;
      }
      landing = await insertCollabInlineFormula(editor, current, latex);
      if (landing == null && context.mounted) {
        _selectionMessage(context, '此处无法转换为行内公式');
      }
    }, selectionAfterAction: () => landing);
  } catch (error, stack) {
    CollabDiagnostics.report(
      '选中文字转换公式失败',
      error: error,
      stackTrace: stack,
      tag: 'DocCollab',
    );
    if (context.mounted) _selectionMessage(context, '转换失败，请重试');
  }
}

/// 在借用 [context] 中提示可重试的选区错误，[message] 为面向用户的原因。
void _selectionMessage(BuildContext context, String message) {
  ScaffoldMessenger.maybeOf(
    context,
  )?.showSnackBar(SnackBar(content: Text(message)));
}

/// 文字链接输入框，拥有输入控制器；返回空字符串表示移除链接，null 表示取消。
class _TextLinkDialog extends StatefulWidget {
  /// [initial] 为共同链接或空字符串，[canRemove] 表示选区至少包含一个链接。
  const _TextLinkDialog({required this.initial, required this.canRemove});

  /// 初始共同链接；空值显示地址提示，不代表移除。
  final String initial;

  /// 是否显示移除入口；混合选区只要有链接就允许清除。
  final bool canRemove;

  /// 创建本弹窗持有的输入状态。
  @override
  State<_TextLinkDialog> createState() => _TextLinkDialogState();
}

/// 持有链接输入和错误提示，不直接修改正文。
class _TextLinkDialogState extends State<_TextLinkDialog> {
  late final TextEditingController _input;
  String? _error;

  /// 复制初始链接，输入控制器由本状态释放。
  @override
  void initState() {
    super.initState();
    _input = TextEditingController(text: widget.initial);
  }

  /// 释放弹窗创建的输入资源。
  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  /// 校验显式协议，禁止脚本或不完整地址；合法结果只返回调用方，尚不写正文。
  void _confirm() {
    final value = _input.text.trim();
    final uri = Uri.tryParse(value);
    final valid =
        value.length <= 4096 &&
        !RegExp(r'\s').hasMatch(value) &&
        uri != null &&
        ((const {'http', 'https'}.contains(uri.scheme) &&
                uri.host.isNotEmpty) ||
            (const {'mailto', 'tel'}.contains(uri.scheme) &&
                uri.path.isNotEmpty));
    if (!valid) {
      setState(() => _error = '请输入完整的 http(s)、mailto 或 tel 链接');
      return;
    }
    Navigator.pop(context, value);
  }

  /// 在借用 [context] 中展示输入和显式移除动作，取消不产生结果。
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('文字链接'),
    content: TextField(
      key: const ValueKey('editor-text-link-input'),
      controller: _input,
      autofocus: true,
      keyboardType: TextInputType.url,
      decoration: InputDecoration(
        hintText: 'https://example.com',
        errorText: _error,
      ),
      onSubmitted: (_) => _confirm(),
    ),
    actions: [
      if (widget.canRemove)
        TextButton(
          key: const ValueKey('editor-text-link-remove'),
          onPressed: () => Navigator.pop(context, ''),
          child: const Text('移除链接'),
        ),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        key: const ValueKey('editor-text-link-save'),
        onPressed: _confirm,
        child: const Text('保存'),
      ),
    ],
  );
}
