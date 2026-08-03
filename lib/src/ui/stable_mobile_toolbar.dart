import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:flutter/material.dart';

/// A layout-based mobile toolbar that keeps the software keyboard visible.
///
/// AppFlowy's built-in V2 toolbar replaces the keyboard with the H/Aa menu.
/// The product interaction used here instead displays a compact secondary bar
/// immediately above the keyboard toolbar without touching the IME.
class StableMobileToolbar extends StatefulWidget {
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
  });

  final EditorState editorState;
  final List<MobileToolbarItem> toolbarItems;
  final Widget child;
  final double toolbarHeight;
  final double buttonHeight;
  final double buttonSpacing;
  final Color itemOutlineColor;
  final Color primaryColor;

  @override
  createState() => _StableMobileToolbarState();
}

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

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Selection?>(
      valueListenable: widget.editorState.selectionNotifier,
      builder: (context, selection, _) {
        final toolbarDisabled =
            widget
                .editorState
                .selectionExtraInfo?[selectionExtraInfoDisableMobileToolbarKey] ==
            true;
        final showToolbar =
            selection != null && !toolbarDisabled && _keyboardVisible;

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

  Widget _buildToolbarAndMenu(BuildContext context) {
    final selectedIndex = _selectedMenuIndex;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (selectedIndex != null) _buildSelectedMenu(context, selectedIndex),
        _buildToolbarRow(context),
      ],
    );
  }

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
                  onPressed: () => _handleToolbarItem(index, item),
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
            icon: Icon(Icons.keyboard_hide, color: style.iconColor),
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

  void _handleToolbarItem(int index, MobileToolbarItem item) {
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
