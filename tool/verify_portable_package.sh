#!/usr/bin/env bash
# Copy this package into an unrelated directory, build its native library and
# exercise the public API from a separate Flutter host. Pass the patched editor.
set -euo pipefail
PACKAGE_ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
EDITOR_ROOT=$(cd "${1:?Usage: verify_portable_package.sh /path/to/appflowy_editor}" && pwd -P)
VERIFY_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/cses-collab-portable.XXXXXX")
trap 'rm -rf "$VERIFY_ROOT"' EXIT
mkdir -p "$VERIFY_ROOT/package" "$VERIFY_ROOT/host/test"
rsync -a --exclude=.dart_tool --exclude=build --exclude=target \
  --exclude=.git --exclude=/example --exclude=/packages --exclude=/docs \
  --exclude='*.xcframework' --exclude=pubspec_overrides.yaml --exclude=pubspec.lock \
  "$PACKAGE_ROOT/" "$VERIFY_ROOT/package/"
cat > "$VERIFY_ROOT/host/pubspec.yaml" <<YAML
name: collab_portable_host
publish_to: none
environment:
  sdk: '>=3.12.0 <4.0.0'
dependencies:
  flutter:
    sdk: flutter
  cses_document_collab:
    path: ../package
dev_dependencies:
  flutter_test:
    sdk: flutter
dependency_overrides:
  appflowy_editor:
    path: $EDITOR_ROOT
YAML
cat > "$VERIFY_ROOT/host/test/public_api_test.dart" <<'DART'
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  late Gateway gateway;
  late CollabDocumentConfig config;
  late CollabController controller;
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockStreamHandler(
      const EventChannel('keyboardHeightEventChannel'),
      MockStreamHandler.inline(onListen: (_, events) => events.success(0.0)));
    directory = await Directory.systemTemp.createTemp('portable-doc-');
    gateway = Gateway();
    config = CollabDocumentConfig(documentId: 'fixture-doc',
      serverIdentity: 'wss://fixture.test/ws', companyId: 'company', userId: 'user',
      databasePath: '${directory.path}/updates.sqlite');
    controller = CollabController.cses(config: config, gateway: gateway);
    await controller.initialize();
    gateway.receive(await File('../package/rust/tests/fixtures/blockcraft-basic.update').readAsBytes());
    await Future<void>.delayed(Duration.zero);
  });
  test('moved package initializes native bindings and reopens SQLite via public API', () async {
    expect(controller.blockCount, 3);
    await controller.close();
    controller = CollabController.cses(config: config, gateway: gateway);
    await controller.initialize();
    expect(controller.persistedUpdateCount, greaterThan(0));
    expect(controller.blockCount, 3);
    expect(controller.canEdit, isFalse);
  });
  testWidgets('editor supplies its own localizations in a separate host', (tester) async {
    await tester.pumpWidget(MaterialApp(home: CollaborativeEditorPage(collab: controller)));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('collaborative-appflowy-editor')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  tearDownAll(() async {
    await controller.close();
    await gateway.events.close();
    await directory.delete(recursive: true);
  });
}
class Gateway implements CsesCollabGateway {
  final events = StreamController<bool>.broadcast();
  Map<String, void Function(Map<String, dynamic>)> callbacks = {};
  bool get isConnected => true;
  Stream<bool> get connectionStates => events.stream;
  Future<void> register({required String pageId, required String documentId,
    required String instanceId, required Map<String, void Function(Map<String, dynamic>)> callbacks}) async {
    this.callbacks = callbacks;
  }
  bool send(String pageId, String action, Map<String, dynamic> body) => true;
  Future<void> unregister(String pageId) async {}
  void receive(List<int> update) => callbacks['collabSync']!({
    'data': base64Encode(update), 'stateVector': base64Encode([0])});
}
DART
cargo build --manifest-path "$VERIFY_ROOT/package/rust/Cargo.toml"
cd "$VERIFY_ROOT/host"
flutter pub get
FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR="$VERIFY_ROOT/package/rust/target/debug/" \
  flutter test --no-pub --reporter expanded
