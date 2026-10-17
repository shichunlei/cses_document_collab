/// 桌面 Mermaid 的三种共享视图；枚举值对应 props.mode。
enum CollabMermaidView {
  /// 只显示源码。
  text('text', '仅文本'),

  /// 只显示图形。
  graph('graph', '仅预览'),

  /// 同时显示源码和图形。
  both('default', '文本与预览');

  /// [value] 是桌面持久字段，[label] 是菜单文案。
  const CollabMermaidView(this.value, this.label);

  /// 桌面共享属性的原始字符串。
  final String value;

  /// 手机和桌面一致的菜单名称。
  final String label;

  /// 解析 [value]；缺失或未知值只在展示时回落为组合视图，不改写原字段。
  static CollabMermaidView parse(Object? value) =>
      values.where((item) => item.value == value).firstOrNull ?? both;
}

/// 随桌面发布的源码示例；仅保存纯文本，不持有编辑器。
///
/// ```dart
/// import 'package:cses_document_collab/src/model/collab_mermaid_options.dart';
/// final source = collabMermaidExamples.first.source;
/// ```
class CollabMermaidExample {
  /// [id] 是稳定菜单标识，[label] 是类型名，[prefix] 是语法首行，
  /// [body] 是桌面原始示例正文；均为不可变字符串。
  const CollabMermaidExample(this.id, this.label, this.prefix, this.body);

  /// 测试与菜单使用的稳定标识。
  final String id;

  /// 用户可见的图表类型名称。
  final String label;

  /// 类型操作插入的语法前缀，包含结尾换行。
  final String prefix;

  /// 模板正文，保留桌面的缩进与换行。
  final String body;

  /// 完整模板源码。
  String get source => prefix + body;
}

/// 与 @ccc/blockcraft 0.11.17/0.11.21 发布产物一致的五类模板。
const collabMermaidExamples = [
  CollabMermaidExample(
    'sequence',
    '时序图',
    'sequenceDiagram\n',
    '\tAlice->>John: Hello John, how are you?\n'
        '\tJohn-->>Alice: Great!\n'
        '\tAlice-)John: See you later!\n',
  ),
  CollabMermaidExample(
    'flowchart',
    '流程图',
    'flowchart LR\n',
    '\tA[Start] --> B{Is it?}\n'
        '\tB -- Yes --> C[OK]\n'
        '\tC --> D[Rethink]\n'
        '\tD --> B\n'
        '\tB -- No ----> E[End]',
  ),
  CollabMermaidExample(
    'class',
    '类图',
    'classDiagram\n',
    '\tclass BankAccount\n'
        '\tBankAccount : +String owner\n'
        '\tBankAccount : +Bigdecimal balance\n'
        '\tBankAccount : +deposit(amount)\n'
        '\tBankAccount : +withdrawal(amount)',
  ),
  CollabMermaidExample(
    'mindmap',
    '思维导图',
    'mindmap\n',
    'Root\n\tA[A]\n\t:::urgent large\n\tB(B)\n\tC',
  ),
  CollabMermaidExample(
    'timeline',
    '时间线图',
    'timeline\n',
    '\ttitle History of Social Media Platform\n'
        '\t2002 : LinkedIn\n'
        '\t2004 : Facebook\n'
        '\t     : Google\n'
        '\t2005 : Youtube\n'
        '\t2006 : Twitter',
  ),
];
