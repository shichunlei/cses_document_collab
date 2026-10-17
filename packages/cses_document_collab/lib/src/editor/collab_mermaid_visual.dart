import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// 使用随包 Mermaid 11.13.0 离线绘图；源码只传给本地 WebView，不写共享文档。
/// 组件拥有平台视图和去抖定时器；Flutter 移除视图时释放原生资源，Controller 无 dispose API。
///
/// ```dart
/// import 'package:cses_document_collab/src/editor/collab_mermaid_visual.dart';
/// import 'package:flutter/material.dart';
/// Widget preview() => const CollabMermaidVisual(source: 'flowchart LR\nA-->B');
/// ```
class CollabMermaidVisual extends StatefulWidget {
  /// [key] 控制身份和状态复用；[source] 为必需的 Mermaid 原文，空值显示输入提示。
  /// 输入变化延迟350毫秒绘图，旧任务失效；不提供文档或宿主脚本桥。
  const CollabMermaidVisual({super.key, required this.source});

  /// 必需的只读源码；由调用方持有，变化不会重建平台视图。
  final String source;

  /// 创建仅负责本地预览的状态。
  @override
  createState() => _MermaidVisualState();
}

/// 预览代次隔离迟到回调；不保存账号、文档或共享数据引用。
class _MermaidVisualState extends State<CollabMermaidVisual> {
  /// 本组件创建的平台控制器，移除视图时失效。
  WebViewController? _controller;

  /// 本组件拥有，源码变化或关闭时取消。
  Timer? _timer;
  int _generation = 0;

  /// 平台加载代次，与源码渲染代次分离；重试和关闭使旧平台回调失效。
  int _loadGeneration = 0;
  bool _ready = false;
  String? _error;

  /// 初始化本地页面，异步错误在组件内显示重试。
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  /// 借用 [oldWidget] 比较源码，取消旧的等待任务；新内容按代次刷新。
  @override
  void didUpdateWidget(covariant CollabMermaidVisual oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source) {
      _timer?.cancel();
      _generation++;
      unawaited(_invalidatePreview());
      _timer = Timer(const Duration(milliseconds: 350), () {
        unawaited(_render());
      });
    }
  }

  /// 创建离线平台视图；仅允许初始随包页面，拒绝图表产生的导航。
  /// 每次 await 后验证当前控制器，关闭或重试后的结果不再回写。
  Future<void> _load() async {
    _timer?.cancel();
    final load = ++_loadGeneration;
    _controller = null;
    _ready = false;
    _error = null;
    if (WebViewPlatform.instance == null) {
      setState(() => _error = '当前设备不支持绘图预览');
      return;
    }

    /// 当前加载仍属于挂载中的平台视图。
    bool current() => mounted && load == _loadGeneration;
    try {
      final controller = WebViewController();
      _controller = controller;
      await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      if (!current()) return;
      await controller.addJavaScriptChannel(
        'DiagramStatus',
        onMessageReceived: (message) {
          if (!current()) return;
          try {
            final data = jsonDecode(message.message);
            if (data is! Map) return;
            if (data['generation'] == _generation) {
              setState(() => _error = data['failed'] == true ? '语法暂时无法绘制，源码仍可编辑和保存' : null);
            }
          } on FormatException {
            // 非本地状态消息不影响文档或可用预览。
          }
        },
      );
      if (!current()) return;
      await controller.setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) =>
              !_ready && request.url.startsWith('file:') ? NavigationDecision.navigate : NavigationDecision.prevent,
          onPageFinished: (_) {
            if (!current()) return;
            _ready = true;
            unawaited(_render());
          },
          onWebResourceError: (error) {
            if (current() && error.isForMainFrame != false) {
              setState(() => _error = '绘图组件加载失败，请重试');
            }
          },
        ),
      );
      if (!current()) return;
      await controller.loadFlutterAsset('packages/cses_document_collab/assets/mermaid/index.html');
      if (current()) setState(() {});
    } catch (_) {
      if (current()) setState(() => _error = '绘图组件加载失败，请重试');
    }
  }

  /// 立即使页面中的旧渲染失效，空源码同时清图，不等待输入去抖。
  Future<void> _invalidatePreview() async {
    final controller = _controller;
    if (!mounted || !_ready || controller == null) return;
    final generation = _generation;
    try {
      await controller.runJavaScript('window.invalidateDiagram($generation, ${widget.source.trim().isEmpty});');
    } catch (_) {
      if (mounted && generation == _generation && identical(controller, _controller)) {
        setState(() => _error = '绘图组件加载失败，请重试');
      }
    }
  }

  /// 将最新源码作为 JSON 数据传入本地绘图函数，平台失败可见且可重试。
  Future<void> _render() async {
    final controller = _controller;
    if (!mounted || !_ready || controller == null) return;
    final generation = ++_generation;
    try {
      await controller.runJavaScript('window.renderDiagram(${jsonEncode(widget.source)}, $generation);');
    } catch (_) {
      if (mounted && generation == _generation && identical(controller, _controller)) {
        setState(() => _error = '绘图组件加载失败，请重试');
      }
    }
  }

  /// 取消等待任务并使所有平台回调失效。
  @override
  void dispose() {
    _timer?.cancel();
    _generation++;
    _loadGeneration++;
    _controller = null;
    super.dispose();
  }

  /// 在借用 [context] 内展示限高预览及错误；语法错误仍保留上次有效图。
  @override
  Widget build(BuildContext context) => SizedBox(
    height: 280,
    child: Column(
      children: [
        if (_error != null)
          Row(
            children: [
              Expanded(child: Text(_error!, style: const TextStyle(fontSize: 12))),
              TextButton(onPressed: () => unawaited(_load()), child: const Text('重试')),
            ],
          ),
        Expanded(
          child: _controller == null
              ? Center(child: Text(_error ?? '正在加载绘图…'))
              : WebViewWidget(key: ValueKey(_controller), controller: _controller!),
        ),
      ],
    ),
  );
}
