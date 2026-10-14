import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:example/pages/meeting_description_demo.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

/// Checks the phone layout independently of the desktop editor test route.
void main() {
  testWidgets('Android layout exposes a mobile text formatting toolbar', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await tester.pumpWidget(
        const MaterialApp(
          localizationsDelegates: [
            GlobalMaterialLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            AppFlowyEditorLocalizations.delegate,
          ],
          supportedLocales: [Locale('en'), Locale('zh')],
          home: MeetingDescriptionDemo(),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 100));

      expect(defaultTargetPlatform, TargetPlatform.android);
      expect(find.byType(AppFlowyEditor), findsOneWidget);
      expect(find.byType(MobileToolbarV2), findsOneWidget);
      expect(find.text('添加块'), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
