import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:html/dom.dart' as dom;

class HTMLHeadingNodeParser extends HTMLNodeParser {
  const HTMLHeadingNodeParser();

  @override
  String get id => HeadingBlockKeys.type;

  @override
  String transformNodeToHTMLString(
    Node node, {
    required List<HTMLNodeParser> encodeParsers,
  }) {
    return toHTMLString(
      transformNodeToDomNodes(node, encodeParsers: encodeParsers),
    );
  }

  /// Encodes borrowed [node] into H1–H6 DOM nodes without changing its data.
  /// [encodeParsers] supplies the parsers used for child content.
  /// Stored levels outside the supported range use the nearest boundary.
  @override
  List<dom.Node> transformNodeToDomNodes(
    Node node, {
    required List<HTMLNodeParser> encodeParsers,
  }) {
    final delta = node.delta ?? Delta();
    final convertedNodes = deltaHTMLEncoder.convert(delta);
    convertedNodes.addAll(
      processChildrenNodes(node.children, encodeParsers: encodeParsers),
    );
    final level = (node.attributes[HeadingBlockKeys.level] as int? ?? 1).clamp(
      1,
      6,
    );
    final tagName = 'h$level';
    final element = wrapChildrenNodesWithTagName(
      tagName,
      childNodes: convertedNodes,
    );
    return [element];
  }
}
