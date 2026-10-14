import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_mobile_collab_demo/src/demo/collab_demo_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
          const EventChannel('keyboardHeightEventChannel'),
          MockStreamHandler.inline(
            onListen: (_, events) => events.success(0.0),
          ),
        );
  });

  testWidgets('connection page scrolls and exposes the editor route', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      const MaterialApp(
        localizationsDelegates: [
          GlobalMaterialLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          AppFlowyEditorLocalizations.delegate,
        ],
        home: CollabDemoPage(),
      ),
    );

    expect(find.byType(SingleChildScrollView), findsWidgets);
    expect(find.text('CSES 协同 Demo'), findsOneWidget);
    expect(find.byKey(const ValueKey('open-collaborative-editor')), findsOne);
    expect(
      find.byKey(const ValueKey('collaborative-appflowy-editor')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('editor-undo')), findsNothing);
    expect(find.byKey(const ValueKey('editor-redo')), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
