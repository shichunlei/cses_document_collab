# 结构迁移审查三项 P2 修复

日期：2026-10-27。对应 [审查记录](review.md) R1、R2、R3，三项均已修复并完成下述范围验证；未提交、未推送。

## 修复范围

- **R1：核心依赖解析。** 根 README 的开发入口及原生回归入口、example README 中返回根包的测试入口、接入文档的核心测试入口统一使用 `flutter pub get --no-example`。明确核心开发无需外部 Common，运行完整 Demo 前才按 `example/pubspec.yaml` 准备 Common 并在 example 单独解析。同步说明 AppFlowy 位于核心包内的 `packages/appflowy_editor/`，避免继续引用旧同级目录方案。
- **R2：设备测试路径。** 卡片触摸、标题字号、三项格式/划词三条命令均改用 `--driver ../test_driver/integration_test.dart`，从 example 执行；同步修正划词菜单段落中的同一驱动说明。标题字号章节拆开“根目录生成夹具”和“example 执行设备回归”两个命令块，消除混合工作目录。
- **R3：文档执行目录。** 接入文档分别列出根包编辑/FRB 测试与 example 认证/Common 测试的命令，配置对应原生库环境路径；图库生成命令明确从仓库根 package 执行。example README 返回根包后的原生测试命令同步指定根包动态库。

本轮仅改上述三份开发文档及验证记录/索引，没有修改 Dart、Rust、生成声明或依赖版本。验证中的图库生成输出保存在临时副本，仓库现有生成文件未改动。

## 本轮验证

| 检查 | 实际结果 | 证据 |
|---|---|---|
| 无 Common 的独立核心解析 | 在仅含依赖声明的临时副本运行 `flutter pub get --offline --no-example`，exit 0；未提供相邻 Common | [输出](p2-fix-independent-pub.txt)、[命令与退出码](p2-fix-isolated-validation.json) |
| 图库生成命令 | 从临时根 package 执行文档同一命令，exit 0，生成 3 组、20 张封面；工具与桌面目录保持文档相对布局 | [输出](p2-fix-cover-generator.txt)、[退出码](p2-fix-isolated-validation.json) |
| 设备驱动及目标路径 | README 中全部 13 处 `--driver` / `--target` 路径从 example 解析均存在；旧重复 example 驱动路径无残留 | [逐项路径](p2-fix-path-check.json) |
| 设备入口静态检查 | 共用驱动与三个受影响目标共 4 文件，`flutter analyze --no-pub` 无问题 | [输出](p2-fix-device-entry-analysis.txt) |
| 三个设备目标编译 | 从 example 逐一运行 `flutter build bundle --debug --no-pub --target ../integration_test/<目标>`，三个 exit 0，均生成 kernel 与资源清单 | [命令与退出码](p2-fix-device-bundles.json)、[卡片日志](p2-fix-bundle-mobile-card.txt)、[标题日志](p2-fix-bundle-heading.txt)、[格式日志](p2-fix-bundle-editor-review.txt) |
| 根包原生测试入口 | 从根包设置 `$PWD/rust/target/debug`，运行 `test/collab_controller_native_test.dart`，2 项通过 | [输出](p2-fix-core-native-entry.txt) |
| 宿主依赖与认证/Common 入口 | 从 example 执行 `flutter pub get --offline` 成功；设置 `$PWD/../rust/target/debug`，运行账号登录与本机 WebSocket 回环两文件，11 项通过 | [解析](p2-fix-example-pub.txt)、[测试](p2-fix-example-auth-gateway.txt) |
| 文档与改动边界 | 修正文档链接有效、Shell 命令块语法有效、业务/原生/生成源码字节未变 | [汇总](p2-fix-validation.json) |
| 最终差异检查 | `git diff --check` 通过 | [输出](p2-fix-diff-check.txt) |

Flutter bundle 构建成功时不输出普通日志，因此三份 bundle 文本输出为空；退出码及实际 kernel/资源清单存在性一并记录，不以空日志本身推断成功。

## 保留的历史结论与限制

- [审查前默认解析失败](review-dependency-probe.json) 保留，说明为何核心入口需要 `--no-example`；旧审查问题、失败及迁移证据没有删除或改写为通过。
- 本轮未连接真机、未执行 `flutter drive` 的设备交互，也未安装或卸载应用。R2 验证覆盖路径、静态检查和目标 bundle 编译；设备运行行为仍沿用既有待验收范围。
- 完整核心/宿主套件及 Android/iOS 平台构建未在本轮重复执行；本轮执行的是与命令工作目录和原生加载路径相关的目标测试。既有核心工具栏测试失败与 2 条静态提示继续保留，不因文档修复宣称解决。
- 不涉及 BlockCraft 模型、块行为或协议升级，本轮未重新声明任何版本兼容范围。
