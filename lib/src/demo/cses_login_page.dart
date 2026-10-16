import 'package:cses_mobile_collab_demo/src/demo/cses_account_login.dart';
import 'package:flutter/material.dart';

/// PRE 测试环境登录入口，用户名和密码初始预填为 `111`，可在提交前修改。
/// Common 上下文就绪后通知页面切换，不持久化输入，登录成功时清空密码。
///
/// ```dart
/// import 'package:cses_mobile_collab_demo/src/demo/cses_login_page.dart';
/// import 'package:flutter/material.dart';
///
/// Widget loginPage(VoidCallback openDocument) =>
///     CsesLoginPage(onLoggedIn: openDocument);
/// ```
class CsesLoginPage extends StatefulWidget {
  /// [key] 控制组件身份与状态复用；[onLoggedIn] 在登录完成后通知宿主。
  /// [login] 是借用的登录服务，默认使用 Common 账号登录，不由页面释放。
  const CsesLoginPage({super.key, required this.onLoggedIn, this.login = const CsesAccountLogin()});

  /// 必填登录完成回调；由宿主决定后续页面，失败或页面销毁后不调用。
  final VoidCallback onLoggedIn;

  /// 借用的登录服务，默认使用 Common 账号登录；页面不持有其生命周期。
  final CsesAccountLogin login;

  /// 创建持有输入控制器与登录请求状态的表单状态。
  @override
  createState() => _CsesLoginPageState();
}

/// 管理表单与请求生命周期；等待期间禁止重复提交，离开后忽略迟到响应。
class _CsesLoginPageState extends State<CsesLoginPage> {
  final _form = GlobalKey<FormState>();

  /// 页面持有的用户名输入，初始为测试值，销毁页面时释放。
  final _userName = TextEditingController()..text = "111";

  /// 页面持有的密码输入，初始为测试值，登录成功时清空、销毁时释放。
  final _password = TextEditingController()..text = "111";
  bool _busy = false;
  bool _obscure = true;
  String? _error;

  /// 校验表单并初始化 Common 登录；销毁后的响应不再注入上下文，成功后清空密码。
  Future<void> _submit() async {
    if (_busy || !_form.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.login.login(_userName.text, _password.text, isActive: () => mounted);
      if (!mounted) return;
      _password.clear();
      widget.onLoggedIn();
    } on CsesLoginFailure catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (error, stackTrace) {
      // 不输出异常正文：第三方异常可能夹带登录请求和密码。保留堆栈便于定位代码。
      debugPrint('账号登录异常：${error.runtimeType}\n$stackTrace');
      if (mounted) setState(() => _error = '登录失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 释放页面创建的用户名和密码控制器，迟到的登录结果由 mounted 检查忽略。
  @override
  void dispose() {
    _userName.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('CSES 协同 Demo')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: AutofillGroup(
                child: Form(
                  key: _form,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Icon(Icons.edit_document, size: 48, color: Theme.of(context).colorScheme.primary),
                      const SizedBox(height: 20),
                      Text('登录账号', style: Theme.of(context).textTheme.headlineSmall, textAlign: TextAlign.center),
                      const SizedBox(height: 8),
                      const Text('登录后自动连接测试文档', textAlign: TextAlign.center),
                      const SizedBox(height: 32),
                      TextFormField(
                        key: const ValueKey('login-username'),
                        controller: _userName,
                        enabled: !_busy,
                        autofillHints: const [AutofillHints.username],
                        autocorrect: false,
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(
                          labelText: '用户名',
                          prefixIcon: Icon(Icons.person_outline),
                          border: OutlineInputBorder(),
                        ),
                        validator: (value) => value == null || value.trim().isEmpty ? '请输入用户名' : null,
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        key: const ValueKey('login-password'),
                        controller: _password,
                        enabled: !_busy,
                        autofillHints: const [AutofillHints.password],
                        obscureText: _obscure,
                        autocorrect: false,
                        enableSuggestions: false,
                        textInputAction: TextInputAction.done,
                        onFieldSubmitted: (_) => _submit(),
                        decoration: InputDecoration(
                          labelText: '密码',
                          prefixIcon: const Icon(Icons.lock_outline),
                          border: const OutlineInputBorder(),
                          suffixIcon: IconButton(
                            tooltip: _obscure ? '显示密码' : '隐藏密码',
                            onPressed: () => setState(() => _obscure = !_obscure),
                            icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                          ),
                        ),
                        validator: (value) => value == null || value.isEmpty ? '请输入密码' : null,
                      ),
                      if (_error != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 16),
                          child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                        ),
                      const SizedBox(height: 24),
                      FilledButton(
                        key: const ValueKey('login-submit'),
                        onPressed: _busy ? null : _submit,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          child: _busy
                              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                              : const Text('登录'),
                        ),
                      ),
                      const SizedBox(height: 24),
                      Text('PRE 测试环境', textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
