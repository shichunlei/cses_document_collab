import 'package:cses_document_collab/src/editor/core/editor_command_context.dart';
import 'dart:async';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/collab_block_actions.dart';
import 'package:cses_document_collab/src/model/collab_host_services.dart';
import 'package:cses_document_collab/src/model/collab_kr.dart';
import 'package:cses_document_collab/src/ui/modal/collab_card_frame.dart';
import 'package:cses_document_collab/src/ui/modal/collab_card_header.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

/// 正式KR列表的工厂；编辑器拥有节点，宿主拥有业务查询。
/// ```dart
/// import 'package:cses_document_collab/src/editor/collab_kr_block.dart';
/// final builder = CollabKrBlockComponentBuilder();
/// // 注册到AppFlowyEditor.blockComponentBuilders['kr-list']。
/// ```
class CollabKrBlockComponentBuilder extends BlockComponentBuilder {
  /// 创建不持有请求资源的工厂。
  CollabKrBlockComponentBuilder();

  /// KR引用必须没有正文和子块。
  @override
  BlockComponentValidate get validate =>
      (node) => node.delta == null && node.children.isEmpty;

  /// 使用借用[context]中的节点和配置构建列表。
  @override
  BlockComponentWidget build(BlockComponentContext context) =>
      _KrBlock(key: context.node.key, node: context.node, configuration: configuration);
}

/// 只持有本地列表状态，不释放宿主资源。
class _KrBlock extends BlockComponentStatefulWidget {
  /// [key]控制身份复用；[node]和[configuration]由编辑器持有。
  const _KrBlock({super.key, required super.node, required super.configuration});

  /// 创建随块释放的局部状态。
  @override
  createState() => _KrBlockState();
}

/// 分页、错误及选区只影响本块；换会议或宿主后旧请求全部失效。
class _KrBlockState extends State<_KrBlock> with SelectableMixin {
  /// 实际选区边界，由组件持有。
  final _bodyKey = GlobalKey();

  /// 本地展示结果，不写共享文档。
  List<CollabKrTopic> _topics = const [];

  /// 首次请求及重试状态。
  bool _loading = false;

  /// 失败提示，null表示未失败。
  String? _error;

  /// 借用宿主，变化时重新加载。
  CollabHostServices? _services;

  /// 当前会议引用。
  String? _meeting;

  /// 请求失效代次，防止迟到结果污染新引用。
  int _generation = 0;

  /// 每个主题独立防重入。
  final Set<String> _paging = {};

  /// 服务端返回空页后停止分页，避免无效重复请求。
  final Set<String> _ended = {};

  /// 分页失败主题，可单独重试。
  final Set<String> _pageErrors = {};

  /// 当前点选的主题/KR身份，仅本地持有；null隐藏转换按钮。
  (String, String)? _selectedKr;

  /// 待办事务防重入。
  bool _converting = false;

  /// 在借用[context]中展示主题、分页和公共块操作；只读仍可加载但不转换。
  @override
  Widget build(BuildContext context) {
    final editor = context.read<EditorState>();
    final services = EditorCommandContext.of(editor).services;
    final meeting = readCollabKr(widget.node.attributes).string('meetingId');
    if (_meeting != meeting || !identical(_services, services)) {
      _selectedKr = null;
      _meeting = meeting;
      _services = services;
      _topics = const [];
      _paging.clear();
      _ended.clear();
      _pageErrors.clear();
      _error = null;
      _loading = services.kr != null;
      final generation = ++_generation;
      if (_loading) {
        unawaited(_load(editor, services, meeting, generation));
      }
    }
    return BlockSelectionContainer(
      node: widget.node,
      delegate: this,
      listenable: editor.selectionNotifier,
      remoteSelection: editor.remoteSelections,
      blockColor: editor.editorStyle.selectionColor,
      supportTypes: const [BlockSelectionType.block],
      selectionAboveBlock: true,
      child: Listener(
        onPointerDown: (_) {
          editor.selection = null;
          FocusManager.instance.primaryFocus?.unfocus();
        },
        child: ListenableBuilder(
          listenable: editor.editableNotifier,
          builder: (context, _) => CollabCardFrame(
            surfaceKey: _bodyKey,
            header: CollabCardHeader(
              leading: const Icon(LucideIcons.listTodo),
              title: const Text('会议 KR'),
              readOnly: !editor.editable,
              more: CollabBlockMoreButton(
                editor: editor,
                node: widget.node,
                actions: [(label: '删除 KR 列表', key: const ValueKey('kr-delete'), run: () => _delete(editor))],
              ),
            ),
            child: _content(editor, services),
          ),
        ),
      ),
    );
  }

  /// 根据借用[editor]的权限和[services]展示列表或可重试状态。
  /// 仅当前点选KR显示最右侧转换按钮；再次点击收起，其他内容占剩余宽度。
  /// 只读不显示转换按钮，成功转换后清除点选，不修改共享属性。
  Widget _content(EditorState editor, CollabHostServices services) {
    if (services.kr == null) return const Text('暂未配置 KR 查询服务');
    if (_loading) return const Text('加载 KR 中…');
    if (_error != null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(_error!),
          TextButton(onPressed: () => _retry(editor, services), child: const Text('重试')),
        ],
      );
    }
    if (_topics.isEmpty) return const Text('本次会议暂无 KR');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final topic in _topics) ...[
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
            child: Text(topic.title, style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          // 文档自身持有纵向滚动，不在块内嵌套无界视口。
          ListView.separated(
            itemBuilder: (_, index) {
              final item = topic.items[index];
              return _buildItemKr(editor, topic, item, services);
            },
            separatorBuilder: (_, index) => const SizedBox(height: 6),
            itemCount: topic.items.length,
            padding: EdgeInsets.zero,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
          ),
          if (topic.items.length < topic.total && !_ended.contains(topic.id))
            TextButton(
              onPressed: _paging.contains(topic.id) ? null : () => _more(editor, services, topic),
              child: Text(
                _paging.contains(topic.id)
                    ? '加载中…'
                    : _pageErrors.contains(topic.id)
                    ? '加载失败，重试'
                    : '加载更多',
              ),
            ),
        ],
      ],
    );
  }

  /// 用借用[editor]的权限及[services]头像构建[topic]内的[item]。
  /// 前三名使用宿主图标或金银铜色加粗数字，其余显示普通数字。
  /// 当前点选项使用桌面同源6%蓝色背景和圆角，不绘制边框；只读不显示选中外观。
  Widget _buildItemKr(EditorState editor, CollabKrTopic topic, CollabKrItem item, CollabHostServices services) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: editor.editable && !_converting
          ? () => setState(() {
              final target = (topic.id, item.id);
              _selectedKr = _selectedKr == target ? null : target;
            })
          : null,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: editor.editable && _selectedKr == (topic.id, item.id) ? const Color(0x0F4A7AFE) : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 10),
          child: Row(
            children: [
              SizedBox(width: 28, child: _rank(item.rank, services)),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(item.title),
                    Wrap(
                      spacing: 8,
                      children: [
                        if (item.authorId?.isNotEmpty == true && services.mentionAvatarBuilder != null)
                          SizedBox(
                            width: 20,
                            height: 20,
                            child: services.mentionAvatarBuilder!(
                              context,
                              userId: item.authorId!,
                              name: item.authorName ?? '',
                              size: 20,
                            ),
                          ),
                        if (item.authorName?.isNotEmpty == true) Text(item.authorName!),
                        if (item.votes != null) Text('${item.votes} 票'),
                      ],
                    ),
                  ],
                ),
              ),
              if (editor.editable && _selectedKr == (topic.id, item.id))
                SizedBox(
                  height: 35,
                  child: TextButton(
                    onPressed: _converting ? null : () => _convert(editor, item),
                    child: const Text('转为待办', style: TextStyle(fontSize: 10)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 渲染从1开始的[rank]；借用[services]的三个宿主图标，缺省为金银铜色加粗数字。
  /// 第四名起使用普通数字，宿主图标占20×20且不接管外部资源。
  Widget _rank(int rank, CollabHostServices services) {
    if (rank < 1 || rank > 3) return Text('$rank');
    final icons = services.krRankIcons;
    if (icons != null) {
      final icon = switch (rank) {
        1 => icons.first,
        2 => icons.second,
        _ => icons.third,
      };
      return Align(
        alignment: Alignment.centerLeft,
        child: Semantics(
          label: '第$rank名',
          excludeSemantics: true,
          child: SizedBox(
            width: 20,
            height: 20,
            child: FittedBox(fit: BoxFit.contain, child: icon),
          ),
        ),
      );
    }
    return Text(
      '$rank',
      style: TextStyle(
        color: const [Color(0xFFC8A65A), Color(0xFF9AA4B2), Color(0xFFCD8B73)][rank - 1],
        fontWeight: FontWeight.bold,
      ),
    );
  }

  /// 检查借用[editor]、宿主[services]及[generation]；删除/换文档/引用变化后拒绝回写。
  bool _valid(EditorState editor, CollabHostServices services, int generation) =>
      mounted &&
      !editor.isDisposed &&
      generation == _generation &&
      identical(EditorCommandContext.of(editor).services, services) &&
      identical(editor.getNodeAtPath(widget.node.path), widget.node) &&
      readCollabKr(widget.node.attributes).string('meetingId') == _meeting;

  /// 加载[meeting]首屏；借用[editor]/[services]，仅[generation]有效时写局部结果，异常报告并展示重试。
  Future<void> _load(EditorState editor, CollabHostServices services, String meeting, int generation) async {
    try {
      final topics = await Future.sync(() => services.kr!.loadTopics(meeting));
      if (!_valid(editor, services, generation)) return;
      setState(() {
        _topics = List.unmodifiable(topics);
        _loading = false;
      });
    } catch (error, stack) {
      if (!_valid(editor, services, generation)) return;
      services.report('加载 KR 失败', error, stack, 'DocCollab');
      setState(() {
        _error = '加载 KR 失败，会议可能已删除或无权访问';
        _loading = false;
      });
    }
  }

  /// 对借用[editor]/[services]重试首屏；旧代次响应失效，不保留旧分页。
  void _retry(EditorState editor, CollabHostServices services) {
    setState(() {
      _loading = true;
      _selectedKr = null;
      _error = null;
      _paging.clear();
      _ended.clear();
      _pageErrors.clear();
    });
    unawaited(_load(editor, services, _meeting!, ++_generation));
  }

  /// 在借用[editor]/[services]中续拉[topic]，同主题串行，不同主题互不阻塞；失败保留旧页。
  Future<void> _more(EditorState editor, CollabHostServices services, CollabKrTopic topic) async {
    if (_paging.contains(topic.id)) return;
    final generation = _generation;
    setState(() {
      _paging.add(topic.id);
      _pageErrors.remove(topic.id);
    });
    try {
      final more = await services.kr!.loadMore(_meeting!, topic.id, topic.items.length);
      if (!_valid(editor, services, generation)) return;
      final ids = topic.items.map((item) => item.id).toSet();
      final fresh = more.where((item) => ids.add(item.id)).toList();
      setState(() {
        if (fresh.isEmpty) _ended.add(topic.id);
        _topics = [
          for (final current in _topics)
            if (current.id == topic.id)
              CollabKrTopic(
                id: topic.id,
                title: topic.title,
                total: topic.total,
                items: List.unmodifiable([...topic.items, ...fresh]),
              )
            else
              current,
        ];
      });
    } catch (error, stack) {
      if (!_valid(editor, services, generation)) return;
      services.report('加载更多 KR 失败', error, stack, 'DocCollab');
      setState(() => _pageErrors.add(topic.id));
    } finally {
      if (_valid(editor, services, generation)) {
        setState(() => _paging.remove(topic.id));
      }
    }
  }

  /// 将[item]作为独立待办插入借用[editor]，错误保留列表并反馈，不修改业务KR。
  Future<void> _convert(EditorState editor, CollabKrItem item) async {
    if (_converting || !editor.editable) return;
    setState(() => _converting = true);
    try {
      final converted = await convertCollabKr(editor, widget.node, item);
      if (converted && mounted) setState(() => _selectedKr = null);
    } catch (error, stack) {
      _services?.report('KR 转待办失败', error, stack, 'DocCollab');
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('转为待办失败')));
      }
    } finally {
      if (mounted) setState(() => _converting = false);
    }
  }

  /// 删除借用[editor]中的当前引用，公共菜单已校验稳定身份和权限；空父容器补正文。
  Future<void> _delete(EditorState editor) async {
    if (editor.isDisposed || !editor.editable || widget.node.parent == null) {
      return;
    }
    final transaction = editor.transaction..deleteNode(widget.node);
    if (widget.node.parent!.children.length == 1) {
      transaction.insertNode(widget.node.path, paragraphNode());
    }
    if (editor.undoManager.undoStack.isNonEmpty) {
      editor.undoManager.undoStack.last.seal();
    }
    await editor.apply(transaction, withUpdateSelection: false, skipHistoryDebounce: true);
  }

  /// 销毁后使仍在执行的宿主请求失效，不关闭借用服务。
  @override
  void dispose() {
    _generation++;
    super.dispose();
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
