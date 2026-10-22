import 'dart:async';
import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_common/runtime/context/context.dart';
import 'package:cses_common/runtime/session/user.dart';
import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'journal_draft.dart';
import 'guidance_people.dart';
import 'journal_store.dart';
import 'journal_surface.dart';
import 'local_journal_controller.dart';

/// 独立的离线横线日记页面，拥有加载、正文、自动保存和预览快照的完整生命周期。
///
/// ```dart
/// import 'package:flutter/material.dart';
/// import 'package:cses_mobile_collab_demo/src/daily_guidance/local_journal_page.dart';
/// import 'package:cses_mobile_collab_demo/src/daily_guidance/journal_store.dart';
/// Future<void> openJournal(BuildContext context, JournalStore store) async {
///   await Navigator.of(context).push<void>(MaterialPageRoute(
///     builder: (_) => LocalJournalPage(store: store)));
/// }
/// ```
class LocalJournalPage extends StatefulWidget {
  /// [key]控制页面身份；[store]是当前账号独占的本地草稿端口，由宿主持有。
  /// 同一store只能打开一个日记页面，读取失败不会新建覆盖原记录。
  /// [directory]可注入组织树，null使用当前登录企业，不转移目录资源所有权。
  const LocalJournalPage({super.key, required this.store, this.directory});

  /// 可选宿主组织目录；null在本页创建账号绑定的真实企业目录，不生成演示人员。
  final GuidanceDirectory? directory;

  /// 页面借用的单写入者存储，路由关闭时不释放宿主资源。
  final JournalStore store;

  /// 创建管理异步加载、退场保存和预览资源的状态。
  @override
  State<LocalJournalPage> createState() => _LocalJournalPageState();
}

/// 拥有日记控制器和独立预览，应用进入后台时尽早持久化当前修订。
class _LocalJournalPageState extends State<LocalJournalPage>
    with WidgetsBindingObserver {
  LocalJournalController? _journal;
  DocumentEditorController? _preview;
  String? _loadError;
  bool _loading = false;
  bool _switching = false;
  bool _leaving = false;
  bool _canPop = false;
  bool _chooseDate = false;
  Selection? _selection;

  /// 本页创建或借用的组织目录，缓存生命周期随页面结束。
  late final GuidanceDirectory _directory;

  /// 组织选择期间阻止重复选择、预览和页面退场。
  bool _picking = false;

  /// 此业务页面绑定的账号与企业，会话变化后不再接收异步选人写回。
  final String? _userId = User().userId;

  /// 创建页面时的企业范围。
  final String _companyId = User().companyId;

  /// 仅用于内存会话比较，不进入草稿。
  final String? _cookie = ctx.cookieId;

  /// 当前业务身份是否仍属于创建页面时的草稿分区。
  bool get _sameAccount =>
      User().userId == _userId &&
      User().companyId == _companyId &&
      ctx.cookieId == _cookie;

  /// 注册生命周期监听并开始读取；加载期间不创建空文档替代未知草稿。
  @override
  void initState() {
    super.initState();
    _directory = widget.directory ?? CsesGuidanceDirectory();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_load());
  }

  /// 异步读取本页store；页面已移除时关闭迟到会话，不向另一个页面回写。
  Future<void> _load() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final journal = await LocalJournalController.open(store: widget.store);
      if (!mounted) {
        await journal.close();
        return;
      }
      setState(() => _journal = journal);
    } catch (_) {
      if (mounted) setState(() => _loadError = '日记读取失败，请重试。原记录不会被覆盖。');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 在[state]进入非前台状态时保存；flush自行转存储异常为可重试状态。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && _journal != null) {
      unawaited(_journal!.flush());
    }
  }

  /// 先注销观察者，视图卸载后按预览、正文顺序关闭本页资源。
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_release());
    super.dispose();
  }

  /// 完整卸载视图后释放快照与正文；会话关闭会等待仍在进行的保存。
  Future<void> _release() async {
    await _preview?.close();
    await _journal?.close();
  }

  /// 正常退出前冻结输入并等待最新修订落盘；失败留在当前页供重试，不丢失内存正文。
  Future<void> _leave() async {
    if (_leaving || _switching || _picking) return;
    setState(() => _leaving = true);
    final journal = _journal;
    journal?.editor.editorState.service.keyboardService?.closeKeyboard();
    FocusManager.instance.primaryFocus?.unfocus();
    if (journal != null) journal.editor.editorState.editable = false;
    final saved = journal == null || await journal.flush();
    if (!mounted) return;
    if (!saved) {
      journal.editor.editorState.editable = true;
      setState(() => _leaving = false);
      return;
    }
    setState(() => _canPop = true);
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) Navigator.of(context).pop();
  }

  /// 收起输入连接后创建同源只读快照；返回编辑时恢复原选区，过期回调不再操作资源。
  Future<void> _togglePreview() async {
    final journal = _journal;
    if (journal == null || _switching || _leaving || _picking) return;
    setState(() {
      _switching = true;
      _chooseDate = false;
    });
    try {
      final state = journal.editor.editorState;
      if (_preview == null) _selection = state.selection;
      state.service.keyboardService?.closeKeyboard();
      FocusManager.instance.primaryFocus?.unfocus();
      await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
      if (!mounted) return;
      if (_preview == null) {
        state.selection = null;
        final preview = DocumentEditorController(
          document: Document.fromJson(
            jsonDecode(jsonEncode(state.document.toJson()))
                as Map<String, dynamic>,
          ),
          commandContext: EditorCommandContext(
            configuration: journalConfiguration,
            localOnly: true,
          ),
        );
        preview.editorState.editable = false;
        setState(() => _preview = preview);
      } else {
        final old = _preview!;
        setState(() => _preview = null);
        await WidgetsBinding.instance.endOfFrame;
        await old.close();
        if (mounted) state.selection = _selection;
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('预览切换失败，请重试')));
      }
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }

  /// 添加或关闭[kind]栏目；[close]默认false，失败显示提示且保留正文。
  Future<void> _section(String kind, {bool close = false}) async {
    final journal = _journal;
    if (journal == null ||
        _picking ||
        _preview != null ||
        _leaving ||
        !_sameAccount) {
      return;
    }
    try {
      if (close) {
        await journal.closeSection(kind);
      } else {
        await journal.addSection(kind);
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('栏目操作失败，内容已保留')));
      }
    }
  }

  /// 在当前光标选择人员；[kind]为空插入句内@，否则创建对应业务行。
  /// 模态期间冻结正文，退场后复核页面/会话与目标修订，取消时只恢复原选区。
  Future<void> _pickPeople({String? kind}) async {
    final journal = _journal;
    if (journal == null ||
        _picking ||
        _preview != null ||
        _leaving ||
        _switching ||
        !_sameAccount) {
      return;
    }
    final target = journal.captureInsertionTarget();
    if (target == null) return;
    setState(() => _picking = true);
    final state = journal.editor.editorState;
    state.service.keyboardService?.closeKeyboard();
    FocusManager.instance.primaryFocus?.unfocus();
    state.editable = false;
    try {
      final people = await showGuidancePeoplePicker(
        context,
        directory: _directory,
        canEdit: () =>
            mounted &&
            _sameAccount &&
            identical(_journal, journal) &&
            !journal.closed &&
            !_leaving &&
            _preview == null,
      );
      if (!mounted ||
          !_sameAccount ||
          !identical(_journal, journal) ||
          journal.closed) {
        return;
      }
      state.editable = true;
      if (people != null && people.isNotEmpty) {
        await journal.insertPeople(target, people, kind: kind);
      } else {
        state.selection = target.selection;
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('人员插入失败，原文已保留，请重试')));
      }
    } finally {
      if (mounted &&
          _sameAccount &&
          identical(_journal, journal) &&
          !journal.closed &&
          !_leaving &&
          !_switching &&
          _preview == null) {
        state.editable = true;
      }
      if (mounted) setState(() => _picking = false);
    }
  }

  /// 为[journal]构建随屏幕换行的业务工具栏；焦点仍由同一正文会话持有。
  Widget _actions(LocalJournalController journal) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
    child: Wrap(
      spacing: 2,
      runSpacing: 0,
      alignment: WrapAlignment.center,
      children: [
        for (final item in [
          (null, '@用户'),
          ('task', '待办'),
          ('help', '都来帮'),
          ('pilot', '领航员'),
        ])
          TextButton(
            key: ValueKey('guidance-action-${item.$1 ?? 'mention'}'),
            onPressed: _picking
                ? null
                : () => unawaited(_pickPeople(kind: item.$1)),
            child: Text(item.$2),
          ),
        for (final item in [('reflection', '感悟'), ('self-check', '自检')])
          if (!journal.hasSection(item.$1))
            TextButton(
              key: ValueKey('guidance-add-${item.$1}'),
              onPressed: _picking ? null : () => unawaited(_section(item.$1)),
              child: Text(item.$2),
            ),
      ],
    ),
  );

  /// 在[context]构建独立路由，保存状态与页面纸张分离，预览使用同样的栏目和日期头部。
  @override
  Widget build(BuildContext context) {
    final journal = _journal;
    return Localizations.override(
      context: context,
      delegates: const [AppFlowyEditorLocalizations.delegate],
      child: PopScope(
        canPop: _canPop,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) unawaited(_leave());
        },
        child: Scaffold(
          backgroundColor: const Color(0xfffaf8f0),
          appBar: AppBar(
            backgroundColor: const Color(0xfffaf8f0),
            leading: IconButton(
              key: const ValueKey('journal-back'),
              tooltip: '返回并保存',
              onPressed: _leaving ? null : () => unawaited(_leave()),
              icon: const Icon(LucideIcons.chevronLeft),
            ),
            title: const Text('今日导向'),
            actions: [
              if (journal != null) ...[
                IconButton(
                  tooltip: '撤销',
                  onPressed: _preview != null || _leaving
                      ? null
                      : journal.editor.editorState.undoManager.undo,
                  icon: const Icon(LucideIcons.undo2),
                ),
                IconButton(
                  tooltip: '重做',
                  onPressed: _preview != null || _leaving
                      ? null
                      : journal.editor.editorState.undoManager.redo,
                  icon: const Icon(LucideIcons.redo2),
                ),
                TextButton(
                  key: const ValueKey('journal-preview'),
                  onPressed: _switching || _leaving
                      ? null
                      : () => unawaited(_togglePreview()),
                  child: Text(_preview == null ? '预览' : '编辑'),
                ),
              ],
            ],
          ),
          body: journal == null
              ? Center(
                  child: _loadError == null
                      ? const CircularProgressIndicator()
                      : Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(_loadError!),
                              TextButton(
                                onPressed: _loading
                                    ? null
                                    : () => unawaited(_load()),
                                child: const Text('重试读取'),
                              ),
                            ],
                          ),
                        ),
                )
              : SafeArea(
                  child: Column(
                    children: [
                      ListenableBuilder(
                        listenable: journal,
                        builder: (context, _) => Semantics(
                          liveRegion: true,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Flexible(
                                child: Text(
                                  journal.error ??
                                      (journal.saving
                                          ? '正在保存到本机…'
                                          : journal.dirty
                                          ? '尚未保存'
                                          : '已保存到本机'),
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: journal.error == null
                                        ? const Color(0xff8a8175)
                                        : Colors.red.shade700,
                                  ),
                                ),
                              ),
                              if (journal.error != null)
                                TextButton(
                                  key: const ValueKey('journal-retry-save'),
                                  onPressed: journal.saving
                                      ? null
                                      : () => unawaited(journal.flush()),
                                  child: const Text('重试保存'),
                                ),
                            ],
                          ),
                        ),
                      ),
                      Expanded(
                        child: Align(
                          alignment: Alignment.topCenter,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 680),
                            child: JournalSurface(
                              key: ObjectKey(_preview ?? journal.editor),
                              editorState:
                                  (_preview ?? journal.editor).editorState,
                              preview: _preview != null || _leaving,
                              onCloseSection: _preview != null || _leaving
                                  ? null
                                  : (kind) =>
                                        unawaited(_section(kind, close: true)),
                              onMention: _preview != null || _leaving
                                  ? null
                                  : () => unawaited(_pickPeople()),
                              header: ListenableBuilder(
                                listenable: journal,
                                builder: (context, _) => _JournalHeader(
                                  date: journal.date,
                                  chooseDate: _chooseDate,
                                  onChoose: _preview != null || _leaving
                                      ? null
                                      : () => setState(
                                          () => _chooseDate = !_chooseDate,
                                        ),
                                  onDate: (date) {
                                    journal.setDate(journalDate(date));
                                    setState(() => _chooseDate = false);
                                  },
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (_preview == null && !_leaving)
                        ListenableBuilder(
                          listenable: journal,
                          builder: (context, _) => _actions(journal),
                        ),
                    ],
                  ),
                ),
        ),
      ),
    );
  }
}

/// 编辑与预览相同的纸张标题和日期，可在编辑态展开行内日历。
class _JournalHeader extends StatelessWidget {
  /// [date]为YYYY-MM-DD，[chooseDate]控制日历，[onChoose]为空时只读，[onDate]提交所选日期。
  const _JournalHeader({
    required this.date,
    required this.chooseDate,
    required this.onChoose,
    required this.onDate,
  });

  /// 已保存的记录日期。
  final String date;

  /// 编辑态是否展开日历。
  final bool chooseDate;

  /// 点击日期的回调，null表示只读。
  final VoidCallback? onChoose;

  /// 提交选中日期，不改变原建档时间。
  final ValueChanged<DateTime> onDate;

  /// 使用[context]渲染已保存日期；日期块沿用正文20像素水平留白，右上月份为大写英文。
  @override
  Widget build(BuildContext context) {
    final value = DateTime.parse(date);
    const weekdays = ['星期一', '星期二', '星期三', '星期四', '星期五', '星期六', '星期日'];
    const months = [
      'JANUARY',
      'FEBRUARY',
      'MARCH',
      'APRIL',
      'MAY',
      'JUNE',
      'JULY',
      'AUGUST',
      'SEPTEMBER',
      'OCTOBER',
      'NOVEMBER',
      'DECEMBER',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
          color: const Color(0xffedddd8),
          child: const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '今日成果',
                style: TextStyle(fontSize: 26, color: Color(0xff3e4650)),
              ),
              SizedBox(height: 6),
              Text(
                '把每一天，写成自己的成长',
                style: TextStyle(fontSize: 13, color: Color(0xff6e6c6b)),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Semantics(
              button: onChoose != null,
              label: '记录日期 $date',
              child: InkWell(
                key: const ValueKey('journal-date'),
                onTap: onChoose,
                child: SizedBox(
                  width: 210,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            '${value.year}',
                            style: const TextStyle(
                              fontSize: 11,
                              color: Color(0xff777d83),
                            ),
                          ),
                          Flexible(
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerRight,
                              child: Text(
                                months[value.month - 1],
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: Color(0xff777d83),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const Divider(color: Color(0xff9ca0a0), height: 14),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Flexible(
                            flex: 3,
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerLeft,
                              child: Text(
                                value.day.toString().padLeft(2, '0'),
                                style: const TextStyle(
                                  fontSize: 56,
                                  height: 1.1,
                                  color: Color(0xff3e4650),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Flexible(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${value.month}月',
                                  style: const TextStyle(fontSize: 16),
                                ),
                                Text(
                                  weekdays[value.weekday - 1],
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: Color(0xff777d83),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const Divider(color: Color(0xff9ca0a0), height: 14),
                      const Text(
                        'D A I L Y   R E C O R D',
                        style: TextStyle(fontSize: 9, color: Color(0xff979c9c)),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        if (chooseDate)
          CalendarDatePicker(
            key: const ValueKey('journal-calendar'),
            initialDate: value,
            firstDate: DateTime(1900),
            lastDate: DateTime(2100, 12, 31),
            onDateChanged: onDate,
          ),
        const SizedBox(height: 20),
      ],
    );
  }
}
