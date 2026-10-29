# 未提交代码审查

日期：2026-10-28。审查当前根包、example、Rust 及生成桥接的未提交改动；暂存区为空。未修改产品代码、依赖或在线数据。

## 已复现问题

1. **P2：读取失败后缓存补丁跨读取代次重放。** `DocumentMetadataController._load` 只在成功读取后清空 `_remoteDuringRead`。首轮读取期间收到名称 A，随后请求失败；下一次读取已经返回更新的名称 B，仍会重放 A 并显示旧名。缓存应只覆盖其所属读取期间的事件，新读取不能把开始前的旧事件当成比结果更新的证据。
2. **P2：图标/封面并发写入没有冲突补读。** `applyRemotePatch` 只为名称设置 `_writeConflict`。本地图标写入等待确认期间收到远端新图标，随后旧请求确认会再次应用本地 patch，覆盖已接收的新值且不重读。封面分支有相同控制流。应逐字段检测冲突并在确认后读取权威结果。
3. **P2：冲突补读期间可覆盖写入任务引用。** `_save` 在等待补读前将 `saving` 设为 false，允许第二次 `save` 替换 `_writing`；第一轮完成时无条件清空 `_writing`，丢失尚未完成的第二轮写入。随后 `close()` 可以在第二次请求确认前完成，违反端口借用资源的关闭顺序。应保持整轮互斥，或按任务身份清理并等待全部在途写入。

## 验证依据

临时探针从 `/tmp/cses_pending_review_test.dart` 运行，使用公开控制器、可控 Future 和模拟业务端口，不访问网络或原生引擎。三个期望正确行为的测试全部失败，分别得到：

- 新 HTTP 名称应为 `newer HTTP`，实际为 `earlier WS`。
- 权威图标应为 `remote final`，实际为 `local`。
- 第二次确认前关闭不应完成，实际已经完成。

探针日志见 [pending-changes-review-probes.log](pending-changes-review-probes.log)，源码文本见 [pending-changes-review-probes.dart.txt](pending-changes-review-probes.dart.txt)。将源码文本复制为 `/tmp/cses_pending_review_test.dart`，在根包运行 `flutter test --no-pub /tmp/cses_pending_review_test.dart --reporter expanded` 可复跑。临时探针不是正式回归测试，未加入产品测试目录。以上为可控端口下的竞态复现，不代表真实双端或真机验收。

现有根包 `document_metadata_controller_test`、`collaborative_editor_page_test`、`collab_presence_identity_native_test` 共 45 项通过；含真实本地原生库的四种在线身份恢复用例。补充 `cses_doc_collaboration_session_test` 和 `document_header_test` 共 36 项通过；example 的 `cses_document_creation_service_test` 和 `document_creation_coordinator_test` 共 62 项通过。合计 143 项通过。

五个核心改动文件的 `flutter analyze --no-pub` 返回 1 条 info：`document_metadata_controller.dart:73` 的 if 缺少大括号，未报告 warning/error。Rust `cargo fmt --check` 和最终 `git diff --check` 通过。本轮未重新生成桥接、运行 cargo check/完整 Rust 测试、构建平台产物或做真机/在线双端验收，不把历史归档的通过状态作为本轮新结论。

本轮只新增审查报告、探针源码文本、失败日志及分类索引链接，保留原有工作区改动。
