import 'dart:async';
import 'dart:math' as math;

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/appflowy_block_editor_adapter.dart';
import 'package:cses_document_collab/src/editor/collab_block_delete.dart';
import 'package:cses_document_collab/src/editor/collab_block_locks.dart';
import 'package:cses_document_collab/src/editor/collab_callout_block.dart';
import 'package:cses_document_collab/src/editor/collab_divider_settings.dart';
import 'package:cses_document_collab/src/editor/collab_formula_sheet.dart';
import 'package:cses_document_collab/src/editor/collab_host_meeting_ui.dart';
import 'package:cses_document_collab/src/editor/collab_host_mention_ui.dart';
import 'package:cses_document_collab/src/editor/collab_list_editing.dart';
import 'package:cses_document_collab/src/editor/collab_mermaid_sheet.dart';
import 'package:cses_document_collab/src/editor/collab_paragraph_indent.dart';
import 'package:cses_document_collab/src/editor/collab_paragraph_typing.dart';
import 'package:cses_document_collab/src/editor/editor_media_source_sheet.dart';
import 'package:cses_document_collab/src/editor/editor_block_conversion.dart';
import 'package:cses_document_collab/src/editor/stable_mobile_toolbar.dart';
import 'package:cses_document_collab/src/model/collab_block_colors.dart';
import 'package:cses_document_collab/src/model/collab_color_palette.dart';
import 'package:cses_document_collab/src/model/collab_divider.dart';
import 'package:cses_document_collab/src/model/collab_formula.dart';
import 'package:cses_document_collab/src/model/collab_inline_formula.dart';
import 'package:cses_document_collab/src/model/collab_meeting.dart';
import 'package:cses_document_collab/src/model/collab_mermaid.dart';
import 'package:cses_document_collab/src/model/collab_page_divider.dart';
import 'package:cses_document_collab/src/model/collab_paragraph_style.dart';
import 'package:cses_document_collab/src/model/collab_resource.dart';
import 'package:cses_document_collab/src/model/collab_table.dart';
import 'package:cses_document_collab/src/model/collab_text_range.dart';
import 'package:cses_document_collab/src/model/collab_user_mention.dart';
import 'package:cses_document_collab/src/model/editor_media_upload.dart';
import 'package:cses_document_collab/src/model/editor_keyboard_action.dart';
import 'package:cses_document_collab/src/editor/core/editor_command_context.dart';
import 'package:cses_document_collab/src/editor/core/editor_configuration.dart';
import 'package:cses_document_collab/src/ui/modal/collab_bottom_sheet.dart';
import 'package:cses_document_collab/src/ui/modal/collab_color_picker.dart';
import 'package:cses_document_collab/src/ui/modal/collab_modal.dart';
import 'package:cses_document_collab/src/ui/modal/collab_modal_colors.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// 移动端标题菜单的展示上限，不改变历史正文或桌面Schema支持的级别。
const _maxHeadingMenuLevel = 6;

/// 添加面板与T菜单共用的一至六级标题图标，顺序与标题级别一一对应。
const _headingMenuIcons = [
  LucideIcons.heading1,
  LucideIcons.heading2,
  LucideIcons.heading3,
  LucideIcons.heading4,
  LucideIcons.heading5,
  LucideIcons.heading6,
];

/// 从[config]取得已启用的一至六级标题，按级别排序，不修改原配置。
List<int> _menuHeadingLevels(EditorConfiguration config) =>
    (config.headingLevels.where((level) => level <= _maxHeadingMenuLevel).toList()..sort());

/// 为同一工具栏的子菜单借用同步执行权限；闭包读取实时互斥状态，不接管正文或业务资源。
class _ToolbarCommandScope extends InheritedWidget {
  /// [canExecute]同步返回当前会话是否接受菜单命令；[child]为借用的工具栏及菜单子树。
  const _ToolbarCommandScope({required this.canExecute, required super.child});

  /// 查询由上层持有的实时权限，回调不得产生正文副作用。
  final bool Function() canExecute;

  /// 在借用[context]中检查权限；范围外的独立面板保留原行为，已卸载上下文拒绝执行。
  static bool allows(BuildContext context) =>
      context.mounted && (context.getInheritedWidgetOfExactType<_ToolbarCommandScope>()?.canExecute() ?? true);

  /// 当[oldWidget]的借用查询被替换时通知依赖者，不缓存查询结果。
  @override
  bool updateShouldNotify(_ToolbarCommandScope oldWidget) => oldWidget.canExecute != canExecute;
}

/// 移动键盘工具栏，借用正文编辑器并隔离添加面板的输入与选区。
/// ```dart
/// import 'package:flutter/material.dart';
/// import 'package:appflowy_editor/appflowy_editor.dart';
/// import 'package:cses_document_collab/src/editor/editor_shortcut_toolbar.dart';
/// final state = EditorState.blank();
/// final toolbar = EditorShortcutToolbar(editorState: state, child: AppFlowyEditor(editorState: state));
/// // 从树中移除toolbar后由创建方state.dispose()。
/// ```
///
/// Only commands represented by the current collaborative schema are active.
/// Unsupported actions stay visible so the interaction model can be evaluated
/// without silently creating local-only nodes that Rust/Yrs cannot preserve.
class EditorShortcutToolbar extends StatefulWidget {
  /// [key] 控制身份与状态复用，[editorState] 为借用编辑器，[child] 为必填正文。
  /// [keyboardActions]默认空，宿主动作按顺序接在内建入口后；其标识必须唯一。
  const EditorShortcutToolbar({
    super.key,
    required this.editorState,
    required this.child,
    this.keyboardActions = const [],
  });

  /// 必填借用编辑器；本组件管理工具栏状态，不释放它。
  final EditorState editorState;

  /// 必填正文组件，工具栏随键盘在其下方显示。
  final Widget child;

  /// 宿主拥有的业务动作，工具栏只借用并管理点击互斥，不接管其异步写回。
  final List<EditorKeyboardAction> keyboardActions;

  /// 创建并持有工具栏控制器与键盘拦截器。
  @override
  createState() => _EditorShortcutToolbarState();
}

/// 移动工具栏状态：拥有样式控制器和退格拦截器，借用编辑器及其键盘服务。
/// 首帧后注册拦截器，编辑器更换时迁移订阅，退出时注销，不释放外部 EditorState。
class _EditorShortcutToolbarState extends State<EditorShortcutToolbar> {
  late _InlineStyleController _inlineStyleController;

  /// 本状态拥有的无状态退格拦截器；注册到借用的键盘服务，退出前注销。
  late final CollabBlockBackspaceInterceptor _backspaceInterceptor;
  AppFlowyKeyboardService? _interceptedKeyboardService;
  int _emptyParagraphKeyboardRequestGeneration = 0;

  /// 当前直达事务或宿主动作的互斥令牌；更换会话后旧Future不能清除新动作状态。
  Object? _pendingActionToken;

  /// 检查借用的预期[state]仍是本实例且可执行快捷命令；闭包同步查询以覆盖重建前的连点。
  bool _canExecuteKeyboardCommand(EditorState state) =>
      mounted &&
      identical(widget.editorState, state) &&
      !state.isDisposed &&
      state.editable &&
      state.selection != null &&
      _pendingActionToken == null;

  /// 创建所属控制器/拦截器并订阅选区，首帧服务挂载后注册；资源在 dispose 中成对释放。
  @override
  void initState() {
    super.initState();
    registerCsesRichTextAttributes();
    _inlineStyleController = _InlineStyleController(widget.editorState);
    _backspaceInterceptor = CollabBlockBackspaceInterceptor();
    widget.editorState.selectionNotifier.addListener(_onSelectionMayNeedEmptyParagraphKeyboard);
    _registerBackspaceInterceptorAfterLayout();
  }

  /// [oldWidget] 提供旧编辑器；编辑器更换时先注销旧服务/选区监听并释放旧样式控制器，
  /// 再绑定当前编辑器并作废旧动作令牌。键盘服务和 EditorState 均由外部持有，不在此关闭。
  @override
  void didUpdateWidget(covariant EditorShortcutToolbar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.editorState != widget.editorState) {
      _pendingActionToken = null;
      _unregisterBackspaceInterceptor();
      oldWidget.editorState.selectionNotifier.removeListener(_onSelectionMayNeedEmptyParagraphKeyboard);
      _inlineStyleController.dispose();
      _inlineStyleController = _InlineStyleController(widget.editorState);
      widget.editorState.selectionNotifier.addListener(_onSelectionMayNeedEmptyParagraphKeyboard);
      _registerBackspaceInterceptorAfterLayout();
    }
  }

  /// 作废当前动作令牌，注销退格拦截器及选区监听，释放样式控制器；外部编辑器保持有效。
  @override
  void dispose() {
    _pendingActionToken = null;
    _unregisterBackspaceInterceptor();
    widget.editorState.selectionNotifier.removeListener(_onSelectionMayNeedEmptyParagraphKeyboard);
    _inlineStyleController.dispose();
    super.dispose();
  }

  /// 在子编辑器首帧挂载服务后注册统一退格入口；已销毁或已注册则跳过，重复回调幂等。
  /// 不创建键盘服务，成功时保存借用引用供迁移/退出注销。
  void _registerBackspaceInterceptorAfterLayout() {
    // EditorShortcutToolbar is the parent of AppFlowyEditor, so its initState
    // runs before the child installs KeyboardService. At the first post-frame
    // callback the service is available and can safely accept the interceptor.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _interceptedKeyboardService != null) {
        return;
      }
      final keyboardService = widget.editorState.service.keyboardService;
      if (keyboardService == null) {
        return;
      }
      keyboardService.registerInterceptor(_backspaceInterceptor);
      _interceptedKeyboardService = keyboardService;
    });
  }

  /// 从借用服务移除本状态拥有的拦截器并清空引用；重复调用安全，不关闭服务。
  void _unregisterBackspaceInterceptor() {
    _interceptedKeyboardService?.unregisterInterceptor(_backspaceInterceptor);
    _interceptedKeyboardService = null;
  }

  void _onSelectionMayNeedEmptyParagraphKeyboard() {
    final requestGeneration = ++_emptyParagraphKeyboardRequestGeneration;
    final selection = widget.editorState.selection;
    if (defaultTargetPlatform != TargetPlatform.android ||
        selection == null ||
        !selection.isCollapsed ||
        !widget.editorState.canInputAt(selection) ||
        widget.editorState.selectionExtraInfo?[selectionExtraInfoDoNotAttachTextService] == true ||
        widget.editorState.selectionUpdateReason != SelectionUpdateReason.uiEvent) {
      return;
    }
    final node = widget.editorState.getNodeAtPath(selection.start.path);
    if (node?.delta?.toPlainText().isNotEmpty != false) {
      return;
    }

    // AppFlowy's NonDeltaTextInputService caches only TextEditingValue, which
    // contains text and offsets but not a block path. Moving from one empty
    // paragraph to another therefore looks unchanged and `attach()` can skip
    // its normal platform `show()` call. Defer the workaround briefly so a
    // successful normal attach gets the first opportunity to update insets.
    unawaited(_showKeyboardForEmptyParagraphIfStillNeeded(selection, requestGeneration));
  }

  Future<void> _showKeyboardForEmptyParagraphIfStillNeeded(Selection selection, int requestGeneration) async {
    await WidgetsBinding.instance.endOfFrame;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    if (!mounted ||
        requestGeneration != _emptyParagraphKeyboardRequestGeneration ||
        widget.editorState.selection != selection ||
        widget.editorState.selectionExtraInfo?[selectionExtraInfoDoNotAttachTextService] == true ||
        ModalRoute.of(context)?.isCurrent == false ||
        _editorKeyboardIsVisible(context)) {
      return;
    }

    final node = widget.editorState.getNodeAtPath(selection.start.path);
    if (node?.delta?.toPlainText().isNotEmpty != false) {
      return;
    }

    // Selection handling has already attached (or reused) AppFlowy's text
    // input connection and requested editor focus. Calling the platform show
    // method directly avoids attaching a second client and fixes precisely the
    // cached-empty-value branch where AppFlowy omitted that one method call.
    widget.editorState.service.keyboardService?.enable();
    await SystemChannels.textInput.invokeMethod<void>('TextInput.show');
  }

  /// 在当前会话执行借用[run]，用[actionLabel]报告未捕获的失败。
  /// 操作期间禁用其他快捷入口；会话更换、视图卸载或关闭后不刷新旧界面或恢复输入。
  /// 宿主继续负责自己的账号、权限、目标快照和异步结果失效，不由此边界重放回调。
  Future<void> _runKeyboardAction(String actionLabel, Future<void> Function() run) async {
    final state = widget.editorState;
    if (_pendingActionToken != null || state.isDisposed || !state.editable || state.selection == null) return;
    final owner = EditorCommandContext.of(state);
    final token = Object();
    setState(() => _pendingActionToken = token);
    try {
      await run();
    } catch (error, stack) {
      if (!mounted ||
          !identical(widget.editorState, state) ||
          state.isDisposed ||
          !identical(EditorCommandContext.of(state), owner)) {
        debugPrint('执行$actionLabel失败，动作所属会话已失效：$error\n$stack');
        return;
      }
      owner.services.report('执行$actionLabel失败', error, stack, 'DocCollab');
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('$actionLabel失败，请重试')));
    } finally {
      if (mounted && identical(_pendingActionToken, token)) {
        setState(() => _pendingActionToken = null);
      }
    }
  }

  /// 为借用[action]构建图标和可见标签，不保存业务状态；禁用由外层工具栏统一处理。
  MobileToolbarItem _hostKeyboardItem(EditorKeyboardAction action) => MobileToolbarItem.action(
    itemIconBuilder: (_, _, _) => Tooltip(
      message: action.label,
      child: KeyedSubtree(
        key: ValueKey('editor-keyboard-host-${action.id}'),
        child: Builder(
          builder: (context) => Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(action.icon, size: 20),
                const SizedBox(width: 4),
                Text(action.label, maxLines: 1, style: TextStyle(fontSize: 12, color: IconTheme.of(context).color)),
              ],
            ),
          ),
        ),
      ),
    ),
    actionHandler: (_, _) {
      if (action.enabled) unawaited(_runKeyboardAction(action.label, action.onPressed));
    },
  );

  /// 构建原生待办直达入口，复用T菜单的类型转换，不打开面板或重新建立输入连接。
  MobileToolbarItem _todoKeyboardItem() => MobileToolbarItem.action(
    itemIconBuilder: (_, _, _) => const Tooltip(
      message: '待办列表',
      child: KeyedSubtree(key: ValueKey('editor-keyboard-todoList'), child: Icon(LucideIcons.squareCheck)),
    ),
    actionHandler: (_, state) => unawaited(
      _runKeyboardAction('待办列表', () async {
        await applyEditorBlockStyle(state, TodoListBlockKeys.type);
      }),
    ),
  );

  /// 在借用[context]中按实例入口集合显示工具栏；内建入口与能力取交集，宿主动作随后排列。
  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform != TargetPlatform.android && defaultTargetPlatform != TargetPlatform.iOS) {
      return widget.child;
    }
    final state = widget.editorState;
    final config = EditorCommandContext.of(state).configuration;
    final actionIds = widget.keyboardActions.map((action) => action.id).toList();
    if (actionIds.toSet().length != actionIds.length) {
      throw ArgumentError.value(actionIds, 'keyboardActions', '宿主快捷动作标识不得重复');
    }
    final builtInItems = [
      for (final item in config.keyboardToolbarItems)
        if (_keyboardItemAllowed(config, item))
          item == EditorKeyboardToolbarItem.todoList
              ? _todoKeyboardItem()
              : _buildKeyboardItem(item, _inlineStyleController),
    ];
    final items = [...builtInItems, for (final action in widget.keyboardActions) _hostKeyboardItem(action)];
    return _ToolbarCommandScope(
      canExecute: () => _canExecuteKeyboardCommand(state),
      child: StableMobileToolbar(
        key: ObjectKey(widget.editorState),
        editorState: widget.editorState,
        toolbarHeight: 52,
        buttonHeight: 42,
        buttonSpacing: 6,
        itemOutlineColor: const Color(0xFFE5E7EB),
        primaryColor: const Color(0xFF2563EB),
        toolbarItems: items,
        canExecuteItem: (index) =>
            _canExecuteKeyboardCommand(state) &&
            (index < builtInItems.length ||
                (index - builtInItems.length < widget.keyboardActions.length &&
                    widget.keyboardActions[index - builtInItems.length].enabled)),
        disabledItemIndices: {
          for (var index = 0; index < items.length; index++)
            if (_pendingActionToken != null ||
                (index >= builtInItems.length && !widget.keyboardActions[index - builtInItems.length].enabled))
              index,
        },
        child: widget.child,
      ),
    );
  }
}

/// 格式菜单的轻量订阅，输入继承由编辑器适配器统一维护；不拥有编辑器。
class _InlineStyleController extends ChangeNotifier {
  /// 订阅借用的 [editorState] 输入状态，创建者负责 dispose。
  _InlineStyleController(this.editorState) {
    _typing = CollabParagraphTyping.isAttached(editorState) ? null : CollabParagraphTyping(editorState);
    editorState.toggledStyleNotifier.addListener(notifyListeners);
    editorState.selectionNotifier.addListener(notifyListeners);
  }

  /// 仅独立编辑器场景由工具栏持有，适配器场景不重复创建。
  CollabParagraphTyping? _typing;

  /// 宿主持有的文档编辑器。
  final EditorState editorState;

  /// 读取 [attribute] 的当前输入格式；null 表示未设置。
  dynamic value(String attribute) => editorState.toggledStyle[attribute];

  /// 切换 [attribute]，可同时取消 [mutuallyExclusiveWith]；空段落格式持久化并可撤销。
  Future<void> toggle(String attribute, {String? mutuallyExclusiveWith}) => setCollabTypingAttributes(editorState, {
    attribute: value(attribute) == true ? null : true,
    ?mutuallyExclusiveWith: null,
  });

  /// 设置 [attribute] 为 [value]，null 取消；等待空段落格式事务完成，失败向菜单边界传播。
  Future<void> setValue(String attribute, dynamic value) => setCollabTypingAttributes(editorState, {attribute: value});

  /// 范围格式由选区直接计算，不需要修改输入状态。
  void clearAll() {}

  /// 仅注销自身监听；借用编辑器由宿主释放。
  @override
  void dispose() {
    _typing?.dispose();
    editorState.toggledStyleNotifier.removeListener(notifyListeners);
    editorState.selectionNotifier.removeListener(notifyListeners);
    super.dispose();
  }
}

/// 键盘直达入口和更多常用网格共用的动作描述，不持有编辑器或异步资源。
class _CommonInsertionAction {
  /// [item]为配置标识，[label]/[icon]为现有展示，[key]为更多面板的稳定测试身份。
  /// [blockType]限制块能力；已实现动作的null类型使用[formatKey]限制行内能力。
  /// [implemented]默认true；false沿用原占位提示，不创建数据。
  const _CommonInsertionAction(
    this.item,
    this.label,
    this.icon,
    this.key, {
    this.blockType,
    this.formatKey,
    this.implemented = true,
  });

  /// 对应的键盘配置项。
  final EditorKeyboardToolbarItem item;

  /// 面板名称与键盘提示。
  final String label;

  /// 沿用原常用入口图标。
  final IconData icon;

  /// 更多面板的稳定身份，不依赖配置排序。
  final String key;

  /// 块类型；行内动作为空。
  final String? blockType;

  /// 行内格式属性；块动作为空。
  final String? formatKey;

  /// 是否已有实际插入实现，false仅显示原占位提示。
  final bool implemented;
}

/// 更多常用目录的单一来源；占位项可显示，但不生成编辑能力或正文数据。
const _commonInsertions = [
  _CommonInsertionAction(
    EditorKeyboardToolbarItem.image,
    '图片',
    LucideIcons.image,
    'editor-shortcut-image-block',
    blockType: 'image',
  ),
  _CommonInsertionAction(
    EditorKeyboardToolbarItem.link,
    '链接',
    LucideIcons.link,
    'editor-shortcut-link-block',
    blockType: 'link',
  ),
  _CommonInsertionAction(
    EditorKeyboardToolbarItem.video,
    '视频',
    LucideIcons.film,
    'editor-shortcut-video-block',
    blockType: 'video',
  ),
  _CommonInsertionAction(
    EditorKeyboardToolbarItem.attachment,
    '附件',
    LucideIcons.paperclip,
    'editor-shortcut-attachment-block',
    blockType: 'attachment',
  ),
  _CommonInsertionAction(
    EditorKeyboardToolbarItem.audio,
    '音频',
    LucideIcons.music2,
    'editor-shortcut-audio-block',
    blockType: 'audio',
  ),
  _CommonInsertionAction(
    EditorKeyboardToolbarItem.bookmark,
    '网页卡片',
    LucideIcons.bookmark,
    'editor-shortcut-bookmark-block',
    blockType: 'bookmark',
  ),
  _CommonInsertionAction(
    EditorKeyboardToolbarItem.embed,
    '网页嵌入',
    LucideIcons.globe,
    'editor-shortcut-embed-block',
    blockType: 'embed',
  ),
  _CommonInsertionAction(
    EditorKeyboardToolbarItem.juejin,
    '掘金',
    LucideIcons.newspaper,
    'editor-shortcut-juejin-embed-block',
    blockType: 'juejin-embed',
  ),
  _CommonInsertionAction(
    EditorKeyboardToolbarItem.figma,
    'Figma',
    LucideIcons.penTool,
    'editor-shortcut-figma-embed-block',
    blockType: 'figma-embed',
  ),
  _CommonInsertionAction(
    EditorKeyboardToolbarItem.table,
    '表格',
    LucideIcons.table2,
    'editor-shortcut-table',
    blockType: 'table',
  ),
  _CommonInsertionAction(
    EditorKeyboardToolbarItem.callout,
    '高亮块',
    LucideIcons.highlighter,
    'editor-shortcut-callout',
    blockType: 'callout',
  ),
  _CommonInsertionAction(
    EditorKeyboardToolbarItem.meeting,
    '会议',
    LucideIcons.users,
    'editor-shortcut-meeting',
    blockType: 'meeting',
  ),
  _CommonInsertionAction(
    EditorKeyboardToolbarItem.formula,
    '公式',
    LucideIcons.sigma,
    'editor-shortcut-formula',
    blockType: 'formula',
  ),
  _CommonInsertionAction(
    EditorKeyboardToolbarItem.mermaid,
    '代码绘图',
    LucideIcons.chartNetwork,
    'editor-shortcut-mermaid',
    blockType: 'mermaid',
  ),
  _CommonInsertionAction(
    EditorKeyboardToolbarItem.mention,
    '@用户',
    LucideIcons.atSign,
    'editor-shortcut-mention-more',
    formatKey: 'cses_inline_mention',
  ),
  _CommonInsertionAction(
    EditorKeyboardToolbarItem.inlineFormula,
    '行内公式',
    LucideIcons.omega,
    'editor-shortcut-inline-formula',
    formatKey: 'cses_inline_latex',
  ),
  _CommonInsertionAction(
    EditorKeyboardToolbarItem.divider,
    '分割线',
    LucideIcons.minus,
    'editor-shortcut-divider',
    blockType: 'divider',
  ),
  _CommonInsertionAction(
    EditorKeyboardToolbarItem.pageDivider,
    '分页符',
    LucideIcons.separatorHorizontal,
    'editor-shortcut-page-divider',
    blockType: 'page-divider',
  ),
  _CommonInsertionAction(
    EditorKeyboardToolbarItem.spreadsheet,
    '电子表格',
    LucideIcons.grid2X2,
    'editor-shortcut-spreadsheet',
    implemented: false,
  ),
  _CommonInsertionAction(
    EditorKeyboardToolbarItem.multiTable,
    '多维表格',
    LucideIcons.layoutDashboard,
    'editor-shortcut-multi-table',
    implemented: false,
  ),
  _CommonInsertionAction(
    EditorKeyboardToolbarItem.mindMap,
    '思维导图',
    LucideIcons.network,
    'editor-shortcut-mind-map',
    implemented: false,
  ),
];

/// 在原常用目录中查找[item]，原工具菜单返回null。
_CommonInsertionAction? _commonInsertion(EditorKeyboardToolbarItem item) =>
    _commonInsertions.where((action) => action.item == item).firstOrNull;

/// 按[config]检查[action]的底层块或格式，不因入口显式选择而开启被禁用能力。
bool _commonInsertionAllowed(EditorConfiguration config, _CommonInsertionAction action) =>
    !action.implemented ||
    (action.blockType != null ? config.allowsBlock(action.blockType!) : config.allowsFormat(action.formatKey!));

/// 对[item]应用[config]的实际能力约束；工具菜单不由直达动作目录处理。
bool _keyboardItemAllowed(EditorConfiguration config, EditorKeyboardToolbarItem item) => switch (item) {
  EditorKeyboardToolbarItem.textStyle => config.inlineFormats.isNotEmpty,
  EditorKeyboardToolbarItem.blockLayout => config.hasLayout,
  EditorKeyboardToolbarItem.addBlock || EditorKeyboardToolbarItem.blockType => true,
  EditorKeyboardToolbarItem.todoList => config.allowsBlock(TodoListBlockKeys.type),
  _ => _commonInsertionAllowed(config, _commonInsertion(item)!),
};

/// 为[item]构建原工具菜单或常用直达按钮，[styles]由所属工具栏借用。
/// 直达按钮仍走稳定书签、模态隔离及退场后恢复，不展示中间的更多网格。
MobileToolbarItem _buildKeyboardItem(EditorKeyboardToolbarItem item, _InlineStyleController styles) => switch (item) {
  EditorKeyboardToolbarItem.addBlock => _addBlockToolbarItem,
  EditorKeyboardToolbarItem.blockType => _blockStyleToolbarItem,
  EditorKeyboardToolbarItem.textStyle => _textDecorationToolbarItem(styles),
  EditorKeyboardToolbarItem.blockLayout => _blockLayoutToolbarItem,
  EditorKeyboardToolbarItem.image => _imageToolbarItem,
  EditorKeyboardToolbarItem.mention => _mentionToolbarItem,
  _ => MobileToolbarItem.action(
    itemIconBuilder: (_, _, _) => Tooltip(
      message: _commonInsertion(item)!.label,
      child: KeyedSubtree(key: ValueKey('editor-keyboard-${item.name}'), child: Icon(_commonInsertion(item)!.icon)),
    ),
    actionHandler: (context, state) => unawaited(_showKeyboardCommonInsertion(context, state, _commonInsertion(item)!)),
  ),
};

/// 在借用[context]/[state]中直达[action]，暂停正文输入直到整个动作退场。
/// 撤权、关闭、宿主切换或旧位置失效时拒绝提交及恢复；失败在当前会话报告。
Future<void> _showKeyboardCommonInsertion(
  BuildContext context,
  EditorState state,
  _CommonInsertionAction action,
) async {
  if (state.isDisposed ||
      !state.editable ||
      !_commonInsertionAllowed(EditorCommandContext.of(state).configuration, action)) {
    return;
  }
  if (state.selection == null) {
    _showToolbarMessage(context, '请先把光标放入正文');
    return;
  }
  final services = EditorCommandContext.of(state).services;
  final session = _EditorModalSession(state);
  var revoked = false;
  Selection? landing;

  /// 撤权永久作废本次操作，重新授权须重新打开。
  void changed() {
    if (!state.editable) revoked = true;
  }

  /// 检查借用上下文、权限和业务端口是否仍属于原会话。
  bool current() =>
      context.mounted &&
      !state.isDisposed &&
      !revoked &&
      state.editable &&
      identical(EditorCommandContext.of(state).services, services);

  state.editableNotifier.addListener(changed);
  try {
    landing = await _performCommonInsertion(context, state, session.bookmark!, current, action);
  } catch (error, stack) {
    if (current()) {
      _reportEditorError(state, '插入${action.label}失败', error: error, stackTrace: stack, tag: 'DocCollab');
    } else {
      debugPrint('插入${action.label}失败：$error\n$stack');
    }
    if (context.mounted && current()) _showToolbarMessage(context, '插入失败，请重试');
  } finally {
    state.editableNotifier.removeListener(changed);
    try {
      await session.finish(current() ? context : null, landing);
    } catch (error, stack) {
      if (current()) {
        _reportEditorError(state, '恢复正文输入失败', error: error, stackTrace: stack, tag: 'DocCollab');
      } else {
        debugPrint('恢复正文输入失败：$error\n$stack');
      }
      if (context.mounted && current()) _showToolbarMessage(context, '请重新点击正文继续编辑');
    }
  }
}

/// 在[context]中执行[state]的[action]，使用[bookmark]重定位原插入位置。
/// [canUseHost]在每次异步返回后检查权限/宿主代次；取消不写入，失效/失败返回null。
/// 调用方拥有模态隔离和焦点恢复，更多面板与键盘直达复用此函数。
Future<Selection?> _performCommonInsertion(
  BuildContext context,
  EditorState state,
  _EditorSelectionBookmark bookmark,
  bool Function() canUseHost,
  _CommonInsertionAction action,
) async {
  /// 异步结束后拒绝迟到结果；书签进一步校验稳定身份及块锁代次。
  Selection? current() => context.mounted && !state.isDisposed && canUseHost() ? bookmark.resolve(state) : null;

  if (current() == null || !_commonInsertionAllowed(EditorCommandContext.of(state).configuration, action)) return null;
  try {
    if (!action.implemented) {
      _showUnsupportedMessage(context, action.label);
      return null;
    }
    final type = action.blockType;
    if (type != null &&
        const {
          'image',
          'link',
          'video',
          'attachment',
          'audio',
          'bookmark',
          'embed',
          'figma-embed',
          'juejin-embed',
        }.contains(type)) {
      final source = await showEditorMediaSourceSheet(
        context,
        blockType: type,
        editorState: state,
        canEdit: () => current() != null,
      );
      final selection = current();
      if (source == null || selection == null) return null;
      return await applyUrlBlockShortcut(state, selection, type, source.url, mediaSource: source);
    }
    switch (action.item) {
      case EditorKeyboardToolbarItem.table:
        return await insertCollabTable(state, current()!);
      case EditorKeyboardToolbarItem.callout:
        return await insertCollabCallout(state, current()!);
      case EditorKeyboardToolbarItem.meeting:
        if (EditorCommandContext.of(state).services.pickMeetingReference == null) {
          _showToolbarMessage(context, '当前实例未提供会议选择服务');
          return null;
        }
        final reference = await pickHostMeetingReference(context, state);
        final selection = current();
        if (reference == null || selection == null) return null;
        return await insertCollabMeeting(state, selection, {
          'meetingId': reference.meetingId,
          'title': reference.title,
          'number': reference.number,
        });
      case EditorKeyboardToolbarItem.formula:
      case EditorKeyboardToolbarItem.inlineFormula:
        final block = action.item == EditorKeyboardToolbarItem.formula;
        final latex = await showCollabFormulaInput(context, state, creatingBlock: block);
        final selection = current();
        if (latex == null || selection == null) return null;
        return block
            ? await insertCollabFormula(state, selection, latex)
            : await insertCollabInlineFormula(state, selection, latex);
      case EditorKeyboardToolbarItem.mermaid:
        final draft = await showCollabMermaidInput(context, state);
        final selection = current();
        if (draft == null || selection == null) return null;
        return await insertCollabMermaid(state, selection, draft.source, view: draft.view);
      case EditorKeyboardToolbarItem.mention:
        final selection = current()!;
        final node = state.getNodeAtPath(selection.start.path);
        if (!selection.isSingle || node?.delta == null || node!.type == 'code') {
          _showToolbarMessage(context, '此位置不支持用户提及');
          return null;
        }
        final original = Delta.fromJson(node.delta!.toJson());
        if (EditorCommandContext.of(state).services.pickMentionUser == null) {
          _showToolbarMessage(context, '当前实例未提供人员选择服务');
          return null;
        }
        final user = await pickHostMentionUser(context, state);
        final target = current();
        if (user == null || target == null || state.getNodeAtPath(target.start.path)?.delta != original) return null;
        return await insertCollabUserMention(state, target, user);
      case EditorKeyboardToolbarItem.divider:
        final draft = await showCollabDividerInput(context, state, canCreate: () => current() != null);
        final selection = current();
        if (draft == null || selection == null) return null;
        return await insertCollabDivider(state, selection, values: draft.values);
      case EditorKeyboardToolbarItem.pageDivider:
        final landing = await insertCollabPageDivider(state, current()!);
        if (landing == null && context.mounted) _showToolbarMessage(context, '分页符只能插入文档顶层，请选择顶层光标位置');
        return landing;
      default:
        return null;
    }
  } catch (error, stack) {
    if (!state.isDisposed && canUseHost()) {
      _reportEditorError(state, '插入${action.label}失败', error: error, stackTrace: stack, tag: 'DocCollab');
    } else {
      debugPrint('插入${action.label}失败：$error\n$stack');
    }
    if (context.mounted && !state.isDisposed && canUseHost()) _showToolbarMessage(context, '插入失败，请重试');
    return null;
  }
}

/// 添加块入口，使用Lucide加号图标；业务面板负责异步错误与正文选区恢复。
final _addBlockToolbarItem = MobileToolbarItem.action(
  itemIconBuilder: (_, _, _) => const Tooltip(
    message: '添加块',
    child: KeyedSubtree(key: ValueKey('editor-shortcut-add'), child: Icon(LucideIcons.circlePlus, size: 27)),
  ),
  actionHandler: (context, editorState) {
    unawaited(showEditorAddBlockSheet(context, editorState));
  },
);

/// The compact keyboard toolbar exposes the same image insertion flow as the
/// exhaustive add sheet. Keeping both entry points on one function guarantees
/// identical URL validation, collaborative node shape and caret restoration.
/// The entry uses the same Lucide image icon as the insertion panel.
final _imageToolbarItem = MobileToolbarItem.action(
  itemIconBuilder: (_, _, _) => const Tooltip(
    message: '插入图片',
    child: KeyedSubtree(key: ValueKey('editor-shortcut-image'), child: Icon(LucideIcons.image)),
  ),
  actionHandler: (context, editorState) {
    unawaited(showEditorUrlBlockDialog(context, editorState, ImageBlockKeys.type));
  },
);

/// 人员工具栏入口使用Lucide的@图标；异步错误由完整弹窗流程报告，正文位置独立保存。
final _mentionToolbarItem = MobileToolbarItem.action(
  itemIconBuilder: (_, _, _) => const Tooltip(
    message: '@用户',
    child: KeyedSubtree(key: ValueKey('editor-shortcut-mention'), child: Icon(LucideIcons.atSign)),
  ),
  actionHandler: (context, state) {
    unawaited(showEditorUserMentionSheet(context, state));
  },
);

/// 在借用 [context]/[editorState] 中调用宿主选择并插入用户；未注入选人端口不打开界面。
/// [keyword] 为初始搜索词，默认空字符串；[replaceTrigger] 为true时替换光标前的@。
/// 保存稳定块身份和原正文，远端重排可重定位，正文变化/删除/权限撤销拒绝提交。
/// 关闭动画完成后恢复原选区或插入后的光标；取消不写正文，失败报告并保留内容。
Future<void> showEditorUserMentionSheet(
  BuildContext context,
  EditorState editorState, {
  String keyword = '',
  bool replaceTrigger = false,
}) async {
  if (editorState.isDisposed || !editorState.editable) return;
  final services = EditorCommandContext.of(editorState).services;
  if (services.pickMentionUser == null) {
    _showToolbarMessage(context, '宿主未提供人员选择器');
    return;
  }
  final selection = editorState.selection;
  if (selection == null || !selection.isSingle) {
    _showToolbarMessage(context, '请选择同一段正文中的位置');
    return;
  }
  final node = editorState.getNodeAtPath(selection.start.path);
  if (node?.delta == null || node!.type == 'code') {
    _showToolbarMessage(context, '此位置不支持用户提及');
    return;
  }
  final id = _mediaTargetId(node);
  final original = node.delta!.toPlainText();
  final range = selection.normalized;
  final originalRange = node.delta!.slice(range.start.offset, range.end.offset);
  final session = _EditorModalSession(editorState);
  Selection? landing;
  try {
    final user = await pickHostMentionUser(context, editorState, keyword: keyword);
    if (user == null || !context.mounted) return;
    final current = session.bookmark?.resolve(editorState);
    final target = findCollabInlineTextNode(editorState, id);
    if (current == null ||
        target?.delta?.toPlainText() != original ||
        target!.delta!.slice(current.normalized.start.offset, current.normalized.end.offset) != originalRange) {
      _showToolbarMessage(context, '插入位置已变化，请重新选择正文位置');
      return;
    }
    var insertion = current;
    if (replaceTrigger) {
      final offset = current.start.offset;
      if (!current.isCollapsed || offset <= 0 || target.delta!.toPlainText()[offset - 1] != '@') {
        return;
      }
      insertion = Selection.single(path: current.start.path, startOffset: offset - 1, endOffset: offset);
    }
    landing = await insertCollabUserMention(editorState, insertion, user);
    if (context.mounted && landing == null) {
      _showToolbarMessage(context, '无法插入此用户提及');
    }
  } catch (error, stack) {
    services.report('插入用户提及失败', error, stack, 'DocCollab');
    if (context.mounted && identical(EditorCommandContext.of(editorState).services, services)) {
      _showToolbarMessage(context, '插入失败，请重试');
    }
  } finally {
    await session.finish(
      context.mounted && identical(EditorCommandContext.of(editorState).services, services) ? context : null,
      landing,
    );
  }
}

/// 以Lucide文字样式图标构建菜单入口，借用 [inlineStyleController] 回显格式。
/// 控制器由所属工具栏释放，颜色与字号子菜单均在原行内切换。
MobileToolbarItem _textDecorationToolbarItem(_InlineStyleController inlineStyleController) =>
    MobileToolbarItem.withMenu(
      itemIconBuilder: (_, _, _) => const KeyedSubtree(
        key: ValueKey('editor-shortcut-inline-style'),
        child: Tooltip(message: '文字样式', child: Icon(LucideIcons.caseSensitive, size: 27)),
      ),
      itemMenuBuilder: (_, editorState, service) =>
          _InlineStyleMenu(editorState: editorState, inlineStyleController: inlineStyleController),
    );

/// 为借用 [context]/[editorState] 中的文字范围打开格式面板，复用键盘工具栏的 T、Aa 和布局控件。
/// 允许连续格式修改；正文变化、删除或权限撤销后禁用面板，取消不修改正文。
/// 面板拥有局部样式控制器，退场后恢复稳定选区及正文输入，不释放编辑器。
Future<void> showEditorSelectionFormats(BuildContext context, EditorState editorState) async {
  final range = CollabTextRange.capture(editorState);
  if (!editorState.editable || range == null || !range.hasText) return;
  try {
    await runEditorHeaderAction<void>(context, editorState, () async {
      editorState.selection = range.resolve(editorState);

      await showCollabBottomSheet<void>(
        context: context,
        requestFocus: false,
        builder: (sheetContext) {
          return _SelectionFormatSheet(editorState: editorState, range: range);
        },
      );
    }, selectionAfterAction: () => editorState.selection);
  } catch (error, stack) {
    _reportEditorError(editorState, '划词格式修改失败', error: error, stackTrace: stack, tag: 'DocCollab');
    if (context.mounted) _showToolbarMessage(context, '格式修改失败，请重试');
  }
}

/// 借用当前范围显示现有格式控件，持有独立的样式状态。
class _SelectionFormatSheet extends StatefulWidget {
  /// [editorState] 由宿主持有，[range] 保存打开时的稳定身份和正文快照。
  const _SelectionFormatSheet({required this.editorState, required this.range});

  /// 借用的正文编辑器，面板退出时不关闭。
  final EditorState editorState;

  /// 打开时的稳定范围，格式变化可持续应用，正文变化后禁止继续操作。
  final CollabTextRange range;

  /// 创建面板拥有的样式控制器状态。
  @override
  createState() => _SelectionFormatSheetState();
}

/// 复用格式、类型与布局命令；每次触摸前按稳定身份重定位，避免远端重排改到其他段落。
class _SelectionFormatSheetState extends State<_SelectionFormatSheet> {
  late final _InlineStyleController _styles;

  /// 稳定范围仅跟随本面板的类型/缩进命令；null表示目标已不支持文字划词。
  CollabTextRange? _range;

  /// 创建面板使用的样式状态，不接管编辑器资源。
  @override
  void initState() {
    super.initState();
    _styles = _InlineStyleController(widget.editorState);
    _range = widget.range;
  }

  /// 接收本面板命令同步写入后捕获的 [range]，保留之后远端变化的失效检查。
  /// 不从异步完成时的实时选区重建，避免把等待期间的远端正文误认成本地转换结果。
  void _acceptLocalRange(CollabTextRange? range) {
    if (mounted) setState(() => _range = range);
  }

  /// 释放本面板的选区监听，编辑器由调用方释放。
  @override
  void dispose() {
    _styles.dispose();
    super.dispose();
  }

  /// 在借用 [context] 中随事务和权限更新面板；失效时只保留关闭操作。
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.editorState.editableNotifier, widget.editorState.selectionNotifier]),
    builder: (context, _) => StreamBuilder<EditorTransactionValue>(
      stream: widget.editorState.transactionStream,
      builder: (context, _) {
        final selection = _range?.resolve(widget.editorState, checkFormatting: false);
        final enabled = widget.editorState.editable && selection != null;
        return CollabBottomSheet(
          key: const ValueKey('editor-selection-format-sheet'),
          title: const Text('文字格式'),
          subtitle: '格式修改即时生效',
          icon: LucideIcons.textCursorInput,
          actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('完成'))],
          child: MobileToolbarTheme(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!enabled) const Text('选区或编辑权限已变化，请关闭后重新选择'),
                IgnorePointer(
                  ignoring: !enabled,
                  child: Listener(
                    onPointerDown: (_) {
                      final current = _range?.resolve(widget.editorState, checkFormatting: false);
                      widget.editorState.selection = widget.editorState.editable ? current : null;
                      if (current == null) {
                        setState(() {});
                      }
                    },
                    child: Opacity(
                      opacity: enabled ? 1 : .35,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (_range != null)
                            Container(
                              padding: const EdgeInsets.all(15),
                              margin: const EdgeInsets.only(bottom: 18),
                              decoration: BoxDecoration(
                                border: Border.all(color: CollabModalColors.of(context).line),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                _range!.text,
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: CollabModalColors.of(context).accent),
                              ),
                            ),
                          _InlineStyleMenu(
                            editorState: widget.editorState,
                            inlineStyleController: _styles,
                            expanded: true,
                          ),
                          const SizedBox(height: 20),
                          const Text('段落布局', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
                          const SizedBox(height: 8),
                          SizedBox(
                            height: 60,
                            child: _BlockLayoutMenu(editorState: widget.editorState, onRangeChanged: _acceptLocalRange),
                          ),
                          const SizedBox(height: 12),
                          const Text('段落类型', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
                          const SizedBox(height: 8),
                          SizedBox(
                            height: 60,
                            child: _BlockStyleMenu(editorState: widget.editorState, onRangeChanged: _acceptLocalRange),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

/// 块类型入口及展开菜单，使用Lucide文字图标并保留原选区命令。
final _blockStyleToolbarItem = MobileToolbarItem.withMenu(
  itemIconBuilder: (context, editorState, service) => const KeyedSubtree(
    key: ValueKey('editor-shortcut-block-style'),
    child: Tooltip(message: '块类型', child: Icon(LucideIcons.type, size: 27)),
  ),
  itemMenuBuilder: (_, editorState, service) => _BlockStyleMenu(editorState: editorState),
);

/// 块布局菜单，借用 [EditorState] 显示对齐、普通文本段及三种列表缩进，不拥有编辑器资源。
class _BlockLayoutMenu extends StatefulWidget {
  /// [editorState] 为借用编辑器；[onRangeChanged] 可接收本地缩进命令的结果快照，默认不通知。
  const _BlockLayoutMenu({required this.editorState, this.onRangeChanged});

  /// 借用的编辑器，提供选区与事务；由宿主释放，菜单不关闭键盘或编辑器。
  final EditorState editorState;

  /// 本地缩进完成时通知格式面板；null结果表示目标已不支持划词，不跟随远端类型变化。
  final ValueChanged<CollabTextRange?>? onRangeChanged;

  /// 创建仅管理菜单展示的状态；列表写入由共用事务负责。
  @override
  createState() => _BlockLayoutMenuState();
}

/// 根据当前选区展示布局、行间距与颜色操作；事务完成后在仍挂载且编辑器未更换时刷新。
class _BlockLayoutMenuState extends State<_BlockLayoutMenu> {
  String? _colorAttribute;

  /// 行间距替换当前布局行，返回时恢复布局按钮。
  bool _lineHeightOpen = false;

  /// 为借用的 [nodes] 汇总当前块颜色，背景与边框使用同一桌面浅色色板。
  Widget _buildBlockColors(List<Node> nodes) {
    final attribute = _colorAttribute!;
    final isBorder = attribute == csesBlockBorderColorAttribute;
    final targets = nodes.where((node) => node.delta != null && (!isBorder || node.type == QuoteBlockKeys.type));
    return CollabColorPicker(
      onError: (error, stack) => _reportEditorError(widget.editorState, '颜色设置失败', error: error, stackTrace: stack),
      keyPrefix: isBorder ? 'editor-block-border-color' : 'editor-block-background-color',
      horizontal: true,
      selection: CollabColorSelection.fromValues(targets.map((node) => node.attributes[attribute] as String?)),
      resetLabel: isBorder ? '默认线条颜色' : '清除块背景色',
      onBack: () => setState(() => _colorAttribute = null),
      onSelected: _setBlockColor,
    );
  }

  /// 将用户选择的 CSS [value] 写入实时选区；null 恢复默认，其他既有颜色不变。
  /// 正文块背景另投影为 AppFlowy ARGB，保存失败交给共用选择器报告。
  /// 工具栏有等待中的宿主动作时拒绝旧颜色面板回调。
  Future<void> _setBlockColor(String? value) async {
    if (!_ToolbarCommandScope.allows(context)) return;
    final state = widget.editorState;
    final selection = state.selection;
    final attribute = _colorAttribute;
    if (state.isDisposed || !state.editable || selection == null || attribute == null) {
      return;
    }
    final transaction = state.transaction;
    for (final node in state.getNodesInSelection(selection)) {
      if (node.delta == null || (attribute == csesBlockBorderColorAttribute && node.type != QuoteBlockKeys.type)) {
        continue;
      }
      if (sameCollabColor(node.attributes[attribute] as String?, value)) {
        continue;
      }
      transaction.updateNode(node, {
        attribute: value,
        if (attribute == csesBlockBackgroundColorAttribute) blockComponentBackgroundColor: collabColorToEditor(value),
      });
    }
    if (transaction.operations.isEmpty) return;
    if (state.undoManager.undoStack.isNonEmpty) {
      state.undoManager.undoStack.last.seal();
    }
    await state.apply(transaction, withUpdateSelection: false, skipHistoryDebounce: true);
    if (mounted && identical(widget.editorState, state)) setState(() {});
  }

  /// 使用 [context] 渲染布局按钮；文本段遵守8级及兄弟深度约束，0级列表仍可退为段落。
  /// 对齐、缩进与颜色入口统一使用Lucide图标，保持既有选中及禁用状态。
  /// 布局按钮间隔保持5逻辑像素，缩进组之后沿用10逻辑像素。
  @override
  Widget build(BuildContext context) {
    final selection = widget.editorState.selection;
    if (selection == null) {
      return const SizedBox.shrink();
    }
    final nodes = widget.editorState.getNodesInSelection(selection);
    if (_lineHeightOpen) {
      return _EditorSpacingMenu(
        editorState: widget.editorState,
        lineHeight: true,
        canExecute: () => _ToolbarCommandScope.allows(context),
        onBack: () => setState(() => _lineHeightOpen = false),
      );
    }
    if (_colorAttribute != null) return _buildBlockColors(nodes);
    final canOutdent = canChangeCollabBlockIndent(widget.editorState, -1);
    final canIncreaseIndent = canChangeCollabBlockIndent(widget.editorState, 1);

    return ListView(
      key: const ValueKey('editor-block-layout-menu'),
      scrollDirection: Axis.horizontal,
      children: [
        if (EditorCommandContext.of(widget.editorState).configuration.hasParagraphLayout) ...[
          _PopupIconButton(
            key: const ValueKey('editor-block-outdent'),
            tooltip: '减少缩进',
            enabled: canOutdent,
            selected: false,
            icon: const Icon(LucideIcons.indentDecrease, size: 28),
            onPressed: () => _changeIndent(-1),
          ),
          const SizedBox(width: 5),
          _PopupIconButton(
            key: const ValueKey('editor-block-indent'),
            tooltip: '增加缩进',
            enabled: canIncreaseIndent,
            selected: false,
            icon: const Icon(LucideIcons.indentIncrease, size: 28),
            onPressed: () => _changeIndent(1),
          ),
          const SizedBox(width: 10),
        ],
        for (final option in const [
          ('left', '左对齐', LucideIcons.textAlignStart),
          ('center', '居中', LucideIcons.textAlignCenter),
          ('right', '右对齐', LucideIcons.textAlignEnd),
          ('justify', '两端对齐', LucideIcons.textAlignJustify),
          ('distributed', '分散对齐', LucideIcons.space),
        ])
          if (EditorCommandContext.of(widget.editorState).configuration.alignments.contains(option.$1)) ...[
            _PopupIconButton(
              key: ValueKey('editor-block-align-${option.$1}'),
              tooltip: option.$2,
              enabled: !const {'justify', 'distributed'}.contains(option.$1) || nodes.every((n) => n.delta != null),
              selected: nodes.isNotEmpty && nodes.every((node) => _alignmentOf(node) == option.$1),
              icon: Icon(option.$3, size: 28),
              onPressed: () => _setAlignment(option.$1),
            ),
            const SizedBox(width: 5),
          ],
        if (EditorCommandContext.of(widget.editorState).configuration.lineHeight) ...[
          _PopupIconButton(
            key: const ValueKey('editor-block-line-height'),
            tooltip: '行间距',
            enabled: widget.editorState.editable && nodes.any(supportsCollabParagraph),
            selected: false,
            icon: const Icon(LucideIcons.moveVertical, size: 28),
            onPressed: () => setState(() => _lineHeightOpen = true),
          ),
          const SizedBox(width: 5),
        ],
        if (EditorCommandContext.of(widget.editorState).configuration.hasParagraphLayout) ...[
          _PopupIconButton(
            key: const ValueKey('editor-block-background-color'),
            tooltip: '块背景色',
            enabled: nodes.any((n) => n.delta != null),
            selected: false,
            icon: const Icon(LucideIcons.paintBucket, size: 28),
            onPressed: () => setState(() => _colorAttribute = csesBlockBackgroundColorAttribute),
          ),
          const SizedBox(width: 5),
          if (nodes.any((n) => n.type == QuoteBlockKeys.type)) ...[
            _PopupIconButton(
              key: const ValueKey('editor-block-border-color'),
              tooltip: '左侧线条颜色',
              selected: false,
              icon: const Icon(LucideIcons.panelLeft, size: 28),
              onPressed: () => setState(() => _colorAttribute = csesBlockBorderColorAttribute),
            ),
            const SizedBox(width: 5),
          ],
        ],
        if (EditorCommandContext.of(widget.editorState).configuration.nextParagraphStyle)
          for (final option in const [
            (null, '下一段：默认', LucideIcons.rotateCcw),
            ('same', '下一段：延续样式', LucideIcons.cornerDownRight),
            ('body', '下一段：正文', LucideIcons.textAlignStart),
          ]) ...[
            _PopupIconButton(
              key: ValueKey('editor-next-paragraph-${option.$1 ?? 'default'}'),
              tooltip: option.$2,
              enabled: nodes.any(supportsCollabParagraph),
              selected:
                  nodes.isNotEmpty &&
                  nodes.every(
                    (node) =>
                        supportsCollabParagraph(node) &&
                        readCollabParagraph(node).values['nextParagraphStyle'] == option.$1,
                  ),
              icon: Icon(option.$3, size: 28),
              onPressed: () => unawaited(_setNextParagraphStyle(option.$1)),
            ),
            const SizedBox(width: 5),
          ],
      ],
    );
  }

  /// 设置实时选区的下一段 [style]，null 恢复默认；失败由共用诊断边界报告。
  /// 所属工具栏等待宿主动作时拒绝旧面板回调。
  Future<void> _setNextParagraphStyle(String? style) async {
    if (!_ToolbarCommandScope.allows(context)) return;
    final state = widget.editorState;
    try {
      await setCollabNextParagraphStyle(state, style);
      if (mounted && identical(widget.editorState, state)) setState(() {});
    } catch (error, stackTrace) {
      _reportEditorError(state, '设置下一段样式失败', error: error, stackTrace: stackTrace);
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('设置失败，请重试')));
      }
    }
  }

  /// 读取借用 [node] 的展示对齐方式；未知/缺失值回退 left，无副作用。
  String _alignmentOf(Node node) {
    final value = node.attributes[blockComponentAlign];
    return const {'left', 'center', 'right', 'justify', 'distributed'}.contains(value) ? value as String : 'left';
  }

  /// 将 [delta]（-1/+1）应用到点击时的当前选区；复用整组选区一个事务及原光标恢复。
  /// 不缓存 build 时选区，失效/只读或上限条件不执行。等待事务完成后检查 mounted 和编辑器
  /// 身份及存活状态再刷新；非预期异常保留错误/堆栈上报 Log.e，并交 FlutterError，不重复用户提示。
  /// 列表零级退为段落时，将同步结果快照交还格式面板，以接续其后操作。
  /// 所属工具栏等待宿主动作时拒绝旧回调，不影响独立格式面板。
  Future<void> _changeIndent(int delta) async {
    if (!_ToolbarCommandScope.allows(context)) return;
    final state = widget.editorState;
    try {
      final completion = changeCollabBlockIndent(state, delta);
      final range = CollabTextRange.capture(state);
      await completion;
      if (mounted && identical(widget.editorState, state) && !state.isDisposed) {
        widget.onRangeChanged?.call(range);
        setState(() {});
      }
    } catch (error, stackTrace) {
      _reportEditorError(state, '文档块缩进失败', error: error, stackTrace: stackTrace, tag: 'DocCollab');
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'DocCollab',
          context: ErrorDescription('changing collaborative block indentation'),
        ),
      );
    }
  }

  /// 复核工具栏互斥后将[alignment]写入当前正文对齐；制图模式拒绝尚未支持的分散对齐。
  Future<void> _setAlignment(String alignment) async {
    if (!_ToolbarCommandScope.allows(context)) return;
    final state = widget.editorState;
    final selection = state.selection;
    if (state.isDisposed || !state.editable || selection == null) return;
    if (!EditorCommandContext.of(state).configuration.alignments.contains(alignment)) return;
    final nodes = state.getNodesInSelection(selection);
    if (const {'justify', 'distributed'}.contains(alignment) && nodes.any((n) => n.delta == null)) {
      return;
    }
    final transaction = state.transaction;
    for (final node in nodes) {
      if (node.attributes[blockComponentAlign] == alignment) continue;
      transaction.add(
        UpdateOperation(
          node.path,
          {blockComponentAlign: alignment},
          {blockComponentAlign: node.attributes[blockComponentAlign]},
        ),
      );
    }
    if (transaction.operations.isEmpty) return;
    if (state.undoManager.undoStack.isNonEmpty) {
      state.undoManager.undoStack.last.seal();
    }
    await state.apply(transaction, withUpdateSelection: false, skipHistoryDebounce: true);
    if (mounted && identical(widget.editorState, state)) setState(() {});
  }
}

/// 对齐和缩进入口，Lucide图标与展开布局菜单使用相同语义。
final _blockLayoutToolbarItem = MobileToolbarItem.withMenu(
  itemIconBuilder: (_, _, _) => const Tooltip(
    message: '对齐与缩进',
    child: KeyedSubtree(
      key: ValueKey('editor-shortcut-block-layout'),
      child: Icon(LucideIcons.textAlignStart, size: 27),
    ),
  ),
  itemMenuBuilder: (_, editorState, service) => _BlockLayoutMenu(editorState: editorState),
);

/// 借用正文编辑器的类型菜单，格式面板可订阅本地转换结果，不持有文档资源。
class _BlockStyleMenu extends StatefulWidget {
  /// [editorState] 由页面拥有；[onRangeChanged] 在本地转换完成后接收同步结果快照，默认不通知。
  const _BlockStyleMenu({required this.editorState, this.onRangeChanged});

  /// 用于实时读取选区和执行类型事务的借用编辑器。
  final EditorState editorState;

  /// 格式面板用它接续自身转换后的选区；null结果表示转为不支持划词的类型。
  final ValueChanged<CollabTextRange?>? onRangeChanged;

  /// 创建菜单自己的披露与互斥状态，不释放借用编辑器。
  @override
  createState() => _BlockStyleMenuState();
}

class _BlockStyleMenuState extends State<_BlockStyleMenu> {
  /// 类型命令执行期间拒绝重复提交；所有退出路径均在 finally 恢复，不持有外部资源。
  bool _applyingStyle = false;

  /// 从H1～H3开始逐级披露，最高到H6；切换正文块时重新推导。
  int _maxHeadingLevel = 3;
  String? _activeNodeId;

  /// 正文类型的Lucide文字图标及转换目标。
  static const _paragraphStyle = _BlockStyleAction(
    blockType: ParagraphBlockKeys.type,
    label: '正文',
    icon: LucideIcons.type,
  );

  /// 列表、代码与引用类型共享的Lucide图标及命令定义。
  static const _blockStyles = <_BlockStyleAction>[
    _BlockStyleAction(blockType: NumberedListBlockKeys.type, label: '有序列表', icon: LucideIcons.listOrdered),
    _BlockStyleAction(blockType: BulletedListBlockKeys.type, label: '无序列表', icon: LucideIcons.list),
    _BlockStyleAction(blockType: TodoListBlockKeys.type, label: '待办列表', icon: LucideIcons.squareCheck),
    _BlockStyleAction(blockType: 'code', label: '代码块', icon: LucideIcons.codeXml),
    _BlockStyleAction(blockType: QuoteBlockKeys.type, label: '引用块', icon: LucideIcons.quote),
  ];

  @override
  void initState() {
    super.initState();
    _activeNodeId = _selectedNodeId();
    _maxHeadingLevel = _headingLimitForSelection();
    widget.editorState.selectionNotifier.addListener(_onSelectionChanged);
  }

  @override
  void didUpdateWidget(covariant _BlockStyleMenu oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.editorState != widget.editorState) {
      oldWidget.editorState.selectionNotifier.removeListener(_onSelectionChanged);
      widget.editorState.selectionNotifier.addListener(_onSelectionChanged);
      _activeNodeId = _selectedNodeId();
      _maxHeadingLevel = _headingLimitForSelection();
    }
  }

  @override
  void dispose() {
    widget.editorState.selectionNotifier.removeListener(_onSelectionChanged);
    super.dispose();
  }

  /// 选区进入另一块时重置渐进标题范围，最多披露至H6。
  void _onSelectionChanged() {
    final nextNodeId = _selectedNodeId();
    if (nextNodeId == _activeNodeId) {
      return;
    }
    _activeNodeId = nextNodeId;
    if (mounted) {
      setState(() => _maxHeadingLevel = _headingLimitForSelection());
    }
  }

  String? _selectedNodeId() {
    final selection = widget.editorState.selection;
    if (selection == null) {
      return null;
    }
    return widget.editorState.getNodeAtPath(selection.start.path)?.id;
  }

  /// 按当前标题推进到下一个已启用级别，连续配置从H1～H3开始，最多显示H6。
  /// 非连续级别跳过被禁用项；仅配置高等级标题时仍保留首个可用入口。
  int _headingLimitForSelection() {
    final levels = _menuHeadingLevels(EditorCommandContext.of(widget.editorState).configuration);
    final initial = math.max(3, levels.firstOrNull ?? 3);
    final selection = widget.editorState.selection;
    if (selection == null) return initial;
    final node = widget.editorState.getNodeAtPath(selection.start.path);
    if (node?.type != HeadingBlockKeys.type) return initial;
    final storedLevel = node?.attributes[HeadingBlockKeys.level];
    final level = storedLevel is int ? storedLevel.clamp(1, _maxHeadingMenuLevel) : 1;
    final next = levels.where((candidate) => candidate > level).firstOrNull ?? level;
    return math.max(initial, next);
  }

  /// 为借用的 [context] 构建类型菜单；高亮当前起点类型，按钮在点击时读取最新选区。
  /// 构建过程无编辑副作用，列表命令由统一事务执行，Heading 选项按当前披露上限显示。
  /// 标题入口最多显示H6；按实例逐级展示配置控制披露，使用对应Lucide图标，不改变已有标题数据。
  @override
  Widget build(BuildContext context) {
    final selection = widget.editorState.selection;
    if (selection == null) {
      return const SizedBox.shrink();
    }
    final node = widget.editorState.getNodeAtPath(selection.start.path);
    final config = EditorCommandContext.of(widget.editorState).configuration;
    final styles = <_BlockStyleAction>[
      _paragraphStyle,
      for (final level in _menuHeadingLevels(config))
        if (level <= _maxHeadingLevel || !config.usesProgressiveHeadingMenu)
          _BlockStyleAction(
            blockType: HeadingBlockKeys.type,
            headingLevel: level,
            label: '$level 级标题',
            icon: _headingMenuIcons[level - 1],
          ),
      ..._blockStyles,
    ].where((style) => config.allowsBlock(style.blockType, level: style.headingLevel)).toList();
    if (!config.hasComplexBlocks) {
      styles.sort((a, b) {
        final order = config.blocks
            .indexWhere((block) => block.type == a.blockType)
            .compareTo(config.blocks.indexWhere((block) => block.type == b.blockType));
        return order != 0 ? order : (a.headingLevel ?? 0).compareTo(b.headingLevel ?? 0);
      });
    }

    return ListView.separated(
      key: const ValueKey('editor-block-style-menu'),
      scrollDirection: Axis.horizontal,
      scrollCacheExtent: const ScrollCacheExtent.pixels(1000),
      itemCount: styles.length,
      separatorBuilder: (_, _) => const SizedBox(width: 4),
      itemBuilder: (context, index) {
        final style = styles[index];
        final selected = node != null && style.matches(node);
        return _PopupIconButton(
          key: ValueKey('editor-block-${style.blockType}-${style.headingLevel ?? 0}'),
          tooltip: style.label,
          selected: selected,
          icon: Icon(style.icon, size: 27),
          onPressed: () => _apply(style),
        );
      },
    );
  }

  /// 将 [style] 应用于点击时的当前选区；列表互换复用统一事务，保留层级、格式、勾选规则和焦点。
  /// 高亮容器、只读/销毁、无选区以及执行中的重复命令不执行；列表与非列表混选不部分切换。
  /// 借用 EditorState，await 后检查菜单仍挂载且编辑器未更换，避免迟到刷新。失败由本边界
  /// 记录原始异常和堆栈并交给 Flutter 错误报告；Future 在事务与菜单刷新结束后完成。
  /// 命令同步应用文档后立即捕获范围，异步结束只交付该快照，不接受等待期间的远端变化。
  /// 所属工具栏等待宿主动作时拒绝执行，不让已关闭菜单的旧回调绕过互斥。
  Future<void> _apply(_BlockStyleAction style) async {
    if (!_ToolbarCommandScope.allows(context)) return;
    final state = widget.editorState;
    final capabilities = EditorCommandContext.of(state).configuration;
    if (!capabilities.allowsBlock(style.blockType, level: style.headingLevel)) return;
    final selection = state.selection;
    if (_applyingStyle || state.isDisposed || !state.editable || selection == null) return;
    final nodes = state.getNodesInSelection(selection);
    if (nodes.isEmpty || nodes.any((node) => node.type == csesCalloutBlockType)) return;
    _applyingStyle = true;
    try {
      final completion = applyEditorBlockStyle(state, style.blockType, headingLevel: style.headingLevel);
      final range = CollabTextRange.capture(state);
      await completion;
      if (!mounted || widget.editorState != state || state.isDisposed) {
        return;
      }
      widget.onRangeChanged?.call(range);
      final level = style.headingLevel;
      setState(() {
        final limit = _headingLimitForSelection();
        _maxHeadingLevel = level != null && level >= 3 ? math.max(_maxHeadingLevel, limit) : limit;
      });
    } catch (error, stackTrace) {
      _reportEditorError(state, '文档列表类型切换失败', error: error, stackTrace: stackTrace, tag: 'DocCollab');
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'DocCollab',
          context: ErrorDescription('切换文档块类型'),
        ),
      );
    } finally {
      _applyingStyle = false;
    }
  }
}

/// 将[blockType]应用到借用[state]的实时选区；[headingLevel]仅用于已启用的H1~H6标题，默认一级；超范围不执行。
/// T菜单、待办入口与键盘标题操作共用此事务，不按在线/离线划分。
/// 能力关闭、只读、销毁、空选区或高亮容器不执行；列表与非列表混选由列表命令整批拒绝。
/// 同类列表不重建或重置勾选，转换保留正文、格式、层级和焦点，异常交由调用边界报告。
Future<void> applyEditorBlockStyle(EditorState state, String blockType, {int? headingLevel}) async {
  final capabilities = EditorCommandContext.of(state).configuration;
  if (!capabilities.allowsBlock(blockType, level: headingLevel)) return;
  final selection = state.selection;
  if (state.isDisposed || !state.editable || selection == null) return;
  final nodes = state.getNodesInSelection(selection);
  if (nodes.isEmpty || nodes.any((node) => node.type == csesCalloutBlockType)) return;
  const listTypes = {'numbered_list', 'bulleted_list', 'todo_list'};
  if (listTypes.contains(blockType) && nodes.any((node) => listTypes.contains(node.type))) {
    await changeCollabListType(state, blockType);
  } else {
    await state.formatNode(
      selection,
      (node) => _convertedNode(
        node,
        blockType,
        headingLevel,
        preservedAttributes: capabilities.blockConversionPreservedAttributes,
      ),
    );
  }
}

/// 标题Markdown使用与T菜单相同的能力及属性转换，避免原生快捷输入丢失宿主元数据。
/// 只处理可编辑文字叶子和已启用的1～6级标题；不持有会话或修改其他快捷键。
final editorHeadingMarkdown = CharacterShortcutEvent(
  key: 'editor-heading-markdown',
  character: ' ',
  handler: (state) {
    final capabilities = EditorCommandContext.of(state).configuration;
    return formatMarkdownSymbol(
      state,
      (node) => node.delta != null && node.children.isEmpty,
      (_, text, selection) =>
          text.isNotEmpty &&
          text.length <= 6 &&
          text.split('').every((character) => character == '#') &&
          capabilities.allowsBlock(HeadingBlockKeys.type, level: text.length),
      (text, node, delta) => [
        _convertedNode(
          node.copyWith(
            attributes: {...node.attributes, blockComponentDelta: delta.compose(Delta()..delete(text.length)).toJson()},
          ),
          HeadingBlockKeys.type,
          text.length,
          preservedAttributes: capabilities.blockConversionPreservedAttributes,
        ),
      ],
    );
  },
);

/// 类型菜单的不可变命令描述；图标与标签不参与文档数据写入。
class _BlockStyleAction {
  /// [blockType] 是目标块类型，[label] 是提示，[icon] 是Lucide图标。
  /// [headingLevel] 仅标题菜单使用，范围1～6；其他类型为null。
  const _BlockStyleAction({required this.blockType, required this.label, required this.icon, this.headingLevel});

  /// 转换命令使用的目标类型，不由菜单重新定义Schema。
  final String blockType;

  /// 标题级别，非标题为null。
  final int? headingLevel;

  /// 对用户展示的操作名称。
  final String label;

  /// 对应类型的Lucide图标，不持有资源。
  final IconData icon;

  /// 判断借用的 [node] 是否匹配类型及可选标题级别，用于回显选中状态。
  bool matches(Node node) {
    if (node.type != blockType) {
      return false;
    }
    return blockType != HeadingBlockKeys.type || node.attributes[HeadingBlockKeys.level] == headingLevel;
  }
}

/// 借用编辑器和输入样式控制器，工具栏采用单行模式，弹窗采用展开模式。
class _InlineStyleMenu extends StatefulWidget {
  /// [editorState]和[inlineStyleController]为借用对象；[expanded]默认false，true展开样式和色板。
  const _InlineStyleMenu({required this.editorState, required this.inlineStyleController, this.expanded = false});

  /// 借用的当前文档编辑器，不由菜单释放。
  final EditorState editorState;

  /// 借用的输入格式控制器，由所属工具栏或面板创建并释放。
  final _InlineStyleController inlineStyleController;

  /// 是否展示完整文字样式及两组色板，状态仍由当前编辑器持有。
  final bool expanded;

  /// 创建仅管理局部展示状态的组件，不释放借用控制器。
  @override
  createState() => _InlineStyleMenuState();
}

/// 持有颜色、字号与字间距子菜单状态；格式命令读取实时选区，不拥有编辑器。
class _InlineStyleMenuState extends State<_InlineStyleMenu> {
  // The two color entries are inserted after the five boolean text styles.
  // Keeping explicit indices makes the visual order stable while `_styles`
  // remains responsible only for on/off attributes such as bold and code.

  // A single picker replaces the normal Aa row. The target records whether a
  // palette choice updates the glyph color (`font_color`) or the inline
  // highlight behind the glyph (`bg_color`).
  _InlineColorTarget? _colorPicker;

  /// 字间距子菜单与字号、颜色互斥；不持有输入状态。
  bool _letterSpacingOpen = false;

  /// 字号选项替换当前文字菜单，不打开新路由或结束输入。
  bool _fontSizesOpen = false;

  /// 进入字号菜单时借用的命令上下文；切换所属会话后拒绝旧菜单写入。
  EditorCommandContext? _fontSizeOwner;

  /// 字号菜单打开期间一旦撤权，重新授权也须返回后重新打开。
  bool _fontSizeRevoked = false;

  /// 当前字号事务尚未完成，阻止重复点击和提前离开菜单。
  bool _fontSizeSaving = false;

  /// 格式键与Lucide图标的映射，顺序供普通和展开样式菜单共用。
  static final _styles = <_InlineStyleAction>[
    _InlineStyleAction(key: AppFlowyRichTextKeys.bold, label: '加粗', icon: LucideIcons.bold),
    _InlineStyleAction(key: AppFlowyRichTextKeys.italic, label: '斜体', icon: LucideIcons.italic),
    _InlineStyleAction(key: AppFlowyRichTextKeys.underline, label: '下划线', icon: LucideIcons.underline),
    _InlineStyleAction(key: AppFlowyRichTextKeys.strikethrough, label: '删除线', icon: LucideIcons.strikethrough),
    _InlineStyleAction(key: AppFlowyRichTextKeys.code, label: '行内代码', icon: LucideIcons.codeXml),
    _InlineStyleAction(key: csesSuperscriptAttribute, label: '上标', icon: LucideIcons.superscript),
    _InlineStyleAction(key: csesSubscriptAttribute, label: '下标', icon: LucideIcons.subscript),
  ];

  /// 订阅借用的格式与权限状态，所属菜单销毁时成对注销。
  @override
  void initState() {
    super.initState();
    widget.inlineStyleController.addListener(_onInlineStyleChanged);
    widget.editorState.editableNotifier.addListener(_onFontSizePermissionChanged);
  }

  /// 替换[oldWidget]的借用资源时迁移监听；换文档关闭字号会话，不释放正文。
  @override
  void didUpdateWidget(covariant _InlineStyleMenu oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.inlineStyleController != widget.inlineStyleController) {
      oldWidget.inlineStyleController.removeListener(_onInlineStyleChanged);
      widget.inlineStyleController.addListener(_onInlineStyleChanged);
    }
    if (!identical(oldWidget.editorState, widget.editorState)) {
      oldWidget.editorState.editableNotifier.removeListener(_onFontSizePermissionChanged);
      widget.editorState.editableNotifier.addListener(_onFontSizePermissionChanged);
      _fontSizesOpen = false;
      _letterSpacingOpen = false;
      _fontSizeOwner = null;
      _fontSizeRevoked = false;
      _fontSizeSaving = false;
    }
  }

  /// 注销格式与权限监听，借用的正文和样式控制器仍由创建者释放。
  @override
  void dispose() {
    widget.inlineStyleController.removeListener(_onInlineStyleChanged);
    widget.editorState.editableNotifier.removeListener(_onFontSizePermissionChanged);
    super.dispose();
  }

  /// 在仍挂载时刷新当前文字格式及字号选中标记。
  void _onInlineStyleChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  /// 在借用 [context] 中回显当前格式；点击命令时重新读取选区，避免使用构建阶段的旧路径。
  /// 字色与背景色保留当前色值；字号、字间距和字样由实例配置选择，图标沿用Lucide。
  @override
  Widget build(BuildContext context) {
    final selection = widget.editorState.selection;
    if (selection == null) {
      return const SizedBox.shrink();
    }

    if (_letterSpacingOpen) {
      return _EditorSpacingMenu(
        editorState: widget.editorState,
        lineHeight: false,
        canExecute: () => _ToolbarCommandScope.allows(context),
        onBack: () => setState(() => _letterSpacingOpen = false),
      );
    }
    if (_fontSizesOpen) return _buildFontSizePicker(selection);
    if (widget.expanded) return _buildExpanded(selection);

    final colorPicker = _colorPicker;
    if (colorPicker != null) {
      return _buildColorPicker(selection, colorPicker);
    }

    final currentTextColor = _currentColor(selection, AppFlowyRichTextKeys.textColor);
    final currentBackgroundColor = _currentColor(selection, AppFlowyRichTextKeys.backgroundColor);

    final config = EditorCommandContext.of(widget.editorState).configuration;
    final buttons = <Widget>[
      for (final style in _styles.take(5))
        if (config.allowsFormat(style.key)) _compactStyle(selection, style),
      if (config.allowsFormat(AppFlowyRichTextKeys.textColor))
        _PopupIconButton(
          key: const ValueKey('editor-inline-text-color'),
          tooltip: '文字颜色',
          selected: !currentTextColor.isMixed && currentTextColor.value != null,
          icon: Icon(
            LucideIcons.baseline,
            key: const ValueKey('editor-inline-text-color-icon'),
            size: 28,
            color: parseCollabBlockColor(currentTextColor.value),
          ),
          onPressed: () => setState(() => _colorPicker = _InlineColorTarget.text),
        ),
      if (config.allowsFormat(AppFlowyRichTextKeys.backgroundColor))
        _PopupIconButton(
          key: const ValueKey('editor-inline-background-color'),
          tooltip: '文字背景颜色',
          selected: !currentBackgroundColor.isMixed && currentBackgroundColor.value != null,
          icon: Icon(
            LucideIcons.paintBucket,
            key: const ValueKey('editor-inline-background-color-icon'),
            size: 28,
            color: parseCollabBlockColor(currentBackgroundColor.value),
          ),
          onPressed: () => setState(() => _colorPicker = _InlineColorTarget.background),
        ),
      if (config.allowsFormat('t:px'))
        _PopupIconButton(
          key: const ValueKey('editor-inline-font-size'),
          tooltip: '字号',
          selected: false,
          icon: const Icon(LucideIcons.aLargeSmall, size: 28),
          onPressed: _openFontSizes,
        ),
      if (config.allowsFormat('t:ls'))
        _PopupIconButton(
          key: const ValueKey('editor-inline-letter-spacing'),
          tooltip: '字间距',
          enabled: widget.editorState.editable,
          selected: false,
          icon: const Icon(LucideIcons.moveHorizontal, size: 28),
          onPressed: () => setState(() => _letterSpacingOpen = true),
        ),
      for (final style in _styles.skip(5))
        if (config.allowsFormat(style.key)) _compactStyle(selection, style),
    ];
    return ListView.separated(
      key: const ValueKey('editor-inline-style-menu'),
      scrollDirection: Axis.horizontal,
      scrollCacheExtent: const ScrollCacheExtent.pixels(1000),
      itemCount: buttons.length,
      separatorBuilder: (_, _) => const SizedBox(width: 6),
      itemBuilder: (_, index) => buttons[index],
    );
  }

  /// 对[selection]构建[style]的原格式按钮；是否显示由实例配置预先筛选。
  Widget _compactStyle(Selection selection, _InlineStyleAction style) => _PopupIconButton(
    key: ValueKey(switch (style.key) {
      csesSuperscriptAttribute => 'editor-inline-superscript',
      csesSubscriptAttribute => 'editor-inline-subscript',
      _ => 'editor-inline-${style.key}',
    }),
    tooltip: style.label,
    selected: _isSelected(selection, style.key),
    icon: Icon(style.icon, size: 28),
    onPressed: () => unawaited(_toggleStyle(style.key)),
  );

  /// 用借用的 [selection] 构建设计稿中的文字样式与圆形色板，所有写入复用既有命令。
  /// 字符格式和颜色入口按实例配置筛选；字号与字间距切换同一横向子菜单，不叠加弹窗。
  Widget _buildExpanded(Selection selection) {
    final c = CollabModalColors.of(context);
    const icons = [
      LucideIcons.bold,
      LucideIcons.italic,
      LucideIcons.underline,
      LucideIcons.strikethrough,
      LucideIcons.codeXml,
      LucideIcons.superscript,
      LucideIcons.subscript,
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('文字样式', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
        const SizedBox(height: 12),
        Row(
          children: [
            for (var i = 0; i < 5; i++)
              if (EditorCommandContext.of(widget.editorState).configuration.allowsFormat(_styles[i].key)) ...[
                if (i > 0) const SizedBox(width: 6),
                Expanded(child: _expandedStyle(selection, _styles[i], icons[i])),
              ],
          ],
        ),
        if (EditorCommandContext.of(widget.editorState).configuration.allowsFormat('t:px'))
          TextButton.icon(
            key: const ValueKey('editor-inline-font-size'),
            onPressed: _openFontSizes,
            icon: const Icon(LucideIcons.aLargeSmall),
            label: const Text('字号'),
          ),
        if (EditorCommandContext.of(widget.editorState).configuration.allowsFormat('t:ls'))
          TextButton.icon(
            key: const ValueKey('editor-inline-letter-spacing'),
            onPressed: () => setState(() => _letterSpacingOpen = true),
            icon: const Icon(LucideIcons.moveHorizontal),
            label: const Text('字间距'),
          ),
        const SizedBox(height: 8),
        if (_styles
            .skip(5)
            .any((style) => EditorCommandContext.of(widget.editorState).configuration.allowsFormat(style.key)))
          Row(
            children: [
              for (var i = 5; i < _styles.length; i++)
                if (EditorCommandContext.of(widget.editorState).configuration.allowsFormat(_styles[i].key)) ...[
                  if (i > 5) const SizedBox(width: 6),
                  Expanded(child: _expandedStyle(selection, _styles[i], icons[i])),
                ],
            ],
          ),
        for (final (attribute, label, prefix, target) in [
          (AppFlowyRichTextKeys.textColor, '文字颜色', 'editor-text-color', 'text'),
          (AppFlowyRichTextKeys.backgroundColor, '文字背景颜色', 'editor-background-color', 'background'),
        ])
          if (EditorCommandContext.of(widget.editorState).configuration.allowsFormat(attribute)) ...[
            const SizedBox(height: 20),
            Row(
              key: ValueKey('editor-inline-$target-color'),
              children: [
                Expanded(
                  child: Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
                ),
                Icon(
                  LucideIcons.palette,
                  key: ValueKey('editor-inline-$target-color-icon'),
                  size: 16,
                  color: parseCollabBlockColor(_currentColor(selection, attribute).value) ?? c.muted,
                ),
              ],
            ),
            const SizedBox(height: 8),
            CollabColorPicker(
              onError: (error, stack) =>
                  _reportEditorError(widget.editorState, '颜色设置失败', error: error, stackTrace: stack),
              keyPrefix: prefix,
              circular: true,
              textColors: attribute == AppFlowyRichTextKeys.textColor,
              selection: _currentColor(selection, attribute),
              resetLabel: attribute == AppFlowyRichTextKeys.textColor ? '默认颜色' : '清除背景色',
              onSelected: (value) => _applyColor(attribute, collabColorToEditor(value)),
            ),
          ],
      ],
    );
  }

  /// 为借用 [selection] 展示 [style] 的选中状态，[icon] 为设计稿线性图标。
  /// 点击只切换当前有效范围，异常由既有完整格式操作边界处理。
  Widget _expandedStyle(Selection selection, _InlineStyleAction style, IconData icon) {
    final c = CollabModalColors.of(context);
    final selected = _isSelected(selection, style.key);
    final key = switch (style.key) {
      csesSuperscriptAttribute => 'editor-inline-superscript',
      csesSubscriptAttribute => 'editor-inline-subscript',
      _ => 'editor-inline-${style.key}',
    };
    return Semantics(
      selected: selected,
      button: true,
      child: Tooltip(
        message: style.label,
        child: InkWell(
          key: ValueKey(key),
          borderRadius: BorderRadius.circular(8),
          onTap: () => unawaited(_toggleStyle(style.key)),
          child: Container(
            height: 42,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: selected ? c.soft : c.field,
              border: Border.all(color: selected ? c.accent : c.line),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 19, color: selected ? c.accent : c.text),
          ),
        ),
      ),
    );
  }

  /// 进入行内字号菜单，借用当前命令上下文并重新开始权限有效期。
  void _openFontSizes() {
    if (!_ToolbarCommandScope.allows(context)) return;
    final state = widget.editorState;
    final owner = EditorCommandContext.of(state);
    if (state.isDisposed || !state.editable || !owner.configuration.allowsFormat('t:px')) return;
    if (CollabTextRange.capture(state, allowCollapsed: true) == null) return;
    setState(() {
      _fontSizesOpen = true;
      _fontSizeOwner = owner;
      _fontSizeRevoked = false;
    });
  }

  /// 返回原文字菜单，释放字号会话引用，不提交格式或关闭键盘。
  void _closeFontSizes() {
    if (_fontSizeSaving) return;
    setState(() {
      _fontSizesOpen = false;
      _fontSizeOwner = null;
      _fontSizeRevoked = false;
    });
  }

  /// 打开字号菜单后发生撤权就失效，快速重新授权不恢复旧菜单。
  void _onFontSizePermissionChanged() {
    if (_fontSizesOpen && !widget.editorState.editable) {
      _fontSizeRevoked = true;
      if (mounted) setState(() {});
    }
  }

  /// 返回[selection]的共同字号及默认状态；混合字号不选中默认或数字预设。
  /// 旧CSS字号也视为显式覆盖；光标位置读取后续输入样式。
  ({num? value, bool isDefault}) _currentFontSize(Selection selection) {
    if (selection.isCollapsed) {
      final value = widget.inlineStyleController.value('t:px');
      final legacy = widget.inlineStyleController.value('s:fontSize');
      return (value: value is num ? value : null, isDefault: value == null && legacy == null);
    }
    Object? value;
    var found = false;
    var mixed = false;
    var inherited = true;
    for (final node in widget.editorState.getNodesInSelection(selection)) {
      final delta = node.delta;
      if (delta == null) continue;
      final start = node.path.equals(selection.start.path) ? selection.start.offset : 0;
      final end = node.path.equals(selection.end.path) ? selection.end.offset : delta.length;
      for (final operation in delta.slice(start, end)) {
        final next = operation.attributes?['t:px'];
        if (found && value != next) mixed = true;
        if (next != null || operation.attributes?['s:fontSize'] != null) inherited = false;
        value = next;
        found = true;
      }
    }
    return (value: !mixed && value is num ? value : null, isDefault: found && inherited);
  }

  /// 从[selection]构建固定返回/默认项与横向数字区，选择后保留菜单与编辑焦点。
  Widget _buildFontSizePicker(Selection selection) {
    final state = widget.editorState;
    final owner = EditorCommandContext.of(state);
    final enabled = !_fontSizeRevoked && !_fontSizeSaving && state.editable && identical(owner, _fontSizeOwner);
    final selected = _currentFontSize(selection.normalized);
    return Row(
      children: [
        IconButton(
          key: const ValueKey('editor-font-size-back'),
          tooltip: '返回',
          onPressed: _fontSizeSaving ? null : _closeFontSizes,
          icon: const Icon(LucideIcons.arrowLeft),
        ),
        _fontSizeOption(null, selected: selected.isDefault, enabled: enabled),
        Expanded(
          child: SingleChildScrollView(
            key: const ValueKey('editor-font-size-menu'),
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final size in owner.configuration.fontSizes)
                  _fontSizeOption(size, selected: selected.value == size, enabled: enabled),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 构建[size]字号项，null显示恢复默认；[selected]回显当前格式，[enabled]控制可操作性。
  /// 只借用菜单状态，点击后由所属编辑器提交一个完整格式事务。
  Widget _fontSizeOption(int? size, {required bool selected, required bool enabled}) {
    final colors = CollabModalColors.of(context);
    return Semantics(
      key: ValueKey(size == null ? 'editor-font-size-default' : 'editor-font-size-$size'),
      button: true,
      selected: selected,
      enabled: enabled,
      label: size == null ? '默认字号' : '字号 $size',
      child: ExcludeSemantics(
        child: TextButton(
          style: TextButton.styleFrom(
            minimumSize: const Size(44, 44),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            foregroundColor: selected ? colors.accent : colors.text,
            backgroundColor: selected ? colors.soft : null,
            side: BorderSide(color: selected ? colors.accent : Colors.transparent),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
          onPressed: enabled ? () => unawaited(_applyFontSize(size)) : null,
          child: Text(size == null ? '默认' : '$size'),
        ),
      ),
    );
  }

  /// 在点击时应用[size]像素；null清除t:px及旧CSS字号，恢复段落或标题继承。
  /// 保留其他字符格式，等待完整格式事务后刷新默认或数字选中态。
  /// 拒绝失效会话、撤权及配置外值，连续选择各自封存历史；失败由公共边界提示。
  Future<void> _applyFontSize(int? size) async {
    if (!_ToolbarCommandScope.allows(context) || _fontSizeSaving || _fontSizeRevoked) return;
    final state = widget.editorState;
    final owner = _fontSizeOwner;
    setState(() => _fontSizeSaving = true);
    try {
      await _runFormatAction((current, selection) async {
        final context = EditorCommandContext.of(current);
        if (!identical(current, state) ||
            !identical(context, owner) ||
            _fontSizeRevoked ||
            !context.configuration.allowsFormat('t:px') ||
            (size != null && !context.configuration.fontSizes.contains(size))) {
          return;
        }
        final range = CollabTextRange.capture(current, allowCollapsed: true);
        final target = range?.resolve(current);
        if (target == null) return;
        if (current.undoManager.undoStack.isNonEmpty) current.undoManager.undoStack.last.seal();
        final attributes = <String, dynamic>{'t:px': size, if (size == null) 's:fontSize': null};
        if (target.isCollapsed) {
          await setCollabTypingAttributes(current, attributes);
        } else {
          widget.inlineStyleController.clearAll();
          await formatCollabParagraphSelection(current, target, attributes);
        }
      });
    } finally {
      if (mounted && identical(state, widget.editorState)) setState(() => _fontSizeSaving = false);
    }
  }

  /// 用 [selection] 回显颜色；[target] 决定字色或浅色，共用选择器保留自定义色。
  Widget _buildColorPicker(Selection selection, _InlineColorTarget target) {
    final isBackground = target == _InlineColorTarget.background;
    final attribute = isBackground ? AppFlowyRichTextKeys.backgroundColor : AppFlowyRichTextKeys.textColor;
    return CollabColorPicker(
      onError: (error, stack) => _reportEditorError(widget.editorState, '颜色设置失败', error: error, stackTrace: stack),
      keyPrefix: isBackground ? 'editor-background-color' : 'editor-text-color',
      horizontal: true,
      textColors: !isBackground,
      selection: _currentColor(selection, attribute),
      resetLabel: isBackground ? '清除背景色' : '默认颜色',
      onBack: () => setState(() => _colorPicker = null),
      onSelected: (value) => _applyColor(attribute, collabColorToEditor(value)),
    );
  }

  /// 汇总借用 [selection] 的 [attribute]；折叠位置读取后续输入格式。
  /// 比较等价CSS/ARGB颜色，混合选区不再与默认色混淆。
  CollabColorSelection _currentColor(Selection selection, String attribute) {
    if (selection.isCollapsed) {
      return CollabColorSelection(widget.inlineStyleController.value(attribute) as String?);
    }
    final nodes = widget.editorState.getNodesInSelection(selection);
    final values = <String?>[];
    for (final node in nodes) {
      final delta = node.delta;
      if (delta == null) continue;
      final start = node == nodes.first ? selection.startIndex : 0;
      final end = node == nodes.last ? selection.endIndex : delta.length;
      for (final operation in delta.slice(start, end)) {
        final value = operation.attributes?[attribute];
        values.add(value is String ? value : null);
      }
    }
    return CollabColorSelection.fromValues(values);
  }

  /// 设置 [attribute] 对应的字色或背景色；[color] 为既有调色板值，null 清除颜色。
  /// 点击时读取实时选区，折叠位置配置后续输入，范围选区复用现有格式事务；失败由共用边界报告。
  Future<void> _applyColor(String attribute, String? color) => _runFormatAction((state, selection) async {
    if (!EditorCommandContext.of(state).configuration.allowsFormat(attribute)) return;
    if (selection.isCollapsed) {
      await widget.inlineStyleController.setValue(attribute, color);
    } else {
      widget.inlineStyleController.clearAll();
      await formatCollabParagraphSelection(state, selection, {attribute: color});
    }
  });

  bool _isSelected(Selection selection, String attribute) {
    if (selection.isCollapsed) {
      return widget.inlineStyleController.value(attribute) == true;
    }
    final nodes = widget.editorState.getNodesInSelection(selection);
    return nodes.isNotEmpty &&
        nodes.allSatisfyInSelection(
          selection,
          (delta) => delta.everyAttributes((attributes) => attributes[attribute] == true),
        );
  }

  /// 切换实时选区的 [attribute] 格式；上下标互斥，空段落同时保存默认字符格式。
  /// 异步完成包含事务和面板回显，错误由共用边界报告，不缓存构建阶段选区。
  Future<void> _toggleStyle(String attribute) => _runFormatAction((state, selection) async {
    if (!EditorCommandContext.of(state).configuration.allowsFormat(attribute)) return;
    final isScript = attribute == csesSuperscriptAttribute || attribute == csesSubscriptAttribute;
    if (selection.isCollapsed) {
      final other = attribute == csesSuperscriptAttribute
          ? csesSubscriptAttribute
          : attribute == csesSubscriptAttribute
          ? csesSuperscriptAttribute
          : null;
      await widget.inlineStyleController.toggle(attribute, mutuallyExclusiveWith: other);
    } else {
      widget.inlineStyleController.clearAll();
      final other = attribute == csesSuperscriptAttribute ? csesSubscriptAttribute : csesSuperscriptAttribute;
      final next = !_isSelected(selection, attribute);
      if (!isScript) {
        await formatCollabParagraphSelection(state, selection, {attribute: next ? true : null});
      } else {
        await formatCollabParagraphSelection(state, selection, {other: null, attribute: next ? true : null});
      }
    }
  });

  /// 校验借用编辑器和实时选区后等待 [action]；允许界面显式不等待此完整错误处理边界。
  /// 当前只读/关闭/无选区或工具栏等待宿主动作时不执行；异常反馈，迟到结果不刷新新编辑器。
  Future<void> _runFormatAction(Future<void> Function(EditorState state, Selection selection) action) async {
    if (!_ToolbarCommandScope.allows(context)) return;
    final state = widget.editorState;
    final selection = state.selection;
    if (state.isDisposed || !state.editable || selection == null) return;
    try {
      await action(state, selection);
      if (mounted && identical(state, widget.editorState)) setState(() {});
    } catch (error, stack) {
      _reportEditorError(state, '文字格式修改失败', error: error, stackTrace: stack, tag: 'DocCollab');
      if (mounted && identical(state, widget.editorState)) {
        _showToolbarMessage(context, '格式修改失败，请重试');
      }
    }
  }
}

/// 编辑器专属行距/字距子菜单；只借用正文，权限变化使当前菜单永久失效直到重开。
class _EditorSpacingMenu extends StatefulWidget {
  /// [editorState]为借用正文，[lineHeight]为true操作段落倍率，false操作字符em字距。
  /// [canExecute]实时核对所属工具栏互斥，[onBack]返回原菜单，不关闭键盘。
  const _EditorSpacingMenu({
    required this.editorState,
    required this.lineHeight,
    required this.canExecute,
    required this.onBack,
  });

  /// 外部持有并释放的编辑器。
  final EditorState editorState;

  /// true选择段落行高倍率；false选择字间距em值。
  final bool lineHeight;

  /// 所属工具栏当前是否允许执行命令；不缓存其结果。
  final bool Function() canExecute;

  /// 未保存时返回上层菜单，不写入正文。
  final VoidCallback onBack;

  /// 创建管理菜单有效期和写入互斥的局部状态。
  @override
  State<_EditorSpacingMenu> createState() => _EditorSpacingMenuState();
}

/// 订阅权限与当前格式；选择实时目标，每次操作保存为独立历史记录。
class _EditorSpacingMenuState extends State<_EditorSpacingMenu> {
  /// 打开时借用的命令上下文，禁止会话切换后继续操作。
  late final EditorCommandContext _owner;

  /// 撤权或更换正文后保持失效，重新授权也不恢复旧回调。
  bool _revoked = false;

  /// 正在等待的格式事务；结束前拒绝连点和返回。
  bool _saving = false;

  /// 菜单测试身份前缀，与字体格式及段落布局入口分离。
  String get _prefix => widget.lineHeight ? 'editor-line-height' : 'editor-letter-spacing';

  /// 当前字段的可访问名称，不进入文档协议。
  String get _label => widget.lineHeight ? '行间距' : '字间距';

  /// 捕获菜单所属实例并监听撤权，不接管编辑器生命周期。
  @override
  void initState() {
    super.initState();
    _owner = EditorCommandContext.of(widget.editorState);
    _revoked = !widget.editorState.editable;
    widget.editorState.editableNotifier.addListener(_permissionChanged);
  }

  /// 更换[oldWidget]的正文时迁移监听并使旧菜单失效，不释放借用实例。
  @override
  void didUpdateWidget(covariant _EditorSpacingMenu oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.editorState, widget.editorState)) {
      oldWidget.editorState.editableNotifier.removeListener(_permissionChanged);
      widget.editorState.editableNotifier.addListener(_permissionChanged);
      _revoked = true;
    }
  }

  /// 注销自行创建的权限监听，外部继续拥有编辑器。
  @override
  void dispose() {
    widget.editorState.editableNotifier.removeListener(_permissionChanged);
    super.dispose();
  }

  /// 一旦失去权限便记录失效，快速恢复权限也必须重新进入菜单。
  void _permissionChanged() {
    if (!widget.editorState.editable) _revoked = true;
    if (mounted) setState(() {});
  }

  /// 实时核对实例、配置和选区；字距沿用同级正文与块锁限制。
  bool get _enabled {
    final state = widget.editorState;
    if (_revoked ||
        _saving ||
        state.isDisposed ||
        !state.editable ||
        !widget.canExecute() ||
        !identical(_owner, EditorCommandContext.of(state)) ||
        state.selection == null) {
      return false;
    }
    if (widget.lineHeight) {
      return _owner.configuration.lineHeight &&
          state.getNodesInSelection(state.selection!).any(supportsCollabParagraph);
    }
    return _owner.configuration.allowsFormat('t:ls') &&
        CollabTextRange.capture(state, allowCollapsed: true)?.resolve(state) != null;
  }

  /// 为[attributes]读取规范em字距；旧CSS em可回显，旧px保留自定义状态。
  ({num? value, bool isDefault}) _letterValue(Attributes attributes) {
    final compact = normalizeParagraphTextDefaults(attributes)['t:ls'];
    if (compact is num) return (value: compact == 0 ? null : compact, isDefault: compact == 0);
    final legacy = attributes['s:letterSpacing'];
    if (legacy == null) return (value: null, isDefault: true);
    final match = legacy is String
        ? RegExp(r'^([-+]?(?:\d+(?:\.\d+)?|\.\d+))em$', caseSensitive: false).firstMatch(legacy.trim())
        : null;
    final value = match == null ? null : double.tryParse(match[1]!);
    return (value: value == 0 ? null : value, isDefault: value == 0);
  }

  /// 汇总实时选区的共同值与默认状态；混合选区不虚构任何选中项。
  ({num? value, bool isDefault}) _current() {
    final state = widget.editorState;
    final selection = state.selection?.normalized;
    if (state.isDisposed || selection == null) return (value: null, isDefault: false);
    final values = <({num? value, bool isDefault})>[];
    if (!widget.lineHeight && selection.isCollapsed) {
      final node = state.getNodeAtPath(selection.start.path);
      if (node == null) return (value: null, isDefault: false);
      return _letterValue(collabParagraphTypingAttributes(node, selection.start.offset, pending: state.toggledStyle));
    }
    for (final node in state.getNodesInSelection(selection).where(supportsCollabParagraph)) {
      if (!selection.isCollapsed &&
          node.path.equals(selection.end.path) &&
          !node.path.equals(selection.start.path) &&
          selection.end.offset == 0) {
        continue;
      }
      if (widget.lineHeight) {
        final raw = readCollabParagraph(node).values['lh'];
        final value = raw is num ? raw : num.tryParse('$raw');
        values.add((value: value, isDefault: raw == null));
      } else {
        final delta = node.delta!;
        final start = node.path.equals(selection.start.path) ? selection.start.offset : 0;
        final end = node.path.equals(selection.end.path) ? selection.end.offset : delta.length;
        if (delta.isEmpty) {
          values.add(_letterValue(paragraphDefaultsToAttributes(readCollabParagraph(node).values['textDefaults'])));
        } else {
          for (final run in delta.slice(start.clamp(0, delta.length), end.clamp(0, delta.length))) {
            values.add(_letterValue(run.attributes ?? {}));
          }
        }
      }
    }
    if (values.isEmpty || values.any((value) => value != values.first)) return (value: null, isDefault: false);
    return values.first;
  }

  /// 在[context]中保持返回/默认固定，仅滚动预设值；大字按自然宽度排版。
  /// 随选区、输入格式与事务回显更新，订阅由Flutter构建组件自动释放。
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.editorState.selectionNotifier, widget.editorState.toggledStyleNotifier]),
    builder: (context, _) => StreamBuilder<EditorTransactionValue>(
      stream: widget.editorState.transactionStream,
      builder: (context, _) {
        final selected = _current();
        final enabled = _enabled;
        return Row(
          children: [
            IconButton(
              key: ValueKey('$_prefix-back'),
              tooltip: '返回',
              onPressed: _saving ? null : widget.onBack,
              icon: const Icon(LucideIcons.arrowLeft),
            ),
            _option(null, selected.isDefault, enabled),
            Expanded(
              child: SingleChildScrollView(
                key: ValueKey('$_prefix-menu'),
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final value
                        in widget.lineHeight
                            ? const [1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]
                            : const [-.1, -.075, -.05, -.025, .025, .05, .075, .1, .15, .2, .3, .4, .5])
                      _option(value, selected.value == value && !selected.isDefault, enabled),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    ),
  );

  /// 展示[value]预设，null为默认；[selected]回显共同值，[enabled]控制操作和语义。
  Widget _option(double? value, bool selected, bool enabled) {
    final colors = CollabModalColors.of(context);
    final text = value == null
        ? '默认'
        : '${value.toString().replaceFirst(RegExp(r'\.0$'), '')}${widget.lineHeight ? '倍' : 'em'}';
    return Semantics(
      key: ValueKey('$_prefix-${value ?? 'default'}'),
      button: true,
      selected: selected,
      enabled: enabled,
      label: '$_label $text',
      child: ExcludeSemantics(
        child: TextButton(
          style: TextButton.styleFrom(
            minimumSize: const Size(44, 44),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            foregroundColor: selected ? colors.accent : colors.text,
            backgroundColor: selected ? colors.soft : null,
            side: BorderSide(color: selected ? colors.accent : Colors.transparent),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
          onPressed: enabled ? () => unawaited(_apply(value)) : null,
          child: Text(text),
        ),
      ),
    );
  }

  /// 将[value]应用到点击时的实时目标；null恢复默认并清除旧CSS字距。
  /// 原生暂缓期间不提交；等待事务再刷新，捕获失败并报告所属编辑器，迟到结果不访问已卸载组件。
  Future<void> _apply(double? value) async {
    if (!_enabled || widget.editorState.localTransactionsPaused) return;
    final state = widget.editorState;
    setState(() => _saving = true);
    try {
      if (widget.lineHeight) {
        await setCollabParagraphLineHeight(state, value);
      } else {
        final target = CollabTextRange.capture(state, allowCollapsed: true)?.resolve(state);
        if (target == null) return;
        if (state.undoManager.undoStack.isNonEmpty) state.undoManager.undoStack.last.seal();
        final attributes = <String, dynamic>{'t:ls': value, 's:letterSpacing': null};
        if (target.isCollapsed) {
          await setCollabTypingAttributes(state, attributes);
        } else {
          await formatCollabParagraphSelection(state, target, attributes);
        }
      }
    } catch (error, stackTrace) {
      _reportEditorError(state, '$_label设置失败', error: error, stackTrace: stackTrace);
      if (mounted && identical(state, widget.editorState)) _showToolbarMessage(context, '设置失败，请重试');
    } finally {
      if (mounted && identical(state, widget.editorState)) setState(() => _saving = false);
    }
  }
}

/// 行内颜色入口，二者共用色板组件但写入各自的字符属性。
enum _InlineColorTarget {
  /// 字符前景色。
  text,

  /// 字符背景色。
  background,
}

/// 工具栏与格式面板的局部操作按钮；面板内使用统一边框和选中背景。
class _PopupIconButton extends StatelessWidget {
  /// [key] 控制身份；[tooltip] 为名称；[selected] 控制选中态；[icon] 是借用图标。
  /// [onPressed] 由业务处理完整异步边界；[enabled] 默认true，false禁用点击。
  const _PopupIconButton({
    super.key,
    required this.tooltip,
    required this.selected,
    required this.icon,
    required this.onPressed,
    this.enabled = true,
  });

  /// 必需的操作名称，同时用于触摸提示。
  final String tooltip;

  /// 由业务持有的选中状态，控制背景和边线。
  final bool selected;

  /// 借用的图标或文本，不接管其资源。
  final Widget icon;

  /// 业务操作回调，调用方负责异步错误边界。
  final VoidCallback onPressed;

  /// 是否允许点击，默认true，禁用时保留占位和说明。
  final bool enabled;

  /// 根据借用 [context] 选择外观；执行点击前复核所属工具栏的同步互斥，不修改业务状态。
  @override
  Widget build(BuildContext context) {
    final inModal = context.findAncestorWidgetOfExactType<CollabBottomSheet>() != null;
    final colors = CollabModalColors.of(context);
    return Tooltip(
      message: tooltip,
      child: Opacity(
        opacity: enabled ? 1 : 0.35,
        child: Material(
          color: inModal
              ? (selected ? colors.soft : colors.field)
              : selected
              ? const Color(0xFFE6EEFF)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: enabled
                ? () {
                    if (_ToolbarCommandScope.allows(context)) onPressed();
                  }
                : null,
            child: Container(
              width: 48,
              height: inModal ? 44 : 48,
              alignment: Alignment.center,
              decoration: inModal
                  ? BoxDecoration(
                      border: Border.all(color: selected ? colors.accent : colors.line),
                      borderRadius: BorderRadius.circular(8),
                    )
                  : null,
              child: IconTheme(
                data: IconThemeData(size: 19, color: selected ? colors.accent : colors.text),
                child: icon,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _InlineStyleAction {
  const _InlineStyleAction({required this.key, required this.label, required this.icon});

  final String key;
  final String label;
  final IconData icon;
}

/// 在[context]内提示[label]仍为占位功能，不写入正文或历史。
void _showUnsupportedMessage(BuildContext context, String label) {
  _showToolbarMessage(context, '$label 暂未支持');
}

void _showToolbarMessage(BuildContext context, String message) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  messenger
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message), duration: const Duration(seconds: 2)));
}

/// The saved selection is independent of focus and survives block reordering.
/// Both endpoints are retained so cancellation also restores expanded ranges.
class _EditorSelectionBookmark {
  /// 捕获借用[state]中[selection]两端的稳定身份、偏移及权限代次。
  _EditorSelectionBookmark(EditorState state, Selection selection)
    : startEpoch = CollabBlockLocks.of(state)?.epoch(_idAt(state, selection.start) ?? '') ?? 0,
      endEpoch = CollabBlockLocks.of(state)?.epoch(_idAt(state, selection.end) ?? '') ?? 0,
      startId = _idAt(state, selection.start),
      endId = _idAt(state, selection.end),
      startOffset = selection.start.offset,
      endOffset = selection.end.offset;

  /// 捕获时两端权限代次，锁定后重新解锁不复用旧书签。
  final int startEpoch;
  final int endEpoch;

  final String? startId;
  final String? endId;
  final int startOffset;
  final int endOffset;

  static String? _idAt(EditorState state, Position point) {
    final node = state.getNodeAtPath(point.path);
    return node == null ? null : _mediaTargetId(node);
  }

  Position? _resolvePoint(EditorState state, String? id, int offset) {
    final node = id == null ? null : _findMediaTarget(state, id);
    if (node == null) return null;
    return Position(path: node.path, offset: offset.clamp(0, node.delta?.length ?? 0));
  }

  /// 在借用[state]中重定位；锁定或权限代次变化后不恢复旧书签。
  Selection? resolve(EditorState state) {
    if (state.isDisposed ||
        !state.editable ||
        (CollabBlockLocks.of(state)?.epoch(startId ?? '') ?? 0) != startEpoch ||
        (CollabBlockLocks.of(state)?.epoch(endId ?? '') ?? 0) != endEpoch) {
      return null;
    }
    final start = _resolvePoint(state, startId, startOffset);
    final end = _resolvePoint(state, endId, endOffset);
    if (start == null || end == null) return null;
    return Selection(start: start, end: end);
  }
}

/// Owns one entire modal flow, including a nested source/file chooser.
/// Never use the live editor selection as the modal's insertion bookmark.
class _EditorModalSession {
  /// 隔离借用 [state] 的正文输入和两类工具栏，保存稳定选区及原有输入样式供退场恢复。
  _EditorModalSession(this.state)
    : bookmark = state.selection == null ? null : _EditorSelectionBookmark(state, state.selection!),
      previousExtraInfo = state.selectionExtraInfo == null
          ? null
          : Map<Object?, Object?>.from(state.selectionExtraInfo!),
      previousStyle = Map<String, dynamic>.from(state.toggledStyle) {
    state.selectionExtraInfo = {
      ...?previousExtraInfo,
      selectionExtraInfoDisableMobileToolbarKey: true,
      selectionExtraInfoDisableFloatingToolbar: true,
      selectionExtraInfoDoNotAttachTextService: true,
    };
    state.selection = null;
    state.service.keyboardService
      ?..closeKeyboard()
      ..disableShortcuts()
      ..disable(disposition: UnfocusDisposition.scope);
    FocusManager.instance.primaryFocus?.unfocus();
  }

  final EditorState state;
  final _EditorSelectionBookmark? bookmark;
  final Map<Object?, Object?>? previousExtraInfo;
  final Map<String, dynamic> previousStyle;

  /// 在借用 [context] 仍允许恢复焦点时恢复 [appliedSelection] 或原稳定选区。
  /// null [context] 仅结束隔离；null [appliedSelection] 使用原选区与输入样式。
  /// 恢复事件暂时抑制划词浮栏，结束后仅归还本会话仍持有的附加选区信息。
  Future<void> finish(BuildContext? context, Selection? appliedSelection) async {
    if (state.isDisposed) return;
    state.selectionExtraInfo = previousExtraInfo;
    state.service.keyboardService?.enableShortcuts();
    if (context == null || !_canRestoreEditorFocus(context, state)) return;
    final selection = appliedSelection ?? bookmark?.resolve(state);
    // A deleted anchor must not silently resolve to a different block.
    if (selection == null || !state.canInputAt(selection)) return;
    final restorationInfo = <Object?, Object?>{...?previousExtraInfo, selectionExtraInfoDisableFloatingToolbar: true};
    await _restoreEditorCaretAndKeyboard(context, state, selection, extraInfo: restorationInfo);
    if (!state.isDisposed && identical(state.selectionExtraInfo, restorationInfo)) {
      state.selectionExtraInfo = previousExtraInfo;
    }
    if (!state.isDisposed && appliedSelection == null && state.selection == selection) {
      for (final entry in previousStyle.entries) {
        state.updateToggledStyle(entry.key, entry.value);
      }
    }
  }
}

/// 在借用 [context]/[editorState] 上展示添加入口并保存稳定书签。
/// 嵌套宿主选择器退场后才恢复正文；取消不写入，权限或会话失效不恢复旧光标。
/// 分页符提交与恢复输入均拒绝面板打开期间撤销过的权限；临时监听随会话移除。
Future<void> showEditorAddBlockSheet(BuildContext context, EditorState editorState) async {
  if (editorState.isDisposed || !editorState.editable) return;
  if (editorState.selection == null) {
    _showToolbarMessage(context, '请先把光标放入正文');
    return;
  }
  final services = EditorCommandContext.of(editorState).services;
  final session = _EditorModalSession(editorState);
  Selection? appliedSelection;
  var permissionRevoked = false;

  /// 撤权后即使恢复授权，旧面板也不能向原书签写入。
  void trackPermission() {
    if (!editorState.editable) permissionRevoked = true;
  }

  editorState.editableNotifier.addListener(trackPermission);

  try {
    appliedSelection = await showCollabBottomSheet<Selection>(
      context: context,
      requestFocus: true,
      builder: (context) {
        return _AddBlockSheet(
          editorState: editorState,
          bookmark: session.bookmark!,
          canUseHost: () => !permissionRevoked && identical(EditorCommandContext.of(editorState).services, services),
        );
      },
    );
  } finally {
    editorState.editableNotifier.removeListener(trackPermission);
    await session.finish(
      context.mounted && !permissionRevoked && identical(EditorCommandContext.of(editorState).services, services)
          ? context
          : null,
      appliedSelection,
    );
  }
}

/// Opens the mobile source sheet with a separate insertion bookmark.
Future<void> showEditorUrlBlockDialog(
  BuildContext context,
  EditorState editorState,
  String blockType, {
  EditorMediaUploadService? service,
}) async {
  if (editorState.isDisposed || !editorState.editable) return;
  if (editorState.selection == null) {
    _showToolbarMessage(context, '请先把光标放入正文');
    return;
  }
  final session = _EditorModalSession(editorState);
  Selection? nextSelection;
  try {
    final source = await showEditorMediaSourceSheet(
      context,
      blockType: blockType,
      editorState: editorState,
      service: service,
      canEdit: () => !editorState.isDisposed && editorState.editable,
    );
    if (source == null || !context.mounted) return;
    final current = session.bookmark?.resolve(editorState);
    nextSelection = current == null
        ? null
        : await applyUrlBlockShortcut(editorState, current, blockType, source.url, mediaSource: source);
    if (context.mounted && nextSelection == null) {
      _showToolbarMessage(context, '插入位置已变化，请重新选择正文位置');
    }
  } finally {
    await session.finish(context.mounted ? context : null, nextSelection);
  }
}

String _mediaTargetId(Node node) =>
    node.attributes[AppFlowyBlockEditorAdapter.collabBlockIdAttribute] as String? ?? node.id;

Node? _findMediaTarget(EditorState state, String id) {
  if (state.isDisposed) return null;
  Node? visit(Node node) {
    if (_mediaTargetId(node) == id) return node;
    for (final child in node.children) {
      final found = visit(child);
      if (found != null) return found;
    }
    return null;
  }

  return visit(state.document.root);
}

/// 在 [action] 的完整头部操作期间隔离正文输入，结束后恢复原稳定块选区。
/// [context] 与 [editorState] 均为借用对象；弹窗必须等待退场动画后完成。
/// [action] 的结果在正文选区恢复后返回，取消为null；异常仍恢复焦点后透传，销毁的编辑器不执行action。
/// [canRestore] 可在异步结束时拒绝恢复已失效会话的焦点；null沿用页面与编辑器存活检查。
/// [selectionAfterAction] 在操作完成后解析目标选区，供新插入正文恢复光标与键盘；
/// 未提供或返回null时恢复原稳定选区，回调不得修改编辑器。
/// [protectBlockLocks] 默认true，自动持有不可续期的块锁租约；false仅供自行跟踪
/// 权限代次并明确处理面板内加锁/解锁的业务会话使用，不绕过事务守卫。
Future<T?> runEditorHeaderAction<T>(
  BuildContext context,
  EditorState editorState,
  Future<T?> Function() action, {
  bool Function()? canRestore,
  Selection? Function()? selectionAfterAction,
  bool protectBlockLocks = true,
}) async {
  if (editorState.isDisposed) return null;
  final locks = CollabBlockLocks.of(editorState);
  final lease = protectBlockLocks ? locks?.beginLease() : null;
  final session = _EditorModalSession(editorState);
  try {
    return await action();
  } finally {
    try {
      await session.finish(
        context.mounted && (canRestore?.call() ?? true) ? context : null,
        editorState.isDisposed ? null : selectionAfterAction?.call(),
      );
    } finally {
      if (lease != null) locks?.endLease(lease);
    }
  }
}

bool _canRestoreEditorFocus(BuildContext context, EditorState state) =>
    context.mounted && !state.isDisposed && state.editable && ModalRoute.of(context)?.isCurrent != false;

/// Restores an AppFlowy text-input client after a dialog or bottom sheet.
///
/// URL-backed insertion deliberately leaves the transaction selection null so
/// no editor input client opens underneath a still-visible modal. Once this
/// method runs, the modal route is gone; it waits for the new paragraph widget
/// to register, then emits one UI selection that both attaches AppFlowy's text
/// input service and requests focus.
Future<void> _restoreEditorCaretAndKeyboard(
  BuildContext context,
  EditorState editorState,
  Selection selection, {
  Map<Object?, Object?>? extraInfo,
}) async {
  // The document mutation and modal dismissal can finish in the same frame.
  // Waiting for the target node's widget registration prevents the input
  // service from attaching before the paragraph has a render/selectable state.
  await _waitForEditableSelectionTarget(editorState, selection);
  if (!context.mounted || !_canRestoreEditorFocus(context, editorState)) return;

  // Re-emitting a UI selection is sufficient: KeyboardService's selection
  // listener attaches the text input service and requests editor focus. Do not
  // call `enable` and `enableKeyBoard` as well, because that produces multiple
  // simultaneous Android `showSoftInput` requests.
  await editorState.updateSelectionWithReason(selection, reason: SelectionUpdateReason.uiEvent, extraInfo: extraInfo);
  if (!context.mounted) {
    return;
  }

  if (defaultTargetPlatform != TargetPlatform.android) {
    return;
  }

  // Keep one guarded recovery for device keyboards that ignore the first show
  // request. Closing the AppFlowy connection resets its cached editing value;
  // re-emitting the same selection then performs a clean attach instead of
  // stacking another show request on an existing connection.
  await Future<void>.delayed(const Duration(milliseconds: 360));
  if (!context.mounted ||
      !_canRestoreEditorFocus(context, editorState) ||
      _editorKeyboardIsVisible(context) ||
      editorState.selection != selection) {
    return;
  }

  final keyboardService = editorState.service.keyboardService;
  keyboardService?.closeKeyboard();
  await WidgetsBinding.instance.endOfFrame;
  if (!context.mounted || !_canRestoreEditorFocus(context, editorState) || editorState.selection != selection) {
    return;
  }
  await editorState.updateSelectionWithReason(selection, reason: SelectionUpdateReason.uiEvent, extraInfo: extraInfo);
}

Future<void> _waitForEditableSelectionTarget(EditorState editorState, Selection selection) async {
  // Three frames cover document notification, AppFlowy block construction and
  // final layout without creating an unbounded wait if the editor route has
  // already been removed. The caller separately checks BuildContext liveness.
  for (var attempt = 0; attempt < 3; attempt += 1) {
    if (editorState.isDisposed || !editorState.editable) return;
    final node = editorState.getNodeAtPath(selection.start.path);
    if (node?.delta != null && node?.context != null) {
      return;
    }
    await WidgetsBinding.instance.endOfFrame;
  }
}

bool _editorKeyboardIsVisible(BuildContext context) {
  final mediaQueryInset = MediaQuery.maybeOf(context)?.viewInsets.bottom ?? 0;
  final view = View.of(context);
  final physicalInset = view.viewInsets.bottom / view.devicePixelRatio;
  return mediaQueryInset > 0 || physicalInset > 0;
}

/// 完整块选择面板，借用编辑器和打开面板时捕获的稳定选区。
/// 支持的操作复用现有块命令；成功后返回目标选区，由外层在退场后恢复正文输入。
class _AddBlockSheet extends StatelessWidget {
  /// [editorState] 为借用编辑器，[bookmark] 是原始稳定位置，
  /// [canUseHost] 检查打开面板时的宿主会话是否仍有效，不持有业务资源。
  const _AddBlockSheet({required this.editorState, required this.bookmark, required this.canUseHost});

  /// 借用的正文状态，面板不释放。
  final EditorState editorState;

  /// 打开时保存的稳定选区，随远端重排解析。
  final _EditorSelectionBookmark bookmark;

  /// 原宿主会话有效性检查，失效面板不得调用新宿主选人。
  final bool Function() canUseHost;

  /// 使用借用的 [context] 构建块入口；代码块与标题、列表复用同一插入及关闭流程。
  /// 返回面板Widget，不持有或释放编辑器；本地块按实例配置选择，文档沿用既有入口。
  /// 在借用 [context] 中渲染可用块入口；插入按保存的稳定选区定位并等待事务完成。
  /// 在借用[context]中构建块/行内入口；用户选择调用宿主选择器并复用稳定插入位置。
  /// 标题显示“添加”及内容块图标，高亮/分页/代码绘图与各自卡片及菜单使用相同语义图标。
  /// 行内公式入口使用Ω图标，与独立公式块的Σ图标区分。
  /// 表格直接创建2×2网格；绘图先收集源码草稿再创建容器和子块；分页符仅插入根级光标位置。
  /// 标题入口按实例启用集合与H1～H6取交集；插入前重查书签，权限/文档失效时不插入。
  @override
  Widget build(BuildContext context) {
    final config = EditorCommandContext.of(editorState).configuration;
    final headingLevels = config.allowsBlock(HeadingBlockKeys.type, level: config.headingLevels.firstOrNull)
        ? _menuHeadingLevels(config)
        : const <int>[];
    return CollabBottomSheet(
      key: const ValueKey('editor-add-block-sheet'),
      title: const Text('添加'),
      subtitle: '在当前光标位置插入',
      icon: LucideIcons.blocks,
      expand: true,
      closeKey: const ValueKey('editor-add-block-close'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionTitle('基础'),
          const SizedBox(height: 14),
          SizedBox(
            height: 78,
            child: ListView.separated(
              key: const ValueKey('editor-add-heading-list'),
              scrollDirection: Axis.horizontal,
              scrollCacheExtent: const ScrollCacheExtent.pixels(1000),
              itemCount: headingLevels.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final level = headingLevels[index];
                return SizedBox(
                  width: 52,
                  child: _HeadingShortcutTile(
                    level: level,
                    onTap: () => _applyAndClose(context, _BlockShortcut.heading(level)),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 18),
          LayoutBuilder(
            builder: (context, constraints) {
              final crossAxisCount = MediaQuery.textScalerOf(context).scale(14) > 22 ? 2 : 3;
              return GridView.count(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                crossAxisCount: crossAxisCount,
                mainAxisSpacing: 12,
                crossAxisSpacing: 10,
                childAspectRatio: 1.18,
                children: [
                  if (!EditorCommandContext.of(editorState).configuration.hasComplexBlocks)
                    for (final block in EditorCommandContext.of(editorState).configuration.blocks)
                      if (block.type != ParagraphBlockKeys.type && block.type != HeadingBlockKeys.type)
                        _ActionShortcutTile(
                          key: ValueKey(
                            'editor-shortcut-${switch (block.type) {
                              BulletedListBlockKeys.type => 'bulleted-list',
                              NumberedListBlockKeys.type => 'numbered-list',
                              TodoListBlockKeys.type => 'todo-list',
                              _ => 'quote',
                            }}',
                          ),
                          icon: switch (block.type) {
                            BulletedListBlockKeys.type => LucideIcons.list,
                            NumberedListBlockKeys.type => LucideIcons.listOrdered,
                            TodoListBlockKeys.type => LucideIcons.squareCheck,
                            _ => LucideIcons.quote,
                          },
                          label: switch (block.type) {
                            BulletedListBlockKeys.type => '无序列表',
                            NumberedListBlockKeys.type => '有序列表',
                            TodoListBlockKeys.type => '待办列表',
                            _ => '引用',
                          },
                          onTap: () => _applyAndClose(context, _BlockShortcut(block.type)),
                        ),
                  if (EditorCommandContext.of(editorState).configuration.hasComplexBlocks) ...[
                    if (EditorCommandContext.of(editorState).configuration.allowsBlock(NumberedListBlockKeys.type))
                      _ActionShortcutTile(
                        key: const ValueKey('editor-shortcut-numbered-list'),
                        icon: LucideIcons.listOrdered,
                        label: '有序列表',
                        onTap: () => _applyAndClose(context, const _BlockShortcut(NumberedListBlockKeys.type)),
                      ),
                    if (EditorCommandContext.of(editorState).configuration.allowsBlock(BulletedListBlockKeys.type))
                      _ActionShortcutTile(
                        key: const ValueKey('editor-shortcut-bulleted-list'),
                        icon: LucideIcons.list,
                        label: '无序列表',
                        onTap: () => _applyAndClose(context, const _BlockShortcut(BulletedListBlockKeys.type)),
                      ),
                    if (EditorCommandContext.of(editorState).configuration.allowsBlock(TodoListBlockKeys.type))
                      _ActionShortcutTile(
                        key: const ValueKey('editor-shortcut-todo-list'),
                        icon: LucideIcons.squareCheck,
                        label: '待办列表',
                        onTap: () => _applyAndClose(context, const _BlockShortcut(TodoListBlockKeys.type)),
                      ),
                    if (EditorCommandContext.of(editorState).configuration.allowsBlock(csesCodeBlockType))
                      _ActionShortcutTile(
                        key: const ValueKey('editor-shortcut-code-block'),
                        icon: LucideIcons.code,
                        label: '代码块',
                        onTap: () => _applyAndClose(context, const _BlockShortcut(csesCodeBlockType)),
                      ),
                    if (EditorCommandContext.of(editorState).configuration.allowsBlock(QuoteBlockKeys.type))
                      _ActionShortcutTile(
                        key: const ValueKey('editor-shortcut-quote'),
                        icon: LucideIcons.quote,
                        label: '引用',
                        onTap: () => _applyAndClose(context, const _BlockShortcut(QuoteBlockKeys.type)),
                      ),
                  ],
                ],
              );
            },
          ),
          if (EditorCommandContext.of(editorState).configuration.hasComplexBlocks) ...[
            const SizedBox(height: 24),
            const _SectionTitle('常用'),
            const SizedBox(height: 14),
            LayoutBuilder(
              builder: (context, constraints) {
                final crossAxisCount = MediaQuery.textScalerOf(context).scale(14) > 22 ? 2 : 3;
                return GridView.count(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  crossAxisCount: crossAxisCount,
                  mainAxisSpacing: 14,
                  crossAxisSpacing: 10,
                  childAspectRatio: 1.18,
                  children: [
                    for (final action in _commonInsertions)
                      if (_commonInsertionAllowed(EditorCommandContext.of(editorState).configuration, action))
                        _ActionShortcutTile(
                          key: ValueKey(action.key),
                          icon: action.icon,
                          label: action.label,
                          onTap: () => _performCommonAndClose(context, action),
                        ),
                  ],
                );
              },
            ),
          ],
        ],
      ),
    );
  }

  /// 在[context]所属更多面板中执行[action]，成功后关闭父面板并返回落点。
  /// 子面板取消、会话失效或操作失败时保留父面板，焦点由外层会话恢复。
  Future<void> _performCommonAndClose(BuildContext context, _CommonInsertionAction action) async {
    final landing = await _performCommonInsertion(context, editorState, bookmark, canUseHost, action);
    if (context.mounted && landing != null) Navigator.pop<Selection>(context, landing);
  }

  /// 按稳定块标记解析插入位置，将 [shortcut] 应用于借用的编辑器。
  /// [context] 属于当前面板；位置失效时提示且保持面板，成功后关闭并返回目标选区。
  /// Future 在块事务和关闭请求完成后结束，退场与焦点恢复由外层负责；事务异常透传。
  Future<void> _applyAndClose(BuildContext context, _BlockShortcut shortcut) async {
    final capturedSelection = bookmark.resolve(editorState);
    if (capturedSelection == null) {
      _showToolbarMessage(context, '插入位置已变化，请重新选择正文位置');
      return;
    }
    final applied = await applyBlockShortcut(
      editorState,
      capturedSelection,
      shortcut.blockType,
      headingLevel: shortcut.headingLevel,
    );
    if (context.mounted && applied) {
      // A non-empty source block inserts a new node and the transaction moves
      // selection to it. Converting an empty block can retain the captured
      // caret instead, so use that as a defensive fallback. Returning the
      // selection distinguishes a successful choice from manual cancellation.
      Navigator.pop<Selection>(context, editorState.selection ?? capturedSelection);
    }
  }
}

class _BlockShortcut {
  const _BlockShortcut(this.blockType) : headingLevel = null;

  const _BlockShortcut.heading(int level) : blockType = HeadingBlockKeys.type, headingLevel = level;

  final String blockType;
  final int? headingLevel;
}

/// Inserts a URL-backed block and returns the editable caret after it.
///
/// Link, image and video components are non-text blocks, so they cannot host
/// the IME caret themselves. A trailing empty paragraph is always retained or
/// created and selected. This is what makes choosing a block from “更多” return
/// immediately to editing with the keyboard open.
/// [editorState]是借用正文，[selection]为插入位置，[blockType]为资源类型，[url]为完整地址。
/// [mediaSource]可补充宿主读取的资源信息；null仅使用url。制图模式返回null。
Future<Selection?> applyUrlBlockShortcut(
  EditorState editorState,
  Selection selection,
  String blockType,
  String url, {
  EditorMediaSource? mediaSource,
}) async {
  if (!EditorCommandContext.of(editorState).configuration.allowsBlock(blockType)) return null;
  if (editorState.isDisposed ||
      !editorState.editable ||
      selection.start.path.isEmpty ||
      !_isUrlBackedBlockType(blockType) ||
      !_isSupportedBlockUrl(url) ||
      (isCollabResourceType(blockType) && !isCollabResourceUrl(blockType, url))) {
    return null;
  }
  final targetPath = selection.start.path;
  final targetNode = editorState.getNodeAtPath(targetPath);
  if (targetNode == null) {
    return null;
  }

  final mediaNode = _urlBackedNode(blockType, url.trim(), mediaSource: mediaSource);
  // This is a new resource, including when replacing an empty paragraph.
  // Without an explicit identity the adapter's positional fallback treats it
  // as a conversion of that paragraph; Rust then skips initial resource props.
  mediaNode.updateAttributes({AppFlowyBlockEditorAdapter.collabBlockIdAttribute: mediaNode.id});
  final sourceIsEmpty = targetNode.delta?.toPlainText().isEmpty == true;
  final insertPath = sourceIsEmpty ? targetPath : targetPath.next;
  final paragraphPath = insertPath.next;
  final paragraphNode = _emptyNode(ParagraphBlockKeys.type, null);
  final nextSelection = Selection.single(path: paragraphPath, startOffset: 0);

  final transaction = editorState.transaction;
  transaction.insertNodes(insertPath, [mediaNode, paragraphNode], deepCopy: false);
  if (sourceIsEmpty) {
    // Replace an unused text node instead of leaving a blank heading/list
    // around the media. The following paragraph becomes the sole editable
    // landing position and starts with the normal paragraph block type.
    // Insert before delete follows AppFlowy's own `formatNode` transaction
    // ordering. Its operation transformer can then identify and remove the
    // original node without shifting the newly inserted resource behind it.
    transaction.deleteNode(targetNode);
  }
  // Do not assign `transaction.afterSelection` here. This function is called
  // while a URL dialog and, in the “更多” flow, a bottom sheet still own focus.
  // Leaving it null closes the old editor input connection; the outer route
  // restores [nextSelection] only after every modal has been dismissed.
  await editorState.apply(transaction);
  return nextSelection;
}

/// Creates a detached resource node for validated [blockType] and HTTP(S) [url].
/// Optional borrowed [mediaSource] contributes uploaded file metadata; null means
/// a link-only source. Link cards use default full width and natural height, with
/// no saved host-name title masking fetched metadata. Returns a node without
/// inserting it or performing network requests; the caller owns insertion.
Node _urlBackedNode(String blockType, String url, {EditorMediaSource? mediaSource}) {
  if (blockType == ImageBlockKeys.type) {
    return Node(
      type: ImageBlockKeys.type,
      attributes: {ImageBlockKeys.url: url, ImageBlockKeys.align: 'center', csesBlockIndentAttribute: 0},
    );
  }
  return Node(
    type: blockType,
    attributes: {
      if (isCollabResourceType(blockType))
        ...CollabResource.fromValues({
          if (blockType == 'attachment')
            'name': mediaSource?.file?.name ?? Uri.parse(url).pathSegments.lastOrNull ?? '附件',
          if (blockType == 'audio') 'sourceType': mediaSource?.file == null ? 'link' : 'local',
          if (mediaSource?.file != null && {'audio', 'attachment'}.contains(blockType)) ...{
            'name': mediaSource!.file!.name,
            'size': mediaSource.file!.size,
            if (blockType == 'attachment') 'type': mediaSource.file!.mimeType,
          },
          if ({'embed', 'figma-embed', 'juejin-embed'}.contains(blockType)) ...{'wr': 100},
        }).nodeAttributes,
      csesEmbedUrlAttribute: url,
      blockComponentAlign: 'left',
      csesBlockIndentAttribute: 0,
    },
  );
}

bool _isUrlBackedBlockType(String blockType) =>
    isCollabResourceType(blockType) ||
    blockType == ImageBlockKeys.type ||
    blockType == csesLinkBlockType ||
    blockType == csesVideoBlockType;

bool _isSupportedBlockUrl(String value) {
  final uri = Uri.tryParse(value.trim());
  return uri != null && (uri.scheme == 'http' || uri.scheme == 'https') && uri.host.isNotEmpty;
}

/// 在借用[editorState]的稳定[selection]处转换空块，或在非空正文后插入[blockType]。
/// [headingLevel]只用于标题，null按一级；超出所属能力、只读或失效目标返回false。
/// 成功写入可撤销事务并返回true；异常交由所属操作边界处理。
Future<bool> applyBlockShortcut(
  EditorState editorState,
  Selection selection,
  String blockType, {
  int? headingLevel,
}) async {
  final capabilities = EditorCommandContext.of(editorState).configuration;
  if (!capabilities.allowsBlock(blockType, level: headingLevel)) return false;
  if (editorState.isDisposed || !editorState.editable || selection.start.path.isEmpty) {
    return false;
  }
  final targetPath = selection.start.path;
  final node = editorState.getNodeAtPath(targetPath);
  if (node == null || node.delta == null) {
    return false;
  }

  final text = node.delta?.toPlainText() ?? '';
  if (text.isEmpty) {
    final nodeSelection = Selection.single(path: targetPath, startOffset: 0);
    await editorState.formatNode(
      nodeSelection,
      (node) => _convertedNode(
        node,
        blockType,
        headingLevel,
        preservedAttributes: capabilities.blockConversionPreservedAttributes,
      ),
    );
    return true;
  }

  final insertPath = targetPath.next;
  final transaction = editorState.transaction
    ..insertNode(insertPath, _emptyNode(blockType, headingLevel), deepCopy: false)
    ..afterSelection = Selection.single(path: insertPath, startOffset: 0);
  await editorState.apply(transaction);
  return true;
}

/// 将借用 [node] 转为 [blockType]，[headingLevel] 仅标题使用，null 按一级，数值限制为1～6。
/// 保留正文及段落默认格式/下一段设置；代码使用独立输入规则，不继承段落字段。
/// [preservedAttributes]指定额外保留的宿主属性键；目标内置属性优先，块背景默认保留。
/// 已转换桌面节点的身份、独立props/meta及扩展字段随替换延续；显式正文转换解除特殊文本角色。
/// 返回新节点，身份由适配器类型转换链处理，不创建资源。
Node _convertedNode(Node node, String blockType, int? headingLevel, {Set<String> preservedAttributes = const {}}) {
  final collabBlockId = node.attributes['cses_collab_block_id'];
  final alignment = node.attributes[blockComponentAlign] as String? ?? 'left';
  final keepsIndent =
      blockType == BulletedListBlockKeys.type ||
      blockType == NumberedListBlockKeys.type ||
      blockType == TodoListBlockKeys.type;
  final attributes = <String, Object>{
    ...preservedEditorBlockAttributes(node, preservedAttributes: preservedAttributes),
    if (blockType != 'code') ...{
      for (final key in collabParagraphKeys)
        if (key != 'heading' && node.attributes[paragraphPropertyAttribute(key)] is String)
          paragraphPropertyAttribute(key): node.attributes[paragraphPropertyAttribute(key)] as String,
      paragraphPropertyAttribute('heading'): blockType == HeadingBlockKeys.type
          ? '{"value":${(headingLevel ?? 1).clamp(1, 6)}}'
          : '{"value":null}',
    },
    blockComponentDelta: (node.delta ?? Delta()).toJson(),
    blockComponentAlign: alignment,
    csesBlockIndentAttribute: keepsIndent
        ? (node.attributes[csesBlockIndentAttribute] as int? ?? 0).clamp(0, 6)
        : 0,
    if (blockType == HeadingBlockKeys.type)
      HeadingBlockKeys.level: (headingLevel ?? 1).clamp(1, 6),
    if (blockType == TodoListBlockKeys.type) TodoListBlockKeys.checked: false,
    if (blockType == 'code') blockComponentBackgroundColor: '0xfff3f4f6',
  };
  if (collabBlockId != null) {
    attributes['cses_collab_block_id'] = collabBlockId;
  }
  if (blockType == ParagraphBlockKeys.type &&
      const {'caption', 'shape-text', 'word-art'}.contains(attributes['bc.flavour'])) {
    attributes['bc.flavour'] = 'paragraph';
  }
  return Node(type: blockType, attributes: attributes);
}

/// 创建[blockType]的空编辑节点；[headingLevel]仅标题使用，null为一级，级别限制1～6。
/// 返回的节点由调用方持有，尚未写入编辑树或原生文档。
Node _emptyNode(String blockType, int? headingLevel) {
  return Node(
    type: blockType,
    attributes: {
      blockComponentDelta: Delta().toJson(),
      blockComponentAlign: 'left',
      csesBlockIndentAttribute: 0,
      if (blockType == HeadingBlockKeys.type)
        HeadingBlockKeys.level: (headingLevel ?? 1).clamp(1, 6),
      if (blockType == TodoListBlockKeys.type) TodoListBlockKeys.checked: false,
      if (blockType == 'code') blockComponentBackgroundColor: '0xfff3f4f6',
    },
  );
}

/// 添加面板的12像素分组标题，不持有状态。
class _SectionTitle extends StatelessWidget {
  /// [label] 为分组名称。
  const _SectionTitle(this.label);

  /// 必需的分组名称。
  final String label;

  /// 在借用 [context] 中展示统一分组文字。
  @override
  Widget build(BuildContext context) => Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500));
}

/// 使用与T菜单一致的Lucide图标展示H1～H6入口，保留下方标题说明。
class _HeadingShortcutTile extends StatelessWidget {
  /// [level] 为1～6标题等级；[onTap] 由业务持有并执行插入。
  const _HeadingShortcutTile({required this.level, required this.onTap});

  /// 必需的标题菜单等级，调用方提供1～6。
  final int level;

  /// 必需的借用插入回调，本组件不持有编辑器。
  final VoidCallback onTap;

  /// 根据 [context] 构建带稳定身份的标题入口；图标复用T菜单映射，点击不接管业务资源。
  @override
  Widget build(BuildContext context) {
    final c = CollabModalColors.of(context);
    return InkWell(
      key: ValueKey('editor-shortcut-heading-$level'),
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: c.field,
          border: Border.all(color: c.line),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_headingMenuIcons[level - 1], size: 27, color: c.accent),
            const SizedBox(height: 5),
            Text('标题 $level', style: const TextStyle(fontSize: 11)),
          ],
        ),
      ),
    );
  }
}

/// 添加面板的统一内容入口，未知能力仍提示尚不支持。
class _ActionShortcutTile extends StatelessWidget {
  /// [key] 控制身份；[icon]/[label] 为图标及名称；[onTap] 为 null 时提示尚不支持。
  const _ActionShortcutTile({super.key, required this.icon, required this.label, this.onTap});

  /// 必需的内容图标，按统一紫色主题展示。
  final IconData icon;

  /// 必需的内容名称，窄屏允许两行。
  final String label;

  /// 可选操作回调，null时显示尚未支持提示。
  final VoidCallback? onTap;

  /// 在 [context] 中以整块浅灰背景、紫色图标和12像素标签展示入口。
  @override
  Widget build(BuildContext context) {
    final c = CollabModalColors.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap ?? () => _showUnsupportedMessage(context, label),
      child: Container(
        decoration: BoxDecoration(
          color: c.field,
          border: Border.all(color: c.line),
          borderRadius: BorderRadius.circular(12),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: onTap != null ? c.accent : c.muted, size: 24),
            const SizedBox(height: 8),
            Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, height: 1.3, color: onTap != null ? c.text : c.muted),
            ),
          ],
        ),
      ),
    );
  }
}

/// 向[editor]所属端口报告[message]、[error]与[stackTrace]，可选[tag]标识操作来源。
void _reportEditorError(
  EditorState editor,
  String message, {
  required Object error,
  required StackTrace stackTrace,
  String? tag,
}) {
  if (editor.isDisposed) return;
  EditorCommandContext.of(editor).services.report(message, error, stackTrace, tag);
}
