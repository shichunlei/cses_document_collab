# 第三阶段历史接入代码审查

日期：2026-10-22。结论：**发现 5 项可复现缺陷（2 项 P1、3 项 P2），建议修复后再提交历史接入变更。** 本轮没有修改业务、Rust、FRB 或 Flutter 实现。

后续修复见[5项问题修复与回归](review-fixes.md)。本文保留审查时的触发条件、失败证据与历史结论，当前修复状态以该记录为准。

## 范围与基线

审查 Rust 生产历史及持久化、Yrs 检查点/相对位置扩展、FRB、Flutter 编辑器委托、投影/选区/输入连接、权限与协同握手的关联调用。包含未跟踪的新历史源码和测试，不仅检查 `git diff`。未审查其他会话的日记/今日导向业务迁移。前轮验证清单的 30 个源文件哈希在本次审查时全部匹配；全量测试通过仍是有效历史记录，但未覆盖下述场景，不能据此声明功能无回归。

BlockCraft 通过桌面配置仓库重新查询 latest=0.11.28；桌面声明/Yarn锁0.11.24、安装0.11.17、历史pnpm0.2.78。首次受限查询DNS失败，允许只读访问后重新查询成功；已缓存发布产物sha512与当前元数据一致。复核随包技能、MIGRATIONS、历史/选区文档和实现，见[版本证据](review-blockcraft-version.json)。未升级桌面、未改变41块及13/14/1/13统计。

## R1 — P1：新建空草稿段落后的首次输入被丢弃/拒绝

位置：[document_history.rs](../../../packages/cses_document_collab/rust/src/api/document_history.rs) 第232～236行，关联第413～425行和 `collab.rs` 第465～475行。

空的 legacy `Y.Text` 根没有内容可进入V1复制。候选历史manager初始scope因此不含该段落文字根；本地适配器在建立订阅后才声明并写入这个根，`commit_local_history` 又在写入结束后才扩scope。若这次只输入文字，没有新StackItem，`new.is_empty()`直接返回成功，未持久化或安装有真实文字变化的候选。

实际公开入口复现：`CollabController.localDraft` 初始化 → 插入一个空段落并将光标放入 → 输入 `hello`。FRB外层按旧权威Doc生成非零after-selection时抛 `INVALID_HISTORY_SELECTION: offset`，控制器回退输入并进入错误状态。原生直接调用也证明返回了非空update但权威文字仍为空。应在写入前覆盖新增/空文字根，且不能把“没有捕获历史项”视为“没有真实更新”。

证据：[公开控制器测试源码](review-empty-draft.dart.txt)、[失败日志](review-empty-draft.txt)、[原生补充测试](review-native-cases.rs.txt)、[原生失败日志](review-empty-rust.txt)。

## R2 — P1：撤销恢复光标时断开了正在使用的输入连接

位置：[collab_controller.dart](../../../packages/cses_document_collab/lib/src/controller/collab_controller.dart) 第687～691行；关联第315～316、346～348和696～698行。

恢复选区时 `_historyExecuting` / `_projectionPending` 仍生效，`editorState.editable=false`。AppFlowy键盘服务在选区通知中调用 `canInputAt`，判断不可输入后执行 `textInputService.close()`。稍后仅恢复editable，没有再次发送选区或重新绑定输入。

真实FRB页面测试先建立有效文本输入连接，再直接 `await owner.undo()`（不点击按钮，排除焦点被按钮抢走）。正文和UTF-16光标恢复正确、最终editable=true，但 `hasAnyClients` 从true变false，平台调用包含 `clearClient` / `hide`，需重新点正文才能接续输入。应协调输入暂停与选区/输入连接恢复的顺序；不能仅以光标值与editable为验收断言。

证据：[测试源码](review-input-connection.dart.txt)、[失败日志](review-input-connection.txt)。

## R3 — P2：表格删行撤销后，无远端变化也无法重做

位置：[document_history.rs](../../../packages/cses_document_collab/rust/src/api/document_history.rs) 第515～517行；误判发生于第344～345行。

表格删除会将节点归档，而非物理移除map。`meta.removable`优先保存 `next`，其中包含 `meta.csesMobileTableDeleted=true`。Undo恢复可达节点并清除该标志后，Redo仍用删除后的原指纹检查，因仅归档标记的差异就误判存在远端贡献。

使用现有 `blockcraft-table.update`，删除第一行及其单元格/正文 → Undo恢复原文成功 → Redo稳定报 `HISTORY_STRUCTURE_CONFLICT: remote contributions in body-0-0`，全程无远端更新。应按操作方向保存删除前可见内容的保护值，或在构建inverse时正确更新保护指纹，同时继续保护真正远端贡献。

证据：[原生补充测试](review-native-cases.rs.txt)、[失败日志](review-table-redo.txt)。

## R4 — P2：远端投影暂停输入被误判为永久撤权

位置：[collab_controller.dart](../../../packages/cses_document_collab/lib/src/controller/collab_controller.dart) 第675～677行。关联 `collab_host_mention_ui.dart` 第59～60行、会议选择器以及表格/Mermaid弹窗的 `_revoked`。

`_queueProjection`无条件临时将editable置false，但现有消费者把这个Notifier作为权限撤销信号，且为避免迟到提交会永久作废进行中的操作。这样普通远端正文变化也会永久禁用选人/会议确认或编辑弹窗，即使更新发生在其他块、权限从未撤销。

真实控制器打开宿主选人 → 收到独立peer的普通prefix更新 → 投影后控制器与editor均恢复可编辑，但借出的 `canEdit` 永久false，返回有效用户也被转换成null。应将临时事务串行化与真实权限撤销分开，保持真实撤权时的失效保护。

证据：[测试源码](review-picker.dart.txt)、[失败日志](review-picker.txt)。

## R5 — P2：初次协同握手跳过自动编号修复

位置：[collab_controller.dart](../../../packages/cses_document_collab/lib/src/controller/collab_controller.dart) 第539～542行，关联第536行的远端投影。

`onSync`先调用 `_applyRemoteUpdate`，有正文变化时新投影立即令editable=false；紧接的编号修复条件又要求editable=true，因此首次握手载入缺失派生order的列表时不再执行既有修复，也没有在投影结束后补做。

独立Yjs从现有ordered夹具移除a/b/c的order，正常完成collabSync后仍有needsRepair=[a,b,c]；手动调用相同原生快照修复才变为空。应在保持只读/预览不写入的前提下，调整修复顺序或投影结束后重新核对权限并补发修复差量。

证据：[测试源码](review-numbering.dart.txt)、[失败日志](review-numbering.txt)、[输入夹具](review-numbering-seed.update)、[生成源码](review-numbering-seed.js.txt)。

## 验证与复现

4项Flutter场景及2项原生测试（空段落在两层交叉验证）均产生预期断言失败。3项Flutter复现由父审查再次直接捕获真实exitCode=1，未使用 `; cat logfile` 的包装退出码。原生失败日志为断言失败，不是缺依赖或缺库。命令、哈希和环境见[审查证据清单](review-evidence.json)。

运行Flutter复现时，将归档的 `.dart.txt` 复制为对应 `/tmp/*.dart`，从 `packages/cses_document_collab` 目录执行清单中的单个命名测试。编号测试须将归档seed复制为 `/tmp/review-ordered-missing.update`。使用已有真实本机动态库；SDK访问需要当前环境允许其正常使用缓存，受限启动失败另行记录，不算功能测试结论。

原生补充测试须在临时Rust crate副本中追加至 `src/api/document_history_tests.rs`，其辅助函数由既有测试模块提供，再按完整测试名过滤执行。源码、fixtures、vendor与manifest保持副本，避免修改工作区。未把这批失败复现并入正式测试，留待用户选择修复时补入回归。

对检查点另做2500轮文本插入/删除、Undo/Redo的分支差分，原文档与fork的可见文字和完整V1字节全部一致；该范围未发现独立checkpoint问题，见[源码](review-checkpoint-differential.rs.txt)、[日志](review-checkpoint-differential.txt)。这不替代大文档性能、输入法、物理手机或真实在线双端验收。本轮没有重新跑完整包测试，也没有修改/提交实现。
