# 桌面文档名称保存与同步核对

日期：2026-10-28。仅分析现有实现并运行现有测试，未修改产品代码、依赖或在线数据。

## 同步链路

1. 正文上方标题通过 `[(title)]="docName"` 保存输入草稿，失焦调用 `onTitleBlur → onRename`；面包屑编辑在失焦或 Enter 后调用同一保存方法，Escape 取消。页面还在离开等场景尝试保存。
2. `DocumentPage.onRename` 要求当前用户是实际 owner 且 `abilities.rename !== false`；名称 trim、未变不请求、已有名称不允许清空，保存中阻止重复提交。调用 `EntityService.modifyDocMeta(id, { name })`，POST `/doc/document/modify`。
3. HTTP 成功后，发起页面更新 `docDetail.name`、`docName`、当前面包屑及独立文档标签页标题；失败恢复旧输入。请求代次和文档 ID 检查阻止切换后的响应更新新页面。
4. 服务端 `ModifyDocumentInfoHandler` 鉴权、修改并保存业务实体，发布 `EditDocumentEvent`；其处理器发布 `DocNodeChangedEvent`。Socket 消费者调用 `DocSocketChanges.node`，向文档主题发送 `metadataChanged`，向父目录主题发送 `childrenChanged`，并更新最近访问/编辑相关主题。视图读取器按实际接收会话生成文档详情/列表数据，名称位于 `body.data.name`。
5. `DocsRealtimeService` 订阅 `{ channel: 'Document', topic: documentId, instance: '' }`，解析消息、去重、过滤较旧投递序号。`EntityService.watchRealtimeChanges` 转为现有 `entitiesUpdate$` 流；文档页收到当前文档的 `metadataChanged` 后合并数据并调用 `applyDocumentName`，列表和目录树按 ID 合并实体。
6. 重连后重新订阅并清除投递序号；文档页通过 `refreshAfterReconnect → initData` 重读详情补齐断线变化。普通 metadataChanged 直接合并推送快照，不逐条发 HTTP 查询。

名称属于宿主文档业务实体字段，不写入 BlockCraft 根块 props、Y.Text 或正文增量，因此不使用正文 Yjs 的字符合并与撤销链路。不能仅凭正文协同已连通推断文档名称也会更新。

另一个入口是列表/目录的实体详情改名：`EntityDetailDialogComponent.onNameInputBlur` 使用相同 modify 接口，成功后额外主动发出 `entitiesUpdate$` 的 name 更新；文档页面的 `onRename` 本身只直接更新当前页面，其余列表依赖实时推送。

## 源码依据

- [标题触发模板](../../../../cses-client/src/pages/docs/pages/document/document.page.html)、[保存、回显与接收推送](../../../../cses-client/src/pages/docs/pages/document/document.page.ts)。
- [业务接口与列表通知](../../../../cses-client/packages/docs/src/entity-catalog/entity.service.ts)、[实体详情改名](../../../../cses-client/packages/docs/src/entity-catalog/components/entity-detail-dialog/entity-detail-dialog.ts)。
- [Document订阅与去重/重连](../../../../cses-client/packages/docs/src/realtime/docs-realtime.service.ts)、[消息字段解析](../../../../cses-client/packages/docs/src/realtime/docs-realtime.util.ts)。
- [列表合并](../../../../cses-client/packages/docs/src/catalog/components/file-table/file-table.ts)、[目录树合并](../../../../cses-client/packages/docs/src/catalog/components/resource-tree/resource-tree.ts)。
- [服务端修改入口](../../../../cses-java/server/src/main/java/org/cses/server/service/doc/services/document/handlers/ModifyDocumentInfoHandler.java)、[编辑事件处理](../../../../cses-java/server/src/main/java/org/cses/server/service/doc/event/handler/EditDocumentEventHandler.java)、[Socket变化投递](../../../../cses-java/server/src/main/java/org/cses/server/service/doc/common/socket/DocSocketChanges.java)、[接收者视图](../../../../cses-java/server/src/main/java/org/cses/server/service/doc/common/socket/DocSocketViewReader.java)。

## 验证与边界

桌面仓库执行以下现有定向测试，5个套件、60项全部通过，无失败或跳过：

```sh
yarn test --runInBand --runTestsByPath \
  src/pages/docs/pages/document/__tests__/document-title-rename.test.ts \
  src/pages/docs/pages/document/__tests__/document-breadcrumb-rename.test.ts \
  packages/docs/src/__tests__/docs-realtime.service.test.ts \
  packages/docs/src/__tests__/docs-realtime.util.test.ts \
  packages/docs/src/catalog/components/resource-tree/__tests__/resource-tree.test.ts
```

覆盖名称规范化、空标题、失败恢复、权限、面包屑、标签页、消息解析、去重/乱序、连接替换/重连和资源树合并。测试使用隔离环境/模拟传输；本轮未操作真实 Tauri、真实后端改名或在线双端，不宣称生产全链路验收通过。无 Dart/Rust 产品源码改动，不运行其格式化/静态分析/构建。

## BlockCraft 版本核对

从桌面目录按配置仓库实时执行 `npm view @ccc/blockcraft@latest version dist.tarball dist.shasum --json --prefer-online --fetch-retries=0 --fetch-timeout=15000`，使用独立临时缓存，返回 ECONNRESET（socket hang up），最新稳定版待核对。

本轮实际读取：桌面声明/Yarn锁 0.11.31，安装 0.11.17，历史 pnpm 锁 0.2.78，未升级。读取安装包及本机留存 0.11.31 发布包的随包 L0、数据层说明与 MIGRATIONS，并核对本次宿主名称/实时消息实现；留存包不作为实时 latest 依据。名称同步由宿主业务链路承担，本轮不扩大块适配/移动端验收范围，42种及13已适配/28部分支持/1结构支持/0未适配统计保持，既有上游差异继续待同步。
