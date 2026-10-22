import 'dart:async';

import 'package:cses_mobile_collab_demo/src/demo/document_creation/document_creation_operation.dart';
import 'package:cses_mobile_collab_demo/src/demo/document_creation/document_list_page.dart';
import 'package:cses_mobile_collab_demo/src/demo/document_creation/document_space_list.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 验证真实Sliver列表的分页、刷新、切换空间、资源失效及窄屏布局。
void main() {
  testWidgets('document rows dispatch their entry and respect disabled opening state', (
    tester,
  ) async {
    final selected = <String>[];

    /// 以[target]和[page]提供固定一项文档，验证交互期间不触发其他加载。
    Future<DocumentListPage> load(DocumentCreationTarget target, int page) async =>
        _page(['a'], page, total: 1);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CustomScrollView(
            slivers: [
              DocumentSpaceList(
                target: _first,
                loadPage: load,
                onOpenDocument: (entry) => selected.add(entry.id),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('文档a'));
    expect(selected, ['a']);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CustomScrollView(
            slivers: [
              DocumentSpaceList(
                target: _first,
                loadPage: load,
                enabled: false,
                openingDocumentId: 'a',
                onOpenDocument: (entry) => selected.add(entry.id),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    final row = find.byKey(const ValueKey('space-document-a'));
    expect(
      tester.widget<InkWell>(find.descendant(of: row, matching: find.byType(InkWell))).onTap,
      isNull,
    );
    expect(
      find.descendant(of: row, matching: find.byType(CircularProgressIndicator)),
      findsOneWidget,
    );
    expect(selected, ['a']);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('loads pages in order and deduplicates document ids while retaining server total', (
    tester,
  ) async {
    final pages = <int>[];
    await tester.pumpWidget(
      _view(_first, (target, page) async {
        expect(target.id, _first.id);
        pages.add(page);
        return _page(page == 1 ? ['a', 'b'] : ['b', 'c'], page, total: 3);
      }),
    );
    await tester.pumpAndSettle();
    expect(find.text('文档列表（3）'), findsOneWidget);
    expect(find.text('文档a'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('load-more-space-documents')));
    await tester.pumpAndSettle();
    expect(pages, [1, 2]);
    expect(find.byKey(const ValueKey('space-document-b')), findsOneWidget);
    expect(find.text('文档c'), findsOneWidget);
    expect(find.byKey(const ValueKey('load-more-space-documents')), findsNothing);
  });

  testWidgets('failed first page retries and distinguishes empty space from failure', (
    tester,
  ) async {
    var attempts = 0;
    await tester.pumpWidget(
      _view(_first, (_, page) async {
        if (++attempts == 1) throw StateError('offline');
        return _page([], page, total: 0);
      }),
    );
    await tester.pumpAndSettle();
    expect(find.text('文档列表加载失败，请重试'), findsOneWidget);
    expect(find.text('当前空间暂无文档'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('retry-space-documents')));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(find.text('当前空间暂无文档'), findsOneWidget);
  });

  testWidgets('failed next page keeps existing rows and retries the same page', (tester) async {
    final pages = <int>[];
    await tester.pumpWidget(
      _view(_first, (_, page) async {
        pages.add(page);
        if (pages.length == 2) throw StateError('network');
        return _page(page == 1 ? ['a', 'b'] : ['c'], page, total: 3);
      }),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('load-more-space-documents')));
    await tester.pumpAndSettle();
    expect(find.text('文档a'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('retry-space-documents')));
    await tester.pumpAndSettle();
    expect(pages, [1, 2, 2]);
    expect(find.text('文档c'), findsOneWidget);
  });

  testWidgets('failed refresh preserves rows and retries the first page instead of appending', (
    tester,
  ) async {
    final pages = <int>[];
    await tester.pumpWidget(
      _view(_first, (_, page) async {
        pages.add(page);
        if (pages.length == 2) throw StateError('network');
        return _page(pages.length == 1 ? ['a'] : ['new'], page, total: 1);
      }),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('refresh-space-documents')));
    await tester.pumpAndSettle();
    expect(find.text('文档a'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('retry-space-documents')));
    await tester.pumpAndSettle();
    expect(pages, [1, 1, 1]);
    expect(find.text('文档a'), findsNothing);
    expect(find.text('文档new'), findsOneWidget);
  });

  testWidgets('late response from previous space never replaces the current space list', (
    tester,
  ) async {
    final previous = Completer<DocumentListPage>();
    final requested = <String>[];

    /// 暂停[target]首空间的第[page]页，其他空间立即返回以制造响应乱序。
    Future<DocumentListPage> load(DocumentCreationTarget target, int page) {
      requested.add(target.id);
      return target.id == _first.id
          ? previous.future
          : Future.value(_page(['current'], page, total: 1));
    }

    await tester.pumpWidget(_view(_first, load));
    await tester.pump();
    await tester.pumpWidget(_view(const DocumentCreationTarget(id: 'next', name: '其他空间'), load));
    await tester.pumpAndSettle();
    previous.complete(_page(['stale'], 1, total: 1));
    await tester.pumpAndSettle();
    expect(requested, ['first', 'next']);
    expect(find.text('文档current'), findsOneWidget);
    expect(find.text('文档stale'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('late failures after unmount do not write state or leak exceptions', (tester) async {
    final response = Completer<DocumentListPage>();
    await tester.pumpWidget(_view(_first, (_, _) => response.future));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    response.completeError(StateError('late response'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('long lists build lazily and render on a narrow screen with large text', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(
          body: CustomScrollView(
            slivers: [
              DocumentSpaceList(
                target: _first,
                loadPage: (_, page) async => DocumentListPage(
                  items: [
                    for (var i = 0; i < 100; i++)
                      DocumentListEntry.fromJson({
                        'id': '$i',
                        'name': '长文档标题用于窄屏及系统大字验证$i',
                        'owner': {'name': '所有者名称很长'},
                        'updatedAt': 1792584000000,
                      }),
                  ],
                  totalCount: 100,
                  pageNumber: page,
                  pageSize: 100,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('space-document-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('space-document-99')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

/// 首个空间的稳定夹具，查询必须使用其id。
const _first = DocumentCreationTarget(id: 'first', name: '个人空间');

/// 用[target]及借用的[load]构建真实Sliver宿主，固定key以覆盖didUpdateWidget。
Widget _view(DocumentCreationTarget target, DocumentPageLoader load) => MaterialApp(
  home: Scaffold(
    body: CustomScrollView(
      slivers: [DocumentSpaceList(target: target, loadPage: load)],
    ),
  ),
);

/// 将[ids]转为第[number]页的元数据；[total]为服务器总数，每页固定两条。
DocumentListPage _page(List<String> ids, int number, {required int total}) => DocumentListPage(
  items: [
    for (final id in ids) DocumentListEntry.fromJson({'id': id, 'name': '文档$id'}),
  ],
  totalCount: total,
  pageNumber: number,
  pageSize: 2,
);
