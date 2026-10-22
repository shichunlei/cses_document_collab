# Rust 历史接入 FRB 与 Flutter 编辑器

后续[代码审查](review.md)复现了2项P1、3项P2，已按优先级修复并补充回归，见[修复记录](review-fixes.md)。下文保留第三阶段最初实现与测试快照，当前结果以修复记录为准。

日期：2026-10-22。第三阶段接续[结构、格式与权限原型](structure-format-locks.md)。本记录描述当前实现；第一、二阶段中“正式引擎仍用 registry Yrs、尚未接 FRB/Flutter”的结论仅适用于当时快照。

## 实现结果

真实 `CollabController` 初始化原生文档后安装 AppFlowy `EditorHistoryDelegate`。页面按钮和既有快捷键继续调用 `undoManager.undo/redo`，由同一个委托进入 Rust；Flutter 不再同时维护一套可回放的路径撤销栈。未初始化的展示替身不安装委托；纯内存 `LocalEditorController` 保留原有历史、配置和离线流程。SQLite 本地草稿与正式协同文档使用原生历史。

FRB 2.13.0 从 Rust 源声明生成 `api/collab/history.dart` 和两侧桥接；未手改生成物。新增同步接口包括启用/更新权限、读取栈可用性、带前后选区的本地快照、Undo/Redo、个人选区书签编解码。原有系统快照入口保留，编号修复、缓存回放及远端整合使用排除的 origin，不进入个人历史，也不清空 redo。

本地输入继续使用现有完整块适配链，不绕到原型限制的 root/callout 指令。原生从候选 Doc 捕获一个 AppFlowy 事务产生的全部 StackItem，合并成一组并附带权限/结构足迹及个人选区。Undo/Redo 在独立候选上执行，检查所有实际消耗组、当前与恢复后锁、受影响子树、未知只读块、图结构和表格规则。删除的子树含远端贡献时拒绝冲突，保留原正文及栈。SQLite INSERT 与 COMMIT 成功后才安装候选 Doc/manager，再投影到 Flutter；发生真实写入/提交失败时不推进正文、历史和 UI。普通文字输入仍沿用既有乐观 UI 和失败回滚，不把它描述成 UI 也等到落盘才出现。

接受候选后重新绑定 legacy maps/order 及 Awareness 的 Doc，保留客户端、时钟和在线状态。新本地编辑清空 redo，远端/系统变化不清空。重复 Undo/Redo 请求共享进行中的任务；重置缓存和关闭等待历史与投影，迟到任务不能访问下一文档。即时发送抛错时，已经提交的历史仍完成页面投影并显示“已保存在本地”；网络成功不等于服务端落库 ACK。

## 选区与输入边界

- 前选区在树变更前捕获。个人书签直接放在拥有它的原生 StackItem metadata 上；Undo 保存当前选区给 redo，反向同理，不维护平行下标数组。
- 文本端点使用稳定块 ID、Yrs StickyIndex 与 UTF-16 偏移，方向保留。投影完成后解析到最新块路径，覆盖远端插字、重排、嵌套端点及逆向范围。端点被删除、不可见或指向错误文本时清除选区，不套用旧路径；跨会话或畸形 token 拒绝解析。
- 修复真实桥接测试暴露的中文/Emoji 光标偏移：Yrs 0.27.4 普通解析在 redone 链上丢失片段内部偏移。隔离扩展增加只读 `get_history_offset`，在每条恢复关联保留 slice.start；不修改上游原生 Undo、Store 核心逻辑或编码。
- `canEdit` 保留文档能力语义；新增 `canAcceptEditorInput` 在历史/投影期间暂缓新输入。页面保持编辑模式和键盘，不因这段临时暂停进入预览。恢复方法不主动抢焦点或唤起键盘。
- token 仅在个人打开会话中使用，不写入共享文档、SQLite 或网络。每个 AppFlowy 事务独立一组，最多 200 组。重启只恢复正文，不恢复个人栈。

## Yrs 来源与发布包核对

正式 Rust 引擎从 registry Yrs 0.27.4 切换为随包 `vendor/yrs-history` 同版本路径依赖，启用 `history-checkpoint`。独立 `history-prototype` 仍是可选原型，Flutter 不调用原型命令。原始 Rust 源 SHA-256 复核仅 `src/lib.rs` 的模块声明不同；功能位于新增 `history_checkpoint.rs`，另有源 Cargo 清单配置及完整 MIT 许可证。`UPSTREAM.json` 和 `LOCAL_CHANGES.md` 记录来源、约束及升级要求。

本轮通过桌面 `.npmrc` 配置仓库无缓存查询，latest 已为 **0.11.28**；桌面声明/Yarn锁 **0.11.24**，实际安装 **0.11.17**，历史 pnpm 锁 **0.2.78**，未替桌面升级。下载并校验 latest tarball 的 sha512，读取随包 SKILL、L0、MIGRATIONS、data/selection 文档与受影响实现，证据见 [版本快照](stage3-blockcraft-registry.json)。

发布包 .28 的 `DocUndoManger` 与 .24/.27 提取片段哈希一致，`SelectionHistoryRestorer` 在 .17/.24/.27/.28 一致；安装版 .17 缺少较新的 history capture continuation。移动端沿用稳定 ID/相对位置和 StackItem 选区思路，不声明已实现桌面的 targeted capture token、跨事务 IME 合组、结构选择、多单元格选择或视图虚拟化恢复。其他对象动画/排版等发布差异保留待同步；41 块及 13/14/1/13 统计保持。

## 验证

命令、退出码、来源哈希及日志索引见 [验证清单](stage3-validation.json)。

| 范围 | 最终结果与证据 |
|---|---|
| Rust 主 crate | `cargo fmt --check`、`cargo check`、本机 `cargo build` 通过；含 prototype 的测试 **182 通过、0 失败/忽略**，其中正式引擎历史回归 13 项。见 [测试](stage3-rust-tests.txt)。 |
| 隔离 Yrs 扩展 | checkpoint 模块 **3 通过**，扩展文件独立格式检查通过；保留上游全包格式基线的两处差异，不能声称该 vendored crate 全量格式检查通过。见 [扩展测试](stage3-checkpoint-tests.txt)、[格式基线](stage3-vendor-format.txt)。 |
| 协同包全量 | **1656 通过、0 失败/跳过**；显式提供桌面与 latest 发布包路径，实际执行可选的手机初始化增量↔桌面 Yjs 互通测试。见 [日志](stage3-cses-full-tests.txt)。 |
| AppFlowy 全量 | **921 通过、0 失败/跳过**，包括外部委托与本地/快捷键历史；全包分析无问题。见 [日志](stage3-appflowy-full-tests.txt)。 |
| Demo 宿主全量 | **123 通过、0 失败/跳过**；通过环境变量指定实际本机动态库，包含权限恢复/关闭原生消费者。见 [精简日志](stage3-host-tests.txt)。 |
| 新桥接/选区/表格目标 | 真实 SQLite 写入与 deferred FK COMMIT 失败下 Undo/Redo 不推进 UI/原生字节/栈，解除故障可重试；文字、格式、远端前缀/重排/删除、锁/宿主撤权、中文/Emoji、页面按钮、重开、关闭与发送异常都有断言。表格既有测试更新为统一可用性与原生历史委托断言，继续实际验证合并、插删行列、布局、撤销/重做及重开。 |
| 分析与格式 | 修改手写 Dart 文件格式、两包目标及宿主关联分析通过。协同包全包分析有 2 条未改动代码的既有 info：video block 第 265 行 unawaited、controller native test 第 186 行 close_sinks；未批量修复无关代码。 |
| 平台构建 | Android 调试 APK 通过，8 个相关 Dart 源在 kernel 中逐字节匹配，含 3 ABI 的 Rust 库，见 [产物](stage3-android-artifact.json)；iOS 真机 arm64、模拟器 arm64/x86_64 原生库与 XCFramework 构建通过。本轮没有重新完成 iOS 整个 App 的 SwiftPM 构建或设备断言。 |

最初全包测试有一项表格断言仍读取旧路径栈，已更新并跑通实际撤销/重做；最初宿主运行未指定动态库目录，5 项因缺库失败，补环境后 123 项全部通过。页面测试的 fake async 关闭/100ms 工具栏定时器需先推进测试帧再等待关闭，不以超时或跳过代替通过。上述探索结果及原始日志哈希保留在验证清单，未将它们重新标为成功。

## 剩余验收与限制

1. 未连接真实服务器或操作物理手机；独立 Yjs 数据层与真实 FRB/SQLite 测试不替代实际桌面/手机在线双端、输入法或服务器落库验收。
2. 本阶段没有专门的长文视口滚动、焦点重建、跨事务 IME 合组、对象/表格范围恢复及跨启动个人历史。
3. 采用全 Doc 候选检查点以维持提交失败原子性；大文档每次编辑的延迟、复制内存及 GC-disabled 历史存储需单独量测，不声明性能验收。
4. 未改动其他会话的离线日记源码、宿主变更、测试和归档；本轮没有提交或推送。
