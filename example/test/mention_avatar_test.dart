import 'package:cses_common/runtime/context/context.dart';
import 'package:cses_mobile_collab_demo/src/demo/mention_avatar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 验证 Common 头像解析规则及加载失败回退，避免头像失败使正文不可操作。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    ctx.faceDomain = 'https://face.example.test';
    ctx.timestamp = DateTime.fromMillisecondsSinceEpoch(1234);
  });
  test(
    'Common supplies defaults, preserves direct URLs and appends its timestamp',
    () {
      expect(
        demoMentionAvatarUrl('999'),
        'https://face.example.test/999/999.jpg?t=1234',
      );
      expect(
        demoMentionAvatarUrl(null),
        'https://face.example.test/default.jpg',
      );
      expect(demoMentionAvatarUrl(''), 'https://face.example.test/default.jpg');
      const direct = 'https://cdn.example.test/avatar.png?version=2';
      expect(demoMentionAvatarUrl(direct), direct);
      const id = 'u /?#%';
      expect(
        demoMentionAvatarUrl(id),
        'https://face.example.test/$id/$id.jpg?t=1234',
      );
    },
  );
  testWidgets(
    'failed image stays circular and retains initial without layout shift',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: DemoMentionAvatar(userId: '999', name: '测试员', size: 20),
          ),
        ),
      );
      expect(
        tester.widget<Image>(find.byType(Image)).image,
        const NetworkImage('https://face.example.test/999/999.jpg?t=1234'),
      );
      final size = tester.getSize(find.byType(ClipOval));
      await tester.pumpAndSettle();
      // The test HTTP client returns 400, exercising the real network image error builder.
      expect(find.text('测'), findsOneWidget);
      expect(tester.getSize(find.byType(ClipOval)), size);
      expect(size, const Size(20, 20));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'empty identity loads Common default avatar and uses a generic failure fallback',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: DemoMentionAvatar(userId: '', name: ''),
          ),
        ),
      );
      expect(
        tester.widget<Image>(find.byType(Image)).image,
        const NetworkImage('https://face.example.test/default.jpg'),
      );
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.person), findsOneWidget);
      expect(tester.getSize(find.byType(ClipOval)), const Size(36, 36));
    },
  );
}
