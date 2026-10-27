import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/collab_formula_sheet.dart';
import 'package:cses_document_collab/src/editor/core/editor_command_context.dart';
import 'package:cses_document_collab/src/editor/editor_shortcut_toolbar.dart';
import 'package:cses_document_collab/src/model/collab_formula.dart';
import 'package:cses_document_collab/src/model/collab_inline_formula.dart';
import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:provider/provider.dart';

/// 展示正文中的单字符公式；点击隔离正文输入并打开编辑面板。
/// 借用编辑器和节点，不创建连接、控制器或持续监听；预览模式只展示。
/// ```dart
/// import 'package:flutter/material.dart';
/// import 'package:appflowy_editor/appflowy_editor.dart';
/// import 'package:cses_document_collab/src/editor/collab_inline_formula.dart';
/// final node = paragraphNode();
/// final formula = CollabInlineFormula(node: node, offset: 0,
///   latex: r'\frac{x}{2}', style: const TextStyle(fontSize: 16));
/// // 放在已提供 EditorState 的编辑器 WidgetSpan 中。
/// ```
class CollabInlineFormula extends StatelessWidget {
  /// [key] 控制身份与状态复用，[node] 由编辑器持有，[offset] 是对象 UTF-16 位置。
  /// [latex] 是不带外围美元符号的原文，[style] 借用所在段落的字色和字号。
  const CollabInlineFormula({
    super.key,
    required this.node,
    required this.offset,
    required this.latex,
    required this.style,
  });

  /// 所在文字块，必需且由编辑器持有，本组件不释放它。
  final Node node;

  /// 对象的 UTF-16 索引，必需；提交前重新核对块身份和文字位置。
  final int offset;

  /// 必需的原始表达式，展示不修剪、不写回；空值显示 TeX 提示。
  final String latex;

  /// 必需的段落视觉样式，控制公式字号与文字颜色，不应用文字行高。
  final TextStyle style;

  /// 在借用 [context] 中提供一个可滚动的行内数学组件，不扩大到整行宽度。
  @override
  Widget build(BuildContext context) {
    final editor = context.read<EditorState>();
    final id = node.attributes['cses_collab_block_id'] as String? ?? node.id;
    final mathStyle = style.copyWith(height: 1);
    final body = latex.isEmpty
        ? Text('TeX', style: mathStyle)
        : latex.length > collabFormulaMaxLength
        ? Text(latex, style: mathStyle)
        : Math.tex(
            latex,
            mathStyle: MathStyle.text,
            textStyle: mathStyle,
            onErrorFallback: (_) => Tooltip(
              message: '暂无法渲染此公式',
              child: Text(latex, style: mathStyle),
            ),
          );
    return Semantics(
      label: '行内公式 $latex',
      button: editor.editable,
      readOnly: !editor.editable,
      child: ExcludeFocus(
        child: GestureDetector(
          key: ValueKey('collab-inline-formula-$id-$offset'),
          behavior: HitTestBehavior.opaque,
          onTap: editor.editable
              ? () async {
                  final target = CollabInlineFormulaTarget.capture(node, offset);
                  if (target == null) return;
                  try {
                    await runEditorHeaderAction<void>(context, editor, () async {
                      await showCollabFormulaInput(context, editor, inlineTarget: target);
                    });
                  } catch (error, stack) {
                    EditorCommandContext.report(editor, '行内公式编辑失败', error: error, stackTrace: stack, tag: 'DocCollab');
                    if (context.mounted) {
                      ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('公式编辑失败，请重试')));
                    }
                  }
                }
              : null,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: (MediaQuery.sizeOf(context).width - 40).clamp(40, double.infinity)),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Padding(padding: const EdgeInsets.symmetric(horizontal: 2), child: body),
            ),
          ),
        ),
      ),
    );
  }
}
