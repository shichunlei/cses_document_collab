import 'dart:async';
import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:flutter/foundation.dart';

import 'journal_draft.dart';
import 'guidance_entries.dart';
import 'guidance_people.dart';
import 'journal_input.dart';
import 'journal_store.dart';
import 'journal_blockcraft_codec.dart';
import 'journal_exchange_keys.dart';

/// 单个日记路由拥有的正文与自动保存会话，借用存储，不创建网络或协同资源。
///
/// ```dart
/// import 'package:cses_mobile_collab_demo/src/daily_guidance/local_journal_controller.dart';
/// import 'package:cses_mobile_collab_demo/src/daily_guidance/journal_store.dart';
/// Future<void> openJournal(JournalStore store) async {
///   final journal = await LocalJournalController.open(store: store);
///   journal.setDate('2026-10-22');
///   await journal.flush();
///   // 正文视图卸载后关闭，重复关闭共享同一结果。
///   await journal.close();
/// }
/// ```
final class LocalJournalController extends ChangeNotifier {
  /// 接管由[draft]恢复的文档与监听；[store]仍由宿主持有，[saveDelay]为去抖间隔。
  /// [services]借用此页面的业务端口，不获取目录、认证或头像资源所有权。
  LocalJournalController._(
    JournalStore store,
    JournalDraft draft,
    Duration saveDelay,
    CollabHostServices? services,
  ) : _store = store,
      _draft = draft,
      _saveDelay = saveDelay {
    final document = Document.fromJson(
      jsonDecode(_draft.documentJson) as Map<String, dynamic>,
    );
    try {
      JournalBlockCraftCodec.restoreIdentities(
        document,
        draft.blockCraftIdsJson,
      );
    } catch (_) {
      document.dispose();
      rethrow;
    }
    editor = DocumentEditorController(
      document: document,
      commandContext: EditorCommandContext(
        configuration: journalEditorConfiguration(document),
        localOnly: true,
        services: services,
        pastePlainText: pasteFromClipboard,
        copySelection: copySelection,
      ),
    );
    editor.editorState.transactionGuard = _allows;
    editor.addListener(_changed);
  }

  /// 从借用的[store]读取草稿后创建会话；无草稿以[now]或当前设备日期新建并安排保存。
  /// [saveDelay]默认500毫秒且不能为负。读取/校验失败直接抛错，不创建替代草稿。
  /// [services]为可选页面实例服务；null使用空端口，关闭会话不会释放宿主资源。
  static Future<LocalJournalController> open({
    required JournalStore store,
    DateTime? now,
    Duration saveDelay = const Duration(milliseconds: 500),
    CollabHostServices? services,
  }) async {
    if (saveDelay.isNegative) throw ArgumentError.value(saveDelay, 'saveDelay');
    final saved = await store.read();
    final draft = saved == null
        ? JournalDraft.blank(now ?? DateTime.now())
        : JournalDraft.fromJson(saved.toJson());
    final result = LocalJournalController._(store, draft, saveDelay, services);
    if (saved == null || saved.needsMigration) result._changed();
    return result;
  }

  /// 此会话独占的选人目标令牌，防止其他会话复用捕获结果。
  final Object _targetOwner = Object();

  final JournalStore _store;
  JournalDraft _draft;
  final Duration _saveDelay;

  /// 此会话唯一拥有的正文，视图只借用，不得另行close或dispose。
  late final DocumentEditorController editor;
  Timer? _timer;
  Future<bool>? _saving;
  Future<void>? _closing;
  int _revision = 0;
  int _savedRevision = 0;
  bool _disposed = false;

  /// ChangeNotifier可以先同步释放；异步保存和正文关闭完成后不再重复释放或通知它。
  bool _notifierDisposed = false;
  String? _error;

  /// 记录日期，不随重新打开或跨天改变。
  String get date => _draft.date;

  /// 是否有尚未成功落盘的修改；包括首次新建的空日记。
  bool get dirty => _revision != _savedRevision;

  /// 当前是否有串行保存任务在途。
  bool get saving => _saving != null;

  /// 最近一次保存失败的可读提示，成功后清除。
  String? get error => _error;

  /// 关闭开始后页面不可再向正文写入。
  bool get closed => _closing != null || _disposed;

  /// 捕获当前已完成事务为独立桌面快照；不读取去抖磁盘稿，不建立网络或原生文档。
  /// 关闭后抛StateError；调用者应先结束输入合成，再保存返回的JSON。
  Map<String, dynamic> exportBlockCraftSnapshot() {
    if (closed) throw StateError('日记已关闭');
    return JournalBlockCraftCodec.exportDraft(_captureDraft());
  }

  /// 捕获已完成输入的独立草稿后在后台转换桌面JSON，避免大文档转换阻塞界面。
  /// 关闭后抛StateError；完成值属于捕获时的修订，调用方异步返回后须复核账号和页面身份。
  Future<Map<String, dynamic>> exportBlockCraftSnapshotAsync() {
    if (closed) throw StateError('日记已关闭');
    return compute(JournalBlockCraftCodec.exportDraft, _captureDraft());
  }

  /// 以实时正文创建独立保存值，不修改编辑树或已有草稿身份。
  JournalDraft _captureDraft() => JournalDraft(
    id: _draft.id,
    date: date,
    createdAt: _draft.createdAt,
    updatedAt: DateTime.now().toUtc(),
    timezoneOffsetMinutes: _draft.timezoneOffsetMinutes,
    documentJson: jsonEncode(editor.editorState.document.toJson()),
    blockCraftIdsJson: JournalBlockCraftCodec.captureIdentities(
      editor.editorState.document,
    ),
  );

  /// 修改记录日期[value]并安排保存，格式必须为真实YYYY-MM-DD，否则抛ArgumentError。
  void setDate(String value) {
    if (!isJournalDate(value)) throw ArgumentError.value(value, 'value');
    if (closed || date == value) return;
    _draft = JournalDraft(
      id: _draft.id,
      date: value,
      createdAt: _draft.createdAt,
      updatedAt: DateTime.now().toUtc(),
      timezoneOffsetMinutes: _draft.timezoneOffsetMinutes,
      documentJson: _draft.documentJson,
    );
    _changed();
  }

  /// 将捕获的[selection]复制为可读纯文本；[cut]默认false，为true时写剪贴板成功后才原子删除。
  /// 已知引用展开为@名称，普通文字/软换行保留；仅支持同栏目正文，跨栏目复制和剪切均拒绝。
  /// 写入失败、等待期间修订/选区/权限变化或关闭时抛错并保留原文；调用者负责提示。
  Future<void> copySelection(Selection selection, {bool cut = false}) async {
    if (closed || (cut && !editor.editorState.editable)) return;
    final state = editor.editorState;
    final range = selection.normalized;
    if (range.isCollapsed) return;
    final nodes = state.getNodesInSelection(range);
    if (nodes.isEmpty ||
        nodes.any(
          (node) =>
              node.parent?.type != journalSectionType ||
              node.parent != nodes.first.parent ||
              !isJournalTextNode(node),
        )) {
      throw StateError('当前选区不支持复制');
    }
    final text = journalSelectionPlainText(nodes, range);
    if (text.contains('\uFFFC')) throw StateError('选区含无法复制的对象');
    if (cut &&
        (text.replaceAll('\n', '').length >
                journalConfiguration.maxCharacters ||
            text.split('\n').length > journalConfiguration.maxBlocks)) {
      throw StateError('展开引用后的内容超过本页粘贴容量，原文已保留');
    }
    final revision = _revision;
    var invalidated = false;

    /// 标记剪贴板等待期间的权限或选区变化，恢复后也不再删除源文。
    void invalidate() {
      if (!state.editable || (state.selection?.normalized != range)) {
        invalidated = true;
      }
    }

    if (cut) {
      state.editableNotifier.addListener(invalidate);
      state.selectionNotifier.addListener(invalidate);
    }
    try {
      await AppFlowyClipboard.setData(text: text);
      if (!cut) return;
      if (closed ||
          invalidated ||
          !state.editable ||
          _revision != revision ||
          (state.selection?.normalized != range)) {
        throw StateError('正文、选区或编辑权限已变化，剪切未删除原文');
      }
      if (state.undoManager.undoStack.isNonEmpty) {
        state.undoManager.undoStack.last.seal();
      }
      await state.deleteSelection(range);
    } finally {
      if (cut) {
        state.editableNotifier.removeListener(invalidate);
        state.selectionNotifier.removeListener(invalidate);
      }
    }
  }

  /// 读取剪贴板纯文本，在正文修订与选区仍相同时原子替换；不解析HTML、链接或电话号码。
  /// 栏目外、跨栏目或已关闭的目标不写入；容量、对象或迟到结果无效时抛StateError，保留原文。
  /// 页面和移动菜单共用此入口，调用者负责展示失败提示；不取得剪贴板资源所有权。
  Future<void> pasteFromClipboard() async {
    if (closed || !editor.editorState.editable) return;
    final state = editor.editorState;
    final selection = state.selection;
    if (selection == null) return;
    final revision = _revision;
    final data = await AppFlowyClipboard.getData();
    if (closed || !state.editable) return;
    if (_revision != revision || state.selection != selection) {
      throw StateError('正文或选区已变化，请重新粘贴');
    }
    final text = data.text;
    if (text == null || text.isEmpty) return;
    final range = selection.normalized;
    final nodes = state.getNodesInSelection(range);
    if (nodes.isEmpty ||
        nodes.any(
          (node) =>
              node.parent?.type != journalSectionType ||
              node.parent != nodes.first.parent ||
              !isJournalTextNode(node),
        )) {
      return;
    }
    final normalized = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final lines = normalized.split('\n');
    if (normalized.contains('\uFFFC') ||
        normalized.replaceAll('\n', '').length >
            journalConfiguration.maxCharacters ||
        lines.length > journalConfiguration.maxBlocks) {
      throw StateError('粘贴内容超出日记支持的格式或容量');
    }
    final first = nodes.first;
    final prefix = first.delta!.slice(0, range.start.offset);
    final prefixLength = prefix.length;
    final suffix = nodes.last.delta!.slice(range.end.offset);
    final replacement = Delta()
      ..addAll(prefix)
      ..insert(lines.first);
    if (lines.length == 1) replacement.addAll(suffix);
    final inserted = <Node>[];
    for (var i = 1; i < lines.length; i++) {
      final delta = Delta()..insert(lines[i]);
      if (i == lines.length - 1) delta.addAll(suffix);
      inserted.add(paragraphNode(delta: delta));
    }
    final transaction = state.transaction
      ..updateNode(first, {blockComponentDelta: replacement.toJson()});
    // 保留首段后，后续节点全部在其后删除/插入；路径已经是目标坐标，不再做自动变换。
    if (nodes.length > 1) {
      transaction.add(
        DeleteOperation(nodes[1].path, nodes.skip(1).toList()),
        transform: false,
      );
    }
    if (inserted.isNotEmpty) {
      transaction.add(
        InsertOperation(first.path.next, inserted),
        transform: false,
      );
    }
    transaction
      ..afterSelection = Selection.collapsed(
        Position(
          path: [...first.path.parent, first.path.last + inserted.length],
          offset: lines.last.length + (lines.length == 1 ? prefixLength : 0),
        ),
      )
      ..selectionExtraInfo = {}
      ..customSelectionType = SelectionType.inline;
    if (!state.canApplyTransaction(transaction)) {
      throw StateError('粘贴后的内容超过日记容量或栏目边界');
    }
    if (state.undoManager.undoStack.isNonEmpty) {
      state.undoManager.undoStack.last.seal();
    }
    await state.apply(transaction, skipHistoryDebounce: true);
  }

  /// 正文事务或日期变化后更新修订号并安排去抖保存；旧任务成功不能标记新修订已保存。
  void _changed() {
    if (closed) return;
    _revision++;
    _timer?.cancel();
    _timer = Timer(_saveDelay, () => unawaited(flush()));
    notifyListeners();
  }

  /// 取消去抖并串行保存直至覆盖当前修订，失败返回false并保留dirty与错误，不抛存储异常。
  /// 多个调用者共享在途任务；退出应等待true后再销毁路由。
  Future<bool> flush() {
    _timer?.cancel();
    _timer = null;
    if (_disposed) return Future.value(!dirty);
    if (_saving != null) return _saving!;
    if (!dirty) return Future.value(true);
    final completer = Completer<bool>();
    _saving = completer.future;
    if (!_notifierDisposed) notifyListeners();
    unawaited(_save(completer));
    return completer.future;
  }

  /// 为[completion]执行串行保存循环，使用独立快照隔离等待中的后续编辑；所有存储失败转为状态。
  Future<void> _save(Completer<bool> completion) async {
    var success = false;
    try {
      while (dirty) {
        final revision = _revision;
        final snapshot = _captureDraft();
        await _store.write(snapshot);
        _savedRevision = revision;
        _error = null;
      }
      success = true;
    } catch (_) {
      _error = '保存失败，内容仍保留在此页，请重试';
    } finally {
      _saving = null;
      if (!_notifierDisposed) notifyListeners();
      completion.complete(success);
    }
  }

  /// 在事务提交前校验[transaction]的栏目边界、受控对象和总容量。
  /// 普通结构编辑只能在一个栏目内；栏目增删须携带根版本及关闭草稿更新，撤销同样校验。
  bool _allows(Transaction transaction) {
    if (closed) return false;
    if (editor
            .editorState
            .document
            .root
            .attributes[journalDesktopImportAttribute] ==
        true) {
      return _allowsImported(transaction);
    }
    normalizeJournalTextInput(editor.editorState, transaction);
    final sectionCommand = transaction.operations.any(
      (op) =>
          op is UpdateOperation &&
          op.path.isEmpty &&
          op.attributes.containsKey('guidance_section_revision'),
    );
    final sectionCount = editor.editorState.document.root.children.length;
    for (final op in transaction.operations) {
      if (op.path.length != 2 ||
          op.path.first < 0 ||
          op.path.first >= sectionCount) {
        if (!sectionCommand || op.path.length > 1) return false;
      }
      if (op is InsertOperation &&
          op.path.length == 2 &&
          op.nodes.any((node) => !isJournalTextNode(node))) {
        return false;
      }
      if (op is UpdateTextOperation && !validJournalDelta(op.delta)) {
        return false;
      }
    }
    if (transaction.operations.every((op) => op is UpdateTextOperation)) {
      return _allowsText(transaction);
    }
    if (!sectionCommand &&
        transaction.operations.any(
          (op) => op is InsertOperation || op is DeleteOperation,
        ) &&
        transaction.operations.map((op) => op.path.first).toSet().length > 1) {
      return false;
    }
    final copy = Document.fromJson(
      jsonDecode(jsonEncode(editor.editorState.document.toJson()))
          as Map<String, dynamic>,
    );
    try {
      for (final op in transaction.operations) {
        final ok = switch (op) {
          InsertOperation() => copy.insert(
            op.path,
            op.nodes.map((node) => node.copyWith()),
          ),
          DeleteOperation() => copy.delete(op.path, op.nodes.length),
          UpdateOperation() => copy.update(op.path, op.attributes),
          UpdateTextOperation() => copy.updateText(op.path, op.delta),
        };
        if (!ok) return false;
      }
      validateJournalDocument(copy);
      return true;
    } catch (_) {
      return false;
    } finally {
      copy.dispose();
    }
  }

  /// 对完整桌面转换树的[transaction]先预演再校验；锁定祖先及跨栏目编辑整次拒绝。
  /// 正式块内部的文字、表格及对象事务可进入任意后代路径，不使用原日记叶块限制。
  bool _allowsImported(Transaction transaction) {
    final document = editor.editorState.document;
    final ids = journalContentNodes([
      document.root,
    ]).map((node) => node.attributes['bc.id'] ?? node.id).toSet();
    for (final operation
        in transaction.operations.whereType<DeleteOperation>()) {
      for (final node in journalContentNodes(operation.nodes)) {
        ids.remove(node.attributes['bc.id'] ?? node.id);
      }
    }
    for (final operation
        in transaction.operations.whereType<InsertOperation>()) {
      for (final node in journalContentNodes(operation.nodes)) {
        final id = node.attributes['bc.id'] ?? node.id;
        if (!ids.add(id)) {
          node.updateAttributes({
            'bc.id': node.id,
            'cses_collab_block_id': node.id,
          });
          ids.add(node.id);
        }
      }
    }
    final sectionCommand = transaction.operations.any(
      (op) =>
          op is UpdateOperation &&
          op.path.isEmpty &&
          op.attributes.containsKey('guidance_section_revision'),
    );
    final sections = <int>{};
    for (final op in transaction.operations) {
      if (op.path.length < 2 && !sectionCommand) return false;
      if (op.path.isNotEmpty) sections.add(op.path.first);
      Node? node = document.nodeAtPath(op.path);
      while (node != null) {
        final lock = BlockCraftJsonCodec.properties(
          node,
          metadata: true,
        )['lock'];
        if (lock is String && lock.isNotEmpty) {
          return false;
        }
        node = node.parent;
      }
      if (op is DeleteOperation) {
        for (final child in journalContentNodes(op.nodes)) {
          final lock = BlockCraftJsonCodec.properties(
            child,
            metadata: true,
          )['lock'];
          if (lock is String && lock.isNotEmpty) return false;
        }
      }
    }
    if (!sectionCommand && sections.length > 1) return false;
    final copy = Document.fromJson(
      jsonDecode(jsonEncode(document.toJson())) as Map<String, dynamic>,
    );
    try {
      for (final op in transaction.operations) {
        final ok = switch (op) {
          InsertOperation() => copy.insert(
            op.path,
            op.nodes.map((node) => node.copyWith()),
          ),
          DeleteOperation() => copy.delete(op.path, op.nodes.length),
          UpdateOperation() => copy.update(op.path, op.attributes),
          UpdateTextOperation() => copy.updateText(op.path, op.delta),
        };
        if (!ok) return false;
      }
      validateJournalDocument(copy);
      return true;
    } catch (_) {
      return false;
    } finally {
      copy.dispose();
    }
  }

  /// 只对[transaction]涉及的文字合成增量，避免每次按键序列化整篇日记；结构事务另行预演。
  bool _allowsText(Transaction transaction) {
    try {
      var length = editor.editorState.document.root.children.fold<int>(
        0,
        (sum, section) =>
            sum +
            section.children.fold<int>(
              0,
              (sum, node) => sum + node.delta!.length,
            ),
      );
      for (final section in closedJournalSections(
        editor.editorState.document,
      )) {
        length += section.children.fold<int>(
          0,
          (sum, node) => sum + node.delta!.length,
        );
      }
      var references =
          [
            ...editor.editorState.document.root.children,
            ...closedJournalSections(editor.editorState.document),
          ].fold<int>(
            0,
            (sum, section) =>
                sum +
                section.children.fold<int>(
                  0,
                  (sum, node) => sum + journalDeltaMentionCount(node.delta!),
                ),
          );
      final changed = <String, Delta>{};
      for (final op in transaction.operations.cast<UpdateTextOperation>()) {
        final key = op.path.join('/');
        final before =
            changed[key] ?? editor.editorState.getNodeAtPath(op.path)?.delta;
        if (before == null) return false;
        final after = before.compose(op.delta);
        if (!after.every((op) => op is TextInsert) ||
            !validJournalDelta(after, complete: true)) {
          return false;
        }
        changed[key] = after;
        length += after.length - before.length;
        references +=
            journalDeltaMentionCount(after) - journalDeltaMentionCount(before);
      }
      return length <= journalConfiguration.maxCharacters && references <= 500;
    } catch (_) {
      return false;
    }
  }

  /// 当前可见栏目是否包含[kind]，不以固定下标判断。
  bool hasSection(String kind) => editor.editorState.document.root.children.any(
    (node) => node.attributes['section'] == kind,
  );

  /// 添加或恢复[kind]栏目；仅接受感悟/自检，已有时不重复。关闭正文可完整撤销恢复。
  Future<void> addSection(String kind) async {
    if (closed ||
        !editor.editorState.editable ||
        !journalSections.skip(1).contains(kind) ||
        hasSection(kind)) {
      return;
    }
    final state = editor.editorState;
    final hidden = closedJournalSections(state.document);
    final section =
        hidden
            .where((node) => node.attributes['section'] == kind)
            .firstOrNull ??
        Node(
          type: journalSectionType,
          attributes: {'section': kind},
          children: [paragraphNode()],
        );
    hidden.removeWhere((node) => node.attributes['section'] == kind);
    final transaction = _sectionTransaction(hidden);
    final index = state.document.root.children.length;
    transaction.add(InsertOperation([index], [section]), transform: false);
    transaction.afterSelection = Selection.collapsed(
      Position(path: [index, 0]),
    );
    await _applyCommand(transaction);
  }

  /// 关闭[kind]可选栏目并把完整内容放入根草稿区；不清空、不占可见空间，可恢复/撤销。
  Future<void> closeSection(String kind) async {
    if (closed || !editor.editorState.editable || kind == 'record') return;
    final state = editor.editorState;
    final section = state.document.root.children
        .where((node) => node.attributes['section'] == kind)
        .firstOrNull;
    if (section == null) return;
    final hidden = [
      ...closedJournalSections(state.document),
      section.copyWith(),
    ];
    final transaction = _sectionTransaction(hidden);
    transaction.add(DeleteOperation(section.path, [section]), transform: false);
    transaction.afterSelection = Selection.collapsed(Position(path: [0, 0]));
    await _applyCommand(transaction);
  }

  /// 将关闭区[hidden]和栏目版本写在同一事务内，供增删及撤销识别。
  Transaction _sectionTransaction(List<Node> hidden) {
    final root = editor.editorState.document.root;
    return editor.editorState.transaction..updateNode(root, {
      journalClosedSectionsAttribute: hidden
          .map((node) => node.toJson())
          .toList(),
      'guidance_section_revision':
          (root.attributes['guidance_section_revision'] as int? ?? 0) + 1,
    });
  }

  /// 捕获人员选择前的稳定目标；无光标时使用今日记录末尾，跨段选区拒绝。
  GuidanceInsertionTarget? captureInsertionTarget() {
    if (closed) return null;
    final state = editor.editorState;
    final last = state.document.root.children.first.children.last;
    final selection =
        state.selection ??
        Selection.collapsed(
          Position(path: last.path, offset: last.delta!.length),
        );
    if (!selection.isSingle) return null;
    final node = state.getNodeAtPath(selection.start.path);
    if (node == null || !isJournalTextNode(node)) return null;
    return GuidanceInsertionTarget._(
      selection: selection,
      nodeId: node.id,
      revision: _revision,
      owner: _targetOwner,
    );
  }

  /// 在仍有效的[target]插入[people]；[kind]为空表示句内@，其余为task/help/pilot可写条目。
  /// 一次多选生成一条；task保留旧格式，help/pilot仅接受人员并写原生@，拒绝组织。
  /// 现有文字转任务保留正文，都来帮/领航员另起业务行。迟到结果抛StateError；
  /// 人数不在1至100、无效类型或help/pilot含组织时抛ArgumentError，不修改正文。
  Future<void> insertPeople(
    GuidanceInsertionTarget target,
    List<GuidancePerson> people, {
    String? kind,
  }) async {
    if (people.isEmpty || people.length > 100) {
      throw ArgumentError('无效的人员数量');
    }
    if (kind == 'help' || kind == 'pilot') {
      if (people.any((person) => person.type != 'user')) {
        throw ArgumentError('都来帮和领航员仅支持人员提及');
      }
      final users = <String, GuidancePerson>{};
      for (final person in people) {
        users.putIfAbsent(person.id, () => person);
      }
      final mentions = Delta();
      for (final person in users.values) {
        mentions.addAll(
          EditorUserMention.createDelta(
            CollabMentionUser(id: person.id, name: person.name),
          ),
        );
      }
      await _insertMentions(target, mentions, kind: kind);
      return;
    }
    await _insertMentions(target, guidanceMentionDelta(people), kind: kind);
  }

  /// 在仍有效的[target]后创建[kind]业务行，内容为[user]的原生人员提及和空格。
  /// [kind]仅接受help/pilot；身份或类型非法抛ArgumentError，目标过期抛StateError。
  /// 不替换来源正文，整条创建为一次可撤销事务；不接受组织或旧自定义对象。
  Future<void> insertUserEntry(
    GuidanceInsertionTarget target,
    CollabMentionUser user, {
    required String kind,
  }) async {
    if (kind != 'help' && kind != 'pilot') {
      throw ArgumentError.value(kind, 'kind', '仅支持都来帮或领航员');
    }
    await _insertMentions(
      target,
      EditorUserMention.createDelta(user),
      kind: kind,
    );
  }

  /// 将独立的[mentions]写到[target]，以[kind]决定句内替换或业务行；校验修订及所属会话。
  /// [kind]为空为句内@，否则仅接受task/help/pilot；拒绝过期或不可写目标并保留正文。
  Future<void> _insertMentions(
    GuidanceInsertionTarget target,
    Delta mentions, {
    String? kind,
  }) async {
    if (closed ||
        !editor.editorState.editable ||
        target.revision != _revision ||
        !identical(target._owner, _targetOwner)) {
      throw StateError('正文已变化，请重新选择人员');
    }
    if (kind != null && !const {'task', 'help', 'pilot'}.contains(kind)) {
      throw ArgumentError('无效的业务条目');
    }
    final state = editor.editorState;
    final node = state.getNodeAtPath(target.selection.start.path);
    if (node?.id != target.nodeId || node?.parent?.type != journalSectionType) {
      throw StateError('插入位置已失效');
    }
    // Delta.addAll会在合并相同格式时修改末尾run，先保存插入长度，避免后缀改变光标位置。
    final mentionLength = mentions.length;
    final transaction = state.transaction..beforeSelection = target.selection;
    if (kind == null) {
      final range = target.selection.normalized;
      final replacement = Delta()
        ..addAll(node!.delta!.slice(0, range.start.offset))
        ..addAll(mentions)
        ..addAll(node.delta!.slice(range.end.offset));
      transaction.updateNode(node, {blockComponentDelta: replacement.toJson()});
      transaction.afterSelection = Selection.collapsed(
        Position(path: node.path, offset: range.start.offset + mentionLength),
      );
    } else {
      final replace =
          kind == 'task' && node!.attributes[guidanceEntryAttribute] == null;
      final delta = Delta()..addAll(mentions);
      if (replace) delta.addAll(node.delta!);
      final entry = paragraphNode(
        delta: delta,
        attributes: {
          guidanceEntryAttribute: kind,
          'guidance_entry_id': 'entry-${DateTime.now().microsecondsSinceEpoch}',
          'guidance_done': false,
        },
      );
      if (replace) {
        transaction.add(DeleteOperation(node.path, [node]), transform: false);
      }
      final path = replace ? node.path : node!.path.next;
      transaction.add(InsertOperation(path, [entry]), transform: false);
      transaction.afterSelection = Selection.collapsed(
        Position(path: path, offset: delta.length),
      );
    }
    await _applyCommand(transaction);
  }

  /// 校验并应用独立可撤销的[transaction]；拒绝时抛错而不更改正文。
  Future<void> _applyCommand(Transaction transaction) async {
    final state = editor.editorState;
    transaction
      ..selectionExtraInfo = {}
      ..customSelectionType = SelectionType.inline;
    if (!state.canApplyTransaction(transaction)) {
      throw StateError('操作超过日记容量或栏目边界');
    }
    if (state.undoManager.undoStack.isNonEmpty) {
      state.undoManager.undoStack.last.seal();
    }
    await state.apply(transaction, skipHistoryDebounce: true);
  }

  /// 视图卸载后冻结编辑，等待在途保存并释放正文、监听和定时器；重复关闭安全。
  /// 保存失败仍保留旧磁盘草稿，正常导航应先通过flush确认成功。
  Future<void> close() => _closing ??= _close();

  /// 发起与close相同的冻结和清理；需要确认最后一次保存完成的所有者应显式等待close。
  /// 异步资源释放异常交给Flutter错误管道，不静默丢弃。
  @override
  void dispose() {
    if (_notifierDisposed) return;
    unawaited(
      close().catchError((Object error, StackTrace stack) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stack,
            library: 'local journal',
            context: ErrorDescription('关闭本地日记会话'),
          ),
        );
      }),
    );
    _notifierDisposed = true;
    super.dispose();
  }

  /// 按冻结正文、保存、注销监听、释放正文的顺序关闭自有资源。
  Future<void> _close() async {
    editor.editorState.editable = false;
    await flush();
    editor.removeListener(_changed);
    await editor.close();
    _disposed = true;
    if (!_notifierDisposed) {
      _notifierDisposed = true;
      super.dispose();
    }
  }
}

/// 人员选择期间保留的单段目标；不可用于其他会话或修订。
///
/// ```dart
/// import 'package:cses_mobile_collab_demo/src/daily_guidance/local_journal_controller.dart';
/// GuidanceInsertionTarget? capture(LocalJournalController journal) =>
///     journal.captureInsertionTarget();
/// ```
final class GuidanceInsertionTarget {
  /// [selection]为捕获时的段内选区，[nodeId]标识目标节点，[revision]为会话修订。
  /// [_owner]绑定唯一控制器，不能把目标带到另一编辑会话。
  const GuidanceInsertionTarget._({
    required this.selection,
    required this.nodeId,
    required this.revision,
    required this._owner,
  });

  /// 仅所属控制器持有的身份令牌，不随草稿保存。
  final Object _owner;

  /// 捕获的段内选区。
  final Selection selection;

  /// 当前编辑树内的稳定节点身份。
  final String nodeId;

  /// 捕获时的会话修订；编辑或日期变化使目标失效。
  final int revision;
}
