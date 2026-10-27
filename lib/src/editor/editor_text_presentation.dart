import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/collab_paragraph_presentation.dart';
import 'package:cses_document_collab/src/editor/collab_text_alignment.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';

/// 为宿主提供的文字 [builder] 应用 [type] 对应的标题、段落缩进及五种对齐。
/// 返回的包装器借用并配置原 builder，不拥有编辑会话或可释放资源。
/// 同一原 builder 的段落样式只配置一次，建议每个节点类型各持有一个 builder。
/// [listIndentWidth]为列表每级缩进的逻辑像素，默认0由原builder负责；非法值抛ArgumentError。
/// 首次配置后重复调用返回同一包装器，后续不重新应用参数。
/// 配合 `decorateEditorTextSpan` 显示行内样式；业务前缀应包装返回的 builder。
///
/// ```dart
/// import 'package:appflowy_editor/appflowy_editor.dart';
/// import 'package:cses_document_collab/cses_document_collab.dart';
/// final builders = {
///   ParagraphBlockKeys.type: configureEditorTextBlock(
///     ParagraphBlockComponentBuilder(), ParagraphBlockKeys.type),
/// };
/// // 将 builders 交给借用现有 EditorState 的 AppFlowyEditor。
/// ```
BlockComponentBuilder configureEditorTextBlock(
  BlockComponentBuilder builder,
  String type, {
  double listIndentWidth = 0,
}) {
  if (!listIndentWidth.isFinite || listIndentWidth < 0) throw ArgumentError.value(listIndentWidth, 'listIndentWidth');
  final existing = _textBuilders[builder];
  if (existing != null) return existing;
  if (listIndentWidth > 0 &&
      const {BulletedListBlockKeys.type, NumberedListBlockKeys.type, TodoListBlockKeys.type}.contains(type)) {
    final padding = builder.configuration.padding;
    builder.configuration = builder.configuration.copyWith(
      padding: (node) {
        final raw = node.attributes[csesBlockIndentAttribute];
        final depth = raw is int ? raw.clamp(0, 6) : 0;
        final original = padding(node);
        return original.copyWith(left: original.left + depth * listIndentWidth);
      },
    );
  }
  final result = CollabTextAlignmentBuilder(configureCollabParagraphPresentation(builder, type));
  _textBuilders[builder] = result;
  return result;
}

/// 每个借用builder只配置一次，缓存不延长编辑会话资源的生命周期。
final _textBuilders = Expando<BlockComponentBuilder>();
