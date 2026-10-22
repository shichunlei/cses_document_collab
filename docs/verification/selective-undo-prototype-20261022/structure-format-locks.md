# 第二阶段：结构、格式选择性撤销与锁权限预检

后续接入状态见[第三阶段：FRB与Flutter历史/选区](frb-editor-history.md)；下文保留本阶段当时的实现和验证结论。

日期：2026-10-22。接续[第一阶段](report.md)，仍为默认关闭的 Rust 原型；未新增 FRB API、修改生成文件或替换手机编辑入口。原有协同与离线控制器继续使用原实现。

## 实现范围

- `history_commands.rs`：原生段落和 callout 插入、完整子树删除、段落/callout 移动；行内加粗/斜体/下划线/删除线/代码/上下标/链接、颜色及排版字段；段落 heading/depth/textAlign、textDefaults、nextParagraphStyle 和 fs/pfs/lh/psb/psa/decoration 的字段级补丁。清除字段与显式 null 区分，未知 props/meta 不整体替换。
- `history_policy.rs`：新会话默认只读，宿主用正式 root ID 注入当前 can_write，根身份不能重绑。每次本地命令、undo、redo 验证当前权限、完整可达图、目标和祖先锁，以及被移动/删除子树的所有隐藏锁。本人锁和模板锁同样阻止正文编辑；解锁由现有独立权限链路负责。本原型不能通过属性补丁修改锁或元数据，含修订记录的文档仍拒绝直接改正文。
- `history_prototype.rs`：每组受影响 ID 与移除保护值保存在原生 StackItem 的元数据上，undo/redo 对应迁移；没有依赖平行索引数组。Yrs 自动跳过过期项时，持久化前检查所有被消费组，不能越过被锁定的旧组。拒绝时权威历史不弹栈。

结构入口限制为 root/callout 子级；移动仅开放 paragraph/callout，拒绝 root、自循环、越界、重复/失鲜 ID 与专用容器。表格行列、媒体题注、块拆分/合并等专用编辑语义未开放；没有把通用数组修改声称为全部块 Schema 适配完成。

## 持久化与选择性冲突

仍以“只读源状态 → 独立候选执行 → 当前权限/锁和候选结构复查 → SQLite INSERT+COMMIT → 整体交换正文及历史”提交。本地、远端、undo/redo 任一写入或 COMMIT 失败，都不改变权威 CRDT、向量、两个带元数据的栈、接受计数及已有数据库行，解除故障后可重试。

独立字段/子树变化保留远端正文、格式和未知属性；真正同时发生的兄弟插入也经过双端收敛验证。远端已覆盖的同一段落属性不会被本地旧撤销覆盖。竞争移动导致重复引用时返回 `HISTORY_STRUCTURE_CONFLICT`。撤销本地建块或重做删除若会移除远端后来贡献的文字/属性/子块，也返回冲突并保留历史，而非强行删去贡献。可达图和锁检查同时覆盖源与候选恢复后的图，拒绝非法、缺失、重复与循环引用。

冲突策略是明确拒绝并保留可审查状态，尚无 UI 冲突恢复入口，也不把任意竞争结构自动合并视为已完成。

## 隔离的原生检查点扩展

第一阶段通过文字相对位置校正 ID，不能覆盖 Y.Map 项、格式标记及整块恢复。本阶段改用复制 V1 内容后，在独立候选中保留原始 `Item.redone` 关联。无需重放旧命令、重建可见投影或重新生成历史 CRDT 身份；原生 UndoManager 算法与线上的 V1 格式未修改。

扩展位于 `rust/vendor/yrs-history`，基于锁定的 crates.io Yrs 0.27.4 源码，仅增加 `history_checkpoint.rs` 与 gated 模块。原始手写源码哈希、确切上游提交/包 checksum 与同提交 MIT LICENSE 来源见 `UPSTREAM.json`，边界见 `LOCAL_CHANGES.md`。其余原始 Rust 源码保持逐文件哈希一致。检查点复制原有 Options，拒绝 GC、非 UTF-16 与子文档；候选存储、订阅及资源独立，只有被接受的候选可以产生外发结果。

别名 `yrs-history` 只用于开发测试或显式 `history-prototype` feature。正式 `yrs` 仍为 registry 0.27.4；[默认生产依赖树](stage2-production-dependencies.txt)没有 vendored 路径依赖。Cargo.lock 由 Cargo 更新，仅增加该独立同版本路径包身份。默认宿主原生构建通过，既有 Flutter 原生测试继续运行真实宿主库。

## 验证

| 检查 | 结果 | 证据 |
|---|---|---|
| 主包 Rust 全量 | 169 通过，0 失败/忽略；原型累计62项，本阶段新增32项 | [stage2-rust-tests.txt](stage2-rust-tests.txt) |
| 检查点所属 crate 独立测试 | 2 通过，382 项无关上游测试未执行 | [stage2-checkpoint-tests.txt](stage2-checkpoint-tests.txt) |
| Flutter 协同/生命周期/远端历史、离线输入/命令、锁与段落样式目标回归 | 32 通过，0 失败/跳过 | [stage2-flutter-regressions.txt](stage2-flutter-regressions.txt) |
| 主包格式、默认/feature 静态检查；独立扩展 crate check | 通过 | [命令和退出码](stage2-rust-checks.json) |
| 默认宿主原生构建 | 通过，原型未启用 | [stage2-rust-build.txt](stage2-rust-build.txt) |
| 扩展声明/文件格式 | 通过 | [stage2-checkpoint-format.txt](stage2-checkpoint-format.txt) |
| 整个上游 fork 的 cargo fmt --check | 失败，限原始 observer.rs 和 sync/protocol.rs 的既存格式差异；原始0.27.4同命令也失败，未批量格式化无关源码 | [fork检查](stage2-vendor-format.txt)、[原始基线](stage2-upstream-format-baseline.txt) |

路径依赖会显示原始上游代码的58条编译警告（库测试75条），主要为未使用项与省略生命周期；原型代码未引入对应警告，未通过关闭 lint 或无关清理掩盖它们。最终源码哈希、上游差异核对、格式基线及范围见 [stage2-validation.json](stage2-validation.json)。

新增回归覆盖多轮插入→删除→恢复、富文本整子树恢复、相同属性反复撤销、远端同键覆盖/其他键保留、显式 null/字段删除、格式与远端补字及同标记覆盖、真正并发兄弟插入、跨父移动、竞争移动拒绝、删除远端贡献拒绝、祖先/本人/模板/隐藏锁、redo 权限变化、过期栈项跳过不能绕过旧锁、撤权后所有命令拒绝、默认只读与根身份绑定、修订保护、非法结构与孤立目标。五类新命令各执行 INSERT/COMMIT 两类故障，命令及其 undo/redo 共30次失败注入，逐次核对精确状态、重试和重开恢复。第一阶段400步文字混合回归保留通过。

探索阶段有一项双端断言误将完整 V1 编码字节作为收敛条件；原生 redone 阻止合并结构片段，因此编码可不同但 CRDT 身份、删除集合和共享值相等。保留[当时失败记录](stage2-exploratory-replica-encoding.txt)，最终测试改为同时核对 Snapshot（向量+删除集合）、原生共享图及具体文字/格式行为；失败时权威状态精确字节不变的断言仍保留。

Flutter 命令为第一阶段六个测试文件，加 `test/block_lock_native_test.dart` 与 `test/paragraph_style_native_test.dart`，使用 `flutter test --no-pub --reporter expanded`。本轮未改 Dart 源或 FRB 签名，无需再生成桥接；工作区其他任务新增的日记功能、Demo和依赖配置均保留，没有将其计入本阶段实现范围。未暂存或提交。

## 版本与未完成范围

本轮重新读取桌面 `.npmrc` 配置并直接验证仓库元数据，latest=0.11.27；声明/Yarn 锁0.11.24、实际安装0.11.17、历史pnpm0.2.78，未升级。核对安装、声明和latest随包技能、MIGRATIONS、DocUndoManager锁预检与 callout/paragraph/格式字段，仍保留菜单/只读链接/CSES UI peer 等上游差异待同步；41块13/14/1/13统计不变。证据见 [本轮版本核对](stage2-blockcraft-registry.json)。

原型仍默认关闭，未接 FRB、Flutter历史端口、手机菜单、相对选区或IME分组；这些接入必须继续验证宿主权限刷新及锁预检。跨重启只恢复内容，不恢复个人历史。尚需容量/GC/压缩与性能指标，整Doc复制及全图扫描不适合未经测量就用于大型正式文档。未运行真实服务/桌面在线双端、物理手机或新增 Android/iOS App 构建，不把本轮原生/Widget回归等同于线上或设备验收。
