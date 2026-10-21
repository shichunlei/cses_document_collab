import 'package:appflowy_editor/appflowy_editor.dart';
import 'dart:io';
import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:cses_document_collab/src/image_composer/image_composer_controller.dart';
import 'package:cses_document_collab/src/native/api/collab.dart' as native;
import 'package:cses_document_collab/src/native/collab_runtime.dart';
import 'package:cses_document_collab/src/native/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

/// 真实原生文档保持活动时本地编辑和预览，验证唯一引擎/宿主服务/正文不被制图占用或关闭。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final suffix = Platform.isMacOS ? 'dylib' : 'so';
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        File('rust/target/debug/libcses_collab_core.$suffix').absolute.path,
      ),
    );
  });

  testWidgets(
    'local preview keeps the active native document and services intact',
    (tester) async {
      await tester.runAsync(() async {
        final directory = await Directory.systemTemp.createTemp(
          'image-composer-isolation-',
        );
        final document = CollabController.localDraft(
          databasePath: '${directory.path}/doc.sqlite',
        );
        ImageComposerController? composer;
        try {
          await document.initialize();
          final state = document.editorState;
          await state.apply(
            state.transaction..insertText(
              state.document.root.children.single,
              0,
              'Existing native document',
            ),
          );
          final before = native
              .currentBlocks()
              .map((b) => (b.id, b.text))
              .toList();
          final services = CollabRuntime.services;
          composer = ImageComposerController(
            initialText: 'Independent image',
            templates: collabImageTemplates,
          );
          final preview = composer.prepare();
          expect(
            preview.editorState.document.root.children.single.delta!
                .toPlainText(),
            'Independent image',
          );
          expect(preview.editorState.selection, isNull);
          expect(preview.editorState.editable, isFalse);
          await composer.close();
          expect(CollabRuntime.owns(document), isTrue);
          expect(identical(CollabRuntime.services, services), isTrue);
          expect(native.currentBlocks().map((b) => (b.id, b.text)), before);
          expect(document.canEdit, isTrue);
          await state.apply(
            state.transaction
              ..insertText(state.document.root.children.single, 0, '!'),
          );
          expect(native.currentBlocks().single.text, startsWith('!Existing'));
        } finally {
          await composer?.close();
          await document.close();
          await directory.delete(recursive: true);
        }
      });
    },
  );
}
