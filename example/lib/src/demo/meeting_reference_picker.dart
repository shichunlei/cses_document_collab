import 'dart:convert';

import 'package:cses_document_collab/cses_document_collab.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Demo宿主在借用[context]中收集已有会议引用；[canEdit]由编辑器借出，不接管所有权。
/// 返回确认的引用，取消/撤权为null，等待路由完全退场后完成；不创建业务会议。
/// 正式宿主可将该入口替换为自己的会议选择/创建页面，成功后返回相同公开值对象。
/// ```dart
/// import 'package:cses_document_collab/cses_document_collab.dart';
/// import 'package:cses_mobile_collab_demo/src/demo/meeting_reference_picker.dart';
/// final services = CollabHostServices(pickMeetingReference: showDemoMeetingReferencePicker);
/// ```
Future<CollabMeetingReference?> showDemoMeetingReferencePicker(
  BuildContext context, {
  required ValueListenable<bool> canEdit,
}) async {
  if (!canEdit.value) return null;
  ModalRoute<CollabMeetingReference>? route;
  final result = await showModalBottomSheet<CollabMeetingReference>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) {
      route = ModalRoute.of(context);
      return _MeetingReferenceInput(canEdit: canEdit);
    },
  );
  await route?.completed;
  return canEdit.value ? result : null;
}

/// 宿主拥有的引用输入表单，不依赖包内部模型、编辑器或事务。
class _MeetingReferenceInput extends StatefulWidget {
  /// [canEdit]是借用权限，页面不释放它。
  const _MeetingReferenceInput({required this.canEdit});

  /// false后禁止确认；路由移除时解除监听。
  final ValueListenable<bool> canEdit;

  /// 创建持有输入框的状态。
  @override
  State<_MeetingReferenceInput> createState() => _MeetingReferenceInputState();
}

/// 页面持有表单及输入控制器，退出时全部释放。
class _MeetingReferenceInputState extends State<_MeetingReferenceInput> {
  final _form = GlobalKey<FormState>();
  final _id = TextEditingController();
  final _title = TextEditingController();
  final _number = TextEditingController();

  /// 仅返回引用快照；业务创建必须由宿主自己的服务和页面执行。
  void _confirm() {
    if (!widget.canEdit.value || !_form.currentState!.validate()) return;
    Navigator.pop(context, CollabMeetingReference(meetingId: _id.text, title: _title.text, number: _number.text));
  }

  /// 校验会议身份[value]的非空和UTF-8大小，不调用包内部实现。
  String? _validateId(String? value) =>
      value == null || value.trim().isEmpty || utf8.encode(value).length > 512 ? '请填写有效会议 ID（最多512字节）' : null;

  /// 校验展示字段[value]长度，[limit]以UTF-16单元计算。
  String? _validateText(String? value, int limit) => (value?.length ?? 0) > limit ? '最多$limit字' : null;

  /// 释放宿主创建的输入控制器；权限信号仍由调用方持有。
  @override
  void dispose() {
    _id.dispose();
    _title.dispose();
    _number.dispose();
    super.dispose();
  }

  /// 在借用[context]内保留固定关闭入口，表单在键盘/大字下独立滚动。
  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * .8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const SizedBox(width: 16),
                const Expanded(
                  child: Text('会议引用', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                ),
                IconButton(
                  key: const ValueKey('meeting-close'),
                  tooltip: '关闭',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: ValueListenableBuilder<bool>(
                  valueListenable: widget.canEdit,
                  builder: (context, enabled, _) => Form(
                    key: _form,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text('填写已有会议的引用信息，仅添加本文档卡片。'),
                        TextFormField(
                          key: const ValueKey('meeting-input-meetingId'),
                          controller: _id,
                          enabled: enabled,
                          decoration: const InputDecoration(labelText: '会议 ID'),
                          validator: _validateId,
                        ),
                        TextFormField(
                          key: const ValueKey('meeting-input-title'),
                          controller: _title,
                          enabled: enabled,
                          decoration: const InputDecoration(labelText: '标题'),
                          maxLines: 3,
                          validator: (value) => _validateText(value, 2000),
                        ),
                        TextFormField(
                          key: const ValueKey('meeting-input-number'),
                          controller: _number,
                          enabled: enabled,
                          decoration: const InputDecoration(labelText: '会议编号'),
                          validator: (value) => _validateText(value, 256),
                        ),
                        if (!enabled) const Text('当前不可编辑，请关闭后重试'),
                        const SizedBox(height: 16),
                        FilledButton(onPressed: enabled ? _confirm : null, child: const Text('添加引用')),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
