import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/collab_block_actions.dart';
import 'package:cses_document_collab/src/editor/collab_mention_tap_handler.dart';
import 'package:cses_document_collab/src/editor/collab_task_card_view.dart';
import 'package:cses_document_collab/src/model/collab_host_services.dart';
import 'package:cses_document_collab/src/model/collab_mention_tap.dart';
import 'package:cses_document_collab/src/model/collab_task_card.dart';
import 'package:cses_document_collab/src/model/collab_task_card_data.dart';
import 'package:cses_document_collab/src/native/collab_runtime.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

/// 正式task引用的卡片工厂；借用宿主详情展示任务信息，不直接查询业务接口。
/// ```dart
/// import 'package:cses_document_collab/src/editor/collab_task_card_block.dart';
/// final builder = CollabTaskCardBlockComponentBuilder();
/// // 注册到 AppFlowyEditor.blockComponentBuilders['task']。
/// ```
class CollabTaskCardBlockComponentBuilder extends BlockComponentBuilder {
  /// 创建不拥有编辑器或业务资源的工厂。
  CollabTaskCardBlockComponentBuilder();

  /// 任务卡片必须是无正文、无子块的void引用。
  @override
  BlockComponentValidate get validate =>
      (node) => node.delta == null && node.children.isEmpty;

  /// 使用借用[context]中的节点与配置创建可选中卡片。
  @override
  BlockComponentWidget build(BlockComponentContext context) =>
      _TaskCard(key: context.node.key, node: context.node, configuration: configuration);
}

/// 编辑器拥有节点与配置，组件只管理视觉选区和操作防重入。
class _TaskCard extends BlockComponentStatefulWidget {
  /// [key]控制组件复用；[node]/[configuration]均借用，不释放。
  const _TaskCard({super.key, required super.node, required super.configuration});

  /// 创建不持有网络资源的局部状态。
  @override
  State<_TaskCard> createState() => _TaskCardState();
}

/// 任务引用的整块选区代理，不拥有编辑器。
class _TaskCardState extends State<_TaskCard> with SelectableMixin {
  /// 视觉边界用于整块选区，随组件释放。
  final _bodyKey = GlobalKey();

  /// 本卡片操作期间拒绝重复事件。
  bool _busy = false;

  /// 当前详情所对应的任务，重试时清空；不写共享引用。
  String? _detailTaskId;

  /// 本次详情借用的宿主，改变后原请求失效。
  CollabHostServices? _detailServices;

  /// 当前展示请求，普通重建/导航不重复加载。
  Future<CollabTaskCardData?>? _detailFuture;

  /// 请求代次，销毁和重试后拒绝旧响应。
  int _generation = 0;

  /// 在借用[context]中显示宿主详情与共享标题，更多菜单支持插入正文和删除引用。
  @override
  Widget build(BuildContext context) {
    final editor = context.read<EditorState>();
    final values = CollabTaskCard.read(widget.node.attributes);
    final id = widget.node.attributes['cses_collab_block_id'] as String? ?? widget.node.id;
    final taskId = values.string('taskId');
    return BlockSelectionContainer(
      node: widget.node,
      delegate: this,
      listenable: editor.selectionNotifier,
      remoteSelection: editor.remoteSelections,
      blockColor: editor.editorStyle.selectionColor,
      supportTypes: const [BlockSelectionType.block],
      selectionAboveBlock: true,
      child: KeyedSubtree(
        key: _bodyKey,
        child: ListenableBuilder(
          listenable: editor.editableNotifier,
          builder: (context, _) {
            final services = CollabRuntime.services;
            final future = _detailsFor(editor, id, taskId, services);
            return FutureBuilder<CollabTaskCardData?>(
              key: ValueKey((taskId, services)),
              future: future,
              builder: (context, snapshot) {
                final loading = future != null && snapshot.connectionState != ConnectionState.done;
                final data = future == null || loading || snapshot.hasError ? null : snapshot.data;
                final missing = future != null && !loading && !snapshot.hasError && data == null;
                return CollabTaskCardView(
                  blockId: id,
                  title: values.string('title'),
                  data: data,
                  loading: loading,
                  failed: snapshot.hasError,
                  missing: missing,
                  busy: _busy,
                  readOnly: !editor.editable,
                  onOpen:
                      _busy ||
                          loading ||
                          snapshot.hasError ||
                          missing ||
                          data?.deleted == true ||
                          services.onMentionTap == null
                      ? null
                      : () => _act(editor, id, services, expected: values.properties),
                  onDelete: editor.editable
                      ? () => _act(editor, id, services, expected: values.properties, delete: true)
                      : null,
                  moreActions: editor.editable
                      ? CollabBlockMoreButton(
                          key: ValueKey('task-card-more-$id'),
                          editor: editor,
                          node: widget.node,
                          enabled: !_busy,
                          actions: [
                            (
                              label: '删除任务',
                              key: ValueKey('task-card-delete-$id'),
                              run: () => _act(editor, id, services, expected: values.properties, delete: true),
                            ),
                          ],
                        )
                      : null,
                  onRetry: _retryDetails,
                );
              },
            );
          },
        ),
      ),
    );
  }

  /// 为借用[editor]中稳定块[id]的[taskId]复用请求；[services]变化后重新加载。
  Future<CollabTaskCardData?>? _detailsFor(EditorState editor, String id, String taskId, CollabHostServices services) {
    if (_detailTaskId == taskId && identical(_detailServices, services)) {
      return _detailFuture;
    }
    _detailTaskId = taskId;
    _detailServices = services;
    final generation = ++_generation;
    _detailFuture = services.loadTaskCard == null ? null : _loadDetails(editor, id, taskId, services, generation);
    return _detailFuture;
  }

  /// 检查借用[editor]中块[id]/[taskId]、宿主[services]和请求[generation]是否仍有效。
  bool _isCurrent(EditorState editor, String id, String taskId, CollabHostServices services, int generation) =>
      mounted &&
      !editor.isDisposed &&
      generation == _generation &&
      identical(CollabRuntime.services, services) &&
      editor.getNodeAtPath(widget.node.path) == widget.node &&
      (widget.node.attributes['cses_collab_block_id'] ?? widget.node.id) == id &&
      CollabTaskCard.read(widget.node.attributes).string('taskId') == taskId;

  /// 等待宿主[services]加载[editor]中块[id]的[taskId]详情；[generation]拒绝迟到响应和错误。
  /// 失败报告原宿主，向FutureBuilder抛出供重试；不关闭宿主请求或写协同文档。
  Future<CollabTaskCardData?> _loadDetails(
    EditorState editor,
    String id,
    String taskId,
    CollabHostServices services,
    int generation,
  ) async {
    try {
      final data = await services.loadTaskCard!(taskId);
      if (!_isCurrent(editor, id, taskId, services, generation)) return null;
      if (data != null && data.taskId != taskId) {
        throw const FormatException('任务详情身份不匹配');
      }
      return data;
    } catch (error, stack) {
      if (!_isCurrent(editor, id, taskId, services, generation)) return null;
      services.report('加载任务详情失败', error, stack, 'DocCollab');
      rethrow;
    }
  }

  /// 手动重试只重置本地请求，不修改共享引用。
  void _retryDetails() {
    if (mounted) setState(() => _detailTaskId = null);
  }

  /// 使宿主仍在执行的请求失效，不释放借用网络或编辑器。
  @override
  void dispose() {
    ++_generation;
    super.dispose();
  }

  /// 对借用[editor]中稳定[id]执行操作；[capturedServices]/[expected]为菜单打开时的宿主及属性。
  /// [delete]为true时仅删引用，不调用宿主，旧菜单不得删除远端改过的引用。
  /// 异步完成前校验组件/会话和属性快照，失败由统一交互包装报告；完成后不恢复正文键盘，也不刷新详情。
  Future<void> _act(
    EditorState editor,
    String id,
    CollabHostServices capturedServices, {
    required String expected,
    bool delete = false,
  }) async {
    if (_busy || !mounted || editor.isDisposed || !identical(capturedServices, CollabRuntime.services)) {
      return;
    }
    setState(() => _busy = true);
    try {
      await runCollabMentionInteraction(context, editor, (services) async {
        if (!mounted || editor.isDisposed) return;
        final node = widget.node;
        if ((node.attributes['cses_collab_block_id'] ?? node.id) != id ||
            editor.getNodeAtPath(node.path) != node ||
            CollabTaskCard.read(node.attributes).properties != expected) {
          return;
        }
        final values = CollabTaskCard.read(node.attributes);
        if (delete) {
          if (!editor.editable) return;
          final transaction = editor.transaction..deleteNode(node);
          if (node.parent!.children.length == 1) {
            transaction.insertNode(node.path, paragraphNode());
          }
          if (editor.undoManager.undoStack.isNonEmpty) {
            editor.undoManager.undoStack.last.seal();
          }
          await editor.apply(transaction, withUpdateSelection: false, skipHistoryDebounce: true);
        } else {
          await services.onMentionTap?.call(
            CollabMentionTap(
              type: CollabMentionType.task,
              id: values.string('taskId'),
              name: values.string('title'),
              attributes: values.values,
            ),
          );
        }
      }, restoreFocus: false);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 返回当前节点的整块起点。
  @override
  Position start() => Position(path: widget.node.path);

  /// 返回当前节点的整块终点（虚拟偏移 1）。
  @override
  Position end() => Position(path: widget.node.path, offset: 1);

  /// [offset] 无文本对应关系，任意命中选择整块终点。
  @override
  Position getPositionInOffset(Offset offset) => end();

  /// 无正文光标不闪烁。
  @override
  bool get shouldCursorBlink => false;

  /// 整块选择覆盖视觉区域。
  @override
  CursorStyle get cursorStyle => CursorStyle.cover;

  /// 返回块在组件内的矩形；[shiftWithBaseOffset] 沿用组件局部原点。
  @override
  Rect getBlockRect({bool shiftWithBaseOffset = false}) {
    final outer = context.findRenderObject();
    final inner = _bodyKey.currentContext?.findRenderObject();
    if (outer is! RenderBox || inner is! RenderBox) return Rect.zero;
    return inner.localToGlobal(Offset.zero, ancestor: outer) & inner.size;
  }

  /// [position] 命中整块，[shiftWithBaseOffset] 保持组件内坐标约定。
  @override
  Rect? getCursorRectInPosition(Position position, {bool shiftWithBaseOffset = false}) => getBlockRect();

  /// [selection] 对应完整矩形，[shiftWithBaseOffset] 保持组件内坐标约定。
  @override
  List<Rect> getRectsInSelection(Selection selection, {bool shiftWithBaseOffset = false}) => [getBlockRect()];

  /// [start]/[end] 的拖动范围总是映射为无正文块的完整选区。
  @override
  Selection getSelectionInRange(Offset start, Offset end) =>
      Selection.single(path: widget.node.path, startOffset: 0, endOffset: 1);

  /// 将 [offset] 转为全局坐标，[shiftWithBaseOffset] 不改变组件原点约定。
  @override
  Offset localToGlobal(Offset offset, {bool shiftWithBaseOffset = false}) =>
      (context.findRenderObject() as RenderBox).localToGlobal(offset);
}
