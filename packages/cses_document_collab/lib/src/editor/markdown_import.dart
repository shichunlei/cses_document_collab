import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/model/collab_code.dart';
import 'package:cses_document_collab/src/model/collab_ordered.dart';
import 'package:cses_document_collab/src/model/collab_code_languages.dart';
import 'package:markdown/markdown.dart' as md;

/// 将 UTF-8 解码后的 [source] 转为可发送至后台 Isolate 的编辑节点 JSON。
/// 列表展开为移动端 depth；表格按行保留文本，HTML 不执行，本地图片保留为链接文本。
/// 空白输入抛出 [FormatException]，不创建空导入事务。
///
/// ```dart
/// import 'package:cses_document_collab/src/editor/markdown_import.dart';
/// final nodes = decodeMarkdownImport('# 文档标题');
/// ```
List<Map<String, dynamic>> decodeMarkdownImport(String source) {
  source = source.replaceFirst(RegExp(r'^\uFEFF'), '');
  if (source.trim().isEmpty) throw const FormatException('Markdown 文件为空');
  final ast = md.Document(
    extensionSet: md.ExtensionSet.gitHubFlavored,
    encodeHtml: false,
  ).parse(source);
  final nodes = <Node>[];
  for (final element in ast) {
    nodes.addAll(_blocks(element));
  }
  if (nodes.isEmpty) throw const FormatException('没有可导入的内容');
  // 为文末媒体或分割线保留可输入位置，与导入内容同属一次撤销。
  nodes.add(paragraphNode());
  return nodes.map((node) => node.toJson()).toList();
}

/// 将 [element] 转为块；[depth] 是列表缩进，[listType] 和 [number] 指定列表上下文。
Iterable<Node> _blocks(
  md.Node element, {
  int depth = 0,
  String? listType,
  int number = 1,
}) sync* {
  if (element is! md.Element) {
    if (element.textContent.trim().isNotEmpty) {
      yield paragraphNode(delta: Delta()..insert(element.textContent));
    }
    return;
  }
  final children = element.children ?? <md.Node>[];
  final tag = element.tag;
  if (tag == 'ul' || tag == 'ol') {
    var index = int.tryParse(element.attributes['start'] ?? '') ?? 1;
    var first = true;
    for (final child in children) {
      final items = _blocks(
        child,
        depth: depth,
        listType: tag,
        number: index++,
      ).toList();
      if (tag == 'ol' && items.isNotEmpty) {
        final start = first ? index - 1 : null;
        final ordered = CollabOrdered(
          order: index - 2,
          start: start,
          numbering: jsonEncode(
            start == null ? <String, dynamic>{} : {'start': start},
          ),
        );
        items.first.updateAttributes({csesOrderedAttribute: ordered.toJson()});
      }
      first = false;
      yield* items;
    }
    return;
  }
  if (tag == 'li') {
    final body = children.where(
      (child) =>
          child is! md.Element || !{'ul', 'ol', 'input'}.contains(child.tag),
    );
    final checkbox = children
        .whereType<md.Element>()
        .where((e) => e.tag == 'input')
        .firstOrNull;
    final delta = _inline(body.toList());
    final node = checkbox != null
        ? todoListNode(
            checked: checkbox.attributes['checked'] == 'true',
            delta: delta,
          )
        : listType == 'ol'
        ? numberedListNode(number: number, delta: delta)
        : bulletedListNode(delta: delta);
    node.updateAttributes({csesBlockIndentAttribute: depth.clamp(0, 6)});
    yield node;
    for (final child in children.whereType<md.Element>().where(
      (e) => e.tag == 'ul' || e.tag == 'ol',
    )) {
      yield* _blocks(child, depth: depth + 1);
    }
    return;
  }
  if (tag == 'pre') {
    final code = children.whereType<md.Element>().firstOrNull;
    final alias = (code?.attributes['class'] ?? '')
        .replaceFirst('language-', '')
        .toLowerCase();
    final language =
        collabCodeLanguages.entries
            .where(
              (e) =>
                  e.value.toLowerCase() == alias ||
                  e.key.toLowerCase() == alias,
            )
            .firstOrNull
            ?.key ??
        'PlainText';
    yield Node(
      type: csesCodeBlockType,
      attributes: {
        'delta':
            (Delta()..insert(
                  element.textContent.replaceFirst(RegExp(r'\n$'), ''),
                ))
                .toJson(),
        collabCodeAttribute: CollabCode(language: language).toJson(),
      },
    );
    return;
  }
  if (tag == 'table' || tag == 'thead' || tag == 'tbody') {
    for (final child in children) {
      yield* _blocks(child);
    }
    return;
  }
  if (tag == 'tr') {
    final delta = Delta();
    for (var i = 0; i < children.length; i++) {
      if (i > 0) delta.insert(' | ');
      for (final op in _inline([children[i]]).toJson()) {
        delta.insert(
          op['insert'] as String,
          attributes: op['attributes'] as Map<String, dynamic>?,
        );
      }
    }
    yield paragraphNode(delta: delta);
    return;
  }
  final image = tag == 'img'
      ? element
      : tag == 'p' &&
            children.length == 1 &&
            children.first is md.Element &&
            (children.first as md.Element).tag == 'img'
      ? children.first as md.Element
      : null;
  final imageUrl = image?.attributes['src'];
  final uri = imageUrl == null ? null : Uri.tryParse(imageUrl);
  if (uri != null &&
      {'http', 'https'}.contains(uri.scheme) &&
      uri.host.isNotEmpty) {
    yield imageNode(url: imageUrl!);
    return;
  }
  if (tag == 'hr') {
    yield dividerNode();
    return;
  }
  if (tag == 'blockquote') {
    // 每段引用单独保留，避免多段引用被拼接而丢失边界。
    for (final child in children) {
      yield quoteNode(delta: _inline([child]));
    }
    return;
  }
  final level = RegExp(r'^h([1-6])$').firstMatch(tag);
  yield level != null
      ? headingNode(level: int.parse(level[1]!), delta: _inline(children))
      : paragraphNode(
          delta: _inline(
            children.isEmpty ? [md.Text(element.textContent)] : children,
          ),
        );
}

/// 解码借用的 [nodes] 为富文本；图片保留地址文字，避免相对文件路径成为不可用的协同资源。
Delta _inline(List<md.Node> nodes) {
  /// 复制借用的 [node]，将行内图片转为含地址的文字，其余格式保留。
  md.Node sanitize(md.Node node) {
    if (node is! md.Element) return node;
    if (node.tag == 'img') {
      return md.Text(
        '![${node.attributes['alt'] ?? ''}](${node.attributes['src'] ?? ''})',
      );
    }
    return md.Element(node.tag, (node.children ?? []).map(sanitize).toList())
      ..attributes.addAll(node.attributes);
  }

  return DeltaMarkdownDecoder().convertNodes(nodes.map(sanitize).toList());
}
