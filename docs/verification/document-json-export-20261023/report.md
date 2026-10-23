# 桌面文档库 JSON 导出格式分析

核对日期：2026-10-23。仅分析桌面源码并生成虚构示例；未修改运行时代码或桌面依赖。

## 结论与入口

桌面文档页面 `BaseDocumentPage.export(doc, 'snapshot')` 将整篇 BlockCraft 根块快照直接编码为 JSON，文件名使用 `${title}.json`，缩进两格，MIME 为 `application/json`。

调用链为 `doc.exportSnapshot()` → `doc.model.toSnapshot(rootId)` → `stripSelectionCommentAttributes()` → `JSON.stringify(snapshot, null, 2)`。模型图递归导出，不依赖屏幕上是否已挂载块组件。

注意当前 `packages/docs/src/document-preferences/settings-menu/doc-setting-menu.ts` 中的快照菜单项被注释；保留导出方法不代表当前界面已开放 JSON 下载。页面菜单事件交由 `DocumentPage` 的 `case 'export'` 分派。

另一条封装是 `BlockCraftEditorComponent.exportJSON()` → `DocExportManager.exportToJson()`。该管理器先调用 `doc.revisions.projectFinalSnapshot()` 获取修订最终投影，再编码 JSON；页面的 snapshot 分支则直接读取 `doc.exportSnapshot()`。两者的块树格式相同，带修订时内容语义不同，不应把包技能所述的最终投影自动套到页面入口。

## 节点结构

每个块包含 `id`、`flavour`、`nodeType`、`props`、`meta`、`children`。

| 字段 | 含义 |
|---|---|
| `id` | 当前块身份，嵌套块各有自己的 ID；根块 ID 不应自动当作后端文档 ID |
| `flavour` | 具体块类型，例如 `root`、`paragraph`、`todo`、`image`、`caption` |
| `nodeType` | 字符串 `root`、`block`、`editable`、`void`，决定如何读取 children |
| `props` | 块的内容与配置，如缩进、标题级别、勾选状态、资源地址、排版 |
| `meta` | 块元数据，如创建/修改时间、锁、折叠等；可为空对象 |
| `children` | root/block：子块数组；editable：富文本 Delta 数组；void：空数组 |

标题仍是 `flavour: 'paragraph'`，通过 `props.heading` 表示级别。普通段落通常包含 `depth: 0`。待办是 `flavour: 'todo'`，当前 Schema 默认 `checked: 0`，勾选使用 `1`。

富文本不是 HTML 字符串，也不是 `{ops: [...]}` 外壳。editable.children 直接保存插入项，例如 `{insert: '文字', attributes: {'a:bold': true}}`。快照保存当前内容；delete/retain 属于编辑操作，不是完整正文快照应逐条回放的内容。

行内格式使用 `a:bold`、`a:italic`、`a:link` 等属性；颜色示例为 `s:color`。固定字号与倍率等另有 `t:px`、`t:fs`、`t:ff` 等语义属性。旧数据可能保留兼容属性，不应仅为导出自行改名。

桌面人员提及使用 `{insert: {mention: '张三'}, attributes: {mentionId: 'user-demo', mentionType: 'user'}}`。显示名称和实体身份各自保留，不能只留下 `@张三` 字符串。

## 导出范围与其他 JSON 的区别

- 根对象本身就是 `flavour: 'root'` 的块，没有自动添加移动端 `JournalDraft` 的 schemaVersion、日期、账号等业务封套。文件标题来自桌面文档详情，正文一级标题只是示例内容，两者独立。
- 资源通常通过块属性中的 URL/引用保存；JSON 导出分支不会额外打包图片、附件或音视频文件。示例图片地址是虚构地址。
- 划词评论过滤器删除 `d:scGroupId`、`s:--sc-rgb`、`d:scResolved`，不应把协作高亮当正文格式。快照导出不构成评论线程、撤销历史、完整修订记录或整个文档库的备份。
- 任务、会议、KR 等业务块按各自 Schema 保存引用/属性；不能由块快照推断已包含对应业务接口返回的全部详情。
- 底层 Yjs 的 `blocks` map 保存扁平块表及子块 ID；JSON 快照由模型递归恢复嵌套树。二进制协同 update 与此 JSON 是不同表示。
- 模板库存档另有 `children` 裸数组（无根配置）或 `{rootProps, children}`（有根配置）格式，见 `template-snapshot.util.ts`。它不是整篇文档 JSON 导出的根块外壳。
- 移动端本地日记的 AppFlowy document 树和 JournalDraft 封套也不是此格式，需要显式转换。

## 示例与验证

[example.json](example.json) 使用桌面实际安装包的 `RootBlockSchema`、`ParagraphBlockSchema`、`TodoBlockSchema`、`ImageBlockSchema`、`DividerBlockSchema` 工厂生成，覆盖标题、带格式正文、人员提及、待办、图片/题注、分隔线。所有姓名、ID、正文、时间及资源地址均为示例。

[生成器](generate-example.mjs) 将块装入 Yjs map，使用生产 `BlockModelGraph` 和 `BlockCraftDoc.exportSnapshot()` 导出，并断言输出与原始树深度一致，再校验 JSON 编码解码一致。没有创建桌面编辑页面；没有经过下载对话框或验证文件导入入口，不能宣称已完成桌面 UI 导出/导入验收。

执行 `node docs/verification/document-json-export-20261023/generate-example.mjs` 通过；Node 仅报告未配置 localStorage 文件的实验性提示，与本次内存模型检查无关。结果见 [validation.json](validation.json)。

## 版本核对

本轮在桌面目录按 `.npmrc` 的 `@ccc:registry=http://npm.runtongqiuben.com/` 查询，沙箱内首次 DNS 失败，提升网络权限后查询成功，返回 `latest=0.11.23`。这是本轮实测，与历史记录的 0.11.28 不同；没有足够依据解释 tag 变化，未覆盖历史结论。桌面当前根声明/Yarn锁为 0.11.28，实际安装包为 0.11.17，历史 pnpm 锁为 0.2.78。

以本轮 `npm view @ccc/blockcraft@0.11.23 dist --json` 返回的 SHA-512 校验临时目录发布压缩包成功。读取安装 .17、latest .23 及已存在声明版 .28 产物的随包 L0、数据/适配指南、MIGRATIONS 和受影响实现，具体指纹见 [source-comparison.json](source-comparison.json)。.28 在本轮只作为声明版缓存对照，不作为实时 latest。

三版根/段落 Schema、Yjs→原生序列化、exportSnapshot、JSON 编码及管理器最终投影片段一致；可编辑块工厂有差异：.23/.28 相较 .17 增加背景/边框、行高、段前段后、textDefaults、nextParagraphStyle 等属性归一化，基础树外壳不变。本例使用安装版已支持的字段。

未升级依赖、未修改移动端适配范围，正式块 41 种及 13已适配/14部分支持/1结构支持/13未适配统计保持。未覆盖能力继续待同步/待验收，未运行 Flutter/Rust 分析、测试或构建，本轮没有相应源码改动。

## 源码定位

- [桌面 JSON 导出分支](../../../../cses-client/src/pages/docs/pages/document/base-document.page.ts)：`getFilteredDocumentSnapshot`、`export`。
- [桌面菜单](../../../../cses-client/packages/docs/src/document-preferences/settings-menu/doc-setting-menu.ts)：被注释的 `export-snapshot`。
- [包数据类型](../../../../cses-client/node_modules/@ccc/blockcraft/framework/model/index.d.ts)：`BlockNodeType`、`BlockSnapshot`、`InlineModel`。
- [包实现](../../../../cses-client/node_modules/@ccc/blockcraft/fesm2022/ccc-blockcraft.mjs)：`BlockModelGraph.toSnapshot`、`yBlock2Native`、各 Schema、`DocExportManager`。
- [评论过滤属性](../../../../cses-client/packages/docs/src/domain/selection-comment-copy-filter.ts)。
- [人员提及转换](../../../../cses-client/packages/docs/src/editor/reference-interactions/mention/mention-embed.converter.ts)。
- [模板序列化](../../../../cses-client/packages/docs/src/template-library/template-snapshot.util.ts)：`serializeTemplateArchive`。
