import 'package:cses_common/runtime/session/user.dart';
import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:cses_mobile_collab_demo/src/demo/mention_avatar.dart';

/// 读取当前登录人员用于新插入的定格卡片；不向协同包暴露账号对象。
/// ```dart
/// import 'package:cses_mobile_collab_demo/src/service/cses_person_card_creator.dart';
/// final person = loadCsesPersonCardCreator();
/// // 作为CollabHostServices.loadPersonCardCreator注入，不用于刷新旧卡片。
/// ```
CollabPersonCardData? loadCsesPersonCardCreator() {
  final user = User();
  if (user.userId?.isNotEmpty != true) return null;
  final name = user.name.isNotEmpty ? user.name : user.userName;
  if (name.isEmpty) return null;
  return CollabPersonCardData(
    name: name,
    avatar: demoMentionAvatarUrl(user.userId!),
    description: user.currentCompany?.deptName,
  );
}
