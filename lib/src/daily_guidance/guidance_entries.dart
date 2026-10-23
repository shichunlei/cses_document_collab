import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'guidance_people.dart';

/// 今日导向行内引用的本地属性；只随业务草稿保存，不属于桌面协议。
const guidanceMentionAttribute = 'guidance_mention';

/// 今日导向业务行的类别属性，允许task、help、pilot。
const guidanceEntryAttribute = 'guidance_entry';

/// 将[person]转为不携带组织子树的行内引用属性；稳定身份和名称快照一起保存。
Map<String, dynamic> guidanceMentionAttributes(GuidancePerson person) => {
  guidanceMentionAttribute: jsonEncode({
    'id': person.id,
    'name': person.name,
    'type': person.type,
    if (person.department != null) 'department': person.department,
  }),
};

/// 从借用的[attributes]解析已知引用；非法、未知或携带目录子树时抛FormatException。
GuidancePerson readGuidanceMention(Map<String, dynamic> attributes) {
  final value = attributes[guidanceMentionAttribute];
  if (value is! String || utf8.encode(value).length > 1024) {
    throw const FormatException('人员引用无效');
  }
  final data = jsonDecode(value);
  if (data is! Map<String, dynamic> || data.containsKey('children')) {
    throw const FormatException('人员引用无效');
  }
  final person = GuidancePerson.fromJson(data);
  if (person.id.length > 256 || person.name.length > 200) {
    throw const FormatException('人员引用过长');
  }
  return person;
}

/// 将[people]按类型和ID去重，构建每个占一个UTF-16位置的原子提及及尾部空格。
Delta guidanceMentionDelta(List<GuidancePerson> people) {
  final delta = Delta();
  final ids = <String>{};
  for (final person in people) {
    if (!ids.add(person.identity)) continue;
    final attributes = guidanceMentionAttributes(person);
    readGuidanceMention(attributes);
    delta.insert('\uFFFC', attributes: attributes);
    delta.insert(' ');
  }
  return delta;
}

/// 使用[context]中的编辑比例渲染[node]在[index]处的[text]；[before]/[after]为默认格式结果。
/// 旧业务引用沿用名称显示，原生用户提及使用编辑器本实例服务渲染；普通文本沿用[after]。
/// 不创建业务资源或修改正文，原生头像及点击由所属会话的宿主服务决定。
InlineSpan decorateGuidanceMention(
  BuildContext context,
  Node node,
  int index,
  TextInsert text,
  TextSpan before,
  TextSpan after,
) {
  if (text.attributes?[guidanceMentionAttribute] == null) {
    return decorateEditorUserMention(context, node, index, text, before, after);
  }
  final person = readGuidanceMention(text.attributes!);
  return TextSpan(
    children: [
      for (final rune in text.text.runes)
        if (rune == 0xfffc)
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Text(
              '@${person.name}',
              textScaler: TextScaler.noScaling,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: (after.style ?? const TextStyle(fontSize: 16, height: 2))
                  .copyWith(color: const Color(0xff367cc0)),
            ),
          )
        else
          TextSpan(text: String.fromCharCode(rune), style: after.style),
    ],
  );
}

/// 为普通段落与业务行共享原生段落输入组件；业务标签不进入可编辑文字。
///
/// ```dart
/// import 'package:cses_mobile_collab_demo/src/daily_guidance/guidance_entries.dart';
/// final builder = GuidanceParagraphBuilder();
/// // 在宿主 AppFlowyEditor 的 paragraph builder 中注册。
/// ```
class GuidanceParagraphBuilder extends ParagraphBlockComponentBuilder {
  /// [configuration]提供与其他正文一致的字号、行距和留白。
  GuidanceParagraphBuilder({super.configuration});

  /// 使用借用的[context]生成段落；无业务属性时完整沿用原段落渲染。
  @override
  BlockComponentWidget build(BlockComponentContext context) {
    if (context.node.attributes[guidanceEntryAttribute] == null) {
      return super.build(context);
    }
    return _GuidanceEntry(node: context.node, configuration: configuration);
  }
}

/// 业务行外壳；唯一node.key由内部段落持有，确保选区和IME仍定位原生文字。
class _GuidanceEntry extends BlockComponentStatelessWidget {
  /// [node]为借用的业务行，[configuration]沿用同源纸张样式。
  const _GuidanceEntry({required super.node, required super.configuration});

  /// 在[context]按正文首行高度放置圆环或业务标签；仅本地任务勾选可写。
  @override
  Widget build(BuildContext context) {
    final state = context.read<EditorState>();
    final kind = node.attributes[guidanceEntryAttribute];
    final scale = state.editorStyle.textScaleFactor;
    final done = node.attributes['guidance_done'] == true;
    final color = kind == 'help'
        ? const Color(0xffbb8a1d)
        : const Color(0xff367cc0);
    final marker = SizedBox(
      height: 32 * scale,
      child: Center(
        child: kind == 'task'
            ? Semantics(
                label: '本地待办',
                checked: done,
                enabled: state.editable,
                child: GestureDetector(
                  key: ValueKey('guidance-task-${node.id}'),
                  behavior: HitTestBehavior.opaque,
                  onTap: state.editable
                      ? () async {
                          await state.apply(
                            state.transaction
                              ..updateNode(node, {'guidance_done': !done}),
                          );
                        }
                      : null,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Icon(
                      done ? Icons.check_circle : Icons.radio_button_unchecked,
                      size: 18 * scale,
                      color: done ? color : const Color(0xffb4b4ab),
                    ),
                  ),
                ),
              )
            : Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: .12),
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Text(
                  kind == 'help' ? '都来帮' : '领航员',
                  textScaler: TextScaler.linear(scale),
                  style: TextStyle(fontSize: 11, color: color),
                ),
              ),
      ),
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        marker,
        const SizedBox(width: 4),
        Expanded(
          child: ParagraphBlockComponentWidget(
            key: node.key,
            node: node,
            configuration: configuration,
          ),
        ),
      ],
    );
  }
}

/// 将[selection]内借用的[nodes]展开为可读纯文本，要求节点按文档顺序且选区已归一化。
/// 已知对象只读取名称快照，不带账号凭据或原子占位符；不修改节点、格式或历史。
String journalSelectionPlainText(List<Node> nodes, Selection selection) {
  final lines = <String>[];
  for (var i = 0; i < nodes.length; i++) {
    final delta = nodes[i].delta!.slice(
      i == 0 ? selection.start.offset : 0,
      i == nodes.length - 1 ? selection.end.offset : nodes[i].delta!.length,
    );
    final text = StringBuffer();
    for (final op in delta.whereType<TextInsert>()) {
      if (op.text.contains('\uFFFC')) {
        final attributes = op.attributes ?? {};
        final name = attributes[guidanceMentionAttribute] == null
            ? EditorUserMention.read(attributes).name
            : readGuidanceMention(attributes).name;
        text.write(op.text.replaceAll('\uFFFC', '@$name'));
      } else {
        text.write(op.text);
      }
    }
    lines.add(text.toString());
  }
  return lines.join('\n');
}
