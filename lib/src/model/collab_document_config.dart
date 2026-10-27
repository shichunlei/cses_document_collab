import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Immutable document identity and local storage settings supplied by the host.
///
/// Credentials and physical connection ownership stay with the host. The formal
/// root ID is kept separate from the cache key, which preserves the existing
/// CSES cache partition contract across package moves and cookie rotation.
class CollabDocumentConfig {
  /// Open an existing formal document. [documentId] is its BlockCraft root ID;
  /// [serverIdentity], [companyId] and [userId] isolate local updates.
  /// [userName] is display-only, [databasePath] is the host-selected SQLite file,
  /// and [editable] is the host's current authorization, not a server guarantee.
  const CollabDocumentConfig({
    required this.documentId,
    required this.serverIdentity,
    required this.companyId,
    required this.userId,
    required this.databasePath,
    this.userName = '',
    this.editable = false,
  }) : isFormal = true;

  /// Open a local draft using [documentId] as its cache key. [databasePath]
  /// identifies the SQLite file. Drafts contain only body blocks.
  const CollabDocumentConfig.localDraft({
    required this.databasePath,
    this.documentId = 'demo-room',
    this.editable = true,
  }) : isFormal = false,
       serverIdentity = '',
       companyId = '',
       userId = '',
       userName = '';

  /// Existing formal root ID or host-owned local draft key.
  final String documentId;

  /// Stable server identity; use the same full WS URL as the existing cache.
  final String serverIdentity;

  /// Company identity used for cache isolation, not authorization.
  final String companyId;

  /// User identity used for cache isolation and Awareness.
  final String userId;

  /// Display name used by Awareness; an empty name falls back to [userId].
  final String userName;

  /// Absolute SQLite path chosen by the host.
  final String databasePath;

  /// Whether the document uses the formal BlockCraft schema.
  final bool isFormal;

  /// Initial host authorization; runtime changes use controller.setEditable.
  final bool editable;

  /// Validate identity and storage before acquiring the process-wide engine.
  /// Throws [FormatException] without opening storage or registering listeners.
  void validate() {
    if (documentId.trim().isEmpty ||
        documentId.length > 128 ||
        databasePath.trim().isEmpty) {
      throw const FormatException('文档 ID 和数据库路径必须有效');
    }
    if (isFormal &&
        [serverIdentity, companyId, userId].any((v) => v.trim().isEmpty)) {
      throw const FormatException('正式文档需要服务端、企业和用户身份');
    }
  }

  /// Exact legacy cache partition; cookie credentials never enter this value.
  String get cacheDocumentId => isFormal
      ? 'cses-blockcraft-v1:${sha256.convert(utf8.encode(jsonEncode([serverIdentity, companyId, userId, documentId])))}'
      : documentId;
}
