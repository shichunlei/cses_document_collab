import 'package:cses_mobile_collab_demo/src/demo/mention_avatar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 头像按用户ID拼接、路径编码与加载失败回退，避免头像失败使正文不可操作。
void main() {
  test(
    'public avatar path encodes one stable identity in each path segment',
    () {
      expect(
        demoMentionAvatarUrl('999'),
        'https://face.jinqidongli.com/999/999.jpg',
      );
      expect(demoMentionAvatarUrl(''), isNull);
      const id = 'u /?#%';
      final uri = Uri.parse(demoMentionAvatarUrl(id)!);
      expect(uri.host, 'face.jinqidongli.com');
      expect(uri.scheme, 'https');
      expect(uri.pathSegments, [id, '$id.jpg']);
      expect(uri.query, isEmpty);
      expect(uri.fragment, isEmpty);
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
        const NetworkImage('https://face.jinqidongli.com/999/999.jpg'),
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
    'empty identity has no network request and uses a generic fallback',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: DemoMentionAvatar(userId: '', name: ''),
          ),
        ),
      );
      expect(find.byType(Image), findsNothing);
      expect(find.byIcon(Icons.person), findsOneWidget);
      expect(tester.getSize(find.byType(ClipOval)), const Size(36, 36));
    },
  );
}
