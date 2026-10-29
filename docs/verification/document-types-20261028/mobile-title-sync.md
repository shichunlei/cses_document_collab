# 手机端文档名称同步适配核查

日期：2026-10-28。延续[桌面链路核对](title-sync.md)，检查共享编辑器包、Demo 和 SaaS 原生文档接入。仅核查、运行现有测试和归档，未修改产品代码、在线文档或依赖。

## 结论

**部分适配：已有改名写入和当前编辑器回显，尚未适配桌面同等的名称实时接收及跨页面列表同步。**

| 场景 | 当前实现与限制 |
|---|---|
| 手机编辑器内改名 | 支持。公共头部弹窗提交 `DocumentMetadataPatch.rename`，Controller 等待业务成功后合并名称并通知页面；AppBar 和头部读取该名称。SaaS 与 Demo 均调用 `/doc/document/modify`。 |
| 手机改名后桌面更新 | 手机具备调用同一正式业务接口的发送路径，服务端可沿既有事件/Document消息链通知桌面；本轮未做真实双端在线验收。 |
| 桌面改名后手机前台实时更新 | 未接入。共享会话仅注册六种 collab 消息；SaaS 与 Demo Gateway 透传这些回调，没有 metadataChanged 处理，也没有独立空 instance 的元数据订阅/消费者。正文增量不能携带业务名称。 |
| 重新打开/恢复前台/重连后读取新名称 | 有补读。初始化调用 header.refresh；SaaS 宿主在 resumed 和主连接 ready 后 refreshAccess 并重读 header；Demo 前台恢复/显式重连读取权限及 header。它们不能代替前台持续在线时的实时名称通知。 |
| 手机列表菜单改名 | 来源页面支持刷新。首页、收藏、共享、文件夹等页面消费 renamed 结果后重读列表。 |
| 编辑器改名后返回首页/收藏列表 | 没有完整自动同步。头部改名只更新 Controller 的业务快照；编辑器更多菜单操作后只 refreshAccess 当前文档。首页/收藏的 onDocumentTap 不等待导航结果后重读，也未发现名称变更领域事件或 childrenChanged/metadataChanged 列表监听，可能继续展示旧名，需列表刷新。 |

本结论限定当前 Flutter 原生编辑器与本地列表源码。保留的 WebView 页面由其网页实现负责，不把其可能具备的同步能力算作原生已适配。

## 关键源码依据

- [公共头部保存](../../../lib/src/editor/document_header.dart)、[名称Controller](../../../lib/src/controller/document_metadata_controller.dart)、[页面标题绑定](../../../lib/src/editor/collaborative_editor_page.dart)。
- [共享会话回调清单](../../../lib/src/sync/cses_doc_collaboration_session.dart)：start 仅登记 collabSync、collabUpdate、collabAwareness、collabSyncStatus、collabError、collabClose；初始化头部读取见 [CollabController](../../../lib/src/controller/collab_controller.dart)。
- [SaaS元数据适配器](../../../../cses/cses.saas/lib/modules/doc/infrastructure/collaboration/doc_collab_metadata_adapter.dart)、[业务写入](../../../../cses/cses.saas/lib/modules/doc/infrastructure/doc_repository_impl.dart)、[Gateway](../../../../cses/cses.saas/lib/modules/doc/infrastructure/collaboration/doc_collab_gateway.dart)、[宿主恢复补读](../../../../cses/cses.saas/lib/modules/doc/presentation/service/doc_collab_host.dart)。
- [SaaS编辑器更多动作](../../../../cses/cses.saas/lib/modules/doc/presentation/editor/page.dart)、[首页列表及导航](../../../../cses/cses.saas/lib/modules/doc/presentation/home/logic.dart)、[首页来源改名刷新](../../../../cses/cses.saas/lib/modules/doc/presentation/home/page.dart)、[收藏列表导航](../../../../cses/cses.saas/lib/modules/doc/presentation/favorite/logic.dart)。
- [Demo业务接口](../../../example/lib/src/service/cses_document_metadata_service.dart)、[Gateway](../../../example/lib/src/demo/common_cses_collab_gateway.dart)、[恢复补读](../../../example/lib/src/demo/document_host.dart)。

对共享包、Demo、SaaS文档模块和Common手写Dart检索 metadataChanged/childrenChanged，仅命中移动目标树算法中的普通局部变量 childrenChanged，没有这两个Socket action的解析与消费者；结合回调注册清单和头部端口只有load/update，确认当前缺口。

## 本轮验证

现有定向测试共67项通过，无失败/跳过：

- 共享包30项：[日志](mobile-title-sdk-tests.log)。执行 `flutter test --no-pub test/document_metadata_controller_test.dart test/document_header_test.dart`；涵盖ACK回显、失败保留旧值、刷新竞态、身份、权限和弹窗行为。日志内network failure堆栈来自明确的保存失败测试。
- SaaS28项：[日志](mobile-title-saas-tests.log)。在SaaS包执行 `flutter test --no-pub test/modules/doc/collaboration/doc_collab_metadata_adapter_test.dart test/modules/doc/collaboration/doc_editor_application_service_test.dart test/modules/doc/collaboration/doc_collab_host_test.dart test/modules/doc/collaboration/doc_collab_gateway_test.dart`；覆盖元数据/业务接口、宿主关闭与授权、Gateway登记生命周期。
- Demo9项：[日志](mobile-title-demo-tests.log)。在example包执行 `flutter test --no-pub test/cses_document_metadata_service_test.dart`；覆盖HTTP字段、权限、业务失败及账号变化。

这些是已接入能力的回归证据，不能证明尚未实现的metadataChanged/childrenChanged链路已通过。未新增测试或产品代码，未做真机、真实后端或在线双端验收，不运行Dart/Rust改动专用格式化、分析和原生构建。

## 版本核对

重新从桌面配置仓库查询 `@ccc/blockcraft@latest`，独立临时缓存返回ECONNRESET，最新稳定版待核对。实际声明/Yarn锁0.11.31、安装0.11.17，未升级；沿用本轮已读取的安装版与留存0.11.31随包L0、数据说明、MIGRATIONS并核对本次受影响实现。留存包不作为实时latest证据。本轮不修改块协议，42种及13已适配/28部分支持/1结构支持/0未适配统计保持，既有上游差异继续待同步。
