import 'dart:async';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_mobile_collab_demo/src/collab/appflowy_block_editor_adapter.dart';
import 'package:cses_mobile_collab_demo/src/collab/io_collab_socket_transport.dart';
import 'package:cses_mobile_collab_demo/src/rust/api/collab.dart' as rust;
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

enum ConnectionStatus { starting, connecting, online, offline, error }

class CollabController extends ChangeNotifier with WidgetsBindingObserver {
  CollabController({
    this.documentId = 'demo-room',
    String serverUrl = 'ws://127.0.0.1:1234',
  }) : _serverUrl = serverUrl {
    _editorAdapter = AppFlowyBlockEditorAdapter(
      onLocalBlocksChanged: _applyEditorBlocks,
    );
  }

  final String documentId;
  late final AppFlowyBlockEditorAdapter _editorAdapter;

  String _serverUrl;
  IoCollabSocketTransport? _transport;
  List<rust.CollabBlock> _lastBlocks = const [];
  String? _error;
  String _lastProtocolEvent = 'not-started';
  String _sharedTypeName = 'cses_mobile_block_order';
  int _persistedUpdateCount = 0;
  ConnectionStatus _status = ConnectionStatus.starting;
  bool _initialized = false;
  bool _initializing = false;
  bool _disposed = false;
  bool _observingLifecycle = false;

  String get serverUrl => _serverUrl;
  String? get error => _error;
  String get lastProtocolEvent => _lastProtocolEvent;
  String get sharedTypeName => _sharedTypeName;
  int get persistedUpdateCount => _persistedUpdateCount;
  int get blockCount => _lastBlocks.length;
  ConnectionStatus get status => _status;
  bool get initialized => _initialized;
  EditorState get editorState => _editorAdapter.editorState;

  Future<void> initialize() async {
    if (_disposed || _initialized || _initializing) {
      return;
    }
    _initializing = true;
    try {
      final supportDirectory = await getApplicationSupportDirectory();
      if (_disposed) {
        return;
      }
      final result = rust.openDocument(
        documentId: documentId,
        databasePath:
            '${supportDirectory.path}/cses_mobile_collab_demo/updates.sqlite3',
      );
      final openedEditorBlocks = _toEditorBlocks(result.blocks);
      final normalizedEditorBlocks = ensureCsesDocumentHeaderBlocks(
        openedEditorBlocks,
      );
      final normalizedRustBlocks = _toRustBlocks(normalizedEditorBlocks);
      if (_rustBlocksEqual(normalizedRustBlocks, result.blocks)) {
        _lastBlocks = List<rust.CollabBlock>.unmodifiable(result.blocks);
      } else {
        // Existing SQLite documents predate the fixed cover/title blocks.
        // Persist the deterministic migration before networking starts; the
        // subsequent Sync Step 1 then advertises the migrated Yrs state without
        // needing to queue an outbound frame before transport construction.
        final migrated = rust.applyBlockSnapshot(blocks: normalizedRustBlocks);
        _lastBlocks = List<rust.CollabBlock>.unmodifiable(migrated.blocks);
      }
      _sharedTypeName = result.sharedTypeName;
      _persistedUpdateCount = result.persistedUpdateCount;
      await _editorAdapter.replaceFromRemote(_toEditorBlocks(_lastBlocks));
      if (_disposed) {
        return;
      }
      _initialized = true;
      _status = ConnectionStatus.offline;
      _lastProtocolEvent = 'local-updates-loaded';
      _transport = IoCollabSocketTransport(
        serverUrl: _serverUrl,
        roomId: documentId,
        syncFrameFactory: rust.createSyncStep1,
        onBinaryMessage: _handleSocketMessage,
        onStateChanged: _handleTransportState,
      );
      WidgetsBinding.instance.addObserver(this);
      _observingLifecycle = true;
      _notify();
      await _transport!.start();
    } catch (exception) {
      _setError(exception);
    } finally {
      _initializing = false;
    }
  }

  void _applyEditorBlocks(List<CollabEditorBlock> nextBlocks) {
    if (!_initialized) {
      return;
    }

    try {
      // Header blocks are structural invariants. Normalizing every local
      // snapshot also repairs an accidental block-level deletion before the
      // state crosses into Rust/Yrs.
      final normalizedBlocks = ensureCsesDocumentHeaderBlocks(nextBlocks);
      final rustBlocks = _toRustBlocks(normalizedBlocks);
      if (_rustBlocksEqual(rustBlocks, _lastBlocks)) {
        return;
      }
      final result = rust.applyBlockSnapshot(blocks: rustBlocks);
      _lastBlocks = List<rust.CollabBlock>.unmodifiable(result.blocks);
      _lastProtocolEvent = 'local-block-update';
      _transport?.send(result.outboundMessage);
      final canonical = _toEditorBlocks(result.blocks);
      if (!_editorBlocksEqual(canonical, nextBlocks)) {
        unawaited(_editorAdapter.replaceFromRemote(canonical));
      }
      _notify();
    } catch (exception) {
      _setError(exception);
    }
  }

  Future<void> updateServerUrlAndReconnect(String value) async {
    try {
      final normalized = value.trim().replaceFirst(RegExp(r'/+$'), '');
      _transport?.updateServerUrl(normalized);
      _serverUrl = normalized;
      await connect();
    } catch (exception) {
      _setError(exception);
    }
  }

  Future<void> connect() async {
    final transport = _transport;
    if (!_initialized || transport == null) {
      return;
    }
    await transport.reconnect(event: 'manual-reconnect');
  }

  Future<void> resetLocalCache() async {
    await _transport?.stop(event: 'local-cache-reset');
    try {
      final result = rust.resetLocalDocument();
      _lastBlocks = List<rust.CollabBlock>.unmodifiable(result.blocks);
      _sharedTypeName = result.sharedTypeName;
      _persistedUpdateCount = result.persistedUpdateCount;
      await _editorAdapter.replaceFromRemote(_toEditorBlocks(result.blocks));
      _lastProtocolEvent = 'local-cache-reset';
      _status = ConnectionStatus.offline;
      _error = null;
      _notify();
    } catch (exception) {
      _setError(exception);
    }
  }

  void _handleSocketMessage(Uint8List data) {
    try {
      final result = rust.handleWireMessage(bytes: data);
      _lastProtocolEvent = result.messageKind;
      if (result.reply.isNotEmpty) {
        _transport?.send(result.reply);
      }
      if (result.changed && !_rustBlocksEqual(result.blocks, _lastBlocks)) {
        _lastBlocks = List<rust.CollabBlock>.unmodifiable(result.blocks);
        unawaited(_syncEditorFromRust(result.blocks));
      }
      _notify();
    } catch (exception) {
      _setError(exception);
    }
  }

  Future<void> _syncEditorFromRust(List<rust.CollabBlock> blocks) async {
    try {
      await _editorAdapter.replaceFromRemote(_toEditorBlocks(blocks));
    } catch (exception) {
      _setError(exception);
    }
  }

  void _handleTransportState(
    CollabTransportStatus status,
    String event,
    Object? error,
  ) {
    _status = switch (status) {
      CollabTransportStatus.idle => ConnectionStatus.starting,
      CollabTransportStatus.connecting => ConnectionStatus.connecting,
      CollabTransportStatus.online => ConnectionStatus.online,
      CollabTransportStatus.offline => ConnectionStatus.offline,
    };
    _lastProtocolEvent = event;
    _error = error == null ? null : '连接失败，已保持离线编辑：$error';
    _notify();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      return;
    }
    final transport = _transport;
    if (transport != null) {
      unawaited(transport.onAppResumed());
    }
  }

  void _setError(Object exception) {
    _status = ConnectionStatus.error;
    _error = exception.toString();
    _notify();
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  static List<CollabEditorBlock> _toEditorBlocks(
    List<rust.CollabBlock> blocks,
  ) {
    return blocks
        .map(
          (block) => CollabEditorBlock(
            id: block.id,
            blockType: block.blockType,
            text: block.text,
            segments: block.segments
                .map(
                  (segment) => CollabEditorTextSegment(
                    text: segment.text,
                    bold: segment.bold,
                    italic: segment.italic,
                    underline: segment.underline,
                    strikethrough: segment.strikethrough,
                    code: segment.code,
                    textColor: segment.textColor,
                    // Rust stores this as a Yrs text attribute; the editor
                    // adapter maps it back to AppFlowy's `bg_color` key.
                    backgroundColor: segment.backgroundColor,
                    superscript: segment.superscript,
                    subscript: segment.subscript,
                  ),
                )
                .toList(growable: false),
            checked: block.checked,
            alignment: block.alignment,
            indent: block.indent,
          ),
        )
        .toList(growable: false);
  }

  static List<rust.CollabBlock> _toRustBlocks(List<CollabEditorBlock> blocks) {
    return blocks
        .map(
          (block) => rust.CollabBlock(
            id: block.id,
            blockType: block.blockType,
            text: block.text,
            segments: block.segments
                .map(
                  (segment) => rust.CollabTextSegment(
                    text: segment.text,
                    bold: segment.bold,
                    italic: segment.italic,
                    underline: segment.underline,
                    strikethrough: segment.strikethrough,
                    code: segment.code,
                    textColor: segment.textColor,
                    // Preserve the ARGB highlight across the Dart-to-Rust
                    // snapshot boundary instead of treating it as local UI.
                    backgroundColor: segment.backgroundColor,
                    superscript: segment.superscript,
                    subscript: segment.subscript,
                  ),
                )
                .toList(growable: false),
            checked: block.checked,
            alignment: block.alignment,
            indent: block.indent,
          ),
        )
        .toList(growable: false);
  }

  static bool _rustBlocksEqual(
    List<rust.CollabBlock> left,
    List<rust.CollabBlock> right,
  ) {
    if (left.length != right.length) {
      return false;
    }
    for (var index = 0; index < left.length; index += 1) {
      final leftBlock = left[index];
      final rightBlock = right[index];
      if (leftBlock.id != rightBlock.id ||
          leftBlock.blockType != rightBlock.blockType ||
          leftBlock.text != rightBlock.text ||
          leftBlock.checked != rightBlock.checked ||
          leftBlock.alignment != rightBlock.alignment ||
          leftBlock.indent != rightBlock.indent ||
          !_rustSegmentsEqual(leftBlock.segments, rightBlock.segments)) {
        return false;
      }
    }
    return true;
  }

  static bool _rustSegmentsEqual(
    List<rust.CollabTextSegment> left,
    List<rust.CollabTextSegment> right,
  ) {
    if (left.length != right.length) {
      return false;
    }
    for (var index = 0; index < left.length; index += 1) {
      final leftSegment = left[index];
      final rightSegment = right[index];
      if (leftSegment.text != rightSegment.text ||
          leftSegment.bold != rightSegment.bold ||
          leftSegment.italic != rightSegment.italic ||
          leftSegment.underline != rightSegment.underline ||
          leftSegment.strikethrough != rightSegment.strikethrough ||
          leftSegment.code != rightSegment.code ||
          leftSegment.textColor != rightSegment.textColor ||
          leftSegment.backgroundColor != rightSegment.backgroundColor ||
          leftSegment.superscript != rightSegment.superscript ||
          leftSegment.subscript != rightSegment.subscript) {
        return false;
      }
    }
    return true;
  }

  static bool _editorBlocksEqual(
    List<CollabEditorBlock> left,
    List<CollabEditorBlock> right,
  ) {
    if (left.length != right.length) {
      return false;
    }
    for (var index = 0; index < left.length; index += 1) {
      if (left[index] != right[index]) {
        return false;
      }
    }
    return true;
  }

  @override
  void dispose() {
    _disposed = true;
    if (_observingLifecycle) {
      WidgetsBinding.instance.removeObserver(this);
      _observingLifecycle = false;
    }
    final transport = _transport;
    _transport = null;
    if (transport != null) {
      unawaited(transport.dispose());
    }
    _editorAdapter.dispose();
    super.dispose();
  }
}

/// Adds the fixed Feishu-style cover/title region to old or empty documents.
///
/// Header IDs are deterministic across clients, preventing two offline phones
/// from inventing competing title blocks while migrating the same room. Any
/// existing header content is preserved and moved ahead of ordinary body
/// blocks; a document with no body also receives one editable paragraph.
List<CollabEditorBlock> ensureCsesDocumentHeaderBlocks(
  List<CollabEditorBlock> blocks,
) {
  CollabEditorBlock? cover;
  CollabEditorBlock? title;
  final body = <CollabEditorBlock>[];
  for (final block in blocks) {
    if (block.blockType == csesDocumentCoverBlockType && cover == null) {
      cover = block;
    } else if (block.blockType == csesDocumentTitleBlockType && title == null) {
      title = block;
    } else if (block.blockType != csesDocumentCoverBlockType &&
        block.blockType != csesDocumentTitleBlockType) {
      body.add(block);
    }
  }

  cover ??= const CollabEditorBlock(
    id: csesDocumentCoverBlockId,
    blockType: csesDocumentCoverBlockType,
    // Only a genuinely missing cover receives the product default. An existing
    // cover block with empty text represents an intentional user removal and
    // is preserved by the normalization loop above.
    text: csesDefaultDocumentCoverUrl,
  );
  title ??= const CollabEditorBlock(
    id: csesDocumentTitleBlockId,
    blockType: csesDocumentTitleBlockType,
    text: '未命名文档',
  );
  if (body.isEmpty) {
    body.add(
      const CollabEditorBlock(
        id: csesDocumentBodyBlockId,
        blockType: ParagraphBlockKeys.type,
        text: '',
      ),
    );
  }
  return List<CollabEditorBlock>.unmodifiable([cover, title, ...body]);
}
