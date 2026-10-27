# 根 package / example 结构迁移

日期：2026-10-27。范围：将原 `packages/cses_document_collab/` 提升为仓库根 package，将原根 Demo 移至 `example/`，更新 GitHub 远程地址及工程路径。未提交或推送代码。

后续入口审查发现的 3 项 P2 已修复：核心依赖解析显式跳过 example、设备测试驱动路径统一、宿主测试与生成工具工作目录说明同步。新增验证见 [修复记录](p2-fixes.md)，以下迁移阶段的原始验证与限制继续保留。

## 最终目录与依赖

```text
仓库根目录（package: cses_document_collab）
├── lib/、assets/、android/、ios/、rust/、cargokit/
├── test/、integration_test/、test_driver/、tool/
├── flutter_rust_bridge.yaml、pubspec.yaml、analysis_options.yaml
├── .agents/skills/collab-modal-ui/
├── example/（package: cses_mobile_collab_demo）
│   ├── lib/、assets/、android/、ios/
│   ├── test/、integration_test/、test_driver/、scripts/
│   └── pubspec.yaml、analysis_options.yaml、README.md
├── packages/appflowy_editor/（保留 fork 及其原 example）
└── docs/（历史记录和证据目录保持原位）
```

- `origin` 的 fetch/push 地址均为 `https://github.com/shichunlei/cses_document_collab.git`，`git ls-remote origin HEAD` 成功，返回 `38757450c634c509b16a6301b177f660e645320f`。
- 根 package 通过 `packages/appflowy_editor` 引用 fork；example 分别通过 `..`、`../packages/appflowy_editor` 和 `../../cses/cses.common` 引用核心包、fork 和外部 Common。
- 当前磁盘工作目录仍为 `mobile-collab-demo/`，GitHub 名称与根 package 名称均已采用 `cses_document_collab`。磁盘目录名不参与上述相对依赖解析。
- 包名、公开 API、应用标识、原生库名和缓存命名保持不变。核心源码无反向宿主/Common import；example 不再导入核心 `src/`。

## 实施与保留范围

1. 整体迁移原 package 和 Demo，分别保留插件与应用的 Android/iOS 工程，未重建空白平台模板。根包原有设备测试仍归根 package 管理；应用与设备构建从 example 驱动。
2. 根 `pubspec.yaml` 增加新仓库地址，修正本地依赖路径；保留开始前宿主及 AppFlowy 的 `file_picker: ^13.3.0` 改动。依赖重新解析后使用该约束，不回退用户版本调整。
3. 修正 example 的 iOS 入口、Runner 构建阶段调用到的 Rust framework 位置，以及核心/宿主测试的文档夹具路径。FRB 配置仍以根包为相对基准，无接口或 ABI 变化，无需重新生成桥接。
4. 独立包验证脚本复制根包时排除 `.git`、example、本地 packages、docs 及构建缓存，通过最终宿主的 override 显式提供同一 AppFlowy fork，避免迁移后复制整个仓库或隐含依赖 Demo。
5. 原宿主 WebSocket 测试直接导入内部会话实现；调整为通过公开 `CsesCollabGateway` 契约验证 Common 订阅、发送、精确路由和注销。协同会话状态机继续由根包测试覆盖；未扩大公开导出。
6. 合并根与包内 AGENTS 约定，迁移 modal skill，修正文档、JSON 和相对链接。根 README 维护包接入与开发入口，example README 维护 Demo 启动说明。历史验证目录、截图、原始日志、日期、源码哈希及结论保持原有含义。
7. iOS 首次重建重新解析并自动升级了部分 Swift 依赖，随后恢复迁移前 `Package.resolved`，按原 pins 重新解析和构建；不保留这些无关升级。初轮输出保留于 `ios-build.txt`，最终检查以原 pins 的复验为准。

[完整性清单](inventory.json) 按开始前 2938 个已跟踪文件核对迁移目标，无文件遗漏。189 个核心 `lib` 文件和 75 个 Rust 源文件全部字节相同，包含生成代码；源模型、Schema、事务和资源生命周期未重写。原有未跟踪的 `docs/日成果-2026-10-23-完整文档结构.json` 保留。

## 验证结果

命令输出均在本目录。下列结果仅代表实际执行范围。

| 检查 | 结果与证据 |
|---|---|
| 依赖解析 | 根包 `flutter pub get --offline` 成功，并自动解析 example；AppFlowy 独立解析成功，见 [fork 解析](appflowy-pub-get.txt) |
| 手写 Dart 格式 | 对实际修改的文件按原有行宽运行 format，见 [夹具路径](dart-format.txt)、[Gateway 测试](gateway-format.txt) |
| 核心包静态检查 | 全包范围无 error/warning，保留 2 条既有 info，命令非零退出；见 [全范围输出](core-analysis.txt)。修改的核心测试及公开入口定向检查无问题，见 [定向输出](changed-files-analysis.txt) |
| example 静态检查 | lib/test/integration_test/test_driver 均无问题；Gateway 调整后再次通过，见 [最终输出](example-analysis-final.txt) |
| AppFlowy 静态检查 | lib 无问题，见 [输出](appflowy-analysis.txt) |
| 核心全量测试 | 1922 通过、1 跳过、1 既有失败，整体非通过，见 [全量输出](core-tests.txt) |
| example 全量测试 | 338 通过，见 [输出](example-tests.txt)；随后 Gateway 调整的 2 项专项复验通过，见 [输出](gateway-tests.txt) |
| 桌面初始化互通 | 补齐路径参数后，原先跳过的 Yjs/发布 Schema/手机 SQLite 往返通过，所在文件 3 项通过，见 [输出](desktop-bootstrap-interop.txt) |
| Rust | fmt/check 通过，208 测试通过，见 [格式](rust-format.txt)、[检查](rust-check.txt)、[测试](rust-tests.txt)；核心宿主库重建成功，见 [构建](native-build.txt) |
| 独立临时宿主 | 2 项通过：公开控制器初始化/SQLite 重开、编辑器本地化装配；见 [输出](portable-package.txt) |
| Android | example 调试 APK 构建成功，重建 Android Rust 目标，见 [输出](android-build.txt) |
| iOS | 首轮模拟器应用构建成功；原 Swift pins 解析通过，见 [解析](ios-pinned-resolution.txt)。最终原 pins 模拟器构建通过，锁文件字节与迁移前相同，见 [复验输出](ios-pinned-build.txt) |
| 路径与完整性 | 旧目录不存在；当前源码/配置/Markdown/JSON 的物理路径已迁移；无新增跨层 import；迁移目标文件与文档链接核查见 [结构检查](structure-check.json) |
| 最终差异检查 | `git diff --check`，结果见 [检查输出](diff-check.txt) |

### 既有失败与提示

- 工具栏用例 `menu choices cannot reenable disabled block and format capabilities` 仍失败：测试未关闭默认行高能力，却期待整个布局工具栏隐藏；本次单独复现，见 [输出](toolbar-isolated-test.txt)。它与 [2026-10-25 基线记录](../heading-level-limit-20261025/report.md) 和 [当时 HEAD 复现](../heading-level-limit-20261025/baseline-menu-test.txt) 一致。该测试及相关核心实现均未改字节，未放宽断言或顺带修改产品行为。
- 全包静态检查的 `collab_video_block.dart:265` / `unawaited_futures` 和 `collab_controller_native_test.dart:186` / `close_sinks` 在 [历史记录](../selective-undo-prototype-20261022/frb-editor-history.md) 中已有；本次对应文件字节未变。
- Rust vendor 保留原有 58 条警告；iOS 构建保留 FFI binary package 缺少 FlutterFramework 依赖的工具提示。未为消除既有提示改写无关实现。

## BlockCraft 核对

使用桌面项目配置的包仓库及新临时缓存实时查询，latest=0.11.31。桌面声明/Yarn 锁=0.11.30，本次实际安装=0.11.17，未升级桌面或移动协议。安装版与 latest 随包技能/L0/MIGRATIONS 已读取，latest 发布归档 SHA1 与实时 dist 一致；公开入口、发布 RootBlockSchema 与 Yjs/原生初始化互通按上述范围核对。[版本和指纹](blockcraft-version.json) 已归档，并同步 [版本跟踪](../../block-adaptation.md#blockcraft-版本跟踪)。

本轮没有改变块适配范围，42 种块及 13/28/1/0 统计保持；独立区域组合、对象动画、图片 gap 等既有版本差异与设备/真实在线待办继续保留，不将路径迁移或目标互通通过解释为全版本兼容完成。

## 路径例外与未验证范围

- Flutter 运行时资源键 `packages/cses_document_collab/assets/mermaid/index.html` 是包资源命名空间，不是仓库旧目录，保留实现与对应测试断言。
- 原始日志中的旧路径是历史证据，未重写；`inventory.json` 的 old 字段是迁移映射。[例外清单](historical-path-exceptions.json) 明确这些保留项。历史文档中原有指向未提供服务端仓库、缺失日志的链接单列于结构检查，不宣称原有文档完整性问题已解决。
- 未执行 Android/iOS 真机交互、iOS 真机签名/归档、真实账号在线双端协同。平台结论限于 Android 调试 APK 和 iOS 模拟器应用的构建；Common 路由测试使用本机 Socket。
- 原宿主未触达的历史 UI 声明与设备脚本原样保留，未借结构迁移批量治理旧实现。

## 后续使用

从根目录执行核心测试；从 `example/` 执行 `flutter run`、Android 构建及宿主测试。iOS 使用 `example/scripts/ios.sh`（可从根目录调用该完整路径），脚本自动进入 example 并先准备根包 Rust XCFramework。包内设备测试从 example 执行时使用 `--target ../integration_test/<文件>` 和对应 `--driver ../test_driver/<文件>`。
