# 桌面文档类型核对

日期：2026-10-28。仅静态读取桌面源码，未修改产品代码、依赖或移动端适配状态。

## 类型与入口

- `DocumentType` 共14个字面量：7个主类型 `text`、`inspiration`、`attachment`、`sheets`、`mindmap`、`whiteboard`、`ppt`；7个历史上传兼容值 `image`、`video`、`audio`、`pdf`、`excel`、`word`、`other`。新上传统一使用 `attachment`，具体格式写入 `meta.attachmentType`。
- 主类型展示含义：在线文档、感悟、附件、电子表格、思维导图、白板、演示文稿。
- 当前共享新建菜单实际渲染“文档”、受配置开关控制的“电子表格”和“文件夹”；文件夹是实体类型，不计文档类型。不能把14个声明值都视为可直接新建的编辑器。
- 原生Vectra白板/思维导图共用 `documentType=whiteboard`，以 `meta.editor=vectra-yjs` 和 `meta.mode=whiteboard/mindmap` 区分；`documentType=mindmap/ppt` 走文件预览入口。
- 文件列表当前筛选维度为在线文档、电子表格、感悟、附件。

## 源码依据

- [类型定义](../../../../cses-client/packages/docs/src/domain/entity.types.ts)
- [新建菜单](../../../../cses-client/packages/docs/src/catalog/components/create-menu/create-menu.html)
- [打开路由分派](../../../../cses-client/packages/docs/src/catalog/services/docs-entity-open.service.ts)
- [附件分类](../../../../cses-client/packages/docs/src/catalog/upload/attachment-type.ts)
- [列表筛选](../../../../cses-client/packages/docs/src/catalog/components/file-table/const.ts)
- [Vectra模式](../../../../cses-client/packages/docs/src/domain/vectra-canvas.ts)

## BlockCraft版本核对与限制

按桌面 `.npmrc` 配置仓库查询latest：首次ENOTFOUND，提升网络权限后ECONNRESET，最新稳定版待核对。当前桌面声明/Yarn锁0.11.31、安装0.11.17、历史pnpm锁0.2.78，未升级。读取安装版及本机留存0.11.31发布包的随包L0/MIGRATIONS，并核对桌面类型、菜单、附件与路由实现；缓存0.11.31不作为实时latest依据。文档业务类型由桌面宿主声明，不能由BlockCraft块类型数量推断。

未新增移动端、Flutter/Rust、设备或真实在线验收；42种块及13/28/1/0状态保持，既有上游能力差异仍待同步。纯文档核对，验证为源码读取、链接存在检查和git diff --check。
