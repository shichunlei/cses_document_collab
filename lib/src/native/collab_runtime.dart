import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/editor/core/editor_command_context.dart';
import 'package:cses_document_collab/src/model/collab_host_services.dart';
import 'package:cses_document_collab/src/native/frb_generated.dart';

/// Process-wide ownership guard matching the Rust engine's single Doc.
/// Acquisition occurs before native initialization. A failed initializer releases
/// ownership; an old controller can never close a newer controller's document.
abstract final class CollabRuntime {
  static Object? _owner;
  static Future<void>? _initialization;
  static CollabHostServices _services = const CollabHostServices();

  /// Whether bindings loaded successfully; failed initialization must not call FFI.
  static bool get nativeReady => RustLib.instance.initialized;

  /// Integrations for the active document; fallback supports isolated UI tests.
  static CollabHostServices get services => _services;

  /// Reserve the engine for [owner] and [services]; concurrent documents fail
  /// with a stable error before touching the native Doc or SQLite.
  static void acquire(Object owner, CollabHostServices services) {
    if (_owner != null && !identical(_owner, owner)) {
      throw StateError('COLLAB_DOCUMENT_IN_USE: 请先等待当前文档关闭');
    }
    legacyEditorServices = () => _services;
    _owner = owner;
    _services = services;
  }

  /// Whether [owner] may access or close the global native document.
  static bool owns(Object owner) => identical(_owner, owner);

  /// Initialize native bindings once; failures remain retryable on the next open.
  static Future<void> initialize() async {
    registerCsesRichTextAttributes();
    try {
      if (!RustLib.instance.initialized) {
        await (_initialization ??= RustLib.init());
      }
    } catch (_) {
      _initialization = null;
      rethrow;
    }
  }

  /// Release only [owner]'s reservation, after native shutdown has completed.
  static void release(Object owner) {
    if (!owns(owner)) return;
    _owner = null;
    _services = const CollabHostServices();
  }
}

/// Internal failure router for editor widgets and protocol callbacks.
abstract final class CollabDiagnostics {
  /// Report [message] with the original [error], [stackTrace] and optional [tag].
  static void report(
    String message, {
    required Object error,
    required StackTrace stackTrace,
    String? tag,
  }) => CollabRuntime.services.report(message, error, stackTrace, tag);
}
