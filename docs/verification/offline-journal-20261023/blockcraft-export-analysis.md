# 今日导向导出桌面 BlockCraft JSON 的转换分析

日期：2026-10-23。结论：可以增加一个独立的纯数据转换器，将今日导向实时正文导出为桌面 `root` 快照。当前已启用的正文文字格式、用户提及及普通待办内容/勾选状态均有对应表示；不能直接将 `JournalDraft.toJson()` 改几个字段名作为最终结果。当前尚未实现此导出器，本轮仅分析。

需区分三个目标：数据可以保存、桌面可以显示/操作、往返移动端后业务语义仍完整。标准文字/用户/普通待办有现成对应；栏目、关闭栏目、当地日期和业务条目需要额外契约，才能达到后两个目标。不能将“可保存在 JSON 的未知字段”称为桌面已支持。

## 1. 正文与栏目

当前保存结构是 `JournalDraft` 业务封套 → `document.document` → `page` → `local-journal-section` → 文本叶块。桌面导出结构是单个 `{id, flavour:'root', nodeType:'root', props, meta, children}`。

建议面向现有桌面渲染器，将可见栏目按原顺序展开为“栏目标题段落 + 原正文块”。今日记录、感悟、自检的标题当前由栏目 Widget 绘制，没有保存在子段落文字里，转换时要显式生成；不将 `local-journal-section` 当作已注册桌面 flavour。若必须维持可折叠/可关闭的同款栏目交互，需另行约定现有容器的准确 Schema 或增加桌面能力，不能凭相似外观直接套用某个块。

原始 `section` 键、草稿 ID、YYYY-MM-DD 记录日期、UTC 建档/修改时间、时区偏移、模板版本可放入约定的命名空间元数据，或与快照一起由独立业务封套保存。命名空间例如 `meta.mobileGuidance` 只是建议，当前没有实现或桌面识别契约。严格要求顶层为桌面根块时，不能再包一层移动端 `document`。

只导出可见栏目。`guidance_closed_sections` 是关闭栏目恢复备份，应继续由本地草稿保存；若目标是完整备份，应明确另存为备份附件/独立字段，不能悄悄混进可见正文。日期按用户所选 YYYY-MM-DD 保存，不根据 UTC 时间重新推算。

## 2. 块类型和属性映射

| 移动节点/字段 | 桌面目标 | 保留边界 |
|---|---|---|
| `paragraph` | `paragraph` / `editable` | `data.delta` 转为 `children` |
| `heading` + `data.level` | `paragraph` + `props.heading` | H1～H6原级别；不创造 heading flavour |
| `bulleted_list` | `bullet` / `editable` | 保留缩进；手机固定圆点与桌面按层级符号可能不同 |
| `numbered_list` | `ordered` / `editable` | 需转换连续组、起始号、重启语义 |
| `todo_list` | `todo` / `editable` | `checked:true/false` 转成 `1/0` |
| `align` | `props.textAlign` | center/right/justify/distributed保留；左对齐可省略 |
| `cses_collab_indent` / `cses_paragraph_depth` | `props.depth` | 普通段落优先读取段落包装值；列表读独立缩进通道，不把栏目结构算作缩进 |
| `cses_paragraph_<key>` 中的 `{"value":...}` | 对应 `props.<key>` | 按已支持白名单解包；不能复制包装字符串到桌面props |

有序列表需特别处理：手机 `buildJournalNumberMarker` 对同栏目内连续 numbered_list 分组，从首项 `number` 开始。桌面编号扫描不一定被同级普通段落截断。因此每个手机连续组的首项应设置明确的 `start` 及 `continuePrevious:false`，后续项按目标编号规则生成。不要只把每行显示编号当 `order` 直接保存并期待桌面插件不重算。跨栏目、普通段落分隔、手动起始号和缩进均需验证。

AppFlowy `Node.toJson()` 不包含 node.id，`Node.fromJson()` 重新分配 ID。单次独立快照可生成全新唯一块 ID；如果导出用于反复覆盖同一份桌面文档或双向更新，则必须新增持久稳定 ID 策略，不能把当前内存 node.id 当作跨重开稳定身份。业务 `guidance_entry_id` 也不是所有正文块的 ID。

## 3. 文字格式

| 今日导向实际 Delta 属性 | BlockCraft Delta 属性 |
|---|---|
| `bold` | `a:bold` |
| `italic` | `a:italic` |
| `underline` | `a:underline` |
| `strikethrough` | `a:strike` |
| `code` | `a:code` |
| `font_color` | `s:color` |
| `bg_color` | `s:background` |
| `cses_superscript` | `a:sup` |
| `cses_subscript` | `a:sub` |
| `t:px`、`t:fs`、`t:ff`、`t:ls` | 沿用相同键；仅当前配置允许出现的字段进入正常导出 |
| 已校验的旧 `s:fontSize` 等兼容值 | 可按桌面原义保留；不是本日记当前允许新写的字段 |

注意原始 AppFlowy JSON 的颜色键是 `font_color`/`bg_color`，不是 Rust 中间模型使用的 `textColor`/`backgroundColor`。颜色值 `0xAARRGGBB` 必须转 CSS `#RRGGBB` 或 `rgba(...)`，保留透明度；原有效 CSS 可保留。

当前字号菜单写入 `t:px`，可原样保留数值；不要把手机系统文字缩放、标题倍率或最终布局后的像素值再次乘进去。段落 `fs/pfs/lh/psb/psa` 等来自对应包装字段，缺省/null/显式覆盖的语义要保持。若遇 `textDefaults`，其中字符键也要遵循桌面字符约定与颜色规则，不应把提及身份当作默认字符格式。

当前 journalConfiguration 开放加粗、斜体、下划线、删除线、代码、字色、背景、字号、上下标和人员提及；未开放字体/倍率/字距菜单、链接、行内公式、行高和下一段样式。不能把当前不存在的数据算作已完整支持。若后续开放链接，对应 `href → a:link`，需补充验证。

保持分段、换行和所有文字，不经纯文本/Markdown/HTML中转，不机械追加末尾换行，不删除空段落。无属性的文本与有格式文本分别转换；显式 false/null 不能通过“仅复制真值”偷偷变成继承默认样式。未知字段应报告，避免静默丢失。

这些字段能够保存格式语义。手机纸张默认16px、2倍行高、正文色由 Widget 配置提供，不一定出现在正文JSON里；如目标是接近手机视觉，可明确设置桌面root默认fs/lh/color，核对目标Schema。纸张横线、封面、标签颜色、系统字体及平台排版不属于正文格式逐项同构的保证。

## 4. 人员提及

当前新提及保存为一个 U+FFFC 及 `cses_inline_mention`（显示名）、`cses_mention_id`（身份）、可选 `cses_mention_type`、`cses_mention_attributes`（原始属性JSON）。转换时通过公开 `EditorUserMention.read` 校验，然后把每个对象字符转为：

```json
{
  "insert": {"mention": "张三"},
  "attributes": {"mentionId": "user_demo_001", "mentionType": "user"}
}
```

同时合并该对象上有意义的文字格式，保留经校验的原始引用属性，规范化ID/类型别名并处理冲突，不能丢弃原JSON中的已知身份字段后声称完整保留。一个run内若合并了多个U+FFFC，应拆成对应数量的独立对象，每个对象在两端都占一个UTF-16位置。普通文字中的“@张三”不能自动升级为真实用户引用。

历史 `guidance_mention` JSON 也须兼容：`type:user` 可转换到同样的用户对象。该历史字段允许 `type:department` 并可含部门名称，而桌面当前提及点击分派仅明确支持user/doc/task/meeting；部门不能伪装成user。可保留可读部门文本及扩展身份元数据，或约定并实现部门对象；未实现前明确报告降级，不能宣称部门交互无损。原生人员工厂本就不保存头像、部门和职位，导出无法补回来源里没有的信息。

标准用户ID、姓名、类型可以完整保存，桌面人员卡片/头像与点击结果仍依赖其宿主服务、账号企业和权限。格式转换本身不发送提醒或创建业务。

## 5. 待办与业务行

存在两套不同数据：

1. 普通 `todo_list` 使用 `checked`，转换为 `flavour:'todo'`、`props.checked:0/1`，正文仍逐段保留格式与用户对象。普通待办文本和勾选状态有标准对应；移动端没有桌面 `created` 时不可捏造任务创建时间，可缺省并保留确知来源时间。
2. 带 `guidance_entry:'task'` 的本地业务行使用 `guidance_done` 和稳定 `guidance_entry_id`。典型段落可转为桌面todo以保留可勾选交互，另存业务种类/ID/状态，便于回转；这是拟议映射，桌面尚无该业务契约。

`help`（都来帮）和 `pilot`（领航员）不能一律转为todo，否则会混淆业务含义。建议标准段落保存富文本与人员引用，使用可读业务标签及约定扩展元数据保留类型/ID/done；若希望桌面继续显示同款标签、编辑和业务提交，则必须接入桌面已有业务合同或增加支持。

类型转换已允许保留业务属性，所以同一个 `todo_list` 还可能带 `guidance_entry`，标准checked与guidance_done是独立状态。两者不同或业务类型与块语义冲突时，需要明确优先级/扩展保存并报告；不能简单布尔或运算、覆盖任意一方。更不能把本地entry ID当后端任务ID并自动生成桌面task-card、派单或通知。

## 6. 建议实施与验收

宿主新增明确命名的导出器（例如 `JournalBlockCraftExporter`，当前尚不存在），负责栏目与业务映射；通用文字/人员/块序列化若跨宿主复用，可放协同包并通过公开入口暴露，宿主不直接导入包内部src。既有Rust正式文档适配逻辑可作为格式依据，但不要为了生成JSON打开原生全局文档、SQLite或WS会话。

导出步骤：完成当前输入事务/中文合成 → 深拷贝实时编辑树及业务身份 → 校验 → 生成ID及标准块 → 转换格式/对象/编号 → 记录需降级或无法映射项 → 独立编码。不要读取500ms去抖前的磁盘草稿，异步文件写入结果也不能标记或覆盖另一份草稿。写文件/分享与HTTP业务提交仍由宿主各自处理。

必要验收包括：全部已启用文字格式的组合和清除、颜色alpha、固定字号与缩放、H1～H6、五种对齐/缩进、列表分组编号、中文/emoji/换行空段、多对象run、同名不同用户、旧引用/部门、两类待办状态及业务属性冲突、关闭栏目、跨时区日期、重复导出ID策略；再用目标安装版及拟采用发布版的Schema和桌面只读/编辑渲染验证。若承诺往返无损，需加反向转换测试及桌面编辑后再导回的验证，光检查JSON可解析不足以证明。

本轮未实现转换器或界面、未生成转换结果、未发业务请求，未运行Flutter/Rust测试或构建，也未做真实桌面加载、点击和双端往返验收；上述为源码分析结论和待实施要求。

## 7. 版本与依据

本轮按桌面`.npmrc`实时查询，返回 latest=0.11.23、integrity=`sha512-hGuC0Ank4stAQqbgfVdTYZaKtTi1dOHopT0Bt1YYQqleHkPBsFiXy6mnwf3E2OpEfcZ3UQaUhKeShArMuOtabw==`，与前轮校验的发布包一致。根声明/Yarn锁0.11.28，安装0.11.17，历史pnpm0.2.78；未升级。沿用已读随包L0/数据/适配指南/MIGRATIONS的同指纹产物，补读当前段落/列表/颜色/提及实现与移动端对应声明。三版基础树序列化一致，.23/.28段落工厂比安装.17增加部分属性归一化，不能把同一树外壳理解为全功能已兼容。详见[桌面格式分析](../document-json-export-20261023/report.md)及其[source-comparison.json](../document-json-export-20261023/source-comparison.json)。

源路径与指纹见[本轮核对](blockcraft-export-analysis.json)。关键代码：

- [草稿和配置](../../../example/lib/src/daily_guidance/journal_draft.dart)、[业务引用/行](../../../example/lib/src/daily_guidance/guidance_entries.dart)、[编号绘制](../../../example/lib/src/daily_guidance/journal_list_markers.dart)、[界面默认样式](../../../example/lib/src/daily_guidance/journal_surface.dart)。
- [AppFlowy字符键](https://github.com/shichunlei/appflowy-editor/blob/9e7593134457eac9193a61ee4023a75de55fcc68/lib/src/editor/block_component/rich_text/appflowy_rich_text_keys.dart)、[Node序列化](https://github.com/shichunlei/appflowy-editor/blob/9e7593134457eac9193a61ee4023a75de55fcc68/lib/src/core/document/node.dart)。
- [公开人员读取](../../../lib/src/editor/editor_user_mentions.dart)、[段落属性](../../../lib/src/model/collab_paragraph_style.dart)、[已有正式格式映射](../../../rust/src/api/collab.rs)、[正式颜色转换](../../../rust/src/api/blockcraft.rs)。
- [桌面人员对象转换](../../../../cses-client/packages/docs/src/editor/reference-interactions/mention/mention-embed.converter.ts)、[点击分派](../../../../cses-client/packages/docs/src/editor/reference-interactions/mention/index.ts)。

本次未改变正式块适配状态，41种及13已适配/14部分支持/1结构支持/13未适配保持，其他差异继续待同步/验收。
