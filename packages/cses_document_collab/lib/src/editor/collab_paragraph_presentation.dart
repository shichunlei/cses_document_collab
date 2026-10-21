import 'package:cses_document_collab/src/editor/collab_paragraph_text_style.dart';
import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/model/collab_paragraph_style.dart';
import 'package:cses_document_collab/src/editor/collab_paragraph_indent.dart';
import 'package:flutter/material.dart';

/// 每个 builder 仅配置一次，避免多个编辑器重复乘算段落字号。
final _paragraphPresentationBuilders = Expando<BlockComponentBuilder>();

/// 包装借用 [builder] 的文字与缩进配置；[type] 为编辑器节点类型。
/// 普通文本段按桌面depth每级偏移32，标题统一最终字符样式优先级。
/// 返回的 builder 与输入共享配置，不创建监听或可释放资源；宿主仍负责编辑器生命周期。
BlockComponentBuilder configureCollabParagraphPresentation(
  BlockComponentBuilder builder,
  String type,
) {
  final configured = _paragraphPresentationBuilders[builder];
  if (configured != null) return configured;
  final original = builder.configuration.textStyle;
  final originalPadding = builder.configuration.padding;
  final originalPlaceholder = builder.configuration.placeholderTextStyle;
  builder.configuration = builder.configuration.copyWith(
    padding: (node) {
      final padding = originalPadding(node);
      return supportsCollabTextIndent(node)
          ? padding.copyWith(
              left: padding.left + collabParagraphDepth(node) * 32,
            )
          : padding;
    },
    placeholderTextStyle: (node, {textSpan}) => collabParagraphTextStyle(
      node,
      originalPlaceholder(node, textSpan: textSpan),
      paragraphDefaultsToAttributes(
        readCollabParagraph(node).values['textDefaults'],
      ),
    ),
    textStyle: (node, {textSpan}) {
      if (node.delta?.isEmpty != true && textSpan?.children != null) {
        return const TextStyle();
      }
      final attrs = node.delta?.isEmpty == true
          ? paragraphDefaultsToAttributes(
              readCollabParagraph(node).values['textDefaults'],
            )
          : const <String, dynamic>{};
      return collabParagraphTextStyle(
        node,
        original(node, textSpan: textSpan),
        attrs,
      );
    },
  );
  final result = type == HeadingBlockKeys.type
      ? ParagraphBlockComponentBuilder(configuration: builder.configuration)
      : builder;
  _paragraphPresentationBuilders[builder] = result;
  return result;
}
