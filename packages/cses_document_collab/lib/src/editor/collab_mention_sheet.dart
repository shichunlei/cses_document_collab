import 'collab_mention_avatar.dart';
import 'package:flutter/scheduler.dart' show SchedulerPhase;
import 'dart:async';

import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:cses_document_collab/src/model/collab_user_mention.dart';
import 'package:cses_document_collab/src/native/collab_runtime.dart';
import 'package:flutter/material.dart';

/// 在借用 [context]/[editor] 上选择人员，查询通过借用 [directory] 或宿主服务。
/// [keyword] 是初始搜索词，默认空字符串。
/// 返回真实人员快照；取消/关闭/权限撤销为null，等待退场动画后完成，不写正文。
Future<CollabMentionUser?> showCollabMentionPicker(
  BuildContext context,
  EditorState editor, {
  CollabMentionDirectory? directory,
  String keyword = '',
}) async {
  if (editor.isDisposed || !editor.editable) return null;
  ModalRoute<CollabMentionUser>? route;
  final result = await showModalBottomSheet<CollabMentionUser>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) {
      route = ModalRoute.of(context);
      return _MentionPicker(
        editor: editor,
        directory: directory ?? CollabRuntime.services.mentionDirectory,
        keyword: keyword,
      );
    },
  );
  await route?.completed;
  return result;
}

/// 拥有搜索输入和请求状态的底部面板，借用编辑器/目录，不释放它们。
class _MentionPicker extends StatefulWidget {
  /// [editor] 提供权限，[directory] 为查询端口，null显示缺少服务，[keyword] 为初始搜索词。
  const _MentionPicker({
    required this.editor,
    required this.directory,
    required this.keyword,
  });

  /// 借用的编辑器，提供权限，面板不释放。
  final EditorState editor;

  /// 借用的人员目录；null禁用搜索并展示说明。
  final CollabMentionDirectory? directory;

  /// 初始关键词，默认由入口提供空字符串。
  final String keyword;

  /// 创建所属输入、去抖定时器与过期请求防护。
  @override
  State<_MentionPicker> createState() => _MentionPickerState();
}

/// 拥有输入和定时器；查询串行身份由generation判定，退出/输入变化使迟到结果失效。
class _MentionPickerState extends State<_MentionPicker> {
  /// 本状态创建并释放的搜索输入控制器。
  late final TextEditingController _input;

  /// 本状态拥有的去抖定时器，输入变化/退出时取消。
  Timer? _debounce;

  /// 每次输入/权限变化/关闭递增，使旧请求失效。
  int _generation = 0;
  List<CollabMentionUser> _users = const [];
  bool _loading = true;
  String? _error;

  /// 初始化输入与权限监听，首个请求立即查询当前企业人员。
  @override
  void initState() {
    super.initState();
    _input = TextEditingController(text: widget.keyword);
    widget.editor.editableNotifier.addListener(_permissionChanged);
    unawaited(_search(++_generation));
  }

  /// 权限撤销使异步结果失效并刷新禁用状态，不恢复正文输入。
  void _permissionChanged() {
    if (!mounted) return;
    final generation = ++_generation;
    if (widget.editor.editable && !widget.editor.isDisposed) {
      _loading = true;
      _error = null;
      _users = const [];
      unawaited(_search(generation));
    }
    if (WidgetsBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    } else {
      setState(() {});
    }
  }

  /// 输入 [value] 变化立即废弃旧列表和请求，250毫秒后查询，避免选中上一关键词结果。
  void _changed(String value) {
    _debounce?.cancel();
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _users = const [];
      _error = null;
    });
    _debounce = Timer(const Duration(milliseconds: 250), () {
      unawaited(_search(generation));
    });
  }

  /// 查询 [generation] 对应输入；捕获失败供重试，关闭/权限变化/过期时不回写。
  Future<void> _search(int generation) async {
    final directory = widget.directory;
    if (directory == null) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '当前未提供人员查询服务';
        });
      }
      return;
    }
    try {
      final users = await directory.search(_input.text);
      if (!mounted ||
          generation != _generation ||
          widget.editor.isDisposed ||
          !widget.editor.editable) {
        return;
      }
      setState(() {
        _users = users;
        _loading = false;
        _error = null;
      });
    } catch (error, stack) {
      if (!mounted || generation != _generation) return;
      CollabDiagnostics.report(
        '人员搜索失败',
        error: error,
        stackTrace: stack,
        tag: 'DocCollab',
      );
      setState(() {
        _loading = false;
        _error = '人员加载失败，请重试';
      });
    }
  }

  /// 销毁所属定时器/输入并解除借用权限监听，迟到请求不能写已关闭面板。
  @override
  void dispose() {
    ++_generation;
    _debounce?.cancel();
    widget.editor.editableNotifier.removeListener(_permissionChanged);
    _input.dispose();
    super.dispose();
  }

  /// 在借用 [context] 中固定标题/搜索，仅惰性人员列表滚动，适应键盘与窄屏大字。
  @override
  Widget build(BuildContext context) {
    final enabled = !widget.editor.isDisposed && widget.editor.editable;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * .6,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      '@用户',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('mention-close'),
                    tooltip: '关闭',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: TextField(
                key: const ValueKey('mention-search'),
                controller: _input,
                enabled: enabled && widget.directory != null,
                onChanged: _changed,
                decoration: const InputDecoration(
                  labelText: '搜索人员',
                  prefixIcon: Icon(Icons.search),
                ),
              ),
            ),
            Expanded(
              child: !enabled
                  ? const Center(child: Text('当前不可编辑'))
                  : _error != null
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(_error!),
                          if (widget.directory != null)
                            TextButton(
                              key: const ValueKey('mention-retry'),
                              onPressed: () {
                                setState(() {
                                  _loading = true;
                                  _error = null;
                                });
                                unawaited(_search(++_generation));
                              },
                              child: const Text('重试'),
                            ),
                        ],
                      ),
                    )
                  : _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _users.isEmpty
                  ? const Center(child: Text('没有匹配的人员'))
                  : ListView.builder(
                      key: const PageStorageKey('mention-users'),
                      itemCount: _users.length,
                      itemBuilder: (context, index) {
                        final user = _users[index];
                        return ListTile(
                          key: ValueKey('mention-user-${user.id}'),
                          leading: CollabMentionAvatar(
                            userId: user.id,
                            name: user.name,
                            avatarUrl: user.avatarUrl,
                          ),
                          title: Text(user.name),
                          subtitle: user.department == null
                              ? null
                              : Text(user.department!),
                          onTap: () {
                            if (!widget.editor.isDisposed &&
                                widget.editor.editable) {
                              Navigator.pop(context, user);
                            }
                          },
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
