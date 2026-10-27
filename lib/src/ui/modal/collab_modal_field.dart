import 'package:cses_document_collab/src/ui/modal/collab_modal_colors.dart';
import 'package:flutter/material.dart';

/// 外置标签的设计稿字段，不持有输入控制器。
///
/// ```dart
/// import 'package:cses_document_collab/src/ui/modal/collab_modal_field.dart';
/// import 'package:flutter/material.dart';
/// const field = CollabModalField(label: '链接地址', child: TextField());
/// ```
class CollabModalField extends StatelessWidget {
  /// [key] 控制身份；[label] 为必需标签；[child] 为借用的输入控件。
  const CollabModalField({super.key, required this.label, required this.child});

  /// 字段上方12像素标签。
  final String label;

  /// 输入控件，不应再次提供浮动 labelText。
  final Widget child;

  /// 在借用 [context] 中按标签8像素间距、字段底部15像素间距排布。
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 15),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: CollabModalColors.of(context).text),
        ),
        const SizedBox(height: 8),
        child,
      ],
    ),
  );
}
