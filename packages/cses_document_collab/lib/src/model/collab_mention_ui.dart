import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'collab_user_mention.dart';

/// 宿主构建人员头像；[context] 借用当前展示位置，[userId] 为稳定身份，
/// [name] 为该位置显示名，[size] 为正逻辑像素边长，[avatarUrl] 为可选资料URL。
/// 正文传null；宿主决定图片地址、缓存、裁切及失败占位。
/// 编辑器只约束尺寸并排除重复无障碍描述；返回组件的State按Flutter生命周期释放。
/// ```dart
/// import 'package:flutter/material.dart';
/// import 'package:cses_document_collab/cses_document_collab.dart';
/// final services = CollabHostServices(
///   mentionAvatarBuilder: (context, {required userId, required name,
///     required size, avatarUrl}) => CircleAvatar(
///       radius: size / 2, child: const Icon(Icons.person)),
/// );
/// ```
typedef CollabMentionAvatarBuilder =
    Widget Function(
      BuildContext context, {
      required String userId,
      required String name,
      required double size,
      String? avatarUrl,
    });

/// 宿主打开单选人员界面；[context] 借用编辑器所在路由，[keyword] 为初始搜索词。
/// [canEdit] 是仅在本次调用期间借用的可编辑信号，false后不能确认；不得释放或保留它。
/// 返回选中人员，取消返回null；Future须等待选择界面完全退场，异常由编辑器报告。
/// 宿主拥有搜索、鉴权、路由及监听清理；不得直接修改编辑器或协同文档。
/// ```dart
/// import 'package:flutter/material.dart';
/// import 'package:cses_document_collab/cses_document_collab.dart';
/// final services = CollabHostServices(
///   pickMentionUser: (context, {required keyword, required canEdit}) async {
///     final route = MaterialPageRoute<CollabMentionUser>(
///       builder: (_) => Scaffold(body: Center(child: TextButton(
///         onPressed: () => Navigator.pop(context, canEdit.value
///           ? const CollabMentionUser(id: 'u1', name: '张三') : null),
///         child: const Text('张三'),
///       ))),
///     );
///     final user = await Navigator.of(context).push(route);
///     await route.completed;
///     return user;
///   },
/// );
/// ```
typedef CollabMentionUserPicker =
    Future<CollabMentionUser?> Function(
      BuildContext context, {
      required String keyword,
      required ValueListenable<bool> canEdit,
    });
