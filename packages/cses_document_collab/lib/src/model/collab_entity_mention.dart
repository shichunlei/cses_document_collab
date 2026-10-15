import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/model/collab_inline_formula.dart';
import 'package:cses_document_collab/src/model/collab_user_mention.dart';

/// 实体原子操作的稳定身份，连同原始属性检测远端变化；不持有编辑器资源。
/// ```dart
/// import 'package:appflowy_editor/appflowy_editor.dart';
/// import 'package:cses_document_collab/src/model/collab_entity_mention.dart';
/// final state = EditorState.blank();
/// final target = CollabEntityMentionTarget.capture(state.document.first!, 0);
/// if (target != null) await deleteCollabEntityMention(state, target);
/// state.dispose();
/// ```
final class CollabEntityMentionTarget {
  /// [blockId] 为块身份，[offset] 为UTF-16位置，[text] 为定位正文；
  /// [name]/[entityId] 为实体显示名与身份，[entityType] 为meeting/task/doc类型，[atomJson] 为冻结的完整原子属性快照。
  const CollabEntityMentionTarget._(
    this.blockId,
    this.offset,
    this.text,
    this.name,
    this.entityId,
    this.entityType,
    String atomJson,
  ) : _atomJson = atomJson;

  /// 所在块的稳定身份，不持有可能被重排替换的Node。
  final String blockId;

  /// 原子占据的UTF-16位置。
  final int offset;

  /// 打开时正文，用于拒绝过期位置。
  final String text;

  /// 共享正文保存的原始实体名称，不代表业务服务中的实时标题。
  final String name;

  /// 原始实体稳定ID，不作为人员身份读取头像。
  final String entityId;

  /// meeting/task/doc中的明确类型，不与同ID用户混同。
  final String entityType;

  /// 冻结完整属性，远端名称、状态或编号变化后旧删除/历史不得覆盖它们。
  final String _atomJson;

  /// 捕获借用 [node] 中UTF-16 [offset] 的实体；普通字符、其他实体或缺身份返回null。
  static CollabEntityMentionTarget? capture(Node node, int offset) {
    final delta = node.delta;
    if (delta == null || offset < 0 || offset >= delta.length) return null;
    final atom = delta.slice(offset, offset + 1);
    final operation = atom.first;
    final attrs = operation.attributes;
    final name = attrs?[collabInlineMentionAttribute];
    final id = attrs?[collabMentionIdAttribute];
    if (operation is! TextInsert ||
        operation.text != collabInlineFormulaCharacter ||
        !const {
          'meeting',
          'task',
          'doc',
        }.contains(attrs?[collabMentionTypeAttribute]) ||
        attrs?[collabMentionAttributesAttribute] is! String ||
        name is! String ||
        id is! String ||
        id.isEmpty) {
      return null;
    }
    return CollabEntityMentionTarget._(
      node.attributes['cses_collab_block_id'] as String? ?? node.id,
      offset,
      delta.toPlainText(),
      name,
      id,
      attrs![collabMentionTypeAttribute] as String,
      jsonEncode(atom.toJson()),
    );
  }

  /// 在借用 [state] 中按块ID重定位；正文或完整原子变化、删除、关闭时返回null。
  Node? resolve(EditorState state) {
    final node = findCollabInlineTextNode(state, blockId);
    if (node == null || node.delta!.toPlainText() != text) return null;
    final current = capture(node, offset);
    return current?._atomJson == _atomJson ? node : null;
  }
}

/// 删除借用 [state] 中稳定 [target] 的一个实体提及，不改变实体业务数据。
/// 只读、关闭或远端变化返回false；成功生成独立历史，撤销恢复完整实体属性；异常透传。
Future<bool> deleteCollabEntityMention(
  EditorState state,
  CollabEntityMentionTarget target,
) async {
  if (state.isDisposed || !state.editable) return false;
  final node = target.resolve(state);
  if (node == null) return false;
  await applyCollabInlineCommand(
    state,
    node,
    target.offset,
    node.delta!.slice(target.offset, target.offset + 1),
    Delta(),
  );
  return true;
}
