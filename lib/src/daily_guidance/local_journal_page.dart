import 'dart:async';
import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_common/runtime/context/context.dart';
import 'package:cses_common/runtime/session/user.dart';
import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:cses_mobile_collab_demo/src/demo/cses_mention_directory.dart';
import 'package:cses_mobile_collab_demo/src/demo/mention_avatar.dart';
import 'package:cses_mobile_collab_demo/src/demo/mention_picker.dart';
import 'package:cses_mobile_collab_demo/src/service/cses_meeting_card_service.dart';
import 'package:cses_mobile_collab_demo/src/service/cses_task_card_service.dart';
import 'package:cses_mobile_collab_demo/src/service/cses_kr_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'journal_draft.dart';
import 'journal_store.dart';
import 'journal_surface.dart';
import 'local_journal_controller.dart';
import 'journal_blockcraft_codec.dart';
import 'journal_json_files.dart';
import 'journal_exchange_keys.dart';

/// 后台将独立[snapshot]转换为可持久化草稿，不持有页面或编辑器资源。
JournalDraft _importJournalSnapshot(Map<String, dynamic> snapshot) =>
    JournalBlockCraftCodec.importSnapshot(snapshot);

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
  /// [mentionDirectory]可注入原生用户目录，null创建本页账号绑定目录；仅查询人员，不包含部门引用。
  /// [jsonFiles]借用导入导出文件端口，默认系统文件框；导入始终创建独立存储和路由。
  const LocalJournalPage({
    super.key,
    required this.store,
    this.mentionDirectory,
    this.jsonFiles = const DeviceJournalJsonFiles(),
  });

  /// 原生用户提及的可选宿主查询端口；由调用方持有，null时本页创建独立会话目录。
  final CollabMentionDirectory? mentionDirectory;

  /// 页面借用的单写入者存储，路由关闭时不释放宿主资源。
  final JournalStore store;

  /// 页面借用的文件交换端口，不由页面释放。
  final JournalJsonFiles jsonFiles;

  /// 创建管理异步加载、退场保存和预览资源的状态。
  @override
  createState() => _LocalJournalPageState();
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

  /// 文件框/转换期间串行化导入导出、编辑和退场，异步返回后复核账号及会话。
  bool _exchanging = false;
  Selection? _selection;

  /// 本页原生提及专用目录；不与其他文档或账号共享缓存，不拥有HTTP连接。
  late final CollabMentionDirectory _mentionDirectory;

  /// 借给正文和预览的实例服务；页面销毁后不接受选人写回，头像资源由Flutter管理。
  late final CollabHostServices _services;

  /// 缓存可选栏目的存在状态，只在结构变化时重建快捷项，普通输入不重建整个正文视图。
  String _sectionActionsSignature = '';

  /// 人员选择期间阻止重复选择、预览和页面退场。
  bool _picking = false;

  /// 当前原生选择会话的失效回调；页面销毁时停表并禁用面板，信号在完整退场后释放。
  VoidCallback? _revokeMentionSelection;

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
    _mentionDirectory = widget.mentionDirectory ?? CsesMentionDirectory();
    _services = CollabHostServices(
      mentionAvatarBuilder: buildDemoMentionAvatar,
      pickMentionUser: _pickMentionUser,
      loadMeetingCard: CsesMeetingCardService().load,
      loadTaskCard: CsesTaskCardService().load,
      kr: CsesKrService(),
    );
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
      final journal = await LocalJournalController.open(
        store: widget.store,
        services: _services,
      );
      if (!mounted) {
        await journal.close();
        return;
      }
      _sectionActionsSignature = _sectionSignature(journal);
      journal.addListener(_refreshSectionActions);
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
    _journal?.removeListener(_refreshSectionActions);
    _revokeMentionSelection?.call();
    _revokeMentionSelection = null;
    unawaited(_release());
    super.dispose();
  }

  /// 完整卸载视图后释放快照与正文；会话关闭会等待仍在进行的保存。
  Future<void> _release() async {
    await _preview?.close();
    await _journal?.close();
  }

  /// 读取[journal]可见的可选栏目身份，不读取正文内容或序列化文档。
  String _sectionSignature(LocalJournalController journal) =>
      '${journal.hasSection('reflection')}:${journal.hasSection('self-check')}';

  /// 响应新增、关闭及撤销重做造成的栏目变化，普通文字和保存状态变化只刷新原有局部视图。
  void _refreshSectionActions() {
    final journal = _journal;
    if (!mounted || journal == null) return;
    final next = _sectionSignature(journal);
    if (next == _sectionActionsSignature) return;
    setState(() => _sectionActionsSignature = next);
  }

  /// 正常退出前冻结输入并等待最新修订落盘；失败留在当前页供重试，不丢失内存正文。
  Future<void> _leave() async {
    if (_leaving || _switching || _picking || _exchanging) return;
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
    if (journal == null || _switching || _leaving || _picking || _exchanging) {
      return;
    }
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
            configuration: journalEditorConfiguration(state.document),
            localOnly: true,
            services: _services,
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

  /// 执行[action]对应的导出或独立打开；捕获完成输入后的快照，异步迟到不回写其他账号。
  /// 文件取消保持原文，转换/写入失败显示可重试提示；导入不覆盖当前日记。
  Future<void> _exchangeJson(String action) async {
    final journal = _journal;
    if (journal == null ||
        _exchanging ||
        _picking ||
        _leaving ||
        _switching ||
        _preview != null ||
        !_sameAccount) {
      return;
    }
    setState(() => _exchanging = true);
    final state = journal.editor.editorState;
    final paused = state.localTransactionsPaused;

    /// 判断本次文件操作是否仍属于活动页面与原业务身份。
    bool current() =>
        mounted &&
        _sameAccount &&
        identical(_journal, journal) &&
        !journal.closed;

    try {
      state.service.keyboardService?.closeKeyboard();
      FocusManager.instance.primaryFocus?.unfocus();
      await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
      await WidgetsBinding.instance.endOfFrame;
      if (!current()) return;
      state.localTransactionsPaused = true;
      if (action == 'export') {
        final snapshot = await journal.exportBlockCraftSnapshotAsync();
        if (!current()) return;
        final saved = await widget.jsonFiles.save(
          snapshot,
          '今日导向-${journal.date}.json',
        );
        if (mounted && current() && saved) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('JSON已导出')));
        }
      } else {
        final snapshot = await widget.jsonFiles.pick();
        if (!current() || snapshot == null) return;
        final draft = await compute(_importJournalSnapshot, snapshot);
        if (!current()) return;
        final store = await widget.jsonFiles.createImportedStore(
          draft,
          '$_companyId:$_userId',
        );
        if (!mounted || !current()) return;
        state.localTransactionsPaused = paused;
        await Navigator.of(context).push<void>(
          MaterialPageRoute(
            builder: (_) => LocalJournalPage(
              store: store,
              mentionDirectory: widget.mentionDirectory,
              jsonFiles: widget.jsonFiles,
            ),
          ),
        );
      }
    } catch (error) {
      if (mounted && current()) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              error is FormatException ? error.message : 'JSON操作失败，原内容已保留，请重试',
            ),
          ),
        );
      }
    } finally {
      if (!state.isDisposed) {
        state.localTransactionsPaused = paused;
        if (!_sameAccount) state.editable = false;
      }
      if (mounted) setState(() => _exchanging = false);
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

  /// 使用借用的[context]为原生提及单选用户；[keyword]为初始搜索词。
  /// [canEdit]由编辑器持有，本页额外复核账号、正文、预览和退场状态。
  /// 等待选择界面完全退出后返回；取消或页面会话失效返回null，不写正文。
  /// Common身份字段没有变更通知，面板期间每200毫秒采样，并在返回前同步复核。
  /// 一旦观测到账号或权限失效便永久禁用该选择会话；账号变化同时冻结旧正文。
  /// 本方法拥有权限信号和定时器，页面销毁时先停表，面板完整退场后解除监听并释放信号。
  Future<CollabMentionUser?> _pickMentionUser(
    BuildContext context, {
    required String keyword,
    required ValueListenable<bool> canEdit,
  }) async {
    final journal = _journal;
    if (!_sameAccount && journal != null && !journal.closed) {
      journal.editor.editorState.editable = false;
    }
    if (!mounted ||
        journal == null ||
        journal.closed ||
        _picking ||
        _leaving ||
        _switching ||
        _preview != null ||
        !_sameAccount ||
        !canEdit.value) {
      return null;
    }
    setState(() => _picking = true);
    final allowed = ValueNotifier<bool>(true);
    Timer? permissionTimer;
    var revoked = false;
    var accountRevoked = false;

    /// 永久撤销当前选择权限并停止采样；页面销毁可调用，不提前释放面板借用的信号。
    void revoke() {
      if (revoked) return;
      revoked = true;
      permissionTimer?.cancel();
      allowed.value = false;
    }

    /// 同步复核本页身份及借用权限；失效后恢复原身份也不重新启用旧选择结果。
    void checkPermission() {
      if (!_sameAccount) accountRevoked = true;
      if (!mounted ||
          accountRevoked ||
          !identical(_journal, journal) ||
          journal.closed ||
          _leaving ||
          _switching ||
          _preview != null ||
          !canEdit.value) {
        revoke();
      }
      if (accountRevoked && !journal.closed) {
        journal.editor.editorState.editable = false;
      }
    }

    _revokeMentionSelection = revoke;
    canEdit.addListener(checkPermission);
    checkPermission();
    if (!revoked) {
      permissionTimer = Timer.periodic(
        const Duration(milliseconds: 200),
        (_) => checkPermission(),
      );
    }
    try {
      final user = await showDemoMentionPicker(
        context,
        canEdit: allowed,
        directory: _mentionDirectory,
        keyword: keyword,
      );
      checkPermission();
      return revoked ? null : user;
    } finally {
      permissionTimer?.cancel();
      canEdit.removeListener(checkPermission);
      checkPermission();
      if (identical(_revokeMentionSelection, revoke)) {
        _revokeMentionSelection = null;
      }
      allowed.dispose();
      if (mounted) setState(() => _picking = false);
    }
  }

  /// 复用原生@人员选择，为[kind]创建领航员或都来帮行，保留来源正文。
  /// 临时暂停本地事务而不撤销编辑权限；完整退场后复核会话、目标修订并恢复输入。
  Future<void> _pickPeople({required String kind}) async {
    final journal = _journal;
    if (journal == null ||
        _picking ||
        _preview != null ||
        _leaving ||
        _switching ||
        !_sameAccount) {
      return;
    }
    final state = journal.editor.editorState;
    if (!state.canAcceptLocalTransactions) return;
    final target = journal.captureInsertionTarget();
    if (target == null) return;
    final wasPaused = state.localTransactionsPaused;

    /// 仅允许仍属本页且可写的同一日记会话接收结果或恢复输入。
    bool current() =>
        mounted &&
        _sameAccount &&
        identical(_journal, journal) &&
        !journal.closed &&
        !state.isDisposed &&
        state.editable &&
        !_leaving &&
        !_switching &&
        _preview == null;

    state.service.keyboardService?.closeKeyboard();
    FocusManager.instance.primaryFocus?.unfocus();
    state.localTransactionsPaused = true;
    try {
      final user = await pickEditorMentionUser(context, state);
      if (!current()) return;
      state.localTransactionsPaused = wasPaused;
      if (user != null) {
        await journal.insertUserEntry(target, user, kind: kind);
      } else if (state.getNodeAtPath(target.selection.start.path)?.id ==
          target.nodeId) {
        state.selection = target.selection;
      }
    } catch (_) {
      if (mounted && current()) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('人员插入失败，原文已保留，请重试')));
      }
    } finally {
      if (!state.isDisposed) state.localTransactionsPaused = wasPaused;
      await WidgetsBinding.instance.endOfFrame;
      if (current()) {
        final selection = state.selection;
        if (selection != null && state.canInputAt(selection)) {
          await state.updateSelectionWithReason(
            selection,
            reason: SelectionUpdateReason.uiEvent,
          );
        }
      }
    }
  }

  /// 为[journal]构建键盘上方的四个宿主动作，已存在的可选栏目不重复提供添加入口。
  /// 各动作的Future包含选人、写入及输入恢复，外壳据此串行化其他工具栏操作。
  List<EditorKeyboardAction> _keyboardActions(LocalJournalController journal) {
    final enabled = !_picking && !_leaving && !_switching && _sameAccount;
    return [
      if (!journal.hasSection('reflection'))
        EditorKeyboardAction(
          id: 'guidance-add-reflection',
          label: '感悟',
          icon: LucideIcons.lightbulb,
          enabled: enabled,
          onPressed: () => _section('reflection'),
        ),
      EditorKeyboardAction(
        id: 'guidance-action-pilot',
        label: '领航员',
        icon: LucideIcons.compass,
        enabled: enabled,
        onPressed: () => _pickPeople(kind: 'pilot'),
      ),
      EditorKeyboardAction(
        id: 'guidance-action-help',
        label: '都来帮',
        icon: LucideIcons.users,
        enabled: enabled,
        onPressed: () => _pickPeople(kind: 'help'),
      ),
      if (!journal.hasSection('self-check'))
        EditorKeyboardAction(
          id: 'guidance-add-self-check',
          label: '自检',
          icon: LucideIcons.listChecks,
          enabled: enabled,
          onPressed: () => _section('self-check'),
        ),
    ];
  }

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
            title: Text(
              journal
                          ?.editor
                          .editorState
                          .document
                          .root
                          .attributes[journalPlainDesktopAttribute] ==
                      true
                  ? '导入文档'
                  : '今日导向',
            ),
            actions: [
              if (journal != null) ...[
                PopupMenuButton<String>(
                  key: const ValueKey('journal-json-menu'),
                  tooltip: 'JSON导入导出',
                  enabled:
                      !_exchanging &&
                      !_leaving &&
                      !_switching &&
                      !_picking &&
                      _preview == null,
                  onSelected: (action) => unawaited(_exchangeJson(action)),
                  icon: const Icon(LucideIcons.fileJson),
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'export', child: Text('导出桌面JSON')),
                    PopupMenuItem(value: 'import', child: Text('打开桌面JSON')),
                  ],
                ),
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
                              keyboardActions:
                                  journal
                                          .editor
                                          .editorState
                                          .document
                                          .root
                                          .attributes[journalPlainDesktopAttribute] ==
                                      true
                                  ? const []
                                  : _keyboardActions(journal),
                              header:
                                  journal
                                          .editor
                                          .editorState
                                          .document
                                          .root
                                          .attributes[journalPlainDesktopAttribute] ==
                                      true
                                  ? const SizedBox.shrink()
                                  : ListenableBuilder(
                                      listenable: journal,
                                      builder: (context, _) => _JournalHeader(
                                        date: journal.date,
                                        chooseDate: _chooseDate,
                                        onChoose: _preview != null || _leaving
                                            ? null
                                            : () => setState(
                                                () =>
                                                    _chooseDate = !_chooseDate,
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
                    ],
                  ),
                ),
        ),
      ),
    );
  }
}

/// 编辑和预览共用的雪山封面，素材随宿主打包，不进入草稿或发起网络请求。
class _JournalCover extends StatelessWidget {
  /// 构建固定封面，不持有编辑会话或外部图片资源。
  const _JournalCover();

  /// 使用[context]的可用宽度和字号安排图片与标题，底部渐变保证文字对比度。
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final scaledTitle = MediaQuery.textScalerOf(context).scale(22);
        final extraHeight = (scaledTitle - 22).clamp(0.0, 44.0) * 1.4;
        final height = (constraints.maxWidth / 2.1).clamp(184.0, 260.0);
        return SizedBox(
          key: const ValueKey('journal-cover'),
          height: height + extraHeight,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Image.asset(
                'assets/images/daily_guidance_mountain.png',
                key: const ValueKey('journal-cover-image'),
                fit: BoxFit.cover,
                alignment: const Alignment(0, -.3),
                excludeFromSemantics: true,
                errorBuilder: (_, error, stackTrace) => const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0xffc6a9ad), Color(0xff26394c)],
                    ),
                  ),
                ),
              ),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0x000b1726), Color(0xb30b1726)],
                    stops: [.3, 1],
                  ),
                ),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 20, 20, 18),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '今日导向',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 22,
                        height: 1.2,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                    SizedBox(height: 5),
                    Text(
                      '聚焦每日核心，做深做细各项成果',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.4,
                        color: Color(0xfff0edef),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
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
        const _JournalCover(),
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
