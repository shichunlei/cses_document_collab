import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:cses_mobile_collab_demo/src/demo/cses_connection_settings.dart';
import 'package:flutter_test/flutter_test.dart';

/// Existing installations must reopen the same partition after package extraction.
void main() {
  test('package cache identity matches the authenticated demo contract', () {
    const old = CsesConnectionSettings(
      websocketUrl: 'wss://example.test/ws',
      cookieId: 'old-cookie',
      companyId: 'company',
      userId: 'user',
      documentId: 'doc',
    );
    const config = CollabDocumentConfig(
      documentId: 'doc',
      serverIdentity: 'wss://example.test/ws',
      companyId: 'company',
      userId: 'user',
      databasePath: '/host/updates.sqlite',
    );
    expect(config.cacheDocumentId, old.cacheDocumentId);
    expect(config.cacheDocumentId, isNot(contains(old.cookieId)));
  });
}
