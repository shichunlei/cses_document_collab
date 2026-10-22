import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:appflowy_editor/src/editor/editor_component/service/ime/delta_input_on_floating_cursor_update.dart';
import 'package:appflowy_editor/src/editor/util/platform_extension.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'ime/delta_input_impl.dart';

// handle software keyboard and hardware keyboard
class KeyboardServiceWidget extends StatefulWidget {
  const KeyboardServiceWidget({
    super.key,
    this.commandShortcutEvents = const [],
    this.characterShortcutEvents = const [],
    this.focusNode,
    this.contentInsertionConfiguration,
    required this.child,
  });

  final ContentInsertionConfiguration? contentInsertionConfiguration;
  final FocusNode? focusNode;
  final List<CommandShortcutEvent> commandShortcutEvents;
  final List<CharacterShortcutEvent> characterShortcutEvents;
  final Widget child;

  @override
  State<KeyboardServiceWidget> createState() => KeyboardServiceWidgetState();
}

@visibleForTesting
class KeyboardServiceWidgetState extends State<KeyboardServiceWidget>
    implements AppFlowyKeyboardService {
  late final SelectionGestureInterceptor interceptor;
  late final EditorState editorState;

  /// Input service created here and closed on disposal; callers only borrow it.
  late final TextInputService textInputService;
  late final FocusNode focusNode;

  final List<AppFlowyKeyboardServiceInterceptor> interceptors = [];

  // previous selection
  Selection? previousSelection;

  // use for IME only
  bool enableIMEShortcuts = true;

  // use for hardware keyboard only
  bool enableKeyboardShortcuts = true;

  @override
  void initState() {
    super.initState();

    editorState = Provider.of<EditorState>(context, listen: false);
    editorState.selectionNotifier.addListener(_onSelectionChanged);

    interceptor = SelectionGestureInterceptor(
      key: 'keyboard',
      canTap: (details) {
        enableIMEShortcuts = true;
        focusNode.requestFocus();
        textInputService.close();
        return true;
      },
    );
    editorState.service.selectionService.registerGestureInterceptor(
      interceptor,
    );

    textInputService = buildTextInputService();

    focusNode = widget.focusNode ?? FocusNode(debugLabel: 'keyboard service');
    focusNode.addListener(_onFocusChanged);

    keepEditorFocusNotifier.addListener(_onKeepEditorFocusChanged);
  }

  /// Unregister selection/focus callbacks and close this widget's owned input
  /// service, invalidating queued IME work before releasing its focus node.
  @override
  void dispose() {
    editorState.selectionNotifier.removeListener(_onSelectionChanged);
    editorState.service.selectionService.unregisterGestureInterceptor(
      'keyboard',
    );
    focusNode.removeListener(_onFocusChanged);
    keepEditorFocusNotifier.removeListener(_onKeepEditorFocusChanged);
    textInputService.close();
    if (widget.focusNode == null) {
      focusNode.dispose();
    }
    super.dispose();
  }

  @override
  void disable({
    bool showCursor = false,
    UnfocusDisposition disposition = UnfocusDisposition.previouslyFocusedChild,
  }) {
    focusNode.unfocus(disposition: disposition);
  }

  @override
  void enable() {
    focusNode.requestFocus();
  }

  @override
  void enableShortcuts() {
    enableKeyboardShortcuts = true;
  }

  @override
  void disableShortcuts() {
    enableKeyboardShortcuts = false;
  }

  // Used in mobile only
  @override
  void closeKeyboard() {
    textInputService.close();
  }

  // Used in mobile only
  @override
  void enableKeyBoard(Selection selection) {
    _attachTextInputService(selection);
  }

  @override
  Widget build(BuildContext context) {
    Widget child = widget.child;
    // if there is no command shortcut event, we don't need to handle hardware keyboard.
    // like in read-only mode.
    if (widget.commandShortcutEvents.isNotEmpty) {
      // the Focus widget is used to handle hardware keyboard.
      child = Focus(
        focusNode: focusNode,
        onKeyEvent: _onKeyEvent,
        child: child,
      );
    }

    // ignore the default behavior of the space key on web
    if (kIsWeb) {
      child = Shortcuts(
        shortcuts: {
          LogicalKeySet(LogicalKeyboardKey.space):
              const DoNothingAndStopPropagationIntent(),
        },
        child: child,
      );
    }

    return child;
  }

  @override
  void registerInterceptor(AppFlowyKeyboardServiceInterceptor interceptor) {
    interceptors.add(interceptor);
  }

  @override
  void unregisterInterceptor(AppFlowyKeyboardServiceInterceptor interceptor) {
    interceptors.remove(interceptor);
  }

  /// handle hardware keyboard
  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (!enableKeyboardShortcuts) {
      return KeyEventResult.ignored;
    }

    if ((event is! KeyDownEvent && event is! KeyRepeatEvent) ||
        !enableIMEShortcuts) {
      if (textInputService.composingTextRange != TextRange.empty) {
        return KeyEventResult.skipRemainingHandlers;
      }
      return KeyEventResult.ignored;
    }

    for (final shortcutEvent in widget.commandShortcutEvents) {
      // check if the shortcut event can respond to the raw key event
      if (shortcutEvent.canRespondToRawKeyEvent(event)) {
        final result = shortcutEvent.handler(editorState);
        if (result == KeyEventResult.handled) {
          AppFlowyEditorLog.keyboard.debug(
            'keyboard service - handled by command shortcut event: $shortcutEvent',
          );
          return KeyEventResult.handled;
        } else if (result == KeyEventResult.skipRemainingHandlers) {
          AppFlowyEditorLog.keyboard.debug(
            'keyboard service - skip by command shortcut event: $shortcutEvent',
          );
          return KeyEventResult.skipRemainingHandlers;
        }
        continue;
      }
    }

    return KeyEventResult.ignored;
  }

  /// Synchronize selection and input, preserving copy-only selections on
  /// protected blocks. A paused projection may refresh an active connection,
  /// but must retain a keyboard the user or platform has already closed.
  void _onSelectionChanged() {
    final doNotAttach = editorState
        .selectionExtraInfo?[selectionExtraInfoDoNotAttachTextService];
    if (doNotAttach == true) {
      return;
    }

    // attach the delta text input service if needed
    final selection = editorState.selection;

    enableIMEShortcuts = true;

    if (selection == null || !editorState.canInputAt(selection)) {
      textInputService.close();
    } else if (!editorState.localTransactionsPaused ||
        textInputService.attached) {
      // For the deletion, we should attach the text input service immediately.
      _attachTextInputService(selection);
      _updateCaretPosition(selection);

      if (editorState.selectionUpdateReason == SelectionUpdateReason.uiEvent) {
        focusNode.requestFocus();
        AppFlowyEditorLog.editor.debug('keyboard service - request focus');
      } else {
        AppFlowyEditorLog.editor.debug(
          'keyboard service - selection changed: $selection',
        );
      }
    }

    previousSelection = selection;
  }

  /// Attach input for borrowed [selection] only while its block-level policy allows it.
  /// Selection remains available for copy when the host denies text input.
  void _attachTextInputService(Selection selection) {
    if (!editorState.canInputAt(selection)) {
      textInputService.close();
      return;
    }
    final textEditingValue = _getCurrentTextEditingValue(selection);
    AppFlowyEditorLog.editor.debug(
      'keyboard service - attach text input service: $textEditingValue',
    );
    if (textEditingValue != null) {
      textInputService.attach(
        textEditingValue,
        TextInputConfiguration(
          viewId: View.of(context).viewId,
          enableDeltaModel: false,
          inputType: TextInputType.multiline,
          textCapitalization: TextCapitalization.sentences,
          inputAction: TextInputAction.newline,
          keyboardAppearance: Theme.of(context).brightness,
          allowedMimeTypes:
              widget.contentInsertionConfiguration?.allowedMimeTypes ?? [],
        ),
      );
      // disable shortcuts when the IME active
      enableIMEShortcuts = textEditingValue.composing == TextRange.empty;
    } else {
      enableIMEShortcuts = true;
    }
  }

  // This function is used to get the current text editing value of the editor
  // based on the given selection.
  TextEditingValue? _getCurrentTextEditingValue(Selection selection) {
    // Get all the editable nodes in the selection.
    final editableNodes = editorState
        .getNodesInSelection(selection)
        .where((element) => element.delta != null);

    // if the selection is inline and the selection is updated by ui event,
    // we should clear the composing range on Android.
    final shouldClearComposingRange =
        editorState.selectionType == SelectionType.inline &&
        editorState.selectionUpdateReason == SelectionUpdateReason.uiEvent;

    if (PlatformExtension.isAndroid && shouldClearComposingRange) {
      textInputService.clearComposingTextRange();
    }

    // Get the composing text range.
    final composingTextRange =
        textInputService.composingTextRange ?? TextRange.empty;
    if (editableNodes.isNotEmpty) {
      // Get the text by concatenating all the editable nodes in the selection.
      var text = editableNodes.fold<String>(
        '',
        (sum, editableNode) => '$sum${editableNode.delta!.toPlainText()}\n',
      );

      // Remove the last '\n'.
      text = text.substring(0, text.length - 1);

      return TextEditingValue(
        text: text,
        selection: TextSelection(
          baseOffset: selection.startIndex,
          extentOffset: selection.endIndex,
        ),
        composing: composingTextRange,
      );
    }
    return null;
  }

  void _onFocusChanged() {
    AppFlowyEditorLog.editor.debug(
      'keyboard service - focus changed: ${focusNode.hasFocus}}',
    );

    /// On web, we don't need to close the keyboard when the focus is lost.
    if (kIsWeb) {
      return;
    }

    // clear the selection when the focus is lost.
    if (!focusNode.hasFocus) {
      if (keepEditorFocusNotifier.shouldKeepFocus) {
        return;
      }

      final children =
          WidgetsBinding.instance.focusManager.primaryFocus?.children;
      if (children != null && !children.contains(focusNode)) {
        editorState.selection = null;
      }
      textInputService.close();
    }
  }

  void _onKeepEditorFocusChanged() {
    AppFlowyEditorLog.editor.debug(
      'keyboard service - on keep editor focus changed: ${keepEditorFocusNotifier.value}}',
    );

    if (!keepEditorFocusNotifier.shouldKeepFocus) {
      focusNode.requestFocus();
    }
  }

  // only verify on macOS.
  void _updateCaretPosition(Selection? selection) {
    if (selection == null || !selection.isCollapsed) {
      return;
    }
    final node = editorState.getNodeAtPath(selection.start.path);
    if (node == null) {
      return;
    }
    final renderBox = node.renderBox;
    final selectable = node.selectable;
    if (renderBox != null && selectable != null) {
      final size = renderBox.size;
      final transform = renderBox.getTransformTo(null);
      final rect = selectable.getCursorRectInPosition(
        selection.end,
        shiftWithBaseOffset: true,
      );
      if (rect != null) {
        textInputService.updateCaretPosition(size, transform, rect);
      }
    }
  }

  /// Whether input captured in [epoch] and [connectionEpoch] still belongs to
  /// the current permission/projection phase and platform input session.
  /// Pausing never detaches the input service itself.
  bool _canProcessInput(int epoch, int connectionEpoch) =>
      mounted &&
      editorState.canAcceptLocalTransactions &&
      editorState.localTransactionEpoch == epoch &&
      _inputConnectionEpoch == connectionEpoch &&
      editorState.canInputAt(editorState.selection);

  /// Session identity from the non-delta service created by this widget.
  int get _inputConnectionEpoch =>
      (textInputService as NonDeltaTextInputService).connectionEpoch;

  /// Refresh rejected input from the current tree, retaining the connection
  /// only if [connectionEpoch] still owns it. An old callback must not refresh
  /// a replacement connection opened while its interceptor was awaiting.
  bool _rejectInput(int connectionEpoch) {
    final selection = editorState.selection;
    if (mounted &&
        !editorState.isDisposed &&
        textInputService.attached &&
        _inputConnectionEpoch == connectionEpoch &&
        editorState.canInputAt(selection)) {
      textInputService.clearComposingTextRange();
      _attachTextInputService(selection!);
    }
    return false;
  }

  /// Build this widget's input service. Each callback rejects stale asynchronous
  /// interceptor results without closing the existing platform connection.
  NonDeltaTextInputService buildTextInputService() {
    return NonDeltaTextInputService(
      onInsert: (insertion) async {
        final epoch = editorState.localTransactionEpoch;
        final connectionEpoch = _inputConnectionEpoch;
        if (!_canProcessInput(epoch, connectionEpoch)) {
          return _rejectInput(connectionEpoch);
        }
        for (final interceptor in interceptors) {
          final result = await interceptor.interceptInsert(
            insertion,
            editorState,
            widget.characterShortcutEvents,
          );
          if (!_canProcessInput(epoch, connectionEpoch)) {
            return _rejectInput(connectionEpoch);
          }
          if (result) {
            AppFlowyEditorLog.input.info(
              'keyboard service onInsert - intercepted by interceptor: $interceptor',
            );
            return false;
          }
        }

        await onInsert(
          insertion,
          editorState,
          widget.characterShortcutEvents,
          isInputCurrent: () => _canProcessInput(epoch, connectionEpoch),
        );
        return _canProcessInput(epoch, connectionEpoch) ||
            _rejectInput(connectionEpoch);
      },
      onDelete: (deletion) async {
        final epoch = editorState.localTransactionEpoch;
        final connectionEpoch = _inputConnectionEpoch;
        if (!_canProcessInput(epoch, connectionEpoch)) {
          return _rejectInput(connectionEpoch);
        }
        for (final interceptor in interceptors) {
          final result = await interceptor.interceptDelete(
            deletion,
            editorState,
          );
          if (!_canProcessInput(epoch, connectionEpoch)) {
            return _rejectInput(connectionEpoch);
          }
          if (result) {
            AppFlowyEditorLog.input.info(
              'keyboard service onDelete - intercepted by interceptor: $interceptor',
            );
            return false;
          }
        }

        await onDelete(deletion, editorState);
        return _canProcessInput(epoch, connectionEpoch) ||
            _rejectInput(connectionEpoch);
      },
      onReplace: (replacement) async {
        final epoch = editorState.localTransactionEpoch;
        final connectionEpoch = _inputConnectionEpoch;
        if (!_canProcessInput(epoch, connectionEpoch)) {
          return _rejectInput(connectionEpoch);
        }
        for (final interceptor in interceptors) {
          final result = await interceptor.interceptReplace(
            replacement,
            editorState,
            widget.characterShortcutEvents,
          );
          if (!_canProcessInput(epoch, connectionEpoch)) {
            return _rejectInput(connectionEpoch);
          }
          if (result) {
            AppFlowyEditorLog.input.info(
              'keyboard service onReplace - intercepted by interceptor: $interceptor',
            );
            return false;
          }
        }

        await onReplace(
          replacement,
          editorState,
          widget.characterShortcutEvents,
          isInputCurrent: () => _canProcessInput(epoch, connectionEpoch),
        );
        return _canProcessInput(epoch, connectionEpoch) ||
            _rejectInput(connectionEpoch);
      },
      onNonTextUpdate: (nonTextUpdate) async {
        final epoch = editorState.localTransactionEpoch;
        final connectionEpoch = _inputConnectionEpoch;
        if (!_canProcessInput(epoch, connectionEpoch)) {
          return _rejectInput(connectionEpoch);
        }
        for (final interceptor in interceptors) {
          final result = await interceptor.interceptNonTextUpdate(
            nonTextUpdate,
            editorState,
            widget.characterShortcutEvents,
          );
          if (!_canProcessInput(epoch, connectionEpoch)) {
            return _rejectInput(connectionEpoch);
          }
          if (result) {
            AppFlowyEditorLog.input.info(
              'keyboard service onNonTextUpdate - intercepted by interceptor: $interceptor',
            );
            return false;
          }
        }

        await onNonTextUpdate(
          nonTextUpdate,
          editorState,
          widget.characterShortcutEvents,
          isInputCurrent: () => _canProcessInput(epoch, connectionEpoch),
        );
        return _canProcessInput(epoch, connectionEpoch) ||
            _rejectInput(connectionEpoch);
      },
      onPerformAction: (action) async {
        final epoch = editorState.localTransactionEpoch;
        final connectionEpoch = _inputConnectionEpoch;
        if (!_canProcessInput(epoch, connectionEpoch)) return;
        for (final interceptor in interceptors) {
          final result = await interceptor.interceptPerformAction(
            action,
            editorState,
          );
          if (!_canProcessInput(epoch, connectionEpoch)) return;
          if (result) {
            AppFlowyEditorLog.input.info(
              'keyboard service onPerformAction - intercepted by interceptor: $interceptor',
            );
            return;
          }
        }

        await onPerformAction(action, editorState);
      },
      onFloatingCursor: (point) async {
        final epoch = editorState.localTransactionEpoch;
        final connectionEpoch = _inputConnectionEpoch;
        if (!_canProcessInput(epoch, connectionEpoch)) return;
        for (final interceptor in interceptors) {
          final result = await interceptor.interceptFloatingCursor(
            point,
            editorState,
          );
          if (!_canProcessInput(epoch, connectionEpoch)) return;
          if (result) {
            AppFlowyEditorLog.input.info(
              'keyboard service onFloatingCursor - intercepted by interceptor: $interceptor',
            );
            return;
          }
        }

        await onFloatingCursorUpdate(point, editorState);
      },
      contentInsertionConfiguration: widget.contentInsertionConfiguration,
    );
  }
}
