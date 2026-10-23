import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:flutter/foundation.dart';

import 'guidance_entries.dart';

/// 在严格校验前修正[transaction]从[state]当前提及边界继承的普通输入属性。
///
/// 仅处理当前单段选区的单个文字操作，并只移除与相邻或选中原子提及相同的身份属性；
/// 合成替换可从光标前开始，但删除范围必须恰好结束于当前折叠光标。
/// 基础格式、对象字符及其他属性保持原值，后续仍须执行完整正文与容量校验。
/// 会同步替换借用事务的增量和逆增量，不修改正文、选区或历史；重复调用无额外效果。
///
/// ```dart
/// import 'package:appflowy_editor/appflowy_editor.dart';
/// import 'package:cses_mobile_collab_demo/src/daily_guidance/journal_input.dart';
/// final state = EditorState.blank(withInitialText: true);
/// state.transactionGuard = (transaction) {
///   normalizeJournalTextInput(state, transaction);
///   return true; // 实际调用方继续执行自己的严格模型校验。
/// };
/// state.dispose();
/// ```
void normalizeJournalTextInput(EditorState state, Transaction transaction) {
  final selection = state.selection;
  if (selection == null || !selection.isSingle) return;
  final operations = transaction.operations;
  if (operations.length != 1) return;
  final operation = operations.single;
  if (!operation.path.equals(selection.start.path)) return;
  final source = state.getNodeAtPath(operation.path)?.delta;
  if (source == null) return;

  final Delta delta;
  if (operation is UpdateTextOperation) {
    delta = operation.delta;
  } else if (operation is UpdateOperation &&
      operation.attributes[blockComponentDelta] is List) {
    final Delta after;
    try {
      after = Delta.fromJson(operation.attributes[blockComponentDelta]);
    } on TypeError {
      return;
    }
    if (!after.every((run) => run is TextInsert) ||
        !after.any(
          (run) =>
              run is TextInsert &&
              _mentionIdentity(run.attributes).isNotEmpty &&
              run.text.runes.any((rune) => rune != 0xfffc),
        )) {
      return;
    }
    delta = source.diff(after);
  } else {
    return;
  }

  final normalized = Delta();
  var sourceOffset = 0;
  int? deletionStart;
  var changed = false;
  for (final run in Delta.fromJson(delta.toJson())) {
    if (run is! TextInsert) {
      normalized.add(run);
      if (run is TextDelete) {
        deletionStart ??= sourceOffset;
      } else {
        deletionStart = null;
      }
      sourceOffset += run.length;
      continue;
    }
    final insertionOffset = deletionStart ?? sourceOffset;
    final attributes = {...?run.attributes};
    final identity = _mentionIdentity(attributes);
    if (identity.isNotEmpty &&
        !run.text.contains('\uFFFC') &&
        _matchesInputRange(delta, selection, insertionOffset) &&
        _inheritsMention(source, insertionOffset, identity)) {
      for (final key in identity.keys) {
        attributes.remove(key);
      }
      normalized.insert(run.text, attributes: attributes);
      changed = true;
    } else {
      normalized.add(run);
    }
  }
  if (changed) {
    transaction.operations = [
      if (operation is UpdateTextOperation)
        UpdateTextOperation(
          operation.path,
          normalized,
          normalized.invert(source),
        )
      else if (operation is UpdateOperation)
        UpdateOperation(
          operation.path,
          {
            ...operation.attributes,
            blockComponentDelta: source.compose(normalized).toJson(),
          },
          {...operation.oldAttributes},
        ),
    ];
  }
}

/// 确认[delta]在[offset]处的插入属于[selection]输入，或替换恰好结束于当前光标。
/// 合成文本从其起点替换到光标时，范围可先于折叠选区，但不接受远离选区的任意修改。
bool _matchesInputRange(Delta delta, Selection selection, int offset) {
  if (offset == selection.normalized.start.offset) return true;
  if (!selection.isCollapsed) return false;
  var cursor = 0;
  for (final run in delta) {
    if (run is TextDelete &&
        cursor == offset &&
        cursor + run.length == selection.start.offset) {
      return true;
    }
    if (run is! TextInsert) cursor += run.length;
  }
  return false;
}

/// 从[attributes]提取旧业务或原生用户身份，保留原始值用于边界匹配。
/// 混合身份仍交给严格模型校验，不将伪造对象归一化为普通文字。
Map<String, dynamic> _mentionIdentity(Map<String, dynamic>? attributes) => {
  if (attributes?[guidanceMentionAttribute] != null)
    guidanceMentionAttribute: attributes![guidanceMentionAttribute],
  for (final key in EditorUserMention.attributeKeys)
    if (attributes?[key] != null) key: attributes![key],
};

/// 检查[source]在[offset]左侧或当前位置的真实对象是否带有同一[identity]属性集。
/// 仅接受已能解析的提及，不为伪造普通字符或未知对象移除失败证据。
bool _inheritsMention(Delta source, int offset, Map<String, dynamic> identity) {
  for (final index in [if (offset > 0) offset - 1, offset]) {
    if (index < 0 || index >= source.length) continue;
    final run = source.slice(index, index + 1).single;
    if (run is! TextInsert ||
        run.text != '\uFFFC' ||
        !mapEquals(_mentionIdentity(run.attributes), identity)) {
      continue;
    }
    try {
      if (identity.containsKey(guidanceMentionAttribute)) {
        if (identity.length != 1) continue;
        readGuidanceMention(run.attributes!);
      } else {
        EditorUserMention.read(run.attributes!);
      }
      return true;
    } on FormatException {
      continue;
    }
  }
  return false;
}
