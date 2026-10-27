import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/collab_host_mention_ui.dart';
import 'package:cses_document_collab/src/editor/collab_inline_mention.dart';
import 'package:cses_document_collab/src/editor/core/editor_command_context.dart';
import 'package:cses_document_collab/src/editor/editor_shortcut_toolbar.dart';
import 'package:cses_document_collab/src/model/collab_user_mention.dart';
import 'package:cses_document_collab/src/ui/modal/collab_editor_display_scope.dart';
import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

/// 可供自定义正文校验、复制和渲染复用的原生用户提及快照。
///
/// 只解释用户对象，不将普通文字或会议、任务、文档引用当作用户；不持有资源。
///
/// ```dart
/// import 'package:cses_document_collab/cses_document_collab.dart';
/// final mention = EditorUserMention.read({
///   'cses_inline_mention': '张三', 'cses_mention_id': 'u1',
/// });
/// print(mention.name); // 可用于纯文本复制。
/// ```
final class EditorUserMention {
  /// 保存已校验的[id]、[name]及可空的原始JSON[raw]，不保留可变属性集合。
  const EditorUserMention._(this.id, this.name, this.raw);

  /// 原生用户对象使用的投影属性；普通输入应移除整组身份属性。
  static const Set<String> attributeKeys = {
    collabInlineMentionAttribute,
    collabMentionIdAttribute,
    collabMentionTypeAttribute,
    collabMentionAttributesAttribute,
  };

  /// 稳定用户ID，非空且最多512个UTF-8字节。
  final String id;

  /// 正文保存的姓名快照，非空且最多20000个UTF-16单元。
  final String name;

  /// 可空的原始用户属性JSON；历史仅含姓名/ID的对象允许缺省。
  final String? raw;

  /// 将人员快照[user]转换为原生对象及尾随空格，不插入正文或持有资源。
  /// 返回独立Delta，长度为2；非法身份/姓名抛ArgumentError，不保存头像、部门或职位。
  /// 可交给宿主业务行的原子事务使用，与原生@插入保持相同格式。
  static Delta createDelta(CollabMentionUser user) => collabUserMentionDelta(user);

  /// 读取借用的[attributes]；格式、用户身份或JSON快照不一致时抛FormatException。
  ///
  /// 显式类型仅接受user；原始JSON最多32768个UTF-8字节，若含类型或ID须与投影一致。
  /// 调用方仍须确认这些属性只附在U+FFFC对象字符上，并按场景校验整篇容量。
  static EditorUserMention read(Map<String, dynamic> attributes) {
    final id = attributes[collabMentionIdAttribute];
    final name = attributes[collabInlineMentionAttribute];
    final type = attributes[collabMentionTypeAttribute];
    final raw = attributes[collabMentionAttributesAttribute];
    if (id is! String ||
        id.trim().isEmpty ||
        utf8.encode(id).length > 512 ||
        name is! String ||
        name.trim().isEmpty ||
        name.length > 20000 ||
        (type != null && type != 'user') ||
        (raw != null && raw is! String)) {
      throw const FormatException('用户提及身份无效');
    }
    if (raw is String) {
      if (utf8.encode(raw).length > 32768) {
        throw const FormatException('用户提及属性超过容量');
      }
      final value = jsonDecode(raw);
      if (value is! Map<String, dynamic>) {
        throw const FormatException('用户提及属性无效');
      }
      if (['mentionType', 'd:mentionType'].any((key) => value[key] != null && value[key] != 'user') ||
          ['mentionId', 'd:mentionId'].any((key) => value[key] != null && value[key] != id)) {
        throw const FormatException('用户提及属性与身份不一致');
      }
    }
    return EditorUserMention._(id, name, raw as String?);
  }

  /// 尝试读取借用的[attributes]；缺失、其他对象或非法属性返回null，不修改来源。
  static EditorUserMention? tryRead(Map<String, dynamic>? attributes) {
    if (attributes == null) return null;
    try {
      return read(attributes);
    } on FormatException {
      return null;
    }
  }
}

/// 借用[context]及[editorState]调用与原生@相同的人员选择服务，不插入正文。
///
/// [keyword]是初始搜索词，默认空；仅启用mention能力且可编辑时调用。
/// Future等待选择器完整退场；取消、权限撤销、换服务或销毁返回null，异常透传。
/// 调用方负责保存并复核业务插入目标、关闭及恢复键盘；不得先把editable置为false。
/// 权限信号由编辑器创建与释放，宿主服务只借用，不得将其用于其他会话。
///
/// ```dart
/// import 'package:flutter/widgets.dart';
/// import 'package:cses_document_collab/cses_document_collab.dart';
/// Future<void> choose(BuildContext context, DocumentEditorController editor) async {
///   final user = await pickEditorMentionUser(context, editor.editorState);
///   if (user != null) {
///     final delta = EditorUserMention.createDelta(user);
///     // 校验业务目标后，将delta提交到宿主事务。
///     print(delta.toJson());
///   }
/// }
/// ```
Future<CollabMentionUser?> pickEditorMentionUser(
  BuildContext context,
  EditorState editorState, {
  String keyword = '',
}) async {
  if (!context.mounted ||
      editorState.isDisposed ||
      !EditorCommandContext.of(editorState).configuration.allowsFormat(collabInlineMentionAttribute)) {
    return null;
  }
  return await pickHostMentionUser(context, editorState, keyword: keyword);
}

/// 为自定义正文复用原生用户提及的姓名、可选头像和点击行为。
///
/// [context]须提供当前EditorState；[node]为借用节点，[index]为UTF-16起点，
/// [text]为待装饰文字，[before]为原始样式，[after]为此前装饰结果。
/// 未识别用户对象返回[after]，可与宿主装饰器组合；服务只读取本实例，不借用活动协同文档。
/// WidgetSpan由正文统一缩放，内部姓名及宿主头像关闭重复的系统字号缩放。
///
/// ```dart
/// import 'package:appflowy_editor/appflowy_editor.dart';
/// import 'package:cses_document_collab/cses_document_collab.dart';
/// AppFlowyEditor body(DocumentEditorController editor) => AppFlowyEditor(
///   editorState: editor.editorState,
///   editorStyle: EditorStyle.mobile(textSpanDecorator: decorateEditorUserMention),
/// );
/// // 调用方在移除body后等待editor.close()。
/// ```
InlineSpan decorateEditorUserMention(
  BuildContext context,
  Node node,
  int index,
  TextInsert text,
  TextSpan before,
  TextSpan after,
) {
  final mention = EditorUserMention.tryRead(text.attributes);
  if (mention == null || !text.text.contains('\uFFFC')) return after;
  final state = context.read<EditorState>();
  var offset = index;
  final children = <InlineSpan>[];
  for (final rune in text.text.runes) {
    children.add(
      rune == 0xfffc
          ? WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: MediaQuery.withNoTextScaling(
                child: CollabEditorDisplayScope(
                  services: EditorCommandContext.of(state).services,
                  preview: !state.editable,
                  child: CollabInlineMention(
                    node: node,
                    offset: offset,
                    name: mention.name,
                    userId: mention.id,
                    style: after.style ?? before.style ?? const TextStyle(fontSize: 16),
                  ),
                ),
              ),
            )
          : TextSpan(text: String.fromCharCode(rune), style: after.style),
    );
    offset += rune > 0xffff ? 2 : 1;
  }
  return TextSpan(children: children);
}

/// 在借用[context]的同段[editorState]选区打开原生用户选择并插入对象。
///
/// [keyword]为初始搜索词，默认空；[replaceTrigger]默认false，true时替换光标前的@。
/// 使用实例注入的pickMentionUser；取消恢复选区，迟到、关闭及失效目标不写入。
/// 未启用mention能力不执行；Future在选择器退场及光标恢复后完成，资源由原所有者释放。
///
/// ```dart
/// import 'package:flutter/widgets.dart';
/// import 'package:cses_document_collab/cses_document_collab.dart';
/// Future<void> pick(BuildContext context, DocumentEditorController editor) =>
///     showEditorUserMention(context, editor.editorState);
/// // 创建editor时在EditorCommandContext中启用mention并注入pickMentionUser。
/// ```
Future<void> showEditorUserMention(
  BuildContext context,
  EditorState editorState, {
  String keyword = '',
  bool replaceTrigger = false,
}) async {
  if (!EditorCommandContext.of(editorState).configuration.allowsFormat(collabInlineMentionAttribute)) return;
  await showEditorUserMentionSheet(context, editorState, keyword: keyword, replaceTrigger: replaceTrigger);
}

/// 为借用[context]/[editorState]处理键入@，先写入普通@再打开同一原生用户选择器。
///
/// 只接管已配置服务、已启用mention的可编辑同段折叠光标；不适用返回false交还输入链。
/// 取消保留@，成功用单字符对象替换；保护拒绝写入时消费本次快捷事件，不重复执行普通输入。
/// Future等待选择及恢复完成，服务变化后不继续旧请求。
///
/// ```dart
/// import 'package:appflowy_editor/appflowy_editor.dart';
/// import 'package:flutter/widgets.dart';
/// import 'package:cses_document_collab/cses_document_collab.dart';
/// CharacterShortcutEvent userAt(BuildContext context) => CharacterShortcutEvent(
///   key: 'host-user-at', character: '@',
///   handler: (state) => handleEditorUserMentionTrigger(context, state),
/// );
/// // 把userAt(context)加入同一编辑器的characterShortcutEvents。
/// ```
Future<bool> handleEditorUserMentionTrigger(BuildContext context, EditorState editorState) async {
  final command = EditorCommandContext.of(editorState);
  final services = command.services;
  if (!context.mounted ||
      editorState.isDisposed ||
      !editorState.editable ||
      !command.configuration.allowsFormat(collabInlineMentionAttribute) ||
      services.pickMentionUser == null) {
    return false;
  }
  final selection = editorState.selection;
  if (selection == null || !selection.isCollapsed) return false;
  final node = editorState.getNodeAtPath(selection.start.path);
  final offset = selection.start.offset;
  final delta = node?.delta;
  if (node == null || delta == null || node.type == 'code' || offset < 0 || offset > delta.length) return false;
  final sourceText = delta.toPlainText();
  final expectedText = '${sourceText.substring(0, offset)}@${sourceText.substring(offset)}';
  final transaction = editorState.transaction..insertText(node, offset, '@');
  transaction.afterSelection = Selection.single(path: node.path, startOffset: offset + 1);
  await editorState.apply(transaction);
  if (node.delta?.toPlainText() != expectedText) return true;
  if (context.mounted &&
      !editorState.isDisposed &&
      editorState.editable &&
      identical(EditorCommandContext.of(editorState).services, services)) {
    await showEditorUserMention(context, editorState, replaceTrigger: true);
  }
  return true;
}
