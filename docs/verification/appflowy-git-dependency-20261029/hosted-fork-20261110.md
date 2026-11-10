# AppFlowy Editor 切换 pub.dev 发布包

2026-11-10，根包和 example 从 Git 固定提交 `9e7593134457eac9193a61ee4023a75de55fcc68`（6.2.0）切换到 `applowy_editor_fork: ^6.2.1`。源码和测试改用发布包的公开入口 `package:applowy_editor_fork/applowy_editor_fork.dart`。发布版包含带页脚列表跳回首项的布局修复，并更新了文件选择器和 SVG 依赖。[pub.dev 版本记录](https://pub.dev/packages/applowy_editor_fork/versions/6.2.1)

- 根包与 example 的 `flutter pub get` 均成功，两个本地锁文件及包配置均解析到 pub.dev 的 6.2.1，SHA-256 为 `7b853ef939dc66673f05a74eda12e4e144b775081129a87d718f464599d37db7`。锁文件沿用仓库现有忽略规则。
- 对涉及的 Dart 文件运行了 `dart format`，保留导入声明相关改动。`flutter analyze --no-pub --no-fatal-infos lib test integration_test` 在两个包均成功。根包保留既有的 `unawaited_futures` 和 `close_sinks` 提示，example 无诊断。
- 根包的编辑页、输入、键盘动作及本地和远端历史回归共 77 项通过。example 的今日导向及制图页面共 194 项通过。涉及原生历史的测试使用本地现有 Rust 调试库。
- 当前源码与接入配置中已检索旧依赖和导入，历史记录保留原始引用。`bash -n tool/verify_portable_package.sh` 和 `git diff --check` 通过。本轮验证覆盖根包与 example，未执行独立宿主脚本全流程、移动端构建或真机测试。
