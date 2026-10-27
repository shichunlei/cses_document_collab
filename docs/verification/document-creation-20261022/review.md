# 新建文档提交前审查

> 后续状态：R1、R2、R3已在本轮修复并补回归；修复内容、最终验证与限制见[修复记录](review-fixes.md)。下文保留修复前审查结论及复现依据。

日期：2026-10-22。结论：暂不建议提交，先修复以下三项。审查未修改业务代码、未暂存或提交。

## R1 / P1：无正式 ID 的挂起记录没有恢复出口

位置：`example/lib/src/demo/document_creation/document_creation_coordinator.dart:106–113、132–135、217–219`。

`_save`先替换内存记录再等待落盘。首次`creating`记录写入失败时，建档 HTTP 尚未发送，但内存中已经存在无docId的挂起操作。存储恢复后，`start`因`pending`拒绝；`resume`因缺少docId拒绝。临时测试确认HTTP调用次数为0，第二次start仍返回null，未能恢复。

真实创建请求超时会将`createUnknown`持久化，重新登录/重启仍只能进入上述拒绝分支。页面提示“在文档库核对”，但当前API、持久化端口和页面没有核对后绑定已知文档、确认未创建或结束该操作的入口，因此该账号后续的新建都会被阻止。禁止盲目重发是合理的，但必须提供核对后的可恢复状态转换。

建议：区分“请求尚未发送”与“请求结果不明”；前者落盘失败恢复后允许安全重试，后者提供人工核验/服务端查询后的明确解决入口，保留原操作追踪信息。覆盖首次记录失败、超时后重启及人工解决后的下一次创建。

## R2 / P1：已有正式文档打开依赖权限 HTTP 成功，且失败后无法恢复

位置：`example/lib/src/demo/document_host.dart:234–245`，关联初始化及恢复分支。

新代码在创建CollabController、恢复SQLite之前等待`editableFor`。权限接口暂时不可用或离线时，已有本地正文也不会打开，回退到`controller == null`首页，正式编辑入口禁用。初始化Future被缓存，生命周期观察者在成功打开后才注册；手动reconnect也只调用可空controller的retry，因此网络恢复后不会重新打开失败的文档。这是已有正式文档本地恢复能力的回归，范围不只新建。

依据为调用顺序与失败分支的源码核对；本轮没有编写/运行完整宿主离线集成复现。现有入口Widget测试使用localDraft，不能覆盖这条正式文档分支。

建议：让已有缓存恢复不被瞬时权限读取失败永久阻断，可先以受限状态恢复缓存，再按明确授权切换；初始化失败须有重试打开当前docId的路径。覆盖有缓存离线打开、权限服务暂时失败后恢复及明确撤权。

## R3 / P2：初始化重试仅比较 state vector，漏检仅删除的修改

位置：`rust/src/api/document_bootstrap.rs:111–115`。

Yjs/yrs的state vector不包含删除集合。临时原生测试先初始化，再用仅删除的Y.Array更新移除初始段落引用，并落盘。此时state vector保持不变，模型仍能通过现有validate，但当前根已经没有段落。相同参数再次prepare仍成功返回旧的“根+一个空段落”快照，与本地正文不一致，违背公开准备接口对既有正文变化的拒绝契约。该问题在准备接口再次被调用时触发，不意味着正常创建流程每次都会触发。

建议：使用包含删除状态的初始化内容/完整CRDT状态校验，或同时核对当前可达初始树及删除集合，确保只删除、替换、插入修改都被识别；不能仅凭state vector推断正文未变化。

## 本轮验证

- `flutter test example/test/document_creation_coordinator_test.dart example/test/cses_document_creation_service_test.dart`：29通过。
- 临时Dart复现：首次creating记录写入失败，确认建档调用为0；恢复存储后二次start应成功的断言失败，实际仍为null，确认R1。临时文件位于仓库外，未改现有测试。
- 临时Rust复现：复制crate到系统临时目录，追加只删除初始段落引用的测试。vector相同、当前块数为0、模型validate通过；再次prepare应拒绝的断言失败，确认R3。仓库内Rust源码未修改。
- 原仓库`cargo test --manifest-path rust/Cargo.toml document_bootstrap::tests`：既有4项初始化测试通过，另102项未在本轮重跑。
- 补充复现的失败输出见[日志](review-probes.txt)。
- `git diff --check`通过。
- 本轮未重复执行前次已记录的全量Rust、协同包目标、平台构建和数据层互通；前次通过结果不覆盖本轮补充边界。
- 真实HTTP、实际桌面/手机在线双端及服务端落库ACK仍未验收；iOS完整App仍受既有SwiftPM依赖解析阻塞。

## BlockCraft版本复核

桌面配置仓库重新查询`npm view @ccc/blockcraft@latest version --json`：0.11.27。桌面根声明/Yarn锁定为0.11.24，实际安装0.11.21。复核随包技能、迁移说明及受影响空正文契约；沿用本轮已校验完整性的0.11.24/0.11.27发布产物，不升级桌面或宣称全量兼容。41块及既有支持范围统计不变。
