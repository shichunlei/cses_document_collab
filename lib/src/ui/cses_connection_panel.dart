import 'package:cses_mobile_collab_demo/src/collab/collab_controller.dart';
import 'package:cses_mobile_collab_demo/src/collab/cses_connection_settings.dart';
import 'package:flutter/material.dart';

/// CSES 测试会话输入面板；预填指定的 PRE 测试配置，等待用户手动连接。
///
/// 默认会话值随 Demo 源码提供；表单修改仅由本 Widget 在内存持有，不另行持久化，
/// 卸载时释放输入资源，重新挂载时恢复默认配置。
///
/// ```dart
/// import 'package:cses_mobile_collab_demo/src/ui/cses_connection_panel.dart';
/// CsesConnectionPanel(collab: controller, onReset: controller.resetLocalCache);
/// ```
class CsesConnectionPanel extends StatefulWidget {
  /// 借用 [collab] 展示状态并执行连接；[onReset] 由页面确认后执行缓存清理。
  const CsesConnectionPanel({
    super.key,
    required this.collab,
    required this.onReset,
  });

  /// 外部持有的单编辑器控制器，本面板不释放它。
  final CollabController collab;

  /// 清缓存操作入口，Future 在确认及清理后完成；执行中按钮不可用。
  final Future<void> Function() onReset;

  /// 创建输入生命周期，表单值不随控制器状态刷新而丢失。
  @override
  State<CsesConnectionPanel> createState() => _CsesConnectionPanelState();
}

/// 持有带默认测试值的表单控制器，不读取或另存登录配置到持久化存储。
class _CsesConnectionPanelState extends State<CsesConnectionPanel> {
  /// 首次挂载时预填 PRE 会话；用户可覆盖每个字段，普通重建保留当前输入。
  ///
  /// 控制器由本 State 创建并在 dispose 中释放；初始化字段不会发起连接，
  /// 仅在用户触发连接命令后将当前输入传给协同控制器。
  final Map<String, TextEditingController> _fields = {
    for (final entry in const {
      'WS 地址': 'wss://ws-pre.jinqidongli.com/ws',
      'cookieId': '5ffd465e263864787b87aa01',
      'deviceId': 'e25c44b7f46b6bb5',
      'companyId': '64118eebd2b665246b7880eb',
      'userId': '5ffd465e263864787b87aa01',
      '测试文档 ID': '6ac76e5375083c8c9f19cbd3',
    }.entries)
      entry.key: TextEditingController(text: entry.value),
  };

  /// 从当前输入构造登录上下文；控制器负责校验、重复命令锁及异常展示。
  Future<void> _connect() => widget.collab.configureCses(
    CsesConnectionSettings(
      websocketUrl: _fields['WS 地址']!.text.trim(),
      cookieId: _fields['cookieId']!.text.trim(),
      deviceId: _fields['deviceId']!.text.trim(),
      companyId: _fields['companyId']!.text.trim(),
      userId: _fields['userId']!.text.trim(),
      documentId: _fields['测试文档 ID']!.text.trim(),
    ),
  );

  /// 释放本面板拥有的输入控制器，外部编辑器和主连接由宿主释放。
  @override
  void dispose() {
    for (final controller in _fields.values) {
      controller.dispose();
    }
    super.dispose();
  }

  /// 根据 [context] 渲染表单和协同诊断；不在构建过程中连接或注册监听。
  @override
  Widget build(BuildContext context) {
    final collab = widget.collab;
    return Card(
      elevation: 0,
      color: Theme.of(context).colorScheme.surfaceContainerLowest,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'CSES 文档协同实验（PRE）',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            const Text(
              '填写已有登录的会话与设备信息，连接已创建的 BlockCraft 文档。'
              'WS 地址填写完整部署路径，不追加文档 ID。未知块、嵌套结构、锁定或修订内容当前仅可预览。',
            ),
            const SizedBox(height: 16),
            for (final entry in _fields.entries) ...[
              TextField(
                key: ValueKey('cses-${entry.key}'),
                controller: entry.value,
                enabled: !collab.busy,
                obscureText: entry.key == 'cookieId',
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: entry.key,
                  hintText: entry.key == 'WS 地址' ? 'wss://<环境主机>/<部署路径>' : null,
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
            ],
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: collab.initialized && !collab.busy
                      ? _connect
                      : null,
                  icon: const Icon(Icons.sync),
                  label: Text(collab.busy ? '处理中' : '连接 / 重连'),
                ),
                TextButton.icon(
                  onPressed: collab.initialized && !collab.busy
                      ? widget.onReset
                      : null,
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('清本机缓存'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (collab.readOnlyReason != null) ...[
              Text('只读：${collab.readOnlyReason}'),
              const SizedBox(height: 8),
            ],
            Wrap(
              spacing: 18,
              runSpacing: 6,
              children: [
                Text('doc: ${collab.documentId}'),
                Text('protocol: ${collab.lastProtocolEvent}'),
                Text('loaded updates: ${collab.persistedUpdateCount}'),
                Text('blocks: ${collab.blockCount}'),
                Text('其他编辑器: ${collab.remoteEditorCount}'),
                Text('shared type: ${collab.sharedTypeName}'),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
