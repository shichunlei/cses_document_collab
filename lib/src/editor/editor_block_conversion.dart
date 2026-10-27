import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart'
    show csesBlockBackgroundColorAttribute;

/// 读取借用[node]在原位类型转换中应保留的身份、元数据和外观属性。
/// [preservedAttributes]指定宿主额外业务键，默认空；返回独立Map，不改变节点或资源所有权。
/// 不复制文字、列表状态或段落样式，目标转换器须按其类型显式设置这些字段。
///
/// ```dart
/// import 'package:appflowy_editor/appflowy_editor.dart';
/// import 'package:cses_document_collab/src/editor/editor_block_conversion.dart';
/// final source = paragraphNode(attributes: {'entry': 'demo'});
/// final attrs = preservedEditorBlockAttributes(source, preservedAttributes: {'entry'});
/// final replacement = paragraphNode(attributes: attrs);
/// // 通过所属EditorState的事务插入replacement，不直接改树。
/// ```
Attributes preservedEditorBlockAttributes(Node node, {Set<String> preservedAttributes = const {}}) {
  final attributes = node.attributes;
  return {
    for (final key in {
      ...preservedAttributes,
      ...attributes.keys.where(
        (key) =>
            key == 'bc.id' ||
            key == 'bc.flavour' ||
            key == 'bc.nodeType' ||
            key.startsWith('bc.p:') ||
            key.startsWith('bc.m:') ||
            key.startsWith('bc.x:'),
      ),
      'cses_collab_block_id',
      csesBlockBackgroundColorAttribute,
      blockComponentBackgroundColor,
      blockComponentTextDirection,
    })
      if (attributes[key] != null) key: attributes[key],
  };
}
