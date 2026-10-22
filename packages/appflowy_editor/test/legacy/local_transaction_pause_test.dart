import 'dart:async';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:appflowy_editor/src/editor/editor_component/service/ime/character_shortcut_event_helper.dart';
import 'package:appflowy_editor/src/editor/editor_component/service/ime/non_delta_input_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../new/infra/testable_editor.dart';

/// Verify local pauses preserve permissions, platform input and remote updates.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'pause is independent of permissions, block guards and input attachment',
    () async {
      final state = EditorState.blank();
      var permissionNotifications = 0;
      state.editableNotifier.addListener(() => permissionNotifications++);
      final selection = Selection.collapsed(Position(path: [0]));
      try {
        final epoch = state.localTransactionEpoch;
        expect(state.localTransactionsPaused, isFalse);
        expect(state.canAcceptLocalTransactions, isTrue);
        state.localTransactionsPaused = true;
        expect(state.localTransactionEpoch, epoch + 1);
        expect(state.editable, isTrue);
        expect(state.canInputAt(selection), isTrue);
        expect(state.canAcceptLocalTransactions, isFalse);
        await state.apply(
          state.transaction..insertText(state.document.first!, 0, 'blocked'),
        );
        expect(state.document.first!.delta!.toPlainText(), isEmpty);
        expect(state.undoManager.undoStack.isEmpty, isTrue);
        state.localTransactionsPaused = true;
        expect(state.localTransactionEpoch, epoch + 1);
        state.localTransactionsPaused = false;
        expect(state.localTransactionEpoch, epoch + 2);
        expect(permissionNotifications, 0);
        state.transactionGuard = (_) => false;
        await state.apply(
          state.transaction..insertText(state.document.first!, 0, 'locked'),
        );
        expect(state.document.first!.delta!.toPlainText(), isEmpty);
        state.transactionGuard = null;
        await state.apply(
          state.transaction..insertText(state.document.first!, 0, 'local'),
        );
        expect(state.document.first!.delta!.toPlainText(), 'local');
        state.editable = false;
        expect(state.localTransactionEpoch, epoch + 3);
        expect(state.canInputAt(selection), isFalse);
        state.localTransactionsPaused = true;
        state.localTransactionsPaused = false;
        expect(state.editable, isFalse);
        expect(state.canAcceptLocalTransactions, isFalse);
      } finally {
        state.dispose();
      }
    },
  );

  test(
    'authoritative projection bypasses readonly and local policies',
    () async {
      final state = EditorState.blank();
      try {
        state.editable = false;
        state.localTransactionsPaused = true;
        state.transactionGuard = (_) => false;
        var notifications = 0;
        state.editableNotifier.addListener(() => notifications++);
        await state.apply(
          state.transaction..insertText(state.document.first!, 0, 'remote'),
          isRemote: true,
        );
        expect(state.document.first!.delta!.toPlainText(), 'remote');
        expect(state.editable, isFalse);
        expect(state.localTransactionsPaused, isTrue);
        expect(notifications, 0);
        expect(state.undoManager.undoStack.isEmpty, isTrue);
      } finally {
        state.dispose();
      }
    },
  );

  test(
    'remote projection can defer selection until stable restoration',
    () async {
      final state = EditorState.blank();
      final originalSelection = Selection.collapsed(Position(path: [0]));
      state.selection = originalSelection;
      var notifications = 0;
      state.selectionNotifier.addListener(() => notifications++);
      try {
        state.localTransactionsPaused = true;
        await state.apply(
          state.transaction..insertNode([0], paragraphNode(text: 'prefix')),
          isRemote: true,
          withUpdateSelection: false,
        );
        expect(state.document.root.children.length, 2);
        expect(state.document.first!.delta!.toPlainText(), 'prefix');
        expect(state.selection, originalSelection);
        expect(notifications, 0);
        final restored = Selection.collapsed(Position(path: [1]));
        state.selection = restored;
        expect(state.selection, restored);
        expect(notifications, 1);
        await state.apply(
          state.transaction..insertNode([0], paragraphNode(text: 'second')),
          isRemote: true,
        );
        expect(state.selection, Selection.collapsed(Position(path: [2])));
        expect(notifications, 2);
      } finally {
        state.dispose();
      }
    },
  );

  test(
    'pause entered from before hook rejects mutation and local history',
    () async {
      final state = EditorState.blank();
      final phases = <TransactionTime>[];
      final subscription = state.transactionStream.listen((event) {
        phases.add(event.$1);
        if (event.$1 == TransactionTime.before) {
          state.localTransactionsPaused = true;
        }
      });
      try {
        await state.apply(
          state.transaction..insertText(state.document.first!, 0, 'blocked'),
        );
        expect(state.document.first!.delta!.toPlainText(), isEmpty);
        expect(phases, [TransactionTime.before]);
        expect(state.undoManager.undoStack.isEmpty, isTrue);
      } finally {
        await subscription.cancel();
        state.dispose();
      }
    },
  );

  test(
    'completed pause invalidates remaining asynchronous shortcut chain',
    () async {
      final state = EditorState.blank();
      final started = Completer<void>();
      final release = Completer<void>();
      var laterCalls = 0;
      try {
        final pending = executeCharacterShortcutEvent(state, 'x', [
          CharacterShortcutEvent(
            key: 'wait',
            character: 'x',
            handler: (_) async {
              started.complete();
              await release.future;
              return false;
            },
          ),
          CharacterShortcutEvent(
            key: 'stale',
            character: 'x',
            handler: (_) async {
              laterCalls++;
              return true;
            },
          ),
        ]);
        await started.future;
        state.localTransactionsPaused = true;
        state.localTransactionsPaused = false;
        release.complete();
        expect(await pending, isFalse);
        expect(laterCalls, 0);
      } finally {
        state.dispose();
      }
    },
  );

  testWidgets(
    'paused typing keeps the real input connection and restores cache',
    (tester) async {
      final editor = tester.editor..addParagraph(initialText: 'ab');
      await editor.startTesting();
      await editor.updateSelection(
        Selection.collapsed(Position(path: [0], offset: 2)),
      );
      final state = editor.editorState;
      final keyboard = tester.state<KeyboardServiceWidgetState>(
        find.byType(KeyboardServiceWidget),
      );
      final input = keyboard.textInputService as NonDeltaTextInputService;
      final original = input.currentTextEditingValue!;
      expect(input.attached, isTrue);
      tester.testTextInput.log.clear();
      state.localTransactionsPaused = true;
      state.selection = state.selection;
      input.updateEditingValue(
        original.copyWith(
          text: '${original.text}X',
          selection: TextSelection.collapsed(offset: original.text.length + 1),
        ),
      );
      await tester.pump(const Duration(milliseconds: 20));
      expect(state.document.first!.delta!.toPlainText(), 'ab');
      expect(input.currentTextEditingValue, original);
      expect(input.attached, isTrue);
      expect(tester.testTextInput.hasAnyClients, isTrue);
      expect(
        tester.testTextInput.log.where(
          (call) => call.method == 'TextInput.clearClient',
        ),
        isEmpty,
      );
      state.localTransactionsPaused = false;
      input.updateEditingValue(
        original.copyWith(
          text: '${original.text}Y',
          selection: TextSelection.collapsed(offset: original.text.length + 1),
        ),
      );
      await tester.pump(const Duration(milliseconds: 20));
      expect(state.document.first!.delta!.toPlainText(), 'abY');
      await editor.dispose();
    },
  );

  for (final transition in ['pause', 'permission', 'notifier']) {
    testWidgets(
      '$transition cycle invalidates awaited IME without stale cache',
      (tester) async {
        final editor = tester.editor..addParagraph(initialText: 'ab');
        await editor.startTesting();
        await editor.updateSelection(
          Selection.collapsed(Position(path: [0], offset: 2)),
        );
        final state = editor.editorState;
        final keyboard = tester.state<KeyboardServiceWidgetState>(
          find.byType(KeyboardServiceWidget),
        );
        final input = keyboard.textInputService as NonDeltaTextInputService;
        final interceptor = _WaitingInputInterceptor();
        keyboard.registerInterceptor(interceptor);
        final original = input.currentTextEditingValue!;
        input.updateEditingValue(
          original.copyWith(
            text: '${original.text}X',
            selection: TextSelection.collapsed(
              offset: original.text.length + 1,
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 20));
        expect(interceptor.started.isCompleted, isTrue);
        if (transition == 'pause') {
          state.localTransactionsPaused = true;
        } else if (transition == 'notifier') {
          state.editableNotifier.value = false;
        } else {
          state.editable = false;
        }
        await state.apply(
          state.transaction..insertText(state.document.first!, 0, 'R'),
          isRemote: true,
        );
        if (transition == 'pause') {
          state.localTransactionsPaused = false;
        } else if (transition == 'notifier') {
          state.editableNotifier.value = true;
        } else {
          state.editable = true;
        }
        state.selection = Selection.collapsed(Position(path: [0], offset: 3));
        final projected = input.currentTextEditingValue;
        interceptor.release.complete();
        await tester.pump();
        expect(state.document.first!.delta!.toPlainText(), 'Rab');
        expect(input.currentTextEditingValue, projected);
        expect(input.attached, isTrue);
        expect(state.undoManager.undoStack.isEmpty, isTrue);
        keyboard.unregisterInterceptor(interceptor);
        await editor.dispose();
      },
    );
  }

  testWidgets('late rejected input cannot reopen a closed input service', (
    tester,
  ) async {
    final release = Completer<bool>();
    final input = NonDeltaTextInputService(
      onInsert: (_) => release.future,
      onDelete: (_) async => true,
      onReplace: (_) async => true,
      onNonTextUpdate: (_) async => true,
      onPerformAction: (_) async {},
    );
    input.attach(
      const TextEditingValue(
        text: 'a',
        selection: TextSelection.collapsed(offset: 1),
      ),
      const TextInputConfiguration(),
    );
    input.updateEditingValue(
      const TextEditingValue(
        text: ' ab',
        selection: TextSelection.collapsed(offset: 3),
      ),
    );
    await tester.pump(const Duration(milliseconds: 20));
    input.close();
    release.complete(false);
    await tester.pump();
    expect(input.currentTextEditingValue, isNull);
    expect(input.attached, isFalse);
    expect(tester.takeException(), isNull);
  });

  for (final waitingAt in [
    'interceptor',
    'shortcut',
    'replacement connection',
    'platform close',
  ]) {
    testWidgets('explicit close invalidates input awaiting $waitingAt', (
      tester,
    ) async {
      final editor = tester.editor..addParagraph(initialText: 'ab');
      await editor.startTesting();
      await editor.updateSelection(
        Selection.collapsed(Position(path: [0], offset: 2)),
      );
      final keyboard = tester.state<KeyboardServiceWidgetState>(
        find.byType(KeyboardServiceWidget),
      );
      final input = keyboard.textInputService as NonDeltaTextInputService;
      final interceptor = _WaitingInputInterceptor();
      final shortcut = CharacterShortcutEvent(
        key: 'await-close',
        character: 'x',
        handler: (_) async {
          interceptor.started.complete();
          await interceptor.release.future;
          return false;
        },
      );
      if (waitingAt == 'shortcut') {
        keyboard.widget.characterShortcutEvents.insert(0, shortcut);
      } else {
        keyboard.registerInterceptor(interceptor);
      }
      final oldEpoch = input.connectionEpoch;
      final pending = input.apply([
        const TextEditingDeltaInsertion(
          oldText: ' ab',
          textInserted: 'x',
          insertionOffset: 3,
          selection: TextSelection.collapsed(offset: 4),
          composing: TextRange.empty,
        ),
      ]);
      expect(interceptor.started.isCompleted, isTrue);
      if (waitingAt == 'platform close') {
        input.connectionClosed();
      } else {
        keyboard.closeKeyboard();
      }
      expect(input.attached, isFalse);
      expect(input.connectionEpoch, greaterThan(oldEpoch));
      keyboard.unregisterInterceptor(interceptor);
      TextEditingValue? replacementValue;
      if (waitingAt == 'replacement connection') {
        keyboard.enableKeyBoard(editor.selection!);
        expect(input.attached, isTrue);
        await input.apply([
          const TextEditingDeltaInsertion(
            oldText: ' ab',
            textInserted: 'Y',
            insertionOffset: 3,
            selection: TextSelection.collapsed(offset: 4),
            composing: TextRange.empty,
          ),
        ]);
        replacementValue = input.currentTextEditingValue;
      }
      interceptor.release.complete();
      expect(await pending, isFalse);
      await tester.pump();
      if (waitingAt == 'replacement connection') {
        expect(editor.document.first!.delta!.toPlainText(), 'abY');
        expect(input.currentTextEditingValue, replacementValue);
        expect(input.attached, isTrue);
      } else {
        expect(editor.document.first!.delta!.toPlainText(), 'ab');
        expect(input.attached, isFalse);
        expect(input.currentTextEditingValue, isNull);
        keyboard.enableKeyBoard(editor.selection!);
        expect(input.attached, isTrue);
        await input.apply([
          const TextEditingDeltaInsertion(
            oldText: ' ab',
            textInserted: 'Y',
            insertionOffset: 3,
            selection: TextSelection.collapsed(offset: 4),
            composing: TextRange.empty,
          ),
        ]);
        expect(editor.document.first!.delta!.toPlainText(), 'abY');
      }
      if (waitingAt == 'shortcut') {
        keyboard.widget.characterShortcutEvents.remove(shortcut);
      }
      await editor.dispose();
    });
  }

  testWidgets('unmount invalidates awaiting input and closes its connection', (
    tester,
  ) async {
    final editor = tester.editor..addParagraph(initialText: 'ab');
    await editor.startTesting();
    await editor.updateSelection(
      Selection.collapsed(Position(path: [0], offset: 2)),
    );
    final keyboard = tester.state<KeyboardServiceWidgetState>(
      find.byType(KeyboardServiceWidget),
    );
    final input = keyboard.textInputService as NonDeltaTextInputService;
    final interceptor = _WaitingInputInterceptor();
    keyboard.registerInterceptor(interceptor);
    final original = input.currentTextEditingValue!;
    input.updateEditingValue(
      original.copyWith(
        text: '${original.text}X',
        selection: TextSelection.collapsed(offset: original.text.length + 1),
      ),
    );
    await tester.pump(const Duration(milliseconds: 20));
    expect(interceptor.started.isCompleted, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(input.attached, isFalse);
    interceptor.release.complete();
    await tester.pump();
    expect(input.currentTextEditingValue, isNull);
    expect(editor.document.first!.delta!.toPlainText(), 'ab');
    expect(tester.takeException(), isNull);
    editor.editorState.dispose();
  });

  testWidgets('closing old service does not cancel another service input', (
    tester,
  ) async {
    var insertions = 0;
    final older = NonDeltaTextInputService(
      onInsert: (_) async => true,
      onDelete: (_) async => true,
      onReplace: (_) async => true,
      onNonTextUpdate: (_) async => true,
      onPerformAction: (_) async {},
    );
    final current = NonDeltaTextInputService(
      onInsert: (_) async {
        insertions++;
        return true;
      },
      onDelete: (_) async => true,
      onReplace: (_) async => true,
      onNonTextUpdate: (_) async => true,
      onPerformAction: (_) async {},
    );
    const value = TextEditingValue(
      text: 'a',
      selection: TextSelection.collapsed(offset: 1),
    );
    older.attach(value, const TextInputConfiguration());
    current.attach(value, const TextInputConfiguration());
    expect(older.debounceKey, isNot(current.debounceKey));
    current.updateEditingValue(
      const TextEditingValue(
        text: ' ab',
        selection: TextSelection.collapsed(offset: 3),
      ),
    );
    older.close();
    await tester.pump(const Duration(milliseconds: 20));
    expect(insertions, 1);
    expect(current.currentTextEditingValue!.text, ' ab');
    expect(current.attached, isTrue);
    current.close();
  });
}

/// Holds an input callback across a permission/projection transition.
class _WaitingInputInterceptor extends AppFlowyKeyboardServiceInterceptor {
  /// Completes when the first insertion is awaiting [release].
  final started = Completer<void>();

  /// The test owns completion; false allows the normal handler to continue.
  final release = Completer<void>();

  /// Wait before interpreting borrowed [insertion] for [editorState] using
  /// [characterShortcutEvents]; the keyboard service must revalidate afterwards.
  @override
  Future<bool> interceptInsert(
    TextEditingDeltaInsertion insertion,
    EditorState editorState,
    List<CharacterShortcutEvent> characterShortcutEvents,
  ) async {
    started.complete();
    await release.future;
    return false;
  }
}
