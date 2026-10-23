import 'dart:async';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/collab_paragraph_typing.dart';
import 'package:cses_document_collab/src/editor/core/editor_command_context.dart';
import 'package:cses_document_collab/src/editor/editor_text_attributes.dart';
import 'package:cses_document_collab/src/model/collab_paragraph_style.dart';
import 'package:cses_document_collab/src/model/collab_inline_formula.dart';
import 'package:flutter/foundation.dart';

/// 数据适配器的事务阶段回调；[event] 借用当前事务，不得异步修改它。
typedef EditorTransactionHook = void Function(EditorTransactionValue event);

/// 可选的数据绑定，保持准备→默认格式→校验→输入继承→发布的事务顺序。
/// 回调由同步层持有，不创建或释放编辑器。
///
/// ```dart
/// import 'package:cses_document_collab/cses_document_collab.dart';
/// final binding = EditorSynchronizationBinding(didApply: (event) {});
/// final editor = DocumentEditorController()..attachSynchronization(binding);
/// editor.detachSynchronization(binding);
/// await editor.close();
/// ```
final class EditorSynchronizationBinding {
  /// [prepare] 在默认格式处理前重定位稳定身份，[validate] 在其后执行模型保护。
  /// [didApply] 在本地输入历史维护后提交同步投影；null跳过相应阶段。
  const EditorSynchronizationBinding({this.prepare, this.validate, this.didApply});

  /// 可选的事务身份准备回调。
  final EditorTransactionHook? prepare;

  /// 可选的模型保护回调。
  final EditorTransactionHook? validate;

  /// 可选的本地事务完成回调；远端投影不调用。
  final EditorTransactionHook? didApply;
}

/// 拥有内存正文、输入继承、选区和历史的会话，不创建网络、原生文档或数据库。
///
/// ```dart
/// import 'package:cses_document_collab/cses_document_collab.dart';
/// final editor = DocumentEditorController();
/// // 页面借用editor；移除视图、等待数据绑定任务并卸载绑定后释放。
/// await editor.close();
/// ```
class DocumentEditorController extends ChangeNotifier {
  /// [document] 转交初始文档所有权，null创建空白正文。
  /// [commandContext] 默认独立空服务；视图卸载后由创建方等待close。
  DocumentEditorController({Document? document, EditorCommandContext commandContext = const EditorCommandContext()}) {
    registerEditorTextAttributes({...collabCharacterKeys.values, ...collabTypographyKeys});
    editorState = EditorState(document: document ?? Document.blank(withInitialText: true));
    EditorCommandContext.bind(editorState, commandContext);
    _typing = CollabParagraphTyping(editorState);
    _subscription = editorState.transactionStream.listen(_onTransaction);
  }

  /// 本会话拥有的正文，视图和数据绑定只借用，不另行dispose。
  late final EditorState editorState;
  late final CollabParagraphTyping _typing;
  late final StreamSubscription<EditorTransactionValue> _subscription;
  EditorSynchronizationBinding? _binding;
  Future<void>? _closing;
  bool _closed = false;

  /// 关闭时保存终态上下文，避免释放后回退到另一个活动文档的兼容端口。
  late final EditorCommandContext _closedContext;
  int _projectionDepth = 0;
  int _revision = 0;

  /// 是否已停止接收本地命令，异步回写前必须核对。
  bool get closed => _closed;

  /// 本地已完成的事务数量，远端投影不增加此版本。
  int get revision => _revision;

  /// 当前实例的能力与业务端口。
  EditorCommandContext get commandContext => _closed ? _closedContext : EditorCommandContext.of(editorState);

  /// 挂载唯一的 [binding]；重复挂载或关闭后调用抛出StateError，不创建连接。
  void attachSynchronization(EditorSynchronizationBinding binding) {
    if (_closed || _binding != null) throw StateError('编辑会话已关闭或已绑定同步');
    _binding = binding;
  }

  /// 卸载所属 [binding]；过期或重复卸载不影响其他绑定。
  void detachSynchronization(EditorSynchronizationBinding binding) {
    if (identical(_binding, binding)) _binding = null;
  }

  /// 在[projection]同步更新树的调用阶段跳过输入继承、历史维护与同步回送。
  /// 当前AppFlowy在apply返回Future前完成事务；返回该Future供调用者等待后续收尾，
  /// 不把发布抑制延长到微任务，否则紧随同步回放的本地编辑会被吞掉。
  /// projection须以recordUndo:false写入；异步后续若再次改树须重新进入project。
  /// 调用者负责串行回放、等待完成后再close；关闭或同步异常返回失败Future。
  Future<void> project(Future<void> Function() projection) {
    if (_closed) return Future<void>.error(StateError('编辑会话已关闭'));
    _projectionDepth++;
    try {
      return Future<void>.sync(projection);
    } finally {
      _projectionDepth--;
    }
  }

  /// 将输入历史从 [source] 转移至重定位后的 [target]，供数据绑定稳定身份回放。
  void transferHistory(UpdateOperation source, UpdateOperation target) => _typing.transferHistory(source, target);

  /// 根据 [event] 的阶段执行共同编辑行为，数据绑定只观察本地事务。
  /// 准备后统一解析行内对象历史，使未绑定同步的正文也可执行同一对象命令。
  void _onTransaction(EditorTransactionValue event) {
    if (_closed || _projectionDepth != 0) return;
    final binding = _binding;
    if (event.$1 == TransactionTime.before) {
      binding?.prepare?.call(event);
      resolveCollabInlineFormulaCommands(editorState, event.$2);
      if (event.$3.recordUndo && !event.$3.isRedo) synchronizeParagraphDefaults(editorState, event.$2);
      binding?.validate?.call(event);
      _typing.before(event.$2, event.$3);
    } else {
      _typing.after(event.$2, event.$3);
      binding?.didApply?.call(event);
      _revision++;
      notifyListeners();
    }
  }

  /// 同步拒绝新命令并释放正文；订阅注销结果由close等待，重复调用安全。
  @override
  void dispose() {
    if (_closed) return;
    _closedContext = EditorCommandContext.of(editorState);
    _closed = true;
    _binding = null;
    editorState.editable = false;
    _closing = _subscription.cancel();
    _typing.dispose();
    editorState.dispose();
    EditorCommandContext.unbind(editorState);
    super.dispose();
  }

  /// 等待订阅注销；调用方须先卸载视图、完成投影并解绑，重复调用共享释放结果。
  Future<void> close() {
    dispose();
    return _closing!;
  }
}
