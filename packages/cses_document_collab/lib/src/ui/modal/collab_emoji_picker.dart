import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:cses_document_collab/src/model/collab_emoji_catalog.dart';
import 'package:cses_document_collab/src/native/collab_runtime.dart';
import 'package:cses_document_collab/src/ui/modal/collab_modal_colors.dart';
import 'package:flutter/foundation.dart'
    show LicenseRegistry, LicenseEntryWithLineBreaks;
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// 惰性目录的一行，标题与表情行共用列表，避免一次挂载整个数据集。
typedef _EmojiRow = ({String? title, List<(String, String)> values});

/// 保留原生彩色表情字形，不让弹窗的中文/业务字体覆盖缺失的Emoji字形。
const _emojiStyle = TextStyle(
  fontSize: 24,
  fontFamilyFallback: [
    'Apple Color Emoji',
    'Noto Color Emoji',
    'Segoe UI Emoji',
  ],
);

/// 文档图标与高亮块共用的桌面同源表情选择器，保存完整原生Unicode。
/// 搜索和底部Tab固定，单一目录与Tab双向定位；有界父级铺满高度，无界父级至多420像素。
/// 最近12项和肤色仅在当前进程内共用，不存文档、账号或网络资料。
/// 父级拥有保存和权限，本组件拥有并释放搜索、焦点及滚动控制器。
/// 父级需提供Material供表情点击反馈绘制，公共底部弹窗或Scaffold已满足。
///
/// ```dart
/// import 'package:cses_document_collab/src/ui/modal/collab_emoji_picker.dart';
/// import 'package:flutter/material.dart';
/// final picker = Material(child: SizedBox(height: 400, child: CollabEmojiPicker(
///   keyPrefix: 'icon-emoji', current: '💡',
///   onSelected: (value) async { /* 保存原生表情 */ },
/// )));
/// ```
class CollabEmojiPicker extends StatefulWidget {
  /// [key]控制状态复用；[keyPrefix]标识搜索、分类和表情按钮。
  /// [current]为已有原文，目录外的组合表情或前缀也回显，不自动改写。
  /// [onSelected]等待父级保存；[enabled]默认true，保存期间禁止重复选择。
  /// [onClear]非空才提供移除，由父级决定空串或元数据清除语义。
  const CollabEmojiPicker({
    super.key,
    required this.keyPrefix,
    required this.onSelected,
    this.current,
    this.enabled = true,
    this.onClear,
  });

  /// 必填稳定前缀；单个表情按钮为keyPrefix-Unicode。
  final String keyPrefix;

  /// 当前原生表情或历史前缀；null表示未设置，不自动选择默认项。
  final String? current;

  /// 必填保存回调，父级调用时重新核对权限和稳定文档身份。
  final Future<void> Function(String value) onSelected;

  /// 是否可编辑，默认true；保存期间禁止重复选择。
  final bool enabled;

  /// 可选移除回调；null隐藏入口，便于父级在固定操作栏提供移除。
  final Future<void> Function()? onClear;

  /// 创建拥有输入和目录滚动的状态，不创建文档、连接或网络订阅。
  @override
  State<CollabEmojiPicker> createState() => _CollabEmojiPickerState();
}

/// 拥有目录缓存、滚动和Tab动画资源；滚动只同步Tab，点击定位允许用户拖动接管。
/// 只在明确选择成功后记录最近使用，浏览/搜索/肤色切换不写入文档。
class _CollabEmojiPickerState extends State<CollabEmojiPicker>
    with TickerProviderStateMixin {
  /// 完整许可在进程中注册一次；许可工厂只保留静态数据，不捕获Widget或文档。
  static bool _licensesRegistered = false;

  /// 进程内有界缓存，不持久化或记录业务身份。
  static final List<String> _recent = [];

  /// 成功选择后推进目录缓存版本，避免每帧扫描最近记录或重建全部目录。
  static int _recentRevision = 0;

  /// 进程内共用肤色；0为默认，1～5由浅到深，只影响有对应变体的目录项。
  static int _skinTone = 0;

  /// 没有最近记录时提供的常用推荐，不作为虚构的使用记录。
  static const _recommended = [
    '😀',
    '😘',
    '😍',
    '👍',
    '😄',
    '😂',
    '💡',
    '🎯',
    '❤️',
    '🚀',
    '✅',
    '🎉',
  ];

  /// 本状态拥有的搜索控制器。
  final _search = TextEditingController();

  /// 本状态拥有的搜索焦点，切换分类或肤色时收起键盘。
  final _focus = FocusNode();

  /// 本状态拥有的惰性目录滚动控制器。
  final _scroll = ScrollController();

  /// 本状态拥有的九个Tab：0定位顶部，1～8依次定位桌面分类。
  late final TabController _tabs;

  /// 本状态拥有的目录过渡；空闲/用户接管时为1，远距离定位淡出后只滑入目标附近。
  late final AnimationController _navigationOpacity;

  /// 只缓存目录数据，不缓存Widget；列数、查询、肤色、当前项或最近项变化才重算。
  (int, String, int, String?, int)? _rowKey;

  /// 最近一次布局的目录行；滚动联动仅使用下方索引，不遍历表情或扫描渲染对象。
  List<_EmojiRow> _cachedRows = const [];

  /// 每个Tab对应的标题行号；0为顶部。搜索时不参与联动，退出搜索后重新建立。
  List<int> _sectionRows = List.filled(9, 0);

  /// 最近布局的统一行高，随标题文字缩放增长，供固定行高列表和定位共用。
  double _rowExtent = 48;

  /// 点击定位期间锁定目标Tab，避免动画经过中间分类时指示器来回切换。
  int? _targetTab;

  /// 新定位、搜索、用户拖动和销毁均使旧异步动画完成结果失效。
  int _navigationEpoch = 0;

  /// 保存互斥，失败后复位；迟到完成不更新已销毁界面。
  bool _saving = false;

  /// 是否展开内联肤色行，不打开第二层弹窗。
  bool _showSkins = false;

  /// 注册静态目录许可，不获取网络或业务状态；输入/滚动资源由本状态持有。
  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 9, vsync: this);
    _navigationOpacity = AnimationController(vsync: this, value: 1);
    _scroll.addListener(_syncCategory);
    if (!_licensesRegistered) {
      _licensesRegistered = true;
      LicenseRegistry.addLicense(() async* {
        for (final notice in collabEmojiLicenses) {
          yield LicenseEntryWithLineBreaks([notice.$1], notice.$2);
        }
      });
    }
  }

  /// 释放本状态创建的输入、焦点及滚动资源。
  @override
  void dispose() {
    _navigationEpoch++;
    _scroll.removeListener(_syncCategory);
    _tabs.dispose();
    _navigationOpacity.dispose();
    _search.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// 保存[value]，null调用移除；最多32字素/256 UTF-8字节，不截断组合表情。
  /// 保存异常留面板提示，成功记录完整Unicode，面板关闭后不刷新局部状态。
  Future<void> _select(String? value) async {
    if (!widget.enabled || _saving) return;
    if (value != null &&
        (value.trim().isEmpty ||
            value.characters.length > 32 ||
            utf8.encode(value).length > 256)) {
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(const SnackBar(content: Text('表情或前缀过长，请缩短后重试')));
      return;
    }
    setState(() => _saving = true);
    try {
      if (value == null) {
        await widget.onClear?.call();
      } else {
        await widget.onSelected(value);
        _recent.remove(value);
        _recent.insert(0, value);
        if (_recent.length > 12) _recent.removeLast();
        _recentRevision++;
      }
    } catch (error, stack) {
      CollabDiagnostics.report(
        '表情设置失败',
        error: error,
        stackTrace: stack,
        tag: 'DocCollab',
      );
      if (mounted) {
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(const SnackBar(content: Text('表情设置失败，请重试')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 搜索或肤色变化时取消旧定位并回到顶部，不改正文或创建滚动控制器。
  void _refresh() {
    _navigationEpoch++;
    _targetTab = null;
    _navigationOpacity.value = 1;
    _tabs.index = 0;
    if (_scroll.hasClients) _scroll.jumpTo(0);
    setState(() {});
  }

  /// 点击[index]对应的Tab，清空搜索、收起键盘/肤色后定位完整目录，不筛除其他分类。
  /// 布局完成后再计算目标；后续点击或手势使旧任务失效。
  void _chooseCategory(int index) {
    _focus.unfocus();
    final needsLayout = _search.text.isNotEmpty || _showSkins;
    _search.clear();
    _showSkins = false;
    _targetTab = index;
    final epoch = ++_navigationEpoch;
    _navigationOpacity.value = 1;
    if (needsLayout) setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || epoch != _navigationEpoch || !_scroll.hasClients) return;
      unawaited(_scrollToCategory(index, epoch));
    });
  }

  /// 将[index]标题定位到顶部；[epoch]防止过期动画影响新导航。
  /// 近距离直接滚动300毫秒；超过两屏时淡出90毫秒，在透明状态布局目标附近，再滑入并淡入。
  /// 目标附近最多滑动0.7屏，避免跨越整份目录时连续创建/回收大量表情行。
  /// 控制器由本状态拥有，关闭或用户接管滚动时取消等待结果，异常记录到诊断。
  Future<void> _scrollToCategory(int index, int epoch) async {
    final position = _scroll.position;
    final target = index == 0 ? 0.0 : 8 + _sectionRows[index] * _rowExtent;
    final offset = target.clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    try {
      if ((offset - position.pixels).abs() > position.viewportDimension * 2) {
        await _navigationOpacity
            .animateTo(0, duration: const Duration(milliseconds: 90))
            .orCancel;
        if (!mounted || epoch != _navigationEpoch || !_scroll.hasClients) {
          return;
        }
        final direction = offset > _scroll.offset ? 1 : -1;
        final approach = (offset - direction * position.viewportDimension * .7)
            .clamp(position.minScrollExtent, position.maxScrollExtent);
        _scroll.jumpTo(approach);
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted || epoch != _navigationEpoch || !_scroll.hasClients) {
          return;
        }
        await Future.wait([
          _navigationOpacity
              .animateTo(1, duration: const Duration(milliseconds: 180))
              .orCancel,
          _scroll.animateTo(
            offset,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOutCubic,
          ),
        ]);
      } else {
        await _scroll.animateTo(
          offset,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOutSine,
        );
      }
    } on TickerCanceled {
      // A new target, pointer gesture or disposal owns the next visible state.
    } catch (error, stack) {
      if (mounted && epoch == _navigationEpoch) {
        CollabDiagnostics.report(
          '表情分类定位失败',
          error: error,
          stackTrace: stack,
          tag: 'DocCollab',
        );
      }
    } finally {
      if (mounted && epoch == _navigationEpoch) {
        _navigationOpacity.value = 1;
        _targetTab = null;
        _syncCategory();
      }
    }
  }

  /// 按顶部经过的分类标题更新Tab；每次最多比较八个偏移，仅Tab自身重建/自动横向定位。
  /// 点击动画期间保持目标，搜索结果不改变分类；允许回弹但不产生负分类。
  void _syncCategory() {
    if (!_scroll.hasClients ||
        _targetTab != null ||
        _search.text.trim().isNotEmpty) {
      return;
    }
    var index = 0;
    for (var i = 1; i < _sectionRows.length; i++) {
      if (_scroll.offset + .5 >= 8 + _sectionRows[i] * _rowExtent) index = i;
    }
    if (_tabs.index != index) {
      _tabs.animateTo(index, duration: const Duration(milliseconds: 140));
    }
  }

  /// [notification]中的真实拖动优先于点击动画；只观察当前纵向列表，不拦截通知。
  bool _onScroll(ScrollNotification notification) {
    if (notification.depth == 0 &&
        notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      _navigationEpoch++;
      _targetTab = null;
      _navigationOpacity.value = 1;
      _syncCategory();
    }
    return false;
  }

  /// 按[columns]列缓存[query]结果及分类标题索引，保持完整Unicode及桌面顺序。
  /// 当前/最近项只出现一次，完整目录始终含八类；滚动和Tab变化不重新计算目录。
  List<_EmojiRow> _rows(int columns, String query) {
    final key = (columns, query, _skinTone, widget.current, _recentRevision);
    if (_rowKey == key) return _cachedRows;
    _rowKey = key;
    _sectionRows = List.filled(9, 0);
    final rows = <_EmojiRow>[];
    final shown = <String>{};

    /// 把[title]和[values]转成目录行，去重后为空的分组不输出标题。
    void section(String title, Iterable<(String, String)> values) {
      final entries = values.where((entry) => shown.add(entry.$1)).toList();
      if (entries.isEmpty) return;
      rows.add((title: title, values: const []));
      for (var i = 0; i < entries.length; i += columns) {
        rows.add((
          title: null,
          values: entries.sublist(i, math.min(i + columns, entries.length)),
        ));
      }
    }

    if (query.isNotEmpty) {
      section(
        '搜索结果',
        allCollabEmojis
            .where((entry) => entry.matches(query))
            .map(
              (entry) => (
                entry.tones.contains(query)
                    ? query
                    : entry.withSkinTone(_skinTone),
                entry.name,
              ),
            ),
      );
    } else {
      final current = widget.current;
      if (current != null && current.isNotEmpty) {
        section('当前', [(current, findCollabEmoji(current)?.name ?? current)]);
      }
      section(
        _recent.isEmpty ? '常用' : '最近使用',
        (_recent.isEmpty ? _recommended : _recent).map((value) {
          final entry = findCollabEmoji(value);
          return (
            _recent.isEmpty ? entry?.withSkinTone(_skinTone) ?? value : value,
            entry?.name ?? value,
          );
        }),
      );
      for (var i = 0; i < collabEmojiCategories.length; i++) {
        final category = collabEmojiCategories[i];
        _sectionRows[i + 1] = rows.length;
        section(
          category.name,
          category.emojis.map(
            (entry) => (entry.withSkinTone(_skinTone), entry.name),
          ),
        );
      }
    }
    if (rows.isEmpty) rows.add((title: '没有找到相关表情', values: const []));
    return _cachedRows = rows;
  }

  /// 使用[context]和有限[width]/[height]构建固定搜索、惰性目录和双向联动Tab。
  /// 低高度时收起分类/肤色行，避免键盘或横屏挤压固定操作区。
  Widget _panel(BuildContext context, double width, double height) {
    final colors = CollabModalColors.of(context);
    final query = _search.text.trim().toLowerCase();
    final enabled = widget.enabled && !_saving;
    final columns = (width / 44).floor().clamp(1, 10);
    final previousRows = _cachedRows;
    final previousExtent = _rowExtent;
    final rows = _rows(columns, query);
    final title = TextPainter(
      text: TextSpan(
        text: '表情与人物',
        style: DefaultTextStyle.of(context).style.copyWith(fontSize: 12),
      ),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    _rowExtent = math.max(48, title.height + 14);
    title.dispose();
    if (!identical(previousRows, rows) || previousExtent != _rowExtent) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _syncCategory();
      });
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: math.min(48, height),
          child: TextField(
            key: ValueKey('${widget.keyPrefix}-search'),
            controller: _search,
            focusNode: _focus,
            enabled: enabled,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: '搜索或粘贴表情',
              prefixIcon: const Icon(LucideIcons.search, size: 18),
              suffixIcon: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (query.isNotEmpty)
                    IconButton(
                      tooltip: '清空搜索',
                      onPressed: enabled
                          ? () {
                              _search.clear();
                              _refresh();
                            }
                          : null,
                      icon: const Icon(LucideIcons.x, size: 16),
                    ),
                  IconButton(
                    key: ValueKey('${widget.keyPrefix}-skin-toggle'),
                    tooltip: '选择肤色',
                    onPressed: enabled
                        ? () {
                            _focus.unfocus();
                            setState(() => _showSkins = !_showSkins);
                          }
                        : null,
                    icon: const Icon(LucideIcons.hand, size: 18),
                  ),
                ],
              ),
            ),
            onChanged: (_) => _refresh(),
            onSubmitted: (_) => _focus.unfocus(),
          ),
        ),
        if (query.isNotEmpty && height >= 180)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: ValueKey('${widget.keyPrefix}-apply'),
              onPressed: enabled
                  ? () async => _select(_search.text.trim())
                  : null,
              child: Text(
                '使用“${_search.text.trim()}”',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        if (_showSkins && height >= 230)
          SizedBox(
            height: 48,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (var tone = 0; tone < 6; tone++)
                    Semantics(
                      selected: _skinTone == tone,
                      label: [
                        '默认肤色',
                        '浅肤色',
                        '中浅肤色',
                        '中等肤色',
                        '中深肤色',
                        '深肤色',
                      ][tone],
                      child: TextButton(
                        key: ValueKey('${widget.keyPrefix}-skin-$tone'),
                        onPressed: enabled
                            ? () {
                                _skinTone = tone;
                                _showSkins = false;
                                _refresh();
                              }
                            : null,
                        style: TextButton.styleFrom(
                          backgroundColor: _skinTone == tone
                              ? colors.soft
                              : null,
                        ),
                        child: Text(
                          ['👍', '👍🏻', '👍🏼', '👍🏽', '👍🏾', '👍🏿'][tone],
                          style: _emojiStyle,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        Expanded(
          child: FadeTransition(
            key: ValueKey('${widget.keyPrefix}-navigation-transition'),
            opacity: _navigationOpacity,
            child: Scrollbar(
              controller: _scroll,
              child: NotificationListener<ScrollNotification>(
                onNotification: _onScroll,
                child: ListView.builder(
                  key: PageStorageKey('${widget.keyPrefix}-list'),
                  controller: _scroll,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  itemCount: rows.length,
                  itemExtent: _rowExtent,
                  itemBuilder: (context, index) {
                    final row = rows[index];
                    if (row.title != null) {
                      return Align(
                        key: ValueKey(
                          '${widget.keyPrefix}-heading-${row.title}',
                        ),
                        alignment: Alignment.centerLeft,
                        child: Text(
                          row.title!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: colors.muted),
                        ),
                      );
                    }
                    return SizedBox(
                      height: _rowExtent,
                      child: Row(
                        children: [
                          for (final entry in row.values)
                            Expanded(
                              child: _button(context, entry.$1, entry.$2),
                            ),
                          for (var i = row.values.length; i < columns; i++)
                            const Spacer(),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
        if (height >= 180) ...[
          Divider(height: 1, color: colors.line),
          SizedBox(
            height: 48,
            child: IgnorePointer(
              ignoring: !enabled,
              child: TabBar(
                key: ValueKey('${widget.keyPrefix}-categories'),
                controller: _tabs,
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                labelColor: colors.accent,
                unselectedLabelColor: colors.muted,
                indicatorColor: colors.accent,
                dividerColor: Colors.transparent,
                indicatorSize: TabBarIndicatorSize.label,
                labelPadding: const EdgeInsets.symmetric(horizontal: 12),
                onTap: _chooseCategory,
                tabs: [
                  for (final category in [
                    ('all', '全部'),
                    ...collabEmojiCategories.map(
                      (entry) => (entry.id, entry.name),
                    ),
                  ])
                    Tab(
                      key: ValueKey(
                        '${widget.keyPrefix}-category-${category.$1}',
                      ),
                      text: category.$2,
                    ),
                ],
              ),
            ),
          ),
        ],
        if (widget.onClear != null && height >= 140)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: ValueKey('${widget.keyPrefix}-clear'),
              style: TextButton.styleFrom(foregroundColor: colors.danger),
              onPressed: enabled ? () async => _select(null) : null,
              child: const Text('移除'),
            ),
          ),
      ],
    );
  }

  /// 按[context]父级约束选择高度；无界调用方使用有限回退，不构建无界列表。
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final height = constraints.hasBoundedHeight
          ? constraints.maxHeight
          : math.min(420.0, MediaQuery.sizeOf(context).height * .55);
      return SizedBox(
        height: height,
        child: _panel(context, constraints.maxWidth, height),
      );
    },
  );

  /// 用[context]主题构建完整原生[value]按钮，[label]提供中文含义及无障碍名称。
  /// 借用弹窗Material绘制墨水反馈，保留键盘激活和长按提示，避免每格创建独立Material与按钮样式状态。
  /// 淡入淡出期间忽略表情提交，滚动手势仍可接管定位。
  Widget _button(BuildContext context, String value, String label) {
    final colors = CollabModalColors.of(context);
    final selected = widget.current == value;
    final enabled = widget.enabled && !_saving;
    final glyph = Padding(
      padding: const EdgeInsets.all(2),
      child: Center(
        child: ExcludeSemantics(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(value, style: _emojiStyle),
          ),
        ),
      ),
    );
    return Semantics(
      selected: selected,
      enabled: enabled,
      label: label,
      button: true,
      child: Tooltip(
        message: label,
        excludeFromSemantics: true,
        child: InkResponse(
          key: ValueKey('${widget.keyPrefix}-$value'),
          onTap: enabled
              ? () async {
                  if (_targetTab != null && _navigationOpacity.value < 1) {
                    return;
                  }
                  await _select(value);
                }
              : null,
          containedInkWell: true,
          highlightShape: BoxShape.rectangle,
          customBorder: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(10)),
          ),
          highlightColor: colors.soft,
          focusColor: colors.soft,
          child: selected
              ? Ink(
                  decoration: BoxDecoration(
                    color: colors.soft,
                    border: Border.all(color: colors.accent),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: glyph,
                )
              : glyph,
        ),
      ),
    );
  }
}
