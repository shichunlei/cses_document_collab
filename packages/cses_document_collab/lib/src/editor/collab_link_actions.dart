import 'dart:async';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/editor/editor_shortcut_toolbar.dart';
import 'package:cses_document_collab/src/model/collab_link_view.dart';
import 'package:cses_document_collab/src/native/collab_runtime.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

/// Prevents duplicate action sheets without extending editor lifetimes.
final _pending = Expando<bool>('link-view-actions');

/// Presents opening/view actions for borrowed [node] in [context].
/// The editor and host services remain borrowed; input is suspended until the
/// sheet's closing animation finishes. URL/identity/permission/session changes
/// invalidate conversion. Failures report to the original host and surface a
/// local message; this future completes after dismissal and any transaction.
Future<void> showCollabLinkActions(BuildContext context, Node node) async {
  final state = context.read<EditorState>();
  final url = collabLinkUrl(node);
  if (url == null || state.isDisposed || _pending[state] == true) return;
  final id = node.attributes['cses_collab_block_id'] as String? ?? node.id;
  final fingerprint = collabLinkFingerprint(node);
  final currentView = collabLinkView(node);
  final services = CollabRuntime.services;
  _pending[state] = true;
  try {
    await runEditorHeaderAction<void>(context, state, () async {
      final route = ModalBottomSheetRoute<CollabLinkView>(
        isScrollControlled: true,
        builder: (sheetContext) => SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  title: Text(
                    url,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.open_in_new),
                  title: const Text('在浏览器打开'),
                  onTap: () async {
                    try {
                      if (!await launchUrl(
                        Uri.parse(url),
                        mode: LaunchMode.externalApplication,
                      )) {
                        throw StateError('无法打开链接');
                      }
                      if (sheetContext.mounted) Navigator.pop(sheetContext);
                    } catch (error, stack) {
                      services.onError?.call(
                        '无法打开链接',
                        error,
                        stack,
                        'DocCollab',
                      );
                      if (sheetContext.mounted) {
                        ScaffoldMessenger.maybeOf(sheetContext)?.showSnackBar(
                          const SnackBar(content: Text('无法打开此链接')),
                        );
                      }
                    }
                  },
                ),
                if (state.editable &&
                    const {'page', 'callout'}.contains(node.parent?.type))
                  for (final view in CollabLinkView.values)
                    ListTile(
                      key: ValueKey('link-view-${view.name}'),
                      title: Text(view.label),
                      trailing: view == currentView
                          ? const Icon(Icons.check)
                          : null,
                      onTap: () => Navigator.pop(sheetContext, view),
                    ),
              ],
            ),
          ),
        ),
      );
      final view = await Navigator.of(context).push(route);
      await route.completed;
      if (view == null ||
          view == currentView ||
          !context.mounted ||
          state.isDisposed ||
          !identical(CollabRuntime.services, services)) {
        return;
      }
      final source = findCollabLinkNode(state, id);
      if (source == null ||
          !await changeCollabLinkView(
            state,
            source,
            view,
            fingerprint: fingerprint,
          )) {
        if (context.mounted && state.editable) {
          ScaffoldMessenger.maybeOf(
            context,
          )?.showSnackBar(const SnackBar(content: Text('内容已更新，请重新选择')));
        }
      }
    });
  } catch (error, stack) {
    services.onError?.call('链接视图切换失败', error, stack, 'DocCollab');
    if (context.mounted &&
        !state.isDisposed &&
        identical(CollabRuntime.services, services)) {
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(const SnackBar(content: Text('切换失败，请重试')));
    }
  } finally {
    _pending[state] = null;
  }
}

/// Redirects taps on a whole-link [node] to view actions in borrowed [context].
/// [span] must be the mobile decorator's span, whose recognizer stays owned by
/// the rich-text renderer. Mixed paragraphs keep their normal behavior; replacing
/// both tap handlers avoids scheduling the upstream long-press editing timer.
TextSpan decorateCollabLinkSpan(
  BuildContext context,
  Node node,
  TextSpan span,
) {
  final recognizer = span.recognizer;
  if (node.type == 'paragraph' &&
      collabLinkUrl(node) != null &&
      recognizer is TapGestureRecognizer) {
    recognizer
      ..onTapDown = null
      ..onTapUp = (_) => unawaited(showCollabLinkActions(context, node));
  }
  return span;
}
