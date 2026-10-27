# 标题范围统一为 H1~H6

日期：2026-10-25。范围为当前移动端仓库、两份本地编辑器包及其宿主消费者。用户要求从文档说明继续落实到代码，不保留可配置、可创建或可导出的七至九级标题能力。

## 实现

- `EditorConfiguration` 的默认与正式文档预设均只包含 1～6；自定义级别超范围抛 `ArgumentError`。菜单、类型转换、快捷输入和本地事务沿用同一配置。
- 协同适配器将正数旧标题投影限制到 H6，反向快照只产生 `heading_1`～`heading_6`。原生正式文档与旧草稿使用同一投影规则；只打开或无变化回放不会改写旧的共享 `props.heading`。
- Rust 写入类型白名单移除高于六级的类型，段落属性补丁只接受 0～6 的整数（0 为正文）。非法类型、属性或计数器标题级别在事务开始前拒绝。编号标题计数器按 0～6 投影；不修改无关的深度规则。
- 桌面 JSON 导入将超范围正标题按 H6 呈现，显式导出输出 1～6，不修改传入快照、正文、身份或未知属性。AppFlowy 标题工厂的扩展属性不再绕过六级限制，旧节点渲染及 HTML/Markdown 导出同样限制六级。
- 原有正向九级回归改为 H6，新增配置、命令、直接事务、撤销/重做、旧数据无回写、JSON往返、导出、原生拒绝原子性与 SQLite 重开用例。高于六级的数值只作为越界/旧数据输入保留在负向测试中。
- 字号期望夹具通过原有 `generate_heading_typography_oracle.mjs` 生成，不手改生成文件；期望范围从九级调整为六级，保留其桌面来源和哈希。README、适配表及分类索引同步。

本轮未修改 FRB 接口或生成桥接文件。原生库通过 `cargo build` 重建后执行真实桥接测试。旧共享数据不做启动迁移；主动 JSON 导出或明确类型转换可以将标题写为六级，读取兼容与主动写入不同。

## BlockCraft 版本核对

通过桌面项目 `.npmrc` 配置仓库重新查询，`latest=0.11.30`；桌面根声明和 Yarn 锁定为 0.11.28，实际安装为 0.11.21，历史 pnpm 锁为 0.2.78。首次受限网络查询被本地代理连接权限阻止，提权重试成功；最新版发布产物 SHA-512 与本轮注册表 `dist.integrity` 一致，见 [版本记录](blockcraft-version.json)。未升级桌面依赖。

读取安装版、.28/.30 随包的 L0、迁移说明、排版指南及实际字号函数。三版用于六级标题的语义缩放和段落字号优先级一致；这不表示整个包的实现相同。移动端按用户要求限定 H1~H6，并保留旧超范围数据的读取兼容；对象动画、组合文档、图片 gap 及其他桌面版本差异不在本轮验收范围。

## 验证结果

| 检查 | 本轮结果 | 证据 |
|---|---|---|
| Rust `cargo check --offline` | 通过；既有 vendor/yrs 警告保留 | [日志](rust-check.txt) |
| Rust `cargo test --offline` | 193 通过，0 失败/忽略 | [日志](rust-tests.txt) |
| Rust `cargo build --offline` | 成功重建当前宿主动态库 | [日志](rust-build.txt) |
| Rust `cargo fmt --check` | 通过 | [日志](rust-fmt.txt) |
| 协同包目标回归 | 172 通过，1 项既有菜单测试失败 | [日志](package-tests.txt) |
| 真实 FRB/SQLite | 9 项全部通过，无跳过，包含本轮新增 H6 与越界原子拒绝用例 | [日志](native-tests.txt) |
| AppFlowy 标题关联回归 | 19 项全部通过 | [日志](appflowy-tests.txt) |
| 宿主消费者 | 39 项全部通过，覆盖 JSON、标题格式、业务身份与制图页面 | [日志](host-tests.txt) |
| 协同包目标静态分析 | 无问题 | [日志](package-analysis.txt) |
| AppFlowy 目标静态分析 | 无问题 | [日志](appflowy-analysis.txt) |
| 宿主 daily_guidance/image_composer 分析 | 无问题 | [日志](host-analysis.txt) |
| 格式及范围 | 已运行修改文件的 Dart 格式化；撤回纯格式噪声，保留既有文件布局。`git diff --check` 通过；新证据仅去除行尾空白，不改变断言/输出结论 | 本报告与代码差异 |

首轮新增回归有错误的测试 API 调用（历史栈长度、异步返回值及 HTML 导出返回类型），修正后通过，未调整生产行为或放宽边界断言。保留 [包初次日志](package-tests-initial.txt)、[AppFlowy 初次日志](appflowy-tests-initial.txt)、[AppFlowy 第二次日志](appflowy-tests-second.txt)、[初次静态分析](package-analysis-initial.txt) 和 [初次 Rust 格式检查](rust-fmt-initial.txt)。

唯一仍失败的测试是 `editor_toolbar_configuration_test.dart` 的 `menu choices cannot reenable disabled block and format capabilities`：其配置没有关闭默认 `lineHeight`，却要求布局菜单完全消失。使用 `git archive HEAD` 提取原协同包源码和原测试，在临时目录独立依赖配置下执行同名用例，复现相同断言失败，见 [HEAD 基线日志](baseline-menu-test.txt)及[提交与指纹](baseline-validation.json)。该隔离副本复用已安装的依赖，未改当前工作区；本轮不修改此无关菜单规则，不把失败描述为通过。

工作期间另有默认字号预设相关改动进入工作区；已保留，不归入本轮标题实现。当前目标检查面对的是包含这些改动的实际源状态。

本轮核对的实现和测试指纹见 [source-hashes.json](source-hashes.json)。

## 复现

在 `rust`：

```sh
cargo fmt --check
cargo check --offline
cargo test --offline
cargo build --offline
```

在 `仓库根 package`：

```sh
flutter test --no-pub test/heading_level_limits_test.dart test/editor_configuration_test.dart test/editor_toolbar_configuration_test.dart test/editor_shortcut_toolbar_test.dart test/appflowy_block_editor_adapter_test.dart test/heading_typography_test.dart test/blockcraft_json_editing_test.dart test/blockcraft_json_integrity_test.dart
flutter test --no-pub test/blockcraft_native_integration_test.dart
```

在 `packages/appflowy_editor`：

```sh
flutter test --no-pub test/new/block_component/heading_block_component test/plugins/markdown/decoder/heading_markdown_decoder_test.dart test/mobile/toolbar/mobile/toolbar_items/heading_mobile_toolbar_item_test.dart
```

在仓库根目录：

```sh
flutter test --no-pub example/test/daily_guidance/journal_blockcraft_editing_test.dart example/test/daily_guidance/journal_blockcraft_codec_test.dart example/test/daily_guidance/journal_blockcraft_integrity_test.dart example/test/image_composer/image_composer_page_test.dart example/test/daily_guidance/journal_format_toolbar_test.dart
```

本轮没有执行完整 Android/iOS App 构建、物理设备或真实在线桌面双向验收。42 种块及 13 已适配/28 部分支持/1 结构支持/0 未适配的统计保持；本轮只收敛标题范围，不把版本核对或部分数据兼容视为全链路兼容完成。
