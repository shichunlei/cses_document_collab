import 'package:cses_document_collab/src/model/collab_formula.dart';
import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';

/// 展示独立 LaTeX 公式；空值显示添加提示，解析失败显示原文。
/// 长公式居中并可横向滚动，不写协同数据，也不创建持久资源。
/// ```dart
/// import 'package:cses_document_collab/src/ui/modal/collab_formula_visual.dart';
/// const preview = CollabFormulaVisual(latex: r'\frac{a}{b}');
/// ```
class CollabFormulaVisual extends StatelessWidget {
  /// [key] 控制身份与状态复用，[latex] 为不带外围美元符号的原始表达式。
  const CollabFormulaVisual({super.key, required this.latex});

  /// 必需的公式原文；由调用方持有，不在展示时修剪或改写。
  final String latex;

  /// 在借用 [context] 的宽度内展示公式；超过编辑长度上限时直接回落原文。
  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodyLarge;
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: ConstrainedBox(
            constraints: BoxConstraints(minWidth: constraints.maxWidth),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
              child: latex.isEmpty
                  ? const Text('添加数学公式', textAlign: TextAlign.center)
                  : latex.length > collabFormulaMaxLength
                  ? _fallback()
                  : Align(
                      alignment: Alignment.center,
                      widthFactor: 1,
                      child: Math.tex(
                        latex,
                        mathStyle: MathStyle.display,
                        textStyle: style,
                        onErrorFallback: (_) => _fallback(),
                      ),
                    ),
            ),
          ),
        );
      },
    );
  }

  /// 显示原文和明确的渲染失败提示，不将显示失败视为内容损坏。
  Widget _fallback() => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      const Text('暂无法渲染此公式', style: TextStyle(color: Colors.orange)),
      Text(latex, textAlign: TextAlign.center),
    ],
  );
}
