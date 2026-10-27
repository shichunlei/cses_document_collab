# 结构迁移审查

日期：2026-10-27。审查范围：本轮未提交的根 package / example 迁移、依赖声明、路径引用、构建和开发入口。仅新增审查记录与索引，不修改工程实现或放宽测试。

结论：发现 3 项 P2，均需修正；未发现 P0/P1 或源码迁移丢失。现有工作区可以构建，不代表干净检出下的所有开发入口都有效。

后续处理：上述 R1、R2、R3 已在同轮完成修复，见 [三项 P2 修复与命令验证](p2-fixes.md)。下文保留审查时的原问题、复现及结论。

## R1 · P2：核心包默认依赖解析被 example 的外部 Common 依赖阻塞

位置：[根 README 开发入口](../../../README.md#开发入口)，第 10 行；关联 [example 依赖](../../../example/pubspec.yaml)。

根 README 将 `flutter pub get` 作为核心开发第一步，但 Flutter 3.44.9 默认启用 `--example`，会继续解析新加入的 example。example 依赖仓库外的 `../../cses/cses.common`；仅检出本仓库而未准备 Common 时，即使根核心包依赖已解析成功，整个命令仍失败。

本轮在 `/private/tmp` 建立仅含根包、example、AppFlowy 依赖声明的临时副本，不提供 Common，结果：

| 命令 | 结果 |
|---|---|
| `flutter pub get --offline` | exit 66；根依赖成功后在 `Resolving dependencies in ./example` 阶段因缺少 cses_common 失败 |
| `flutter pub get --offline --no-example` | exit 0 |

证据：[默认解析](review-pub-get-default.txt)、[核心独立解析](review-pub-get-coreOnly.txt)、[退出码](review-dependency-probe.json)。同时读取当前 Flutter SDK 的 `commands/packages.dart`，确认 `example` flag 默认为 true。

建议：核心包开发入口明确使用 `flutter pub get --no-example`；进入 example 后再独立解析其依赖，并说明运行完整 Demo 前需提供 Common。无需因此向核心包加入 Common 依赖。

## R2 · P2：三条设备测试命令重复拼接 example 目录

位置：根 README 第 655、701、711 行。

文档要求在 example 中运行，却将驱动指定为 `--driver example/test_driver/integration_test.dart`。实际查找位置变为仓库内 `example/example/test_driver/integration_test.dart`，该文件不存在。相邻 `--target ../integration_test/...` 已按 example 的工作目录调整，两者不一致；受影响的是卡片触摸、标题字号、三项格式/划词设备回归。

文件存在性检查结果：

- example 下的 `example/test_driver/integration_test.dart`：不存在。
- example 下的 `../test_driver/integration_test.dart`：存在，为核心包设备测试驱动。
- example 下的 `test_driver/integration_test.dart`：存在，为原宿主驱动。

建议：这三条包内设备测试统一使用 `--driver ../test_driver/integration_test.dart`，保持与迁移记录及其他已修正设备命令相同的工作目录约定。此次未启动设备测试，也未触碰已安装应用。

## R3 · P2：接入文档的命令工作目录仍沿用旧根宿主结构

位置：[接入文档](../../collab-package-integration.md) 第 72、113 行。

- 第 72 行仍称根目录 `flutter test test` 覆盖认证与 Common 回环；这些测试已经位于 example，根目录同名命令只运行核心包测试，可能使调用方误以为已完成宿主验证。
- 第 113 行要求“在宿主根目录执行” `python3 tool/sync_document_cover_catalog.py ../cses-client/...`。新宿主根目录是 example；此时 `example/tool/sync_document_cover_catalog.py` 和所写相对桌面路径均不存在。该命令实际应在仓库根 package 执行。

建议：分别写明核心包根目录与 example 的执行入口；图库生成命令标注从仓库根目录执行。此处是未同步的有效开发说明，不是应保持原样的原始历史日志。

## 已核对且未发现遗漏的范围

- 按迁移前 2938 个已跟踪文件与路径映射核对，迁移目标全部存在；可执行脚本未丢失执行位。
- 根包 189 个 lib 文件、75 个 Rust 源文件保持迁移前字节；生成代码未被手改。两套 Android/iOS 工程归属、FRB 相对配置、Cargo vendor 关系和插件资源声明匹配。
- 根 package 与 example 的实际解析分别指向根包、同一 AppFlowy fork 与既有 Common 路径；example 未发现直接导入核心 src，核心源码未发现反向依赖宿主/Common。
- iOS 三个宿主脚本按脚本位置计算 example/root，Runner 调用脚本的相对路径有效；Android Gradle 的 Flutter source 仍相对 example/android/app 指向 example。
- Git fetch/push 地址均为新 GitHub 名称。Cargo.lock 的新根路径例外有效；没有迁移后的源码因忽略规则新增而丢失，原位置已跟踪的历史日志不计作迁移缺失。
- Mermaid `packages/cses_document_collab/assets/mermaid/index.html` 是 Flutter 运行时包资源键，保留正确，不能当作旧文件系统目录删除。
- `git diff --check` 通过。本轮未修改源码，未重复执行已经通过的全量构建与测试；此前 Android/iOS 模拟器、338 项宿主测试、208 项 Rust 测试等证据仍保留。核心包 1 项既有失败与 2 条既有静态提示继续按原报告记录，不混入上述新发现。

## 审查限制

临时副本验证的是依赖解析，未编译空占位源码；设备命令通过路径存在性及工作目录核查确认失效，未在真机执行。本轮不重新审查 BlockCraft 模型或版本兼容性，也不以历史构建成功代替干净检出入口验证。
