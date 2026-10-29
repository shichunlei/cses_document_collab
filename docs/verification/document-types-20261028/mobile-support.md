# 移动端文档类型支持范围

核对日期：2026-10-28。本文保留实施前的核对结论；当前类型解析与打开分流见[实施验证](implementation.md)。静态读取当前工作区（含SaaS尚未提交的原生接入），不代表已发布安装包状态；本轮未执行设备、在线业务或运行时验收。

## 结论

| 桌面类型 | 当前移动原生能力 | 边界 |
|---|---|---|
| text 在线文档 | 重点支持，具备正文/格式、插入删除、历史、本地存储和协同基础；SaaS已有独立原生路由及权限、头部和互动接入 | 非完整桌面功能；SaaS列表仍走WebView，AppBar协同编辑进入原生页；首次打开需在线鉴权，冷启动离线授权缓存未提供。Demo具备文本新建，但不能推断SaaS新建初始化闭环已完成 |
| inspiration 感悟 | 对兼容BlockCraft普通正文可复用文本编辑能力，但没有按inspiration类型独立创建、模板切换、类型分流及完整业务闭环 | 桌面感悟模板与独立内容组合、render-unit等高级能力不能推断移动已支持；Demo今日导向是独立宿主业务，不等于桌面感悟类型已接通 |
| attachment 附件 | 文本正文中的附件块可展示名称/类型/大小并打开；Demo有选取上传，SaaS原生Binding未注入上传扩展。WebView附件卡片可交资源模块打开 | 独立attachment文档的类型/meta解析和路由未接通；应用内下载管理及Office内容编辑未实现 |
| sheets 电子表格 | 未接入独立工作簿原生引擎及路由 | 正文table块支持不等于sheets；公式计算、工作表管理等未接入 |
| mindmap 思维导图 | 未接入独立文档原生查看/编辑链路 | JSON mind-map引用/显式树及Mermaid mindmap均不能替代Vectra/文件格式文档；正式mind-map块仍占位保护 |
| whiteboard 白板 | 未接入独立Vectra画布及类型/meta.mode分流 | JSON对象渲染不等于正式画布；正式shape/object-group/placement-layout等仍未接入 |
| ppt 演示文稿 | 未接入文档库PPT原生编辑器和独立类型路由 | 其他业务的PPT播放或通用文件打开不能算本类型完整支持 |

历史image/video/audio/pdf/excel/word/other也没有按DocumentType接通专门分流；已有正文媒体块及通用资源打开只覆盖相应资源能力。

当前SaaS DocInfoEntity/DocListEntity未解析documentType与meta；Demo DocumentListEntry同样未解析类型。请求接受documentType字符串、记录能列出、存在通用WebView入口，均不能证明对应格式原生支持。其H5实际预览依赖网页和后端，本轮未验收。

## 正文功能与宿主差异

42种正式块仍是13已适配/28部分支持/1结构支持，JSON覆盖全部不表示在线完整支持。正式路径缺shape、shape-text、word-art、object-group、placement-layout、render-unit、task-list、mind-map；修订存在时仅预览。依据[完整性核查](../block-adaptation-audit-20261027/report.md)，本轮读取Rust/Dart相关投影与资源实现，没有重新运行历史测试。

SaaS原生Binding已注入元数据、锁权限、点赞/全文评论、图片预览与段落链接；上传、人员/会议/任务等扩展未注入，不能照搬Demo能力声明。代码存在不作为发布或真实服务联调通过依据。

## 源码依据

- [SaaS入口及限制](../../../../cses/cses.saas/lib/modules/doc/CLAUDE.md)
- [原生Binding](../../../../cses/cses.saas/lib/modules/doc/presentation/editor/binding.dart)
- [双详情导航](../../../../cses/cses.saas/lib/modules/doc/routes/navigator.dart)
- [列表实体](../../../../cses/cses.saas/lib/modules/doc/domain/entity/doc_list.dart)
- [详情实体](../../../../cses/cses.saas/lib/modules/doc/domain/entity/doc_info.dart)
- [WebView附件转资源](../../../../cses/cses.saas/lib/modules/doc/presentation/preview/logic.dart)
- [Demo文本创建](../../../example/lib/src/service/cses_document_creation_service.dart)
- [附件块](../../../lib/src/editor/collab_attachment_block.dart)
- [附件外部打开](../../../lib/src/editor/collab_resource_block_base.dart)

## 版本与验证

本轮重新通过桌面配置仓库查询latest，ENOTFOUND，最新稳定版待核对。桌面声明/Yarn0.11.31、实际安装0.11.17、历史pnpm0.2.78保持。结合本轮及前一问题已读取的安装版和本机留存0.11.31随包L0/MIGRATIONS，并补查app指南和宿主相关实现；没有升级依赖，没有新增移动端能力，其他上游差异继续待同步。

仅新增核对记录，运行链接存在检查与git diff --check；不把旧测试结果当成本轮通过。
