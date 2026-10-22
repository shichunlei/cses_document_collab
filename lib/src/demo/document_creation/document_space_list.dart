import 'dart:async';

import 'package:flutter/material.dart';

import 'document_creation_operation.dart';
import 'document_list_page.dart';

/// 当前空间或文件夹的分页文档列表Sliver；只读取元数据，不打开协同文档。
///
/// ```dart
/// import 'package:flutter/material.dart';
/// import 'package:cses_mobile_collab_demo/src/demo/document_creation/document_space_list.dart';
/// import 'package:cses_mobile_collab_demo/src/demo/document_creation/document_creation_operation.dart';
/// import 'package:cses_mobile_collab_demo/src/demo/document_creation/document_list_page.dart';
/// Widget documents(DocumentCreationTarget target, DocumentPageLoader load) =>
///   CustomScrollView(slivers: [DocumentSpaceList(target: target, loadPage: load)]);
/// ```
class DocumentSpaceList extends StatefulWidget {
  /// [key]控制状态复用；[target]提供当前真实父节点，[loadPage]由宿主持有。
  /// 更换目标或加载端口后重置分页；未完成请求的旧结果不会安装到新目标。
  const DocumentSpaceList({super.key, required this.target, required this.loadPage});

  /// 当前空间或文件夹；其ID用作列表查询的id字段。
  final DocumentCreationTarget target;

  /// 借用的分页加载函数，失败显示重试，组件不释放底层网络资源。
  final DocumentPageLoader loadPage;

  /// 创建仅持有列表元数据和在途请求版本的状态。
  @override
  State<DocumentSpaceList> createState() => _DocumentSpaceListState();
}

/// 持有分页快照及请求版本；关闭或切换空间后忽略迟到响应。
class _DocumentSpaceListState extends State<DocumentSpaceList> {
  List<DocumentListEntry> _items = [];
  int? _totalCount;
  int _page = 0;
  bool _hasMore = false;
  bool _loading = false;
  bool _failed = false;

  /// 失败重试保持原页，刷新失败不能误变成下一页追加。
  bool _failedReset = true;

  /// 每次刷新或切换目标递增，防止过期分页覆盖新的列表。
  int _requestVersion = 0;

  /// 首次挂载读取第一页，失败由加载流程映射为可重试状态。
  @override
  void initState() {
    super.initState();
    unawaited(_load(reset: true));
  }

  /// [oldWidget]目标或加载端口变化时丢弃旧快照，并使旧请求失效。
  @override
  void didUpdateWidget(covariant DocumentSpaceList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.target.id != widget.target.id || oldWidget.loadPage != widget.loadPage) {
      _items = [];
      _totalCount = null;
      _page = 0;
      _hasMore = false;
      unawaited(_load(reset: true));
    }
  }

  /// [reset]为true时读取第一页并替换快照，否则追加下一页，按文档ID去重。
  /// 加载失败保留已有条目；迟到响应同时核对mounted与请求版本。
  Future<void> _load({required bool reset}) async {
    if (_loading && !reset) return;
    final version = reset ? ++_requestVersion : _requestVersion;
    final pageNumber = reset ? 1 : _page + 1;
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final page = await widget.loadPage(widget.target, pageNumber);
      if (!mounted || version != _requestVersion) return;
      if (page.pageNumber != pageNumber) throw const FormatException('返回文档页码不匹配');
      setState(() {
        final merged = <String, DocumentListEntry>{
          if (!reset)
            for (final item in _items) item.id: item,
          for (final item in page.items) item.id: item,
        };
        _items = List.unmodifiable(merged.values);
        _totalCount = page.totalCount;
        _page = pageNumber;
        _hasMore = page.hasMore;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || version != _requestVersion) return;
      setState(() {
        _loading = false;
        _failed = true;
        _failedReset = reset;
      });
    }
  }

  /// 为[item]组合所有者及本地时区的最后修改时间，缺省字段不伪造占位。
  String _subtitle(DocumentListEntry item) {
    final time = item.modifiedAt?.toLocal();
    return [
      if (item.ownerName?.trim().isNotEmpty == true) item.ownerName!,
      if (time != null)
        '${time.year}-${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')} '
            '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}',
    ].join(' · ');
  }

  /// 为[context]构建惰性Sliver列表；滚动、窄屏与大字由外层视口统一约束。
  @override
  Widget build(BuildContext context) => SliverMainAxisGroup(
    slivers: [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 12, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _totalCount == null ? '文档列表' : '文档列表（$_totalCount）',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              TextButton.icon(
                key: const ValueKey('refresh-space-documents'),
                onPressed: _loading ? null : () => unawaited(_load(reset: true)),
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('刷新'),
              ),
            ],
          ),
        ),
      ),
      if (_items.isNotEmpty)
        SliverList.builder(
          itemCount: _items.length,
          itemBuilder: (context, index) {
            final item = _items[index];
            final subtitle = _subtitle(item);
            return Padding(
              key: ValueKey('space-document-${item.id}'),
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.description_outlined,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(item.displayName, maxLines: 2, overflow: TextOverflow.ellipsis),
                              if (subtitle.isNotEmpty) ...[
                                const SizedBox(height: 4),
                                Text(
                                  subtitle,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                ],
              ),
            );
          },
        ),
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
          child: Column(
            children: [
              if (_loading)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator()),
                )
              else if (_failed) ...[
                const Text('文档列表加载失败，请重试'),
                TextButton(
                  key: const ValueKey('retry-space-documents'),
                  onPressed: () => unawaited(_load(reset: _failedReset)),
                  child: const Text('重试'),
                ),
              ] else if (_items.isEmpty)
                const Text('当前空间暂无文档')
              else if (_hasMore)
                TextButton(
                  key: const ValueKey('load-more-space-documents'),
                  onPressed: () => unawaited(_load(reset: false)),
                  child: const Text('加载更多'),
                ),
            ],
          ),
        ),
      ),
    ],
  );
}
