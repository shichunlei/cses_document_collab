# 两项标题兼容 P1 修复

日期：2026-10-25。对应 [review.md](review.md) 中的两项 P1，仅修复旧标题拆段拒绝及旧列表计数器误合并。P2 的非 paragraph JSON heading 导出问题保持待修复；低层模型 API 观察也未扩展为本轮改动。

## 修复结果

1. `collab_paragraph_editing.dart` 在生成新段落属性时，将标题节点的可见级别同步到新节点 `level` 与 `props.heading`，限制为 H1~H6；其他段落族的新建数值 heading 同样规范到 0～6。仅修改新节点的独立属性副本，原块的旧值、身份及正文保留。段首插入、段中拆分、段尾 same 续写及 body 回落均覆盖。
2. `blockcraft.rs::ordered_projection` 恢复使用原始 `depth + heading` 作为计数器 key，保留旧数据的分组与边界；对外 `CollabOrdered.heading` 仍是 0～6 的展示投影。握手修复只补真实缺失/错误的 order，不以裁剪后的展示值重建旧组。

Rust 原生接口和 FRB 签名未变化，未修改生成桥接代码；按现有流程重新构建宿主动态库后运行真实桥接测试。未修改 P2 相关 JSON 编码实现。

## 回归与数据保留

- 新增的 5 个真实控制器用例在修复前全部复现失败，见 [修复前日志](p1-fix-before-tests.txt)。
- 3 个旧标题用例分别覆盖段首、段中、段尾；经真实握手、拆段、原生撤销重做及 SQLite 重开，原块仍保存旧 heading=9，新块保存 heading=6，正文完整且新身份稳定。
- 2 个旧编号组用例分别使用编号正确和编号缺失的 Yjs 文档，包含原始 heading 为 7/8/7 的三个组项。握手、重同步、普通文字编辑、原生撤销重做及重开后编号始终为零基 `[0,0,1]`；原始级别不被修改，派生展示投影仍为六级。
- Rust 双副本回归另验证无变化回放、缺失 order 的真实修复、文字增量交换、原始 heading、未知 props 与 meta 作者字段保留。
- 18 项编辑器边界用例覆盖三个旧级别、三个光标位置及 same/body 两种下一段策略。
- 可携带已知删除集的 Yjs 增量不一定编码为 `[0,0]`。新增测试首轮曾错误使用此字节值判断“没有写入”，已改为比较状态向量及原始共享属性是否变化；未修改生产增量编码或放宽原有数据保留断言。保留 [首次原生关联日志](p1-fix-native-tests-first.txt)、[首次 Rust 日志](p1-fix-rust-tests-first.txt)及[首次静态分析](p1-fix-analysis-first.txt)。

## 最终验证

| 检查 | 结果 | 证据 |
|---|---|---|
| Rust check | 通过，既有 vendor/yrs 警告保留 | [日志](p1-fix-rust-check.txt) |
| Rust 全量测试 | 194 通过，0 失败/忽略 | [日志](p1-fix-rust-tests.txt) |
| Rust 宿主动态库构建 | 通过 | [日志](p1-fix-rust-build.txt) |
| Rust fmt check | 通过 | [日志](p1-fix-rust-fmt.txt) |
| 标题、回车、输入、编号及工具栏关联回归 | 149 项通过 | [日志](p1-fix-editor-tests.txt) |
| 控制器、FRB、段落、编号、SQLite关联回归 | 36 项通过，无跳过 | [日志](p1-fix-native-tests.txt) |
| 宿主 JSON、标题格式及身份完整性回归 | 30 项通过 | [日志](p1-fix-host-tests.txt) |
| 目标静态分析 | 无问题 | [日志](p1-fix-analysis.txt) |
| 格式与差异 | 修改的 Dart 文件已格式化；`git diff --check` 通过 | 本轮差异 |

没有重跑与本轮无关的全包菜单失败；上一轮 HEAD 已复现的禁用菜单用例仍按其历史结论保留，不能将本轮定向通过解释为全仓测试通过。

## 夹具与复现

新增样本由 `tool/generate_legacy_heading_fixtures.mjs` 使用桌面已安装 Yjs 13.6.19 生成，保存于包自身 `rust/tests/fixtures`，不依赖宿主业务或根目录证据。生成清单 `legacy-heading-fixtures.json` 保存每份增量的 SHA-256 和准确服务端状态向量。不会改动桌面依赖、真实文档或账户。

```sh
# 在协同包目录，重新生成夹具时显式提供桌面依赖根目录。
node tool/generate_legacy_heading_fixtures.mjs /Users/shichunlei/workspace/cses-client
cargo fmt --check --manifest-path rust/Cargo.toml
cargo check --offline --manifest-path rust/Cargo.toml
cargo test --offline --manifest-path rust/Cargo.toml
cargo build --offline --manifest-path rust/Cargo.toml
flutter test --no-pub test/heading_p1_native_test.dart test/paragraph_style_native_test.dart test/ordered_numbering_native_test.dart test/blockcraft_native_integration_test.dart
flutter test --no-pub test/heading_level_limits_test.dart test/paragraph_style_test.dart test/paragraph_input_test.dart test/collab_ordered_test.dart test/editor_shortcut_toolbar_test.dart
```

本轮重新查询配置仓库，latest 仍为 0.11.30，桌面根声明/Yarn 锁为 0.11.28，安装版为 0.11.21。复核随包技能、迁移及 `resolveNextParagraphStyle`、原始列表计数器实现；未升级依赖。首次受限代理查询失败，提权后查询成功。

42 块及 13 已适配/28 部分支持/1 结构支持/0 未适配的统计保持。本轮未执行完整 Android/iOS App 构建、物理设备或真实在线双端验收。当前只关闭两项 P1，不能据此关闭 P2 或其他桌面版本差异待办。
