import 'package:cses_document_collab/src/model/collab_host_services.dart';
import 'package:flutter/widgets.dart';

/// 向正文展示组件借出实例服务与纯内容预览标记，不管理业务或编辑器资源。
///
/// ```dart
/// import 'package:cses_document_collab/cses_document_collab.dart';
/// import 'package:cses_document_collab/src/ui/modal/collab_editor_display_scope.dart';
/// import 'package:flutter/widgets.dart';
/// const scope = CollabEditorDisplayScope(services: CollabHostServices(),
///   preview: true, child: SizedBox());
/// ```
class CollabEditorDisplayScope extends InheritedWidget {
  /// [key]控制身份，[services]借自当前编辑实例，[preview]为true时隐藏编辑装饰。
  /// [child]为借用正文子树，不转移任何控制器或回调的所有权。
  const CollabEditorDisplayScope({super.key, required this.services, required this.preview, required super.child});

  /// 当前实例的业务端口；本地未注入时为空服务，不解析活动协同文档。
  final CollabHostServices services;

  /// 是否为无编辑操作的正文预览。
  final bool preview;

  /// 订阅[context]最近的正文展示作用域；历史独立组件未装配时返回null。
  static CollabEditorDisplayScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<CollabEditorDisplayScope>();

  /// 在[oldWidget]的实例端口或预览状态改变时通知展示子树。
  @override
  bool updateShouldNotify(CollabEditorDisplayScope oldWidget) =>
      !identical(services, oldWidget.services) || preview != oldWidget.preview;
}
