import 'dart:io';

import 'package:cses_document_collab/src/native/api/collab.dart' as native;
import 'package:cses_document_collab/src/native/frb_generated.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';

/// Creates a desktop-compatible replacement of borrowed [source] as [type].
/// [id] is a fresh native block identity; links use the actual a:link projection.
native.CollabBlock _replacement(
  native.CollabBlock source,
  String type,
  String id,
) => native.CollabBlock(
  id: id,
  replacesId: source.id,
  blockType: type,
  text: source.text,
  parentId: source.parentId,
  checked: false,
  alignment: source.alignment,
  indent: source.indent,
  resource: type == 'paragraph'
      ? null
      : const native.CollabResource(properties: '{}'),
  segments: type == 'paragraph'
      ? [
          native.CollabTextSegment(
            text: source.text,
            href: source.text,
            bold: false,
            italic: false,
            underline: false,
            strikethrough: false,
            code: false,
            superscript: false,
            subscript: false,
          ),
        ]
      : [],
);

/// Exercises the regenerated FRB ABI, native replacements, peers and SQLite recovery.
/// Missing libraries fail explicitly; build the host Rust library before running.
void main() {
  setUpAll(() async {
    final library = File(
      Platform.isMacOS
          ? 'rust/target/debug/libcses_collab_core.dylib'
          : 'rust/target/debug/libcses_collab_core.so',
    );
    expect(library.existsSync(), isTrue, reason: 'cargo build is required');
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(library.absolute.path),
    );
  });
  for (final kind in ['bookmark', 'embed', 'figma-embed', 'juejin-embed']) {
    test(
      '$kind converts six ways and recovers the URL/link format from SQLite',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'link-view-frb-',
        );
        final path = '${directory.path}/cache.sqlite';
        try {
          native.openCsesDocument(
            documentId: 'fixture-doc',
            cacheDocumentId: 'links',
            databasePath: path,
          );
          native.applyDocumentUpdate(
            bytes: await File(
              'rust/tests/fixtures/blockcraft-resources.update',
            ).readAsBytes(),
          );
          final index = native.currentBlocks().indexWhere(
            (b) => b.blockType == kind,
          );
          final url = native.currentBlocks()[index].text;
          final sequence = kind == 'bookmark'
              ? [
                  'paragraph',
                  'bookmark',
                  'embed',
                  'paragraph',
                  'embed',
                  'bookmark',
                ]
              : [
                  'paragraph',
                  'embed',
                  'bookmark',
                  'paragraph',
                  'bookmark',
                  'embed',
                ];
          var number = 0;
          for (final type in sequence) {
            final blocks = native.currentBlocks();
            blocks[index] = _replacement(
              blocks[index],
              type,
              'converted-${number++}',
            );
            expect(
              native.applyBlockSnapshot(blocks: blocks).v1Update,
              isNotEmpty,
            );
            final projection = native.currentBlocks()[index];
            expect(projection.blockType, type);
            expect(projection.text, url);
            if (type == 'paragraph') {
              expect(projection.segments.single.href, url);
            }
            expect(native.documentReadOnlyReason(), isNull);
            native.closeDocument();
            native.openCsesDocument(
              documentId: 'fixture-doc',
              cacheDocumentId: 'links',
              databasePath: path,
            );
            expect(native.currentBlocks()[index].text, url);
            if (type == 'paragraph') {
              expect(native.currentBlocks()[index].segments.single.href, url);
            }
          }
        } finally {
          native.closeDocument();
          await directory.delete(recursive: true);
        }
      },
    );
  }
}
