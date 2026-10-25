import 'package:appflowy_editor/appflowy_editor.dart';

class HeadingNodeParser extends NodeParser {
  const HeadingNodeParser();

  @override
  String get id => HeadingBlockKeys.type;

  /// Encodes borrowed [node] as an H1–H6 Markdown heading.
  /// [encoder] is the optional parent encoder; nested text uses the Delta encoder.
  /// Out-of-range stored levels are clamped without changing the node.
  @override
  String transform(Node node, DocumentMarkdownEncoder? encoder) {
    final delta = node.delta ?? Delta()
      ..insert('');
    final markdown = DeltaMarkdownEncoder().convert(delta);
    final attributes = node.attributes;
    final level = (attributes[HeadingBlockKeys.level] as int? ?? 1).clamp(1, 6);
    final result = '${'#' * level} $markdown';
    final suffix = node.next == null ? '' : '\n';

    return '$result$suffix';
  }
}
