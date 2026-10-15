import 'package:cses_document_collab/src/model/collab_meeting_card_data.dart';
import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/model/collab_host_services.dart';
import 'package:cses_document_collab/src/editor/editor_shortcut_toolbar.dart';
import 'package:cses_document_collab/src/native/collab_runtime.dart';
import 'package:cses_document_collab/src/model/collab_meeting.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

/// 为正式 meeting 注册可选中的无正文组件；显示引用快照，按宿主详情显示状态，加入/查看按钮通知宿主，底部删除仅移除文档引用。
/// ```dart
/// import 'package:cses_document_collab/src/editor/collab_meeting_block.dart';
/// final builder = CollabMeetingBlockComponentBuilder();
/// // 在 AppFlowyEditor 的 blockComponentBuilders 中以 'meeting' 注册。
/// ```
class CollabMeetingBlockComponentBuilder extends BlockComponentBuilder {
  /// 创建无资源所有权的会议引用组件工厂，编辑器由页面持有。
  CollabMeetingBlockComponentBuilder();

  /// 拒绝正文 Delta 与子块，以保持桌面 void 结构。
  @override
  BlockComponentValidate get validate =>
      (node) => node.delta == null && node.children.isEmpty;

  /// 使用借用 [context] 的节点与配置创建组件，不写入共享属性。
  @override
  BlockComponentWidget build(BlockComponentContext context) => _MeetingBlock(
    key: context.node.key,
    node: context.node,
    configuration: configuration,
  );
}

/// 借用 AppFlowy 节点展示会议引用，无定时器、连接或输入控制器。
class _MeetingBlock extends BlockComponentStatefulWidget {
  /// [key] 控制身份与状态复用，[node] 与 [configuration] 均由编辑器持有。
  const _MeetingBlock({
    super.key,
    required super.node,
    required super.configuration,
  });

  /// 创建整块选区代理，编辑器仍由调用方持有。
  @override
  createState() => _MeetingBlockState();
}

/// 为无正文块提供完整矩形选区与远端选中展示。
class _MeetingBlockState extends State<_MeetingBlock> with SelectableMixin {
  /// 内部视觉边界，随本 Widget 释放，不绑定编辑输入。
  final _bodyKey = GlobalKey();

  /// 导航或删除期间拒绝同一卡片重复操作。
  bool _busy = false;

  /// 当前本地详情的会议ID；换引用/重试后重置，不写回文档。
  String? _detailMeetingId;

  /// 当前详情所借用的宿主，身份变化使请求失效。
  CollabHostServices? _detailServices;

  /// 当前展示请求；FutureBuilder负责观察，不拥有宿主的网络资源。
  Future<CollabMeetingCardData?>? _detailFuture;

  /// 请求代次，销毁或换引用后拒绝旧响应及错误提示。
  int _detailGeneration = 0;

  /// 在借用 [context] 内构建非交互卡片背景，只为主按钮和删除按钮绑定事件。
  /// 状态/标题/主持人等只供本地展示；预览隐藏删除，按钮操作不自动弹正文键盘。
  @override
  Widget build(BuildContext context) {
    final editor = context.read<EditorState>();
    final node = widget.node;
    final id = node.attributes['cses_collab_block_id'] as String? ?? node.id;
    final values = CollabMeeting.readAttributes(node.attributes);
    final services = CollabRuntime.services;
    final meetingId = values.string('meetingId');
    final future = _detailsFor(editor, id, meetingId, services);
    final child = Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: FutureBuilder<CollabMeetingCardData?>(
        key: ValueKey((meetingId, services)),
        future: future,
        builder: (context, snapshot) {
          final loading =
              future != null &&
              snapshot.connectionState != ConnectionState.done;
          final data = future == null || loading || snapshot.hasError
              ? null
              : snapshot.data;
          final unavailable =
              future != null && !loading && !snapshot.hasError && data == null;
          return ListenableBuilder(
            listenable: editor.editableNotifier,
            builder: (context, _) => _MeetingCardView(
              key: ValueKey('collab-meeting-$id'),
              blockId: id,
              title: data?.title ?? values.string('title'),
              number: data?.number ?? values.string('number'),
              data: data,
              loading: loading,
              failed: snapshot.hasError,
              unavailable: unavailable,
              busy: _busy,
              onOpen:
                  _busy ||
                      loading ||
                      snapshot.hasError ||
                      unavailable ||
                      data?.state == CollabMeetingCardState.deleted ||
                      meetingId.trim().isEmpty ||
                      services.onMeetingCardTap == null
                  ? null
                  : () => _openMeeting(editor, id, meetingId, services, data),
              onDelete: editor.editable
                  ? (_busy
                        ? null
                        : () => _deleteReference(
                            editor,
                            id,
                            values.properties,
                            services,
                          ))
                  : null,
              showDelete: editor.editable,
              onRetry: snapshot.hasError && !_busy ? _retryDetails : null,
            ),
          );
        },
      ),
    );
    return BlockSelectionContainer(
      node: node,
      delegate: this,
      listenable: editor.selectionNotifier,
      remoteSelection: editor.remoteSelections,
      blockColor: editor.editorStyle.selectionColor,
      supportTypes: const [BlockSelectionType.block],
      selectionAboveBlock: true,
      child: KeyedSubtree(key: _bodyKey, child: child),
    );
  }

  /// 为借用[editor]中稳定块[id]的[meetingId]复用单次请求；[services]变化时重新加载。
  /// 未提供加载器返回null，仅展示共享引用；网络资源仍由宿主持有。
  Future<CollabMeetingCardData?>? _detailsFor(
    EditorState editor,
    String id,
    String meetingId,
    CollabHostServices services,
  ) {
    if (_detailMeetingId == meetingId && identical(_detailServices, services)) {
      return _detailFuture;
    }
    _detailMeetingId = meetingId;
    _detailServices = services;
    final generation = ++_detailGeneration;
    _detailFuture = services.loadMeetingCard == null || meetingId.trim().isEmpty
        ? null
        : _loadDetails(editor, id, meetingId, services, generation);
    return _detailFuture;
  }

  /// 检查借用[editor]中稳定块[id]是否仍引用[meetingId]，且[services]/[generation]仍属于当前请求。
  bool _isCurrentRequest(
    EditorState editor,
    String id,
    String meetingId,
    CollabHostServices services,
    int generation,
  ) {
    if (!mounted ||
        editor.isDisposed ||
        generation != _detailGeneration ||
        !identical(services, CollabRuntime.services)) {
      return false;
    }
    final node = findCollabMeeting(editor, id);
    return node != null &&
        CollabMeeting.readAttributes(node.attributes).string('meetingId') ==
            meetingId;
  }

  /// 从借用[services]加载[editor]中稳定块[id]的[meetingId]详情；[generation]隔离迟到响应。
  /// 当前请求异常报告原宿主后交FutureBuilder显示重试，失效结果/错误直接忽略。
  Future<CollabMeetingCardData?> _loadDetails(
    EditorState editor,
    String id,
    String meetingId,
    CollabHostServices services,
    int generation,
  ) async {
    try {
      final data = await services.loadMeetingCard!(meetingId);
      if (!_isCurrentRequest(editor, id, meetingId, services, generation)) {
        return null;
      }
      if (data != null && data.meetingId != meetingId) {
        throw const FormatException('会议详情身份不匹配');
      }
      return data;
    } catch (error, stack) {
      if (!_isCurrentRequest(editor, id, meetingId, services, generation)) {
        return null;
      }
      services.report('加载会议详情失败', error, stack, 'DocCollab');
      rethrow;
    }
  }

  /// 废弃当前详情请求，下一次构建重新读取；不修改共享引用或恢复正文键盘。
  void _retryDetails() {
    if (!mounted) return;
    setState(() => _detailMeetingId = null);
  }

  /// 销毁时使仍在宿主执行的请求失效；不关闭借用的网络资源。
  @override
  void dispose() {
    ++_detailGeneration;
    super.dispose();
  }

  /// 在借用[editor]中为稳定块[id]的[meetingId]调用宿主[services]；[data]是当前详情，可为空。
  /// 回调期间拒绝重复导航/删除，使用当前展示的业务标题/编号；只通知宿主，不额外请求详情，关闭键盘后不恢复。
  Future<void> _openMeeting(
    EditorState editor,
    String id,
    String meetingId,
    CollabHostServices services,
    CollabMeetingCardData? data,
  ) async {
    if (_busy ||
        !mounted ||
        editor.isDisposed ||
        !identical(services, CollabRuntime.services)) {
      return;
    }
    final current = findCollabMeeting(editor, id);
    final callback = services.onMeetingCardTap;
    if (current == null || callback == null) return;
    final values = CollabMeeting.readAttributes(current.attributes);
    if (meetingId.trim().isEmpty ||
        values.string('meetingId') != meetingId ||
        (data != null && data.meetingId != meetingId)) {
      return;
    }
    setState(() => _busy = true);
    try {
      await runEditorHeaderAction<void>(context, editor, () async {
        if (!mounted ||
            editor.isDisposed ||
            !identical(services, CollabRuntime.services)) {
          return;
        }
        await callback(
          meetingId,
          data?.title ?? values.string('title'),
          data?.number ?? values.string('number'),
        );
      }, canRestore: () => false);
    } catch (error, stack) {
      services.report('打开会议失败', error, stack, 'DocCollab');
      if (mounted && identical(services, CollabRuntime.services)) {
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(const SnackBar(content: Text('打开会议失败，请重试')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 在借用[editor]中删除稳定[id]的会议引用，[expected]为按钮展示时的完整属性JSON。
  /// [services]是原宿主，失效/撤权不执行；成功直接移除块，可撤销，不调用详情回调或打开键盘。
  Future<void> _deleteReference(
    EditorState editor,
    String id,
    String expected,
    CollabHostServices services,
  ) async {
    if (_busy ||
        !mounted ||
        editor.isDisposed ||
        !editor.editable ||
        !identical(services, CollabRuntime.services)) {
      return;
    }
    setState(() => _busy = true);
    try {
      final deleted = await runEditorHeaderAction<bool>(
        context,
        editor,
        () => deleteCollabMeeting(editor, id, expected: expected),
        canRestore: () => false,
      );
      if (deleted == false &&
          mounted &&
          identical(services, CollabRuntime.services)) {
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(const SnackBar(content: Text('引用已变化或不可编辑，请重试')));
      }
    } catch (error, stack) {
      services.report('删除会议引用失败', error, stack, 'DocCollab');
      if (mounted && identical(services, CollabRuntime.services)) {
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(const SnackBar(content: Text('删除失败，请重试')));
      }
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
  Rect? getCursorRectInPosition(
    Position position, {
    bool shiftWithBaseOffset = false,
  }) => getBlockRect();

  /// [selection] 对应完整矩形，[shiftWithBaseOffset] 保持组件内坐标约定。
  @override
  List<Rect> getRectsInSelection(
    Selection selection, {
    bool shiftWithBaseOffset = false,
  }) => [getBlockRect()];

  /// [start]/[end] 的拖动范围总是映射为无正文块的完整选区。
  @override
  Selection getSelectionInRange(Offset start, Offset end) =>
      Selection.single(path: widget.node.path, startOffset: 0, endOffset: 1);

  /// 将 [offset] 转为全局坐标，[shiftWithBaseOffset] 不改变组件原点约定。
  @override
  Offset localToGlobal(Offset offset, {bool shiftWithBaseOffset = false}) =>
      (context.findRenderObject() as RenderBox).localToGlobal(offset);
}

/// 会议卡片的本地展示；背景与标题没有点击回调，两个操作分置底部两侧。
class _MeetingCardView extends StatelessWidget {
  /// [key]控制身份与状态复用，[blockId]为稳定块身份，[title]/[number]为有效展示字段，[data]为可空业务快照。
  /// [loading]/[failed]/[unavailable]分别表示加载、失败、会议不存在；[busy]屏蔽重复操作。
  /// [onOpen]仅绑定加入/查看按钮；[showDelete]由权限决定，[onDelete]为空时禁用删除；
  /// [onRetry]为空不显示重试，回调及其业务资源均由调用方持有。
  const _MeetingCardView({
    super.key,
    required this.blockId,
    required this.title,
    required this.number,
    required this.data,
    required this.loading,
    required this.failed,
    required this.unavailable,
    required this.busy,
    required this.onOpen,
    required this.showDelete,
    required this.onDelete,
    required this.onRetry,
  });

  /// 稳定引用块身份，用于独立按钮键。
  final String blockId;

  /// 当前标题，空名展示未命名会议。
  final String title;

  /// 当前编号，仅本地展示。
  final String number;

  /// 宿主业务快照，未提供或加载中为空。
  final CollabMeetingCardData? data;

  /// 正在读取当前业务详情。
  final bool loading;

  /// 当前业务请求失败，主按钮不可用。
  final bool failed;

  /// 宿主确认会议不存在，主按钮不可用。
  final bool unavailable;

  /// 正在打开会议或删除引用。
  final bool busy;

  /// 主按钮回调，null禁用按钮。
  final VoidCallback? onOpen;

  /// 编辑权限决定是否显示删除入口。
  final bool showDelete;

  /// 独立删除回调，null禁用按钮。
  final VoidCallback? onDelete;

  /// 失败重试回调，null不显示。
  final VoidCallback? onRetry;

  /// 在借用[context]内按状态绘制边框、强调条、淡底色及状态标签；窄屏信息自然换行。
  @override
  Widget build(BuildContext context) {
    final state = data?.state ?? CollabMeetingCardState.unknown;
    final color = switch (state) {
      CollabMeetingCardState.notStarted => const Color(0xFF4A7AFE),
      CollabMeetingCardState.inProgress => const Color(0xFF00B42A),
      CollabMeetingCardState.paused => const Color(0xFFFF7D00),
      _ => const Color(0xFF86909C),
    };
    final label = loading
        ? '加载中'
        : failed
        ? '状态加载失败'
        : unavailable
        ? '会议不存在'
        : state.label;
    final action =
        state == CollabMeetingCardState.completed ||
            state == CollabMeetingCardState.canceled
        ? '查看会议'
        : '加入会议';
    final time = data?.startTime?.toLocal();
    return ExcludeFocus(
      child: Container(
        key: ValueKey('meeting-card-surface-$blockId'),
        decoration: BoxDecoration(
          border: Border.all(color: color.withValues(alpha: .3)),
          borderRadius: BorderRadius.circular(8),
          gradient: LinearGradient(
            colors: [color.withValues(alpha: .06), Colors.white],
            stops: const [0, .65],
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: 3,
              child: ColoredBox(
                key: ValueKey('meeting-card-accent-$blockId'),
                color: color,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(
                        Icons.groups_outlined,
                        color: Color(0xFF4A7AFE),
                        size: 22,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          title.isEmpty ? '未命名会议' : title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF1F2329),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Padding(
                    padding: const EdgeInsets.only(left: 32),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: color.withValues(alpha: .1),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            '● $label',
                            style: TextStyle(
                              fontSize: 12,
                              color: color,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                        if (time != null)
                          _meta(
                            '${_twoDigits(time.month)}-${_twoDigits(time.day)} ${_twoDigits(time.hour)}:${_twoDigits(time.minute)}',
                          ),
                        if (data?.moderatorName?.isNotEmpty == true)
                          _meta(data!.moderatorName!),
                        if (data?.memberCount != null)
                          _meta('${data!.memberCount}人'),
                        if (number.isNotEmpty) _meta('会议编号：$number'),
                        if (onRetry != null)
                          TextButton(
                            onPressed: onRetry,
                            child: const Text('重试'),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  OverflowBar(
                    alignment: showDelete
                        ? MainAxisAlignment.spaceBetween
                        : MainAxisAlignment.end,
                    overflowAlignment: OverflowBarAlignment.end,
                    spacing: 8,
                    overflowSpacing: 8,
                    children: [
                      if (showDelete)
                        TextButton.icon(
                          key: ValueKey('meeting-delete-$blockId'),
                          onPressed: onDelete,
                          style: TextButton.styleFrom(
                            foregroundColor: const Color(0xFF86909C),
                          ),
                          icon: const Icon(Icons.delete_outline, size: 18),
                          label: const Text('删除引用'),
                        ),
                      FilledButton(
                        key: ValueKey('meeting-open-$blockId'),
                        onPressed: onOpen,
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF4A7AFE),
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(6),
                          ),
                        ),
                        child: busy
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : Text(action),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 为本地元信息[value]提供小号中性色文本，允许窄屏按Wrap换行。
  Widget _meta(String value) => Text(
    value,
    style: const TextStyle(fontSize: 12, color: Color(0xFF8A8F99)),
  );

  /// 将月份、日或时分[value]补齐两位，不依赖宿主本地化包。
  String _twoDigits(int value) => value.toString().padLeft(2, '0');
}
