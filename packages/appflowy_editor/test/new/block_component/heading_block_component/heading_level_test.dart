import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter_test/flutter_test.dart';

/// 验证公开标题工厂不能通过扩展属性绕过H1~H6边界。
void main() {
  test(
    'heading attributes retain valid overrides and clamp invalid overrides',
    () {
      for (final level in [0, 1, 6, 7, 8, 9]) {
        final node = headingNode(
          level: 2,
          text: 'Heading',
          attributes: {HeadingBlockKeys.level: level, 'custom': 'keep'},
        );
        expect(node.attributes[HeadingBlockKeys.level], level.clamp(1, 6));
        expect(node.attributes['custom'], 'keep');
        expect(node.delta!.toPlainText(), 'Heading');
      }
    },
  );

  test(
    'HTML and Markdown exports clamp legacy levels without changing stored data',
    () {
      for (final level in [7, 8, 9]) {
        final node = Node(
          type: HeadingBlockKeys.type,
          attributes: {
            HeadingBlockKeys.level: level,
            HeadingBlockKeys.delta: (Delta()..insert('Heading')).toJson(),
          },
        );
        expect(
          const HeadingNodeParser().transform(node, null),
          '###### Heading',
        );
        final html = const HTMLHeadingNodeParser().transformNodeToHTMLString(
          node,
          encodeParsers: [],
        );
        expect(html, '<h6>Heading</h6>');
        expect(node.attributes[HeadingBlockKeys.level], level);
      }
    },
  );
}
