import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/markdown_import.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/model/collab_code.dart';
import 'package:flutter_test/flutter_test.dart';

/// 将 [source] 解码为节点，以检查最终投影使用的属性而非临时 AST。
List<Node> parse(String source) => decodeMarkdownImport(
  source,
).map((json) => Node.fromJson(Map<String, Object>.from(json))).toList();

/// 覆盖导入的正文格式、结构降级和内容保留边界。
void main() {
  test('headings, rich text, links, code and divider survive', () {
    final nodes = parse(
      '\uFEFF# 标题\n\n**粗体** [链接](https://example.com)\n\n```dart\nvoid main() {}\n```\n\n---',
    );
    expect(nodes[0].type, 'heading');
    expect(nodes[0].attributes['level'], 1);
    expect(
      nodes[1].delta!.toJson(),
      contains(containsPair('attributes', containsPair('bold', true))),
    );
    expect(
      nodes[1].delta!.toJson(),
      contains(
        containsPair('attributes', containsPair('href', 'https://example.com')),
      ),
    );
    expect(nodes[2].type, 'code');
    expect(nodes[2].delta!.toPlainText(), 'void main() {}');
    expect(CollabCode.fromAttributes(nodes[2].attributes).language, 'Dart');
    expect(nodes[3].type, 'divider');
    expect(nodes.last.type, 'paragraph');
  });
  test('nested lists and tasks use flat mobile depth', () {
    final nodes = parse('- parent\n  - child\n- [x] done\n\n3. third');
    expect(nodes.take(4).map((e) => e.type), [
      'bulleted_list',
      'bulleted_list',
      'todo_list',
      'numbered_list',
    ]);
    expect(nodes[1].attributes[csesBlockIndentAttribute], 1);
    expect(nodes[2].attributes['checked'], true);
    expect(nodes[3].attributes['number'], 3);
  });
  test('tables preserve rows and images preserve source without file access', () {
    final nodes = parse(
      '| A | B |\n| - | - |\n| C | **D** |\n\n![本地图片](./local.png)\n\n> first\n>\n> second',
    );
    expect(nodes.map((e) => e.delta?.toPlainText()).toList(), [
      'A | B',
      'C | D',
      '![本地图片](./local.png)',
      'first',
      'second',
      '',
    ]);
  });
  test('empty file fails without creating an import', () {
    expect(() => parse('\uFEFF \n'), throwsFormatException);
  });
}
