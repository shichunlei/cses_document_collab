import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/native/collab_runtime.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 将正式文档身份和宿主链接构造器绑定到一个借用编辑器，不修改正文或历史。
/// 创建方须先[dispose]再释放编辑器；关闭后旧菜单和迟到复制提示失效。
///
/// ```dart
/// import 'package:appflowy_editor/appflowy_editor.dart';
/// import 'package:cses_document_collab/src/editor/collab_paragraph_links.dart';
/// final editor = EditorState.blank();
/// final links = CollabParagraphLinks(editor: editor, documentId: 'doc-1',
///   buildLink: (doc, block) => Uri.https('example.com', '/doc/$doc',
///     {'blockId': block}).toString());
/// // 正式页面中的更多菜单通过of(editor)借用该绑定。
/// links.dispose();
/// editor.dispose();
/// ```
final class CollabParagraphLinks {
  /// [editor]和[buildLink]由外部持有，不转移资源所有权；[documentId]为正式文档ID。
  /// [buildLink]同步接收文档ID及稳定块ID，返回完整链接；异常由菜单报告。
  /// 同一编辑器只能持有一个活动绑定，否则抛出[StateError]。
  CollabParagraphLinks({required this.editor, required this.documentId, required this.buildLink}) {
    if (_attached[editor] != null) throw StateError('编辑器已有段落链接绑定');
    _attached[editor] = this;
  }

  /// 借用编辑器，必须晚于本绑定释放。
  final EditorState editor;

  /// 正式文档ID，不使用本地缓存分区键。
  final String documentId;

  /// 借用宿主的同步构造器，负责环境域名及路由编码。
  final String Function(String documentId, String blockId) buildLink;

  /// 绑定随编辑器身份存活，不延长其生命周期。
  static final _attached = Expando<CollabParagraphLinks>('collab-paragraph-links');

  /// 返回借用[editor]的绑定；草稿或未配置宿主能力时为null。
  static CollabParagraphLinks? of(EditorState editor) => _attached[editor];

  /// 检查借用[node]仍属于当前编辑器且具有正式稳定ID，不调用宿主或写入文档。
  bool supports(Node node) =>
      !editor.isDisposed &&
      identical(of(editor), this) &&
      documentId.isNotEmpty &&
      node.attributes['cses_collab_block_id'] is String &&
      (node.attributes['cses_collab_block_id'] as String).isNotEmpty &&
      identical(editor.getNodeAtPath(node.path), node);

  /// 使用借用[context]提示复制借用[node]的段落链接；只读及块锁不禁止复制。
  /// [isCurrent]可选检查菜单权限/快照是否仍有效，默认仅检查绑定、节点和宿主。
  /// 调用方须等待菜单退场并校验权限/快照；无效绑定或节点直接返回。
  /// Future在系统剪贴板完成后结束；空链接抛出[StateError]，平台及构造失败向菜单传播。
  /// 迟到结果在关闭、权限或宿主变化、节点替换后不显示提示；不恢复正文键盘。
  Future<void> copy(BuildContext context, Node node, {bool Function()? isCurrent}) async {
    if (!context.mounted || !supports(node) || !(isCurrent?.call() ?? true)) return;
    final services = CollabRuntime.services;
    final editable = editor.editable;
    final link = buildLink(documentId, node.attributes['cses_collab_block_id'] as String);
    if (link.trim().isEmpty) throw StateError('段落链接为空');
    await Clipboard.setData(ClipboardData(text: link));
    if (context.mounted &&
        supports(node) &&
        (isCurrent?.call() ?? true) &&
        editor.editable == editable &&
        identical(CollabRuntime.services, services)) {
      ScaffoldMessenger.maybeOf(context)
        ?..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('段落链接已复制')));
    }
  }

  /// 移除当前绑定；重复关闭安全，不释放借用资源或影响后续新绑定。
  void dispose() {
    if (identical(of(editor), this)) _attached[editor] = null;
  }
}
