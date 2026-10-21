import 'package:flutter/foundation.dart';
import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/model/collab_host_services.dart';
import 'package:cses_document_collab/src/editor/core/editor_configuration.dart';

/// 一个编辑实例的业务端口与能力，不持有网络或数据库资源。
/// 未绑定的历史组件沿用兼容端口，新独立会话显式绑定空服务。
///
/// ```dart
/// import 'package:cses_document_collab/cses_document_collab.dart';
/// final context = EditorCommandContext(configuration: EditorConfiguration.local, localOnly: true);
/// final editor = DocumentEditorController(commandContext: context);
/// await editor.close();
/// ```
class EditorCommandContext {
  /// [configuration] 默认原文档预设，[localOnly]标记纯本地装配且默认false。
  /// [services] 为null时使用空端口，与同步绑定独立。
  /// [pastePlainText] 可接管纯文本粘贴，借用所属会话且必须自行校验迟到结果。
  const EditorCommandContext({
    this.configuration = EditorConfiguration.document,
    this.localOnly = false,
    CollabHostServices? services,
    this.pastePlainText,
  }) : _services = services ?? const CollabHostServices(),
       _legacy = false;

  /// 历史适配器与未绑定组件的兼容上下文，不用于独立本地会话。
  const EditorCommandContext.legacy()
    : configuration = EditorConfiguration.document,
      localOnly = false,
      _services = const CollabHostServices(),
      pastePlainText = null,
      _legacy = true;

  final CollabHostServices _services;
  final bool _legacy;

  /// 不随网络状态变化的编辑能力配置。
  final EditorConfiguration configuration;

  /// 纯本地会话不使用协同块装饰或业务服务，不表示能力集合。
  final bool localOnly;

  /// 可选纯文本粘贴命令，返回Future在事务完成后结束。
  final Future<void> Function()? pastePlainText;

  static final _contexts = Expando<EditorCommandContext>('editor-command-context');

  /// 此会话借用的业务端口；兼容模式保留原宿主切换检测语义。
  CollabHostServices get services => _legacy ? legacyEditorServices?.call() ?? _services : _services;

  /// 获取 [editor] 的上下文，历史裸EditorState使用兼容模式。
  static EditorCommandContext of(EditorState editor) => _contexts[editor] ?? const EditorCommandContext.legacy();

  /// 为 [editor] 绑定 [context]；由文档所有者在释放编辑器时清除。
  static void bind(EditorState editor, EditorCommandContext context) => _contexts[editor] = context;

  /// 向[editor]所属实例报告[message]、[error]及[stackTrace]，并携带可选[tag]。
  /// editor为空或已释放时只保留控制台诊断，避免迟到失败进入其他活动文档的服务。
  static void report(
    EditorState? editor,
    String message, {
    required Object error,
    required StackTrace stackTrace,
    String? tag,
  }) {
    if (editor == null || editor.isDisposed) {
      debugPrint('$tag: $message: $error\n$stackTrace');
      return;
    }
    of(editor).services.report(message, error, stackTrace, tag);
  }

  /// 清除 [editor] 的借用上下文，不关闭任何宿主资源。
  static void unbind(EditorState editor) => _contexts[editor] = null;
}

/// 旧组件的服务解析器，仅由原生装配层安装，不从包级公开入口导出。
/// 新编辑会话显式绑定自身上下文，不读取此兼容端口。
CollabHostServices Function()? legacyEditorServices;
