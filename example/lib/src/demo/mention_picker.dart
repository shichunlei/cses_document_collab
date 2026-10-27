import 'dart:async';

import 'package:cses_common/observability/api/log.dart';
import 'package:cses_document_collab/cses_document_collab.dart' show CollabMentionUser, CollabMentionDirectory;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show SchedulerPhase;

import 'mention_avatar.dart';

/// Demo宿主在借用 [context] 上选择人员；[directory] 提供当前企业查询。
/// [canEdit] 为借用的权限信号，false禁止确认；本函数不访问编辑器内部状态。
/// [keyword] 是初始搜索词，默认空字符串。
/// ```dart
/// import 'package:flutter/material.dart';
/// import 'package:cses_document_collab/cses_document_collab.dart';
/// import 'package:cses_mobile_collab_demo/src/demo/mention_picker.dart';
/// CollabHostServices pickerServices(CollabMentionDirectory directory) => CollabHostServices(
///   pickMentionUser: (context, {required keyword, required canEdit}) =>
///     showDemoMentionPicker(context, directory: directory, canEdit: canEdit, keyword: keyword),
/// );
/// ```
/// 返回真实人员快照；取消/关闭/权限撤销为null，等待退场动画后完成，不写正文。
Future<CollabMentionUser?> showDemoMentionPicker(
  BuildContext context, {
  required ValueListenable<bool> canEdit,
  required CollabMentionDirectory directory,
  String keyword = '',
}) async {
  if (!canEdit.value) return null;
  ModalRoute<CollabMentionUser>? route;
  final result = await showModalBottomSheet<CollabMentionUser>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) {
      route = ModalRoute.of(context);
      return _MentionPicker(canEdit: canEdit, directory: directory, keyword: keyword);
    },
  );
  await route?.completed;
  return canEdit.value ? result : null;
}

/// 拥有搜索输入和请求状态的底部面板，借用权限信号/目录，不释放它们。
class _MentionPicker extends StatefulWidget {
  /// [canEdit] 提供权限，[directory] 为查询端口，[keyword] 为初始搜索词。
  const _MentionPicker({required this.canEdit, required this.directory, required this.keyword});

  /// 借用的权限信号，面板移除监听但不释放。
  final ValueListenable<bool> canEdit;

  /// 借用的当前会话人员目录，组件不释放。
  final CollabMentionDirectory directory;

  /// 初始关键词，默认由入口提供空字符串。
  final String keyword;

  /// 创建所属输入、去抖定时器与过期请求防护。
  @override
  createState() => _MentionPickerState();
}

/// 拥有输入和定时器；查询串行身份由generation判定，退出/输入变化使迟到结果失效。
class _MentionPickerState extends State<_MentionPicker> {
  /// 本状态创建并释放的搜索输入控制器。
  late final TextEditingController _input;

  /// 本状态拥有的去抖定时器，输入变化/退出时取消。
  Timer? _debounce;

  /// 每次输入/权限变化/关闭递增，使旧请求失效。
  int _generation = 0;

  /// 仅保留当前关键词已完成且有效的结果。
  List<CollabMentionUser> _users = const [];

  /// 当前查询是否尚未结束，输入变化时清空列表并置true。
  bool _loading = true;

  /// 当前有效请求的可重试错误文案。
  String? _error;

  /// 初始化输入与权限监听，首个请求立即查询当前企业人员。
  @override
  void initState() {
    super.initState();
    _input = TextEditingController(text: widget.keyword);
    widget.canEdit.addListener(_permissionChanged);
    unawaited(_search(++_generation));
  }

  /// 权限撤销使异步结果失效并刷新禁用状态，不恢复正文输入。
  void _permissionChanged() {
    if (!mounted) return;
    _debounce?.cancel();
    final generation = ++_generation;
    if (widget.canEdit.value) {
      _loading = true;
      _error = null;
      _users = const [];
      unawaited(_search(generation));
    }
    if (WidgetsBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
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
    if (!mounted || generation != _generation || !widget.canEdit.value) return;
    final directory = widget.directory;
    try {
      final users = await directory.search(_input.text);
      if (!mounted || generation != _generation || !widget.canEdit.value) {
        return;
      }
      setState(() {
        _users = users;
        _loading = false;
        _error = null;
      });
    } catch (error, stack) {
      if (!mounted || generation != _generation || !widget.canEdit.value) {
        return;
      }
      Log.e('人员搜索失败', error: error, stackTrace: stack, tag: 'DocCollab');
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
    widget.canEdit.removeListener(_permissionChanged);
    _input.dispose();
    super.dispose();
  }

  /// 在借用 [context] 中固定标题/搜索，仅惰性人员列表滚动，适应键盘与窄屏大字。
  @override
  Widget build(BuildContext context) {
    final enabled = widget.canEdit.value;
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
                    child: Text('@用户', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
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
                enabled: enabled,
                onChanged: _changed,
                decoration: const InputDecoration(labelText: '搜索人员', prefixIcon: Icon(Icons.search)),
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
                          leading: DemoMentionAvatar(userId: user.id, name: user.name, avatarUrl: user.avatarUrl),
                          title: Text(user.name),
                          subtitle: user.department == null ? null : Text(user.department!),
                          onTap: () {
                            if (widget.canEdit.value) {
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
