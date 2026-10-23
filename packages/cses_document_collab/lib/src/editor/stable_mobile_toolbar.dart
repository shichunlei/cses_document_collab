import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// A layout-based mobile toolbar that keeps the software keyboard visible.
///
/// AppFlowy's built-in V2 toolbar replaces the keyboard with the H/Aa menu.
/// The product interaction used here instead displays a compact secondary bar
/// immediately above the keyboard toolbar without touching the IME.
///
/// ```dart
/// import 'package:appflowy_editor/appflowy_editor.dart';
/// import 'package:cses_document_collab/src/editor/stable_mobile_toolbar.dart';
/// final state = EditorState.blank();
/// final toolbar = StableMobileToolbar(
///   editorState: state,
///   toolbarItems: const [],
///   child: AppFlowyEditor(editorState: state),
/// );
/// // 从树中移除toolbar后由创建方state.dispose()。
/// ```
class StableMobileToolbar extends StatefulWidget {
  /// [key]控制身份与状态复用，[editorState]为借用的正文状态，[child]为必填正文。
  /// [toolbarItems]是按展示顺序提供的入口，本组件不拥有其业务资源。
  /// [toolbarHeight]为主工具栏逻辑像素高度，默认52；[buttonHeight]为按钮高度，默认42。
  /// [buttonSpacing]为主题按钮间距，默认6逻辑像素；[itemOutlineColor]为边线颜色。
  /// [primaryColor]为工具栏主题主色；没有入口时仅展示正文，存在入口时自动附加右侧收起按钮。
  /// [disabledItemIndices]为禁用入口的零基下标，默认空；不禁用固定的收起键盘按钮。
  /// [canExecuteItem]可提供实时执行校验，按零基下标查询；null只检查现有禁用集合和正文权限。
  const StableMobileToolbar({
    super.key,
    required this.editorState,
    required this.toolbarItems,
    required this.child,
    this.toolbarHeight = 52,
    this.buttonHeight = 42,
    this.buttonSpacing = 6,
    this.itemOutlineColor = const Color(0xFFE5E7EB),
    this.primaryColor = const Color(0xFF2563EB),
    this.disabledItemIndices = const {},
    this.canExecuteItem,
  });

  /// 借用的编辑器，本组件不释放它。
  final EditorState editorState;

  /// 调用方提供的菜单入口，空列表不产生菜单按钮。
  final List<MobileToolbarItem> toolbarItems;

  /// 必填正文，不受菜单展示配置影响。
  final Widget child;

  /// 主工具栏逻辑像素高度，默认52。
  final double toolbarHeight;

  /// 主题按钮逻辑像素高度，默认42。
  final double buttonHeight;

  /// 主题按钮间距，单位逻辑像素，默认6。
  final double buttonSpacing;

  /// 工具栏边线的主题颜色。
  final Color itemOutlineColor;

  /// 工具栏的主题主色。
  final Color primaryColor;

  /// 禁用点击的入口零基下标，默认空；调用方负责与[toolbarItems]保持一致。
  final Set<int> disabledItemIndices;

  /// 可选的同步权限查询，执行点击时再次调用；回调和状态由调用方持有，不得在查询中修改正文。
  final bool Function(int index)? canExecuteItem;

  @override
  createState() => _StableMobileToolbarState();
}

/// 持有当前子菜单与键盘可见状态，注册并在销毁时解除窗口指标观察。
/// 正文和入口回调均由外部拥有；点击时同步复核权限，禁用或移除入口时清理选中菜单。
class _StableMobileToolbarState extends State<StableMobileToolbar>
    with WidgetsBindingObserver
    implements MobileToolbarWidgetService {
  int? _selectedMenuIndex;
  bool _keyboardVisible = false;

  double _keyboardHeight(BuildContext context) {
    final mediaQueryHeight = MediaQuery.viewInsetsOf(context).bottom;
    final view = View.of(context);
    final viewHeight = view.viewInsets.bottom / view.devicePixelRatio;
    return mediaQueryHeight > viewHeight ? mediaQueryHeight : viewHeight;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  /// 在[oldWidget]更新后清理已禁用或移除的子菜单，避免等待中的操作仍保留可交互面板。
  @override
  void didUpdateWidget(covariant StableMobileToolbar oldWidget) {
    super.didUpdateWidget(oldWidget);
    final selected = _selectedMenuIndex;
    if (selected != null && !_canExecuteItem(selected)) {
      _selectedMenuIndex = null;
    }
  }

  /// 同步校验[index]对应的入口；旧回调在重建前也必须遵守实时权限和编辑器生命周期。
  bool _canExecuteItem(int index) =>
      mounted &&
      !widget.editorState.isDisposed &&
      widget.editorState.editable &&
      index >= 0 &&
      index < widget.toolbarItems.length &&
      !widget.disabledItemIndices.contains(index) &&
      (widget.canExecuteItem?.call(index) ?? true);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _keyboardVisible = _keyboardHeight(context) > 0;
    if (!_keyboardVisible) {
      _selectedMenuIndex = null;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    if (!mounted) {
      return;
    }
    final view = View.of(context);
    final keyboardVisible = view.viewInsets.bottom > 0;
    if (keyboardVisible == _keyboardVisible &&
        (keyboardVisible || _selectedMenuIndex == null)) {
      return;
    }
    setState(() {
      _keyboardVisible = keyboardVisible;
      if (!keyboardVisible) {
        _selectedMenuIndex = null;
      }
    });
  }

  /// 使用[context]构建正文；允许编辑、有可用入口且键盘可见时才占用工具栏高度。
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        widget.editorState.selectionNotifier,
        widget.editorState.editableNotifier,
      ]),
      builder: (context, _) {
        final selection = widget.editorState.selection;
        final toolbarDisabled =
            widget
                .editorState
                .selectionExtraInfo?[selectionExtraInfoDisableMobileToolbarKey] ==
            true;
        final showToolbar =
            selection != null &&
            widget.editorState.editable &&
            !toolbarDisabled &&
            _keyboardVisible &&
            widget.toolbarItems.isNotEmpty;

        return Column(
          children: [
            Expanded(child: widget.child),
            if (showToolbar)
              MobileToolbarTheme(
                toolbarHeight: widget.toolbarHeight,
                buttonHeight: widget.buttonHeight,
                buttonSpacing: widget.buttonSpacing,
                itemOutlineColor: widget.itemOutlineColor,
                primaryColor: widget.primaryColor,
                child: Builder(
                  builder: (toolbarContext) =>
                      _buildToolbarAndMenu(toolbarContext),
                ),
              ),
          ],
        );
      },
    );
  }

  /// 在借用[context]中展示仍获准执行的子菜单和固定工具栏；失效菜单不再保留可点击区域。
  Widget _buildToolbarAndMenu(BuildContext context) {
    final selectedIndex = _selectedMenuIndex;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (selectedIndex != null && _canExecuteItem(selectedIndex))
          _buildSelectedMenu(context, selectedIndex),
        _buildToolbarRow(context),
      ],
    );
  }

  /// 在借用 [context] 中构建非空菜单行及选中背景，收起键盘始终固定在滚动入口右侧。
  Widget _buildToolbarRow(BuildContext context) {
    final style = MobileToolbarTheme.of(context);
    return Container(
      key: const ValueKey('editor-mobile-toolbar'),
      height: style.toolbarHeight,
      decoration: BoxDecoration(
        color: style.backgroundColor,
        border: Border(
          top: BorderSide(color: style.itemOutlineColor),
          bottom: BorderSide(color: style.itemOutlineColor),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: widget.toolbarItems.length,
              itemBuilder: (context, index) {
                final item = widget.toolbarItems[index];
                final icon = item.itemIconBuilder?.call(
                  context,
                  widget.editorState,
                  this,
                );
                if (icon == null) {
                  return const SizedBox.shrink();
                }
                return IconButton(
                  style: IconButton.styleFrom(
                    backgroundColor: _selectedMenuIndex == index
                        ? const Color(0xFFF1F3F5)
                        : Colors.transparent,
                  ),
                  icon: icon,
                  onPressed: _canExecuteItem(index)
                      ? () => _handleToolbarItem(index, item)
                      : null,
                );
              },
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: VerticalDivider(width: 1),
          ),
          IconButton(
            key: const ValueKey('editor-toolbar-close-keyboard-or-menu'),
            padding: EdgeInsets.zero,
            tooltip: '收起键盘',
            onPressed: _dismissKeyboard,
            icon: Icon(LucideIcons.keyboardOff, color: style.iconColor),
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }

  Widget _buildSelectedMenu(BuildContext context, int selectedIndex) {
    final menuBuilder = widget.toolbarItems[selectedIndex].itemMenuBuilder;
    return Container(
      key: const ValueKey('editor-toolbar-popup'),
      height: 64,
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: MobileToolbarTheme.of(context).backgroundColor,
        border: Border.all(color: const Color(0xFFE5E7EB)),
        borderRadius: BorderRadius.circular(14),
        boxShadow: const [
          BoxShadow(
            color: Color(0x22000000),
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child:
          menuBuilder?.call(context, widget.editorState, this) ??
          const SizedBox.shrink(),
    );
  }

  /// 执行[index]的[item]前同步复核权限，拒绝同帧连点或异步等待后的旧入口回调。
  void _handleToolbarItem(int index, MobileToolbarItem item) {
    if (!_canExecuteItem(index)) return;
    if (item.hasMenu) {
      if (_selectedMenuIndex == index) {
        closeItemMenu();
      } else {
        setState(() => _selectedMenuIndex = index);
      }
      return;
    }

    if (_selectedMenuIndex != null) {
      closeItemMenu();
    }
    item.actionHandler?.call(context, widget.editorState);
  }

  @override
  void closeItemMenu() {
    if (_selectedMenuIndex != null) {
      setState(() => _selectedMenuIndex = null);
    }
  }

  void _dismissKeyboard() {
    _selectedMenuIndex = null;
    widget.editorState.service.keyboardService?.closeKeyboard();
    widget.editorState.selection = null;
  }
}
