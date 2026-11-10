# Demo 环境配置合并验证

2026-11-10 合并 `e92940e` 与 `733a7a6` 时，唯一冲突位于 [Demo README](../../../example/README.md)。合并结果保留了远端的 `.env.json` 配置说明，并按根包与 Demo 的实际依赖声明，使用 pub.dev 上的 `applowy_editor_fork: ^6.2.1`。两处本地依赖解析结果均为 6.2.1。

在 `example/` 运行以下定向测试，18 项全部通过。运行时以空值模板临时提供 Flutter 所需资源，测试结束后删除临时文件。

```sh
flutter test --no-pub --reporter expanded test/demo_environment_test.dart \
  test/cses_account_login_test.dart test/cses_login_page_test.dart \
  test/mention_avatar_test.dart
```

本轮未运行在线连接或真机测试。
