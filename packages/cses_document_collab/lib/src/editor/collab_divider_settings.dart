import 'package:cses_document_collab/src/editor/core/editor_command_context.dart';
import 'package:cses_document_collab/src/model/collab_host_services.dart';
import 'dart:convert';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/collab_block_actions.dart';
import 'package:cses_document_collab/src/editor/collab_block_locks.dart';
import 'package:cses_document_collab/src/editor/collab_paragraph_links.dart';
import 'package:cses_document_collab/src/editor/editor_shortcut_toolbar.dart';
import 'package:cses_document_collab/src/model/collab_color_palette.dart';
import 'package:cses_document_collab/src/model/collab_divider.dart';
import 'package:cses_document_collab/src/ui/modal/collab_bottom_sheet.dart';
import 'package:cses_document_collab/src/ui/modal/collab_color_picker.dart';
import 'package:cses_document_collab/src/ui/modal/collab_divider_visual.dart';
import 'package:cses_document_collab/src/ui/modal/collab_menu_row.dart';
import 'package:cses_document_collab/src/ui/modal/collab_modal.dart';
import 'package:cses_document_collab/src/ui/modal/collab_modal_colors.dart';
import 'package:cses_document_collab/src/ui/modal/collab_modal_segments.dart';
import 'package:cses_document_collab/src/ui/modal/collab_switch_row.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// 打开稳定 [id] 对应分割线的统一设置面板；借用 [context] 和 [editor]。
/// 外观即时写入，锁开关在面板内提交；锁定时保留查看、授权解锁和宿主块链接。
/// 等待退场后执行插入/删除，插入才恢复新段落光标；远端锁或撤权使旧会话永久失效。
Future<void> showCollabDividerSettings(BuildContext context, EditorState editor, String id) async {
  if (editor.isDisposed || !editor.editable || findCollabDivider(editor, id) == null || _open[editor] == true) return;
  final host = collabBlockActionContext(context);
  final session = _DividerSession(editor, id);
  _open[editor] = true;
  try {
    await runEditorHeaderAction<void>(
      host,
      editor,
      () async {
        final result = await showCollabBottomSheet<_DividerResult>(
          context: host,
          useRootNavigator: false,
          builder: (_) => _DividerSettings(editor: editor, session: session),
        );
        session.action = result?.action;
        if (result?.action != null && host.mounted) await session.execute(host, result!);
      },
      protectBlockLocks: false,
      canRestore: () =>
          session.current &&
          (session.action == _DividerAction.insert || (session.action == null && !session.lockChanged)),
      selectionAfterAction: () {
        final node = session.insertedId == null ? null : findCollabActionNode(editor, session.insertedId!);
        return node == null ? null : Selection.single(path: node.path, startOffset: 0);
      },
    );
  } catch (error, stack) {
    EditorCommandContext.report(editor, '分割线操作失败', error: error, stackTrace: stack, tag: 'DocCollab');
    if (host.mounted && session.sameHost) {
      ScaffoldMessenger.maybeOf(host)?.showSnackBar(const SnackBar(content: Text('操作失败，请重试')));
    }
  } finally {
    session.dispose();
    _open[editor] = null;
  }
}

/// 在借用 [context]/[editor] 中暂存新分割线外观，完成并退场后返回草稿；取消返回null。
/// [canCreate] 可检查外层稳定书签和宿主会话，默认只验证编辑权限；false时禁止完成。
/// 调用方负责隔离正文输入及将返回属性一次插入；本函数不写正文、选区或历史。
///
/// ```dart
/// import 'package:appflowy_editor/appflowy_editor.dart';
/// import 'package:cses_document_collab/src/editor/collab_divider_settings.dart';
/// import 'package:cses_document_collab/src/editor/editor_shortcut_toolbar.dart';
/// import 'package:cses_document_collab/src/model/collab_divider.dart';
/// import 'package:flutter/widgets.dart';
/// Future<CollabDivider?> choose(BuildContext context, EditorState editor) =>
///   runEditorHeaderAction<CollabDivider>(context, editor,
///     () => showCollabDividerInput(context, editor));
/// // 返回值仅为本地草稿，创建者仍需按稳定插入书签提交。
/// ```
Future<CollabDivider?> showCollabDividerInput(
  BuildContext context,
  EditorState editor, {
  bool Function()? canCreate,
}) async {
  if (editor.isDisposed || !editor.editable || _open[editor] == true) return null;
  _open[editor] = true;
  final services = EditorCommandContext.of(editor).services;
  try {
    final result = await showCollabBottomSheet<_DividerResult>(
      context: context,
      useRootNavigator: false,
      builder: (_) => _DividerSettings(
        editor: editor,
        canCreate: () => identical(EditorCommandContext.of(editor).services, services) && (canCreate?.call() ?? true),
      ),
    );
    if (!context.mounted ||
        editor.isDisposed ||
        !editor.editable ||
        !identical(EditorCommandContext.of(editor).services, services) ||
        !(canCreate?.call() ?? true)) {
      return null;
    }
    return result?.values == null ? null : CollabDivider(result!.values!);
  } finally {
    _open[editor] = null;
  }
}

/// 同一借用编辑器仅允许一个分割线面板，不延长编辑器生命周期。
final _open = Expando<bool>('divider-panel');

/// 面板退场后执行的操作；锁开关独立在当前面板内完成。
enum _DividerAction {
  /// 复制宿主按稳定块身份生成的链接，不恢复输入。
  copy,

  /// 插入后置正文并恢复新光标。
  insert,

  /// 删除分割线，末块留下空段落。
  delete,

  /// 定位有效继承锁的来源，不恢复输入。
  locate,
}

/// 新建结果带[values]草稿；既有块命令带[action]及点击时的属性[snapshot]。
typedef _DividerResult = ({Map<String, dynamic>? values, _DividerAction? action, String? snapshot});

/// 面板借用编辑器，拥有节点/权限监听、设置区滚动控制器及局部外观状态。
class _DividerSettings extends StatefulWidget {
  /// [editor]为借用编辑器；[session]非null编辑稳定目标，否则创建草稿。
  /// [canCreate]仅创建模式使用，默认只校验编辑权限；会话由入口释放。
  const _DividerSettings({required this.editor, this.session, this.canCreate});

  /// 必需的借用编辑器，面板不创建或关闭其资源。
  final EditorState editor;

  /// 由展示入口持有的编辑会话；null表示创建模式。
  final _DividerSession? session;

  /// 创建模式的外层书签/宿主校验，不拥有回调资源。
  final bool Function()? canCreate;

  /// 创建局部状态，不创建网络/原生资源。
  @override
  State<_DividerSettings> createState() => _DividerSettingsState();
}

/// 监听权威树与目标属性，串行提交显式修改；关闭时解绑本面板监听。
class _DividerSettingsState extends State<_DividerSettings> {
  /// 最大胶带绘图高52逻辑像素，加上下各12像素留白，固定预览槽为76像素。
  /// 薄线和花边在槽内垂直居中，粗细、样式或目标删除均不改变头部布局。
  static const double _previewHeight = 52 + 12 * 2;

  /// 借用并监听目标及祖先；远端事务不经过 transactionStream，须直接观察节点。
  final Set<Node> _listenedNodes = {};

  /// 当前样式分类索引，0线型、1贴纸胶带、2花边。
  int _tab = 0;

  /// 仅创建模式持有的局部属性，确认前不进入编辑器或撤销栈。
  final Map<String, dynamic> _draft = {};

  /// 创建期间发生撤权后不允许恢复原草稿提交。
  bool _creationRevoked = false;

  /// 是否为尚未写入正文的创建模式。
  bool get _creating => widget.session == null;

  /// 当前会话允许操作；创建还须通过外层稳定书签校验。
  bool get _available =>
      !widget.editor.isDisposed &&
      widget.editor.editable &&
      (_creating ? !_creationRevoked && (widget.canCreate?.call() ?? true) : widget.session!.current);

  /// 写入还需通过当前块锁及会话权限检查。
  bool get _writable => _available && (_creating || widget.session!.writable);

  /// 本面板持有的下方设置区滚动控制器；切换样式页归零，关闭时释放。
  final ScrollController _contentScrollController = ScrollController();

  /// 单次属性/删除提交期间拒绝新的写入，避免并发历史记录。
  bool _saving = false;

  /// 滑动期间的暂存值；松手只提交一次，避免每帧生成协同事务。
  double? _opacityDraft;
  String? _error;

  /// 解析当前稳定目标，删除或销毁返回 null，不缓存可能过期的 Node。
  CollabDivider? get _divider {
    if (_creating) return CollabDivider(Map<String, dynamic>.unmodifiable(_draft));
    final node = findCollabDivider(widget.editor, widget.session!.id);
    return node == null ? null : CollabDivider(CollabDivider.readAttributes(node.attributes).values);
  }

  /// 绑定目标、祖先和编辑权限变化；远端更新、删除及权限撤销均可刷新面板。
  @override
  void initState() {
    super.initState();
    final style = _divider?.style ?? '';
    _tab = style.startsWith('tape-')
        ? 1
        : style.startsWith('edge-')
        ? 2
        : 0;
    _syncListeners();
    widget.editor.editableNotifier.addListener(_onTreeChanged);
    widget.session?.addListener(_onTreeChanged);
  }

  /// 对最新目标和祖先建立借用监听，重排后解除旧节点，不关闭任何节点。
  void _syncListeners() {
    final next = <Node>{widget.editor.document.root};
    var node = _creating ? null : findCollabDivider(widget.editor, widget.session!.id);
    while (node != null) {
      next.add(node);
      node = node.parent;
    }
    for (final old in _listenedNodes.difference(next)) {
      old.removeListener(_onTreeChanged);
    }
    for (final added in next.difference(_listenedNodes)) {
      added.addListener(_onTreeChanged);
    }
    _listenedNodes
      ..clear()
      ..addAll(next);
  }

  /// 重新定位稳定目标并请求下一帧刷新；结构操作期间不写入或缓存临时节点。
  void _onTreeChanged() {
    if (!mounted || widget.editor.isDisposed) return;
    if (_creating && !widget.editor.editable) _creationRevoked = true;
    _syncListeners();
    if (!_writable) _opacityDraft = null;
    setState(() {});
  }

  /// 在 [property] 上提交 [value] 的单字段修改；防止面板并发写入。
  /// 已失效目标或权限拒绝显示可理解的提示，失败不静默丢弃。
  Future<void> _change(String property, Object? value) async {
    if (_saving || !_writable) return;
    if (_creating) {
      setState(() {
        _draft[property] = value;
        _opacityDraft = null;
      });
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (_divider == null || !_writable) {
        if (mounted) {
          setState(() => _error = '分割线已删除或当前不可编辑');
        }
        return;
      }
      await changeCollabDividerProperty(widget.editor, widget.session!.id, property, value);
    } catch (error, stack) {
      EditorCommandContext.report(widget.editor, '修改分割线失败', error: error, stackTrace: stack, tag: 'DocCollab');
      if (mounted) {
        setState(() => _error = '修改失败，请重试');
      }
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
          _opacityDraft = null;
        });
      }
    }
  }

  /// 在授权范围内切换[value]锁状态，等待投影后更新当前面板；失败保留并显示提示。
  Future<void> _toggle(bool value) async {
    if (_saving || !_available) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.session!.toggle(value);
    } catch (error, stack) {
      EditorCommandContext.report(widget.editor, '分割线锁操作失败', error: error, stackTrace: stack, tag: 'DocCollab');
      if (mounted) setState(() => _error = '锁操作失败，请重新打开后重试');
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
          _opacityDraft = null;
        });
      }
    }
  }

  /// 返回点击时[action]及最新属性快照，由外层在退场后重新校验并执行。
  void _choose(_DividerAction action) {
    if (_saving || !_available || (action == _DividerAction.insert || action == _DividerAction.delete) && !_writable) {
      return;
    }
    final node = findCollabDivider(widget.editor, widget.session!.id);
    if (node == null) return;
    setState(() => _saving = true);
    Navigator.pop<_DividerResult>(context, (values: null, action: action, snapshot: jsonEncode(node.attributes)));
  }

  /// 创建模式仅返回局部草稿，编辑模式结束即时设置；失效创建不能提交。
  void _done() {
    if (_saving || (_creating && !_available)) return;
    setState(() => _saving = true);
    Navigator.pop<_DividerResult>(
      context,
      _creating ? (values: Map<String, dynamic>.from(_draft), action: null, snapshot: null) : null,
    );
  }

  /// 解除节点及权限监听并释放本面板的滚动控制器；不关闭借用的编辑器或通知器。
  @override
  void dispose() {
    widget.editor.editableNotifier.removeListener(_onTreeChanged);
    widget.session?.removeListener(_onTreeChanged);
    for (final node in _listenedNodes) {
      node.removeListener(_onTreeChanged);
    }
    _listenedNodes.clear();
    _contentScrollController.dispose();
    super.dispose();
  }

  /// 选择 [values] 中唯一的样式页，下方滚动区归零以展示该页第一项。
  /// 不改共享属性或正文选区；固定头部保持可见，不创建或释放控制器。
  void _selectStyleTab(Set<int> values) {
    if (_contentScrollController.hasClients) {
      _contentScrollController.jumpTo(0);
    }
    setState(() => _tab = values.single);
  }

  /// 按 [context] 的屏幕/键盘约束渲染三页预设及立即保存的外观控件。
  /// 标题、预览及样式页切换固定，下方预设与外观设置使用剩余空间独立滚动。
  /// 预览槽固定为最大绘图高度加留白，实际分割线保持各档粗细并居中显示。
  /// 样式页以选中背景区分，不显示挤占标签宽度的勾选图标；三页名称始终完整单行。
  /// 贴纸胶带页隐藏不影响预设图案的线色控件；切换页不清除已有颜色属性。
  /// 清除与预设颜色使用一致的选中、可用状态和布局，重复选择不提交事务。
  /// 创建仅暂存外观；编辑在设置下方列出锁、复制和插入，删除固定左下，锁定时隐藏插入/删除。
  @override
  Widget build(BuildContext context) {
    final divider = _divider;
    final enabled = divider != null && _writable && !_saving;
    final session = widget.session;
    final lock = session?.locks?.state(session.id);
    final protected = lock?.locked == true || lock?.containsLock == true;
    final actionsEnabled = _available && !_saving;
    final current = divider ?? const CollabDivider({});
    final styles = collabDividerStyles.entries
        .where(
          (e) => _tab == 1
              ? e.key.startsWith('tape-')
              : _tab == 2
              ? e.key.startsWith('edge-')
              : !e.key.startsWith('tape-') && !e.key.startsWith('edge-'),
        )
        .toList();
    return CollabBottomSheet(
      key: const ValueKey('collab-divider-settings'),
      title: Text(_creating ? '添加分割线' : '分割线'),
      subtitle: _creating
          ? '选择样式后，点击完成插入'
          : !_available
          ? '内容或权限已更新，请重新打开'
          : protected
          ? '已锁定，解锁后可修改'
          : '外观修改即时生效',
      icon: LucideIcons.minus,
      canClose: !_saving,
      expand: true,
      scrollController: _contentScrollController,
      scrollKey: const ValueKey('divider-settings-content'),
      header: Padding(
        key: const ValueKey('divider-settings-header'),
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              key: const ValueKey('divider-settings-preview'),
              height: _previewHeight,
              child: Center(
                child: divider == null
                    ? const Text('分割线已删除')
                    : Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: CollabDividerVisual(divider: current),
                      ),
              ),
            ),
            CollabModalSegments<int>(
              values: const {0: '线型', 1: '贴纸胶带', 2: '花边'},
              selected: _tab,
              onSelected: (value) => _selectStyleTab({value}),
            ),
          ],
        ),
      ),
      leadingAction: _creating
          ? TextButton(onPressed: _saving ? null : () => Navigator.pop(context), child: const Text('取消'))
          : protected
          ? null
          : TextButton.icon(
              key: const ValueKey('divider-delete'),
              style: TextButton.styleFrom(foregroundColor: CollabModalColors.of(context).danger),
              onPressed: enabled ? () => _choose(_DividerAction.delete) : null,
              icon: const Icon(LucideIcons.trash2),
              label: const Text('删除分割线'),
            ),
      actions: [
        FilledButton(
          key: const ValueKey('divider-done'),
          onPressed: _saving || (_creating && !_available) ? null : _done,
          child: const Text('完成'),
        ),
      ],
      child: KeyedSubtree(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: styles.length,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                mainAxisExtent: 56,
                crossAxisSpacing: 10,
                mainAxisSpacing: 8,
              ),
              itemBuilder: (context, index) {
                final entry = styles[index];
                return Semantics(
                  label: entry.value,
                  selected: current.style == entry.key,
                  button: true,
                  child: InkWell(
                    key: ValueKey('divider-style-${entry.key}'),
                    onTap: enabled ? () async => await _change('style', entry.key) : null,
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: current.style == entry.key
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context).dividerColor,
                        ),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: CollabDividerVisual(
                        divider: CollabDivider({'style': entry.key, 'lineColor': current.lineColor}),
                        preview: true,
                      ),
                    ),
                  ),
                );
              },
            ),
            if (_tab != 1) ...[
              const SizedBox(height: 16),
              const Text('线色'),
              CollabColorPicker(
                circular: true,
                keyPrefix: 'divider-color',
                resetKey: const ValueKey('divider-color-clear'),
                textColors: true,
                enabled: enabled,
                selection: CollabColorSelection(current.lineColor),
                onSelected: (value) => _change('lineColor', value ?? ''),
              ),
            ],
            const SizedBox(height: 12),
            Text('透明度 ${((_opacityDraft ?? current.opacity) * 100).round()}%'),
            const SizedBox(height: 10),
            SliderTheme(
              data: SliderTheme.of(
                context,
              ).copyWith(trackHeight: 4, thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5)),
              child: Slider(
                key: const ValueKey('divider-opacity'),
                value: _opacityDraft ?? current.opacity,
                min: .1,
                max: 1,
                divisions: 90,
                padding: EdgeInsets.symmetric(horizontal: 8),
                onChanged: enabled ? (value) => setState(() => _opacityDraft = value) : null,
                onChangeEnd: enabled ? (value) async => await _change('opacity', value) : null,
              ),
            ),
            SizedBox(height: 12),
            const Text('长度'),
            _options('length', current.length, const {'short': '短', 'medium': '中', 'long': '长', 'full': '通栏'}, enabled),
            const SizedBox(height: 12),
            const Text('粗细'),
            _options('thickness', current.thickness, const {'thin': '细', 'regular': '常规', 'thick': '粗'}, enabled),
            const SizedBox(height: 12),
            if (session != null) ...[
              SizedBox(height: 10),
              const Divider(height: 0),
              SizedBox(height: 12),
              if (session.locks != null && session.locks!.userId.isNotEmpty)
                CollabSwitchRow(
                  key: ValueKey('block-lock-${session.id}'),
                  leading: const Icon(LucideIcons.lockKeyhole),
                  title: const Text('锁定'),
                  subtitle: Text(
                    !_available
                        ? '锁状态或权限已更新，请重新打开'
                        : lock?.locked == true && lock?.explicit != true
                        ? '由上级内容块锁定'
                        : lock?.template == true
                        ? '模板内容已锁定'
                        : lock?.locked == true && lock?.ownerId != session.locks!.userId
                        ? '由其他用户锁定'
                        : '锁定后可查看，解锁后可修改',
                  ),
                  value: lock?.locked ?? false,
                  onChanged: actionsEnabled && session.locks!.canToggle(session.id)
                      ? (value) async => await _toggle(value)
                      : null,
                ),
              if (lock?.locked == true && lock?.explicit != true)
                CollabMenuRow(
                  leading: const Icon(LucideIcons.cornerUpLeft),
                  title: const Text('定位上级锁定块'),
                  onTap: actionsEnabled ? () => _choose(_DividerAction.locate) : null,
                ),
              if (session.canCopy)
                CollabMenuRow(
                  key: const ValueKey('divider-copy-link'),
                  leading: const Icon(LucideIcons.link),
                  title: const Text('复制块链接'),
                  onTap: actionsEnabled ? () => _choose(_DividerAction.copy) : null,
                ),
              if (!protected)
                CollabMenuRow(
                  key: const ValueKey('divider-insert-below'),
                  leading: const Icon(LucideIcons.listEnd),
                  title: const Text('下方插入'),
                  onTap: enabled ? () => _choose(_DividerAction.insert) : null,
                ),
            ],
            if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
        ),
      ),
    );
  }

  /// [property] 控件按 [selected] 展示，[options] 提供键/标签；[enabled] 控制写入。
  Widget _options(String property, String selected, Map<String, String> options, bool enabled) =>
      CollabModalSegments<String>(
        values: options,
        selected: selected,
        itemKeys: {for (final entry in options.entries) entry.key: ValueKey('divider-$property-${entry.key}')},
        onSelected: enabled ? (value) async => await _change(property, value) : null,
      );
}

/// 持有一个稳定分割线的权限会话；自身锁操作可推进代次，远端变化不能复活旧面板。
/// 展示入口创建和释放本会话，编辑器、锁服务与宿主绑定均为借用资源。
class _DividerSession extends ChangeNotifier {
  /// [editor]为借用编辑器，[id]为稳定分割线身份；捕获初始节点、锁代次和宿主绑定。
  _DividerSession(this.editor, this.id)
    : locks = CollabBlockLocks.of(editor),
      links = CollabParagraphLinks.of(editor),
      _target = findCollabDivider(editor, id),
      _services = EditorCommandContext.of(editor).services {
    _epoch = locks?.epoch(id) ?? 0;
    editor.editableNotifier.addListener(_observe);
    locks?.addListener(_observe);
  }

  /// 页面持有的编辑器，不由本会话释放。
  final EditorState editor;

  /// 面板整个生命周期对应同一个稳定分割线。
  final String id;

  /// 打开时借用的锁投影，替换绑定后本会话失效。
  final CollabBlockLocks? locks;

  /// 打开时借用的正式文档链接绑定，草稿或未配置时为null。
  final CollabParagraphLinks? links;

  /// 打开时的节点身份，删除后同ID重建也不能复用旧面板。
  final Node? _target;

  /// 捕获宿主服务身份，拒绝跨账号/文档会话的迟到结果。
  final CollabHostServices _services;

  /// 最近一次明确接受的锁代次，仅成功的自身加解锁可推进。
  int _epoch = 0;

  /// 撤权、远端锁变化或关闭后永久失效。
  bool _invalid = false;

  /// 路由或宿主退出后不再向已释放的通知器发送迟到锁结果。
  bool _closed = false;

  /// 自身锁提交期间延迟锁代次判定，完成时只接受一次预期转换。
  bool _toggling = false;

  /// 退场后选择的块命令；null表示普通关闭或完成。
  _DividerAction? action;

  /// 新插入正文的稳定身份，退场后重定位光标。
  String? insertedId;

  /// 面板内已经执行过锁操作，普通完成不再自动唤起原正文键盘。
  bool lockChanged = false;

  /// 宿主与锁绑定仍属原编辑器；不判断节点是否仍存在。
  bool get sameHost =>
      !editor.isDisposed &&
      identical(EditorCommandContext.of(editor).services, _services) &&
      identical(CollabBlockLocks.of(editor), locks);

  /// 当前未失效且节点、权限和锁代次仍有效；自身提交中只展示当前投影，不开放新操作。
  bool get current =>
      !_invalid &&
      sameHost &&
      editor.editable &&
      identical(findCollabDivider(editor, id), _target) &&
      _target != null &&
      (_toggling || (locks?.epoch(id) ?? 0) == _epoch);

  /// 内容写入须通过块锁守卫，包含祖先锁与其他活动会话租约。
  bool get writable => current && (locks?.writable(id) ?? true);

  /// 只有原正式链接绑定仍有效且目标有稳定ID才提供复制入口。
  bool get canCopy =>
      identical(CollabParagraphLinks.of(editor), links) && _target != null && links?.supports(_target) == true;

  /// 记录不可逆的权限失效并通知借用面板；自身提交结束时另行核对锁代次。
  void _observe() {
    if (!sameHost || !editor.editable || (!_toggling && (locks?.epoch(id) ?? 0) != _epoch)) _invalid = true;
    notifyListeners();
  }

  /// 在授权下提交[value]显式锁，失败透传；仅单次预期转换允许当前会话继续。
  /// 额外远端锁变化、权限撤销或目标替换将永久失效，不续接旧操作。
  Future<void> toggle(bool value) async {
    final manager = locks;
    if (!current || _toggling || manager == null || !manager.canToggle(id)) return;
    final before = manager.state(id);
    final epoch = manager.epoch(id);
    _toggling = true;
    try {
      await manager.commit(id, value, before);
      final after = manager.state(id);
      if (!current ||
          manager.epoch(id) != epoch + 1 ||
          after.locked != value ||
          after.explicit != value ||
          (value && (after.template || after.ownerId != manager.userId))) {
        _invalid = true;
        throw StateError('锁状态或权限已变化');
      }
      _epoch = manager.epoch(id);
      lockChanged = true;
    } catch (_) {
      if (manager.epoch(id) != epoch) _invalid = true;
      rethrow;
    } finally {
      _toggling = false;
      if (!_closed) notifyListeners();
    }
  }

  /// 在借用[context]上执行退场后的[result]，重新核对权限、目标和点击时快照。
  /// 插入/删除为独立历史；复制不写正文，锁定允许复制；失败由展示入口统一报告。
  Future<void> execute(BuildContext context, _DividerResult result) async {
    if (!context.mounted || !current) return;
    final node = findCollabDivider(editor, id)!;
    if (jsonEncode(node.attributes) != result.snapshot) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('内容已更新，请重新打开')));
      return;
    }
    switch (result.action) {
      case _DividerAction.copy:
        if (canCopy) {
          await links!.copy(context, node, isCurrent: () => current && jsonEncode(node.attributes) == result.snapshot);
        }
      case _DividerAction.locate:
        final source = locks?.state(id).sourceId;
        final target = source == null ? null : findCollabActionNode(editor, source)?.key.currentContext;
        if (target != null && target.mounted) {
          await Scrollable.ensureVisible(target, duration: const Duration(milliseconds: 250));
        }
      case _DividerAction.insert:
        if (!writable) return;
        final paragraph = await insertCollabParagraphBelow(editor, node);
        insertedId = paragraph == null ? null : CollabBlockLocks.idOf(paragraph);
      case _DividerAction.delete:
        if (!writable || locks?.state(id).containsLock == true) return;
        final transaction = editor.transaction..deleteNode(node);
        if (node.parent!.children.length == 1) transaction.insertNode(node.path, paragraphNode());
        if (editor.undoManager.undoStack.isEmpty == false) editor.undoManager.undoStack.last.seal();
        await editor.apply(transaction, skipHistoryDebounce: true);
      case null:
        return;
    }
  }

  /// 注销自有监听并永久失效；不关闭借用编辑器、锁或宿主服务。
  @override
  void dispose() {
    _closed = true;
    _invalid = true;
    editor.editableNotifier.removeListener(_observe);
    locks?.removeListener(_observe);
    super.dispose();
  }
}
