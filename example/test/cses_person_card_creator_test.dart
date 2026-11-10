import 'package:cses_common/runtime/context/context.dart';
import 'package:cses_common/runtime/session/user.dart';
import 'package:cses_mobile_collab_demo/src/service/cses_person_card_creator.dart';
import 'package:flutter_test/flutter_test.dart';

/// 宿主仅在插入边界复制登录姓名和公开头像，无账号时不生成假人员。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    ctx.faceDomain = 'https://face.example.test';
    ctx.timestamp = DateTime.fromMillisecondsSinceEpoch(1234);
  });
  test(
    'creator snapshot copies current identity and never changes after account edits',
    () {
      final user = User();
      final oldId = user.userId;
      final oldName = user.name;
      final oldAccount = user.userName;
      addTearDown(() {
        user.userId = oldId;
        user.name = oldName;
        user.userName = oldAccount;
      });
      user.userId = null;
      expect(loadCsesPersonCardCreator(), isNull);
      user.userId = 'u/one';
      user.name = '张三';
      user.userName = 'account';
      final frozen = loadCsesPersonCardCreator()!;
      expect(frozen.name, '张三');
      expect(frozen.avatar, 'https://face.example.test/u/one/u/one.jpg?t=1234');
      user.name = '李四';
      expect(frozen.name, '张三');
      user.name = '';
      expect(loadCsesPersonCardCreator()!.name, 'account');
    },
  );
}
