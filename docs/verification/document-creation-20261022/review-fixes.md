# 新建文档三项审查问题修复

日期：2026-10-22。对应[提交前审查](review.md)的R1、R2、R3；未暂存或提交。

## 修复结果

### R1：区分未发出的创建与未知结果，提供明确的核对出口

首次创建意图改为成功落盘后才安装到内存。存储失败时未发送HTTP，也不再遗留阻止重试的挂起操作；已获得的正式ID仍沿用先保留内存、再补写恢复记录的策略。

创建超时保持createUnknown，不自动重发。页面要求用户在文档库核对并勾选确认，再点击“结束此次记录”。协调器核对操作ID和账号，将reviewed阶段成功落盘后才解除挂起；不删除服务端文档、不准备正文、不自动再次创建。下一次创建是独立的用户操作。最近记录保留原操作ID及reviewed阶段，下一项创建仍按既有“每账号最近一项”契约替换记录，不新增历史文档库。

人工结束失败保留原挂起操作；旧页面ID、在途请求或账号变化不能结束其他操作。唯一任务在执行回调前安装，同步门禁失败也能解除busy，避免失败Future被重新缓存。

回归同时发现Common的HttpManager.post把传输错误和业务拒绝合并为isSuccess=false。本模块改为借用Common已经配置的Dio及其鉴权/拦截器/地址，保留原始异常和HTTP状态，不新建客户端或修改Common。401/403与显式业务false视为拒绝；超时、网络失败、5xx和异常协议响应保持未知结果，禁止自动重建。

### R2：缓存先恢复，只读等待授权，并提供可重试打开

正式控制器先以editable=false恢复同一SQLite分区，权限读取成为宿主持有的独立任务。即使权限HTTP尚未返回或暂时失败，正文已可只读查看；明确编辑授权后才开放本地写入及缓存补传。已有授权下的瞬时传输错误保留现有权限，明确拒绝撤权。请求期间身份变化同样撤权；恢复主连接前再次检查账号，旧请求不借用新账号连接。

手动重试及前台恢复先刷新HTTPS权限，再恢复WebSocket，授权恢复不依赖Socket就绪。打开控制器前的初始化失败会清理临时协调器并解除失败Future缓存，首页提供“重试打开文档”。初始化失败后仍观察前台恢复。文档切换、关闭等待权限任务结束，迟到结果检查关闭状态及控制器身份。

原生宿主回归使用真实Common HTTP拦截器、公开包入口、FRB和SQLite，HTTP传输使用替身；Common连接只指向本机关闭端口。覆盖缓存先于权限响应打开、瞬时故障后手动恢复、明确拒绝撤权、Socket离线时前台授权恢复、关闭期间的迟到响应、存储失败后重新打开及账号切换期间撤权。

### R3：初始化重试同时核对插入和删除状态

准备接口将已保存向量解码后与当前snapshot.state_map比较，并要求当前snapshot.delete_set为空。初始事务从全新Doc一次插入root与paragraph，不包含删除；因此无需改变SQLite标记结构，也兼容此前只保存initial_vector的记录。

只删除初始段落引用时，向量虽未变化，删除集合也会触发DOCUMENT_BOOTSTRAP_CHANGED。测试同时核对已有正文及SQLite更新数量未被准备重试修改；既有同操作重试、身份冲突、插入修改、事务回滚和根来源冲突回归保持。

Rust变更仅在私有实现，未改变FRB签名或ABI，无需重新生成桥接文件；已重建本机动态库供真实FRB测试使用。

## 验证结果

| 验证 | 最终结果 |
|---|---|
| 宿主关联六个测试文件 | 62通过，0失败、0跳过；包含6项真实宿主/FRB/SQLite权限与生命周期回归 |
| 协同包目标测试 | 21通过，0失败、0跳过，包含0.11.27真实桌面Yjs数据层互通 |
| Rust全量测试 | 107通过，0失败、0跳过 |
| 宿主及协同包目标静态检查 | 无问题 |
| cargo fmt --check / cargo check | 通过 |
| Dart格式 / git diff --check | 9个修改文件最终格式复核无变化，diff检查通过 |
| 本机原生动态库 | 重建成功，真实FRB测试使用本轮产物 |
| Android调试APK | 构建成功；核对嵌入的6个修改Dart源文件与当前工作区完全一致；未运行设备流程 |

最终摘要见[验证输出](review-fixes-validation.txt)，源文件与APK校验及未验收边界见[机器记录](review-fixes.json)。

修复前的三个回归均确认失败，分别为：未发HTTP的首次记录失败仍pending；权限HTTP未返回时控制器为null；只删除更新后重新准备返回旧快照。修复过程中，宿主权限用例曾在setEditable异步完成前断言旧错误已清除，账号竞态用例曾与首轮权限刷新重叠等待另一项请求，现等待完整授权状态和已有刷新完成，并对等待加有界超时；这不放宽权限、正文或生命周期断言。

首次桌面互通使用系统旧Node失败（缺少node:assert/strict），使用明确的Node24路径后通过；没有更改互通测试或降低断言。

## 运行方式

宿主关联测试（本机原生库须先构建）：

```bash
cargo build --manifest-path packages/cses_document_collab/rust/Cargo.toml
FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR="$PWD/packages/cses_document_collab/rust/target/debug" \
  flutter test --no-pub --timeout=90s \
  test/document_creation_coordinator_test.dart \
  test/cses_document_creation_service_test.dart \
  test/document_host_native_test.dart \
  test/collab_demo_page_test.dart \
  test/cses_document_metadata_service_test.dart \
  test/cses_account_login_test.dart
```

协同包真实原生及互通测试沿用[实施报告](report.md)的命令，必须显式提供Node18以上路径；本轮使用Node24、桌面安装Yjs及完整性已核对的BlockCraft0.11.27发布产物。

## 版本及边界

通过桌面配置仓库重新查询latest=0.11.27；桌面声明/Yarn锁定/安装为0.11.24/0.11.24/0.11.21。复核安装版及已校验完整性的.24/.27随包技能、MIGRATIONS、root/paragraph工厂及数据层契约，未升级依赖。41块及13/14/1/13能力统计不变，其他上游差异保持待同步。

本轮没有执行真实业务HTTP建档、实际桌面窗口与手机在线双端或服务端正文落库ACK验收。iOS完整App前次受SwiftPM解析阻塞，本轮未重试该未变化的环境问题，不将本机或Android构建等同iOS完整App通过。
