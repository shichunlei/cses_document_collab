import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:flutter_test/flutter_test.dart';

/// 创建独立于 Common 的文档配置；[server]、[company]、[user]、[doc] 决定缓存身份。
CollabDocumentConfig _config({
  String server = 'wss://example.test/ws',
  String company = 'company',
  String user = 'user',
  String doc = 'doc',
}) => CollabDocumentConfig(
  documentId: doc,
  serverIdentity: server,
  companyId: company,
  userId: user,
  databasePath: '/host/updates.sqlite',
);

/// 删除宿主旧配置后，包仍须使用既有分区，不合并不同服务端、企业或用户的离线更新。
void main() {
  test('document config retains the exact legacy cache partition', () {
    // 固定迁移前的实际键，避免两个相同的计算实现一起出错却仍互相相等。
    expect(
      _config().cacheDocumentId,
      'cses-blockcraft-v1:e8cab2376c3412af932d2e24ad2ecd09390c6579c570092b0a263cd6b2fe1d0b',
    );
  });

  test('document cache isolates server company user and document', () {
    final key = _config().cacheDocumentId;
    for (final other in [
      _config(server: 'wss://other.test/ws'),
      _config(company: 'other'),
      _config(user: 'other'),
      _config(doc: 'other'),
    ]) {
      expect(other.cacheDocumentId, isNot(key));
    }
  });
}
