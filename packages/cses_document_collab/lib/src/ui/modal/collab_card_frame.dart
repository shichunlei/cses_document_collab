import 'package:cses_document_collab/src/ui/modal/collab_card_lock_overlay.dart';
import 'package:flutter/material.dart';

/// 编辑器卡片的公共外框；只借用内容，不创建控制器或处理文档事务。
///
/// ```dart
/// import 'package:cses_document_collab/src/ui/modal/collab_card_frame.dart';
/// import 'package:cses_document_collab/src/ui/modal/collab_card_header.dart';
/// import 'package:lucide_icons_flutter/lucide_icons.dart';
/// import 'package:flutter/material.dart';
/// const card = CollabCardFrame(
///   header: CollabCardHeader(
///     leading: Icon(LucideIcons.users),
///     title: Text('会议'),
///   ),
///   child: Padding(padding: EdgeInsets.all(12), child: Text('会议内容')),
/// );
/// ```
class CollabCardFrame extends StatelessWidget {
  /// [key]控制组件身份与状态复用，[surfaceKey]标记外框的实际渲染边界。
  /// [header]和[child]分别为借用的标题栏与内容，不转移其资源所有权；
  /// [header]默认null，不显示标题栏及其分隔线，适用于只展示内容的卡片。
  /// [margin]默认为零，由调用方维持块间距；[showDivider]默认显示分隔线，
  /// 收起代码时可设为false，仅保留标题栏。
  const CollabCardFrame({
    super.key,
    this.surfaceKey,
    this.header,
    required this.child,
    this.margin = EdgeInsets.zero,
    this.showDivider = true,
  });

  /// 可选实际外框标记，用于选区定位及测试。
  final Key? surfaceKey;

  /// 可选标题栏；默认null时不占标题栏或分隔线空间，调用方负责类型身份、权限和操作。
  final Widget? header;

  /// 必填原有内容；播放器和平台视图继续由其创建者释放。
  final Widget child;

  /// 外框外侧间距，默认零。
  final EdgeInsetsGeometry margin;

  /// 存在标题栏时是否显示与正文间的细线，默认true；无标题栏时忽略。
  final bool showDivider;

  /// 在借用的[context]中绘制圆角卡片；正文继续裁切，锁标独立覆盖在外框右上角。
  /// [margin]位于整层外侧，使标记始终跟随实际卡片边缘，不受标题高度或外边距影响。
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: margin,
      child: CollabCardLockOverlay(
        child: Container(
          key: surfaceKey,
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: const Color(0xFFE5E7EB)),
            borderRadius: BorderRadius.circular(12),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ?header,
              if (header != null && showDivider)
                const Divider(
                  height: 1,
                  thickness: 1,
                  color: Color(0xFFE5E7EB),
                ),
              child,
            ],
          ),
        ),
      ),
    );
  }
}
