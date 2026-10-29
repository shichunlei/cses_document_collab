# AppFlowy Editor 切换 Git 依赖

日期：2026-10-29。根包与 example 改用用户指定的 `https://github.com/shichunlei/appflowy-editor.git`，并移除本地 `packages/appflowy_editor/` 副本。

## 来源与兼容性

远端默认分支为 main，本轮读取的 HEAD 为 `9e7593134457eac9193a61ee4023a75de55fcc68`；两个 pubspec 使用相同 URL 和该完整 ref，包版本仍为 6.2.0。

先克隆远端并对比本地 864 个已跟踪文件，再对 pub get 实际安装的 Git 缓存复核：只有 `.gitignore` 不同，运行时源码、测试、资源、补丁和依赖声明均一致。根包与 example 均解析到同一缓存目录。见 [实际依赖检查](dependency-check.json)。未修改 Git 缓存、上游 fork 或其补丁。

两个本地 pubspec.lock 的 source、URL 和 resolved-ref 已由 pub get 更新为 Git；Dart 锁文件依照仓库既有 `.gitignore` 保持不跟踪，未改变其管理规则。完整 ref 在 pubspec 中固定 AppFlowy 自身版本，不依赖被忽略的锁文件来选择分支 HEAD。

## 修改范围

- 根包及 example 的直接依赖改为相同 Git 来源，移除整个本地编辑器副本（864 个已跟踪文件及其本地生成缓存）。
- 异地引用脚本不再要求编辑器目录参数，也不创建 AppFlowy path override；独立宿主直接解析核心包声明的 Git 依赖。
- 同步根/示例 README、接入文档及 AGENTS.md 中当前有效的目录和依赖说明。
- 历史报告中 4 个指向已删除源码的链接改为固定提交的 GitHub blob 链接，保留原报告结论、日期和失败限制。见 [链接变更清单](reference-updates.json)。历史文本、命令日志、JSON 的原始路径和哈希属于当时验证身份，保持原记录，不作为当前可运行路径。
- 更新验证分类索引，原始命令输出沿用按目录限定的空白处理规则。未修改 Dart/Rust 实现、生成桥接或公共 API。

## 验证

- 根包 `flutter pub get --no-example` 及 example `flutter pub get` 均通过，各只改变 AppFlowy 这一项依赖来源。见 [根包解析](root-pub-get.txt)、[示例解析](example-pub-get.txt)。
- 根包 `flutter analyze --no-pub lib test integration_test test_driver`：无 error/warning，有 2 条未改动文件的既有 info：`collab_video_block.dart:265` 的未等待 Future、`collab_controller_native_test.dart:186` 的未关闭 Sink。未顺带清理，见 [根包分析](root-analyze.txt)。
- example `flutter analyze --no-pub lib test integration_test`：无问题，见 [示例分析](example-analyze.txt)。
- 根包适配器、原生历史、输入、列表 Enter/缩进和完整协同页面回归 **227 项通过**，见 [根包测试](root-tests.txt)。
- example 页面、创建服务和协调器回归 **64 项通过**，见 [示例测试](example-tests.txt)。
- 更新后的 `tool/verify_portable_package.sh` 完整运行：复制包到不相关临时目录、重新构建原生库、无 override 解析 Git 依赖，**2 项通过**（原生初始化及 SQLite 重开、独立宿主本地化与编辑页）。见 [异地验证](portable-host.txt)。合计 **293 项测试通过**。
- `bash -n tool/verify_portable_package.sh`、当前源码/配置/接入文档的旧路径与跨包内部 import 检索、最终 `git diff --check` 均通过。没有手写 Dart 改动，不执行无关格式化。

本轮未构建 Android/iOS 安装包或执行真机/在线双端验收。异地验证中的 Cargo 构建仍报告 yrs 的既有 warning；不将警告或未验证平台算作通过。未自动提交或推送。
