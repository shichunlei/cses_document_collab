import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_mobile_collab_demo/src/collab/collab_block_colors.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

/// 使用桌面左侧竖线颜色，保留 AppFlowy 的输入和选区外壳。
Widget buildCollabQuoteBorder(BuildContext context, Node node) {
  final scale = context.read<EditorState>().editorStyle.textScaleFactor;
  return Padding(
    padding: const EdgeInsets.only(right: 8),
    child: Container(
      key: const ValueKey('collab-quote-border'),
      width: 3 * scale,
      color:
          parseCollabBlockColor(
            node.attributes['cses_block_border_color'] as String?,
          ) ??
          const Color(0xff00bcf0),
    ),
  );
}
