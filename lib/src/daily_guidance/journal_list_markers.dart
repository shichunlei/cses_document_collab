import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

/// 为借用的[node]绘制圆点；[context]提供日记编辑器的字号缩放，不改变正文或选区。
/// 供BulletedListBlockComponentBuilder的iconBuilder使用，只支持日记的平铺列表。
Widget buildJournalBulletMarker(BuildContext context, Node node) {
  final scale = context.read<EditorState>().editorStyle.textScaleFactor;
  return _marker(
    context,
    node,
    SizedBox.square(
      key: ValueKey('journal-marker-glyph-${node.id}'),
      dimension: 5 * scale,
      child: const DecoratedBox(
        decoration: BoxDecoration(
          color: Color(0xff3e4650),
          shape: BoxShape.circle,
        ),
      ),
    ),
  );
}

/// 为借用的[node]绘制当前连续编号，[direction]控制编号文字方向。
/// [context]提供日记缩放；同栏目连续编号沿用首项number属性，不创建菜单或资源。
Widget buildJournalNumberMarker(
  BuildContext context,
  Node node,
  TextDirection direction,
) {
  final state = context.read<EditorState>();
  var first = node;
  var offset = 0;
  while (first.previous?.type == NumberedListBlockKeys.type) {
    first = first.previous!;
    offset++;
  }
  final start = first.attributes[NumberedListBlockKeys.number];
  final number = (start is int ? start : 1) + offset;
  return _marker(
    context,
    node,
    Text(
      '$number.',
      key: ValueKey('journal-marker-glyph-${node.id}'),
      style: state.editorStyle.textStyleConfiguration.text.copyWith(height: 2),
      textScaler: TextScaler.linear(state.editorStyle.textScaleFactor),
      textDirection: direction,
      textHeightBehavior: const TextHeightBehavior(
        applyHeightToFirstAscent: true,
        applyHeightToLastDescent: true,
      ),
    ),
  );
}

/// 为借用的[node]绘制居中的待办框；[onTap]由原列表组件持有并执行勾选事务。
/// [context]提供日记缩放及可编辑状态；预览禁用回调，标记区保留勾选语义及点击范围。
Widget buildJournalTodoMarker(
  BuildContext context,
  Node node,
  VoidCallback onTap,
) {
  final state = context.read<EditorState>();
  final scale = state.editorStyle.textScaleFactor;
  final checked = node.attributes[TodoListBlockKeys.checked] == true;
  return Semantics(
    checked: checked,
    enabled: state.editable,
    label: '待办',
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: state.editable ? onTap : null,
      child: _marker(
        context,
        node,
        Container(
          key: ValueKey('journal-marker-glyph-${node.id}'),
          width: 16.5 * scale,
          height: 16.5 * scale,
          decoration: BoxDecoration(
            color: checked ? const Color(0xff00bcf0) : null,
            border: checked
                ? null
                : Border.all(
                    color: const Color(0xffbdbdbd),
                    width: 1.3 * scale,
                  ),
            borderRadius: BorderRadius.circular(5 * scale),
          ),
          child: checked
              ? Icon(LucideIcons.check, size: 12 * scale, color: Colors.white)
              : null,
        ),
      ),
    ),
  );
}

/// 将[node]的标记[child]约束在正文第一行高度内；[context]与正文共用缩放。
/// 宽度至少为原列表的26逻辑像素，长编号可扩宽；多行正文不改变标记的垂直位置。
Widget _marker(BuildContext context, Node node, Widget child) {
  final scale = context.read<EditorState>().editorStyle.textScaleFactor;
  return Container(
    key: ValueKey('journal-list-marker-${node.id}'),
    height: 32 * scale,
    constraints: BoxConstraints(minWidth: 26 * scale),
    padding: EdgeInsets.only(right: 4 * scale),
    alignment: Alignment.center,
    child: child,
  );
}
