import 'package:cses_common/network/http/client/http_manager.dart';
import 'package:cses_common/runtime/context/context.dart';
import 'package:cses_common/runtime/session/user.dart';
import 'package:cses_document_collab/cses_document_collab.dart'
    show DocumentMetadata, DocumentMetadataPatch, DocumentMetadataService;

/// 复用Common HTTP的鉴权、域名、拦截器，对齐桌面头部读写与权限。
/// 实例绑定创建时的账号、企业与cookie；不拥有HTTP客户端，登录切换前由宿主等待请求结束。
///
/// ```dart
/// import 'package:cses_mobile_collab_demo/src/demo/cses_document_metadata_service.dart';
/// import 'package:cses_document_collab/cses_document_collab.dart' show DocumentMetadataPatch;
/// Future<void> renameAfterCommonLogin(String id) async {
///   final service = CsesDocumentMetadataService();
///   final detail = await service.load(id);
///   if (detail.canRename) await service.update(id, const DocumentMetadataPatch.rename('新标题'));
/// }
/// ```
class CsesDocumentMetadataService implements DocumentMetadataService {
  /// 在Common登录完成后创建，捕获当前账号/企业/会话；不发请求，宿主切换账号前须等待文档关闭。
  CsesDocumentMetadataService()
    : _userId = User().userId,
      _companyId = User().companyId,
      _cookie = ctx.cookieId;

  /// 创建时的用户ID；null或空值不能发业务请求。
  final String? _userId;

  /// 创建时的企业ID，用于隔离账号上下文变更。
  final String _companyId;

  /// 创建时的会话标识；只在本服务检查，不进入协同数据。
  final String? _cookie;

  /// 请求前后确认登录身份；缺少登录或上下文变化时抛FormatException，阻止旧会话响应写回。
  void _checkSession() {
    if (_userId == null ||
        _userId.isEmpty ||
        _cookie == null ||
        User().userId != _userId ||
        User().companyId != _companyId ||
        ctx.cookieId != _cookie) {
      throw const FormatException('登录状态已变化，请重新打开文档');
    }
  }

  /// [path] 是业务路由，[params] 是仅含本次字段的请求参数，均经Common公共封装发送。
  /// Future仅在收到标准成功Map且会话仍一致时完成；业务拒绝/格式错误抛FormatException，网络异常透传。
  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> params,
  ) async {
    _checkSession();
    final response = await HttpManager.getInstance().post(path, params: params);
    _checkSession();
    final data = response.data;
    if (data is! Map || data['isSuccess'] != true) {
      throw const FormatException('文档业务请求失败');
    }
    return Map<String, dynamic>.from(data);
  }

  /// 读取 [documentId] 的详情与权限；正式ID不能为空，返回保留桌面原字段的快照。
  /// Future等待两次Common请求；权限兼容rename缺失，身份变更/格式失败或网络错误向调用方抛出。
  @override
  Future<DocumentMetadata> load(String documentId) async {
    final detail = await _post('/doc/document/view', {'id': documentId});
    if (detail['id'] != documentId || detail['name'] is! String) {
      throw const FormatException('文档详情格式错误');
    }
    final permission = await _post('/doc/permission/read', {'id': documentId});
    final owner = detail['owner'];
    final localUser = detail['localUser'];
    final abilities = permission['abilities'];
    // 与桌面头部一致：图标/封面需要 owner 级角色；名称需实际 owner 身份。
    // 桌面 canRenameDocument 仅在 rename 明确为 false 时禁止改名；
    // 旧响应缺少 abilities/rename 时仍允许所有者，不能强制要求 true。
    final role = localUser is Map ? localUser['role'] : null;
    return DocumentMetadata(
      id: documentId,
      name: detail['name'] as String,
      icon: _object(detail['icon']),
      banner: _object(detail['banner']),
      canChangeAppearance: role is num && role >= 1000,
      canRename:
          owner is Map &&
          owner['id'] == _userId &&
          (abilities is! Map || abilities['rename'] != false),
    );
  }

  /// 将业务 [value] Map复制为字符串键Map；null保持未设置，非Map或非法键抛类型错误。
  Map<String, dynamic>? _object(Object? value) =>
      value == null ? null : Map<String, dynamic>.from(value as Map);

  /// 向固定 [documentId] 写入单字段 [patch]；null图标/封面使用移除路由，其他字段使用modify。
  /// Future仅在业务ACK成功且身份未变化时完成；失败透传给控制器，不做本地乐观更新。
  @override
  Future<void> update(String documentId, DocumentMetadataPatch patch) async {
    if (patch.changesIcon && patch.icon == null) {
      await _post('/doc/document/icon/remove', {'id': documentId});
    } else if (patch.changesBanner && patch.banner == null) {
      await _post('/doc/document/banner/remove', {'id': documentId});
    } else {
      await _post('/doc/document/modify', {
        'id': documentId,
        if (patch.name != null) 'name': patch.name,
        if (patch.changesIcon) 'icon': patch.icon,
        if (patch.changesBanner) 'banner': patch.banner,
      });
    }
  }
}
