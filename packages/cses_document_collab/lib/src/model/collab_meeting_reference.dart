import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// 宿主选择或创建会议后返回的引用快照；不持有编辑器或业务资源。
/// ```dart
/// import 'package:cses_document_collab/cses_document_collab.dart';
/// const reference = CollabMeetingReference(meetingId: 'm1', title: '周会');
/// ```
final class CollabMeetingReference {
  /// [meetingId] 为业务会议稳定身份，[title] 为共享标题，[number] 为共享编号。
  /// 标题与编号默认空；包在插入前校验ID最多512 UTF-8字节、标题2000/编号256 UTF-16单元。
  const CollabMeetingReference({required this.meetingId, this.title = '', this.number = ''});

  /// 必填业务身份；不能用标题或编号代替。
  final String meetingId;

  /// 可选共享标题，默认空，不代表实时会议详情。
  final String title;

  /// 可选共享编号，默认空。
  final String number;
}

/// 宿主在借用的[context]上选择已有会议，或通过宿主页面创建会议后返回引用。
/// [canEdit]是仅在调用期间借用的权限信号；false后不得确认，不得保留或释放信号。
/// 返回null表示取消；Future必须等宿主界面完全退场。宿主拥有路由、表单、业务创建、
/// 搜索、鉴权及资源，不得直接访问编辑器；包只校验并插入返回的引用。
/// ```dart
/// import 'package:cses_document_collab/cses_document_collab.dart';
/// final services = CollabHostServices(
///   pickMeetingReference: (context, {required canEdit}) async => null,
/// );
/// // 将null替换为宿主页面选择或创建成功后的CollabMeetingReference。
/// ```
typedef CollabMeetingReferencePicker =
    Future<CollabMeetingReference?> Function(BuildContext context, {required ValueListenable<bool> canEdit});
