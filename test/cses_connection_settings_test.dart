import 'package:cses_mobile_collab_demo/src/demo/cses_connection_settings.dart';
import 'package:flutter_test/flutter_test.dart';

/// 生成可选 [cookie]、[company]、[user]、[doc]、[url] 的本地测试会话。
CsesConnectionSettings _settings({
  String cookie = 'cookie',
  String company = 'company',
  String user = 'user',
  String doc = 'doc',
  String url = 'wss://example.test/ws',
}) => CsesConnectionSettings(
  websocketUrl: url,
  cookieId: cookie,
  companyId: company,
  userId: user,
  documentId: doc,
);

/// 验证地址边界和缓存分区不依赖会话凭证轮换。
void main() {
  test('valid full deployment URL and nonempty login context', () {
    expect(_settings().validate, returnsNormally);
  });
  test(
    'cache survives cookie rotation and isolates tenant user document server',
    () {
      final key = _settings().cacheDocumentId;
      expect(key, startsWith('cses-blockcraft-v1:'));
      expect(_settings(cookie: 'rotated').cacheDocumentId, key);
      for (final other in [
        _settings(company: 'other'),
        _settings(user: 'other'),
        _settings(doc: 'other'),
        _settings(url: 'wss://other.test/ws'),
      ]) {
        expect(other.cacheDocumentId, isNot(key));
      }
      expect(key, isNot(contains('cookie')));
    },
  );
  test('rejects missing context, invalid doc and unsupported URL queries', () {
    for (final settings in [
      _settings(cookie: ' '),
      _settings(doc: ''),
      _settings(doc: 'a' * 129),
      _settings(url: 'https://example.test/ws'),
      _settings(url: 'wss://example.test/ws?cookieId=secret'),
      _settings(url: 'wss://example.test/ws?deployment=a'),
      _settings(url: 'wss://user:secret@example.test/ws'),
    ]) {
      expect(settings.validate, throwsFormatException);
    }
  });
}
