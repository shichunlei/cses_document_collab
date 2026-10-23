# 今日导向键盘工具栏方案

日期：2026-10-22。当前为方案与源码核对，未实施功能或升级依赖，未运行新功能测试、构建或真机验收。

此处“当前”描述实施前的方案阶段；后续结果以[键盘菜单实施与验证](keyboard-toolbar-implementation.md)为准，保留原方案用于对照。

## 需求口径

按用户最后明确的定义：待办为编辑器原生 Todo 列表，@ 为编辑器原生用户提及；感悟、领航员、都来帮、自检为宿主自定义功能。新按钮不再沿用截图底部“待办先选人”和自定义 @ 的旧动作。

建议工具栏顺序：

```text
T  Aa  @  待办  感悟  领航员  都来帮  自检  │ 收起键盘
              ← 整体可横向滑动 →          │ 固定
```

保留单行高度，原生项使用编辑器图标，自定义项保留名称以便识别。收起键盘固定最右；预览不显示编辑工具栏。实施时建议移除截图下方重复的换行入口；键盘收起时仍可点击正文唤起工具栏。

## 六项行为

| 入口 | 建议行为 |
|---|---|
| @ | 使用编辑器现有用户提及选择与插入流程，工具栏和键入 @ 共用一条链路。沿用原生用户范围和表现，不继续调用旧日记多选提及动作。 |
| 待办 | 当前段落或符合既有条件的选中段落转为 Todo 列表，保留正文、栏目归属和选区；复用 T 菜单的转换规则，不触发人员选择。勾选、回车延续/空项退出和撤销沿用列表行为。 |
| 感悟、自检 | 复用宿主的添加/恢复栏目动作，保留各最多一个和关闭后可恢复的规则；已存在时隐藏入口。 |
| 领航员、都来帮 | 复用各自宿主业务动作，保留选人和新增业务行流程。 |

## 实现边界

1. 在通用工具栏内增加 Todo 一级入口，与 T 菜单共用类型转换命令；当前原生 @ 顶栏标识已存在。日记已支持 Todo 的渲染、复选状态、回车和保存，主要补直达入口。
2. 给公开 `EditorInteractionShell` 增加可选宿主动作列表，包含稳定 ID、名称、图标、可用状态和异步回调，经内部工具栏统一展示。四个自定义功能由宿主注入，不写入通用包的业务枚举。既有内建配置保持可用，本页按内建项在前、自定义项在后组合。
3. 原生 @ 需补齐日记接入，不能只开启按钮：启用 mention 能力、注入本实例选人/头像服务；复用包内对象命令解析及渲染，通过窄的公开契约供宿主调用；同步日记对象校验、输入身份清理、复制/剪切、保存重开与预览。裸日记控制器当前没有协同适配器的对象命令解析阶段，需接入通用本地事务流程，无需因此创建协同连接或原生文档。
4. 新 @ 写原生对象、新待办写 Todo。旧草稿中的自定义引用与旧业务待办继续读取和显示，不因入口调整强制批量迁移。自定义业务行中的既有引用仍按其业务契约处理。
5. Todo 转换保持既有跨栏目/不支持选区保护；选择面板完整退场后再核对目标、正文修订、账号、页面和权限。防止重复提交，失败不改原文；直接操作后保持键盘，模态操作结束后在有效会话恢复选区和输入。自定义选人流程仍由宿主管理会话，不重复冻结正文。

## 源码核对依据

- [页面底部旧入口和宿主动作](../../../lib/src/daily_guidance/local_journal_page.dart)：`_actions`、`_pickPeople`、`_section`。
- [日记能力和对象校验](../../../lib/src/daily_guidance/journal_draft.dart)：`journalConfiguration` 已启用 Todo，未启用原生 mention；`validJournalDelta` 当前只识别旧日记引用。
- [日记渲染与字符触发](../../../lib/src/daily_guidance/journal_surface.dart)：已注册 Todo；当前装饰器和 @ 快捷链仍走旧引用。
- [通用外壳](../../../packages/cses_document_collab/lib/src/editor/editor_interaction_shell.dart)：目前没有宿主快捷动作参数。
- [工具栏](../../../packages/cses_document_collab/lib/src/editor/editor_shortcut_toolbar.dart)：已有原生 @，T 菜单已有 Todo 转换；[配置](../../../packages/cses_document_collab/lib/src/editor/core/editor_configuration.dart)尚无 Todo 顶栏标识。
- [工具栏容器](../../../packages/cses_document_collab/lib/src/editor/stable_mobile_toolbar.dart)：已支持横向滚动和固定右侧收起键盘。
- [原生对象命令](../../../packages/cses_document_collab/lib/src/model/collab_inline_formula.dart)：`applyCollabInlineCommand` 依赖事务前解析；[控制器](../../../packages/cses_document_collab/lib/src/editor/core/document_editor_controller.dart)当前通过可选 binding 安装解析阶段。
- [日记复制](../../../lib/src/daily_guidance/guidance_entries.dart)、[输入归一化](../../../lib/src/daily_guidance/journal_input.dart)：需要同时识别新旧引用。
- [宿主现有提及装配](../../../lib/src/demo/document_host.dart)：已有 `CsesMentionDirectory` 与 `showDemoMentionPicker`，日记应显式注入自己的实例服务。

## 实施后验证范围

分别在协同包和宿主运行目标分析与相关测试，覆盖：Todo 转换/勾选/回车/历史；原生 @ 插入、取消、删除、中文组合输入、普通连续输入、复制/剪切、保存重开和预览；旧草稿恢复；四个自定义动作及感悟/自检唯一性；重复点击、失效选区和账号切换。界面覆盖 320/390 窄屏、大字、横屏、横向滚动和固定收起按钮，并在 Android/iOS 核验模态退场后的键盘恢复。当前未完成这些新路径验收。

## BlockCraft 版本核对

- 在桌面 `/Users/shichunlei/workspace/cses-client` 使用其 `.npmrc` 配置的 `@ccc` 仓库查询。首次受沙箱代理连接限制，npm 回退旧缓存的 0.11.27，不将其作为 latest；随后使用独立空缓存只读查询成功，latest 为 **0.11.28**。
- 桌面根声明 **0.11.28**、Yarn 锁定 **0.11.28**、实际安装 **0.11.21**；docs 子包声明 `^0.11.0-alpha`。本轮未修改桌面依赖或安装目录。
- 下载 0.11.28 发布包到临时目录，SHA-512 与仓库元数据/Yarn integrity 一致：`sha512-KNVpgHHAY6ds1bo+EvtiQjS80aoS5kS6oSuJ9nIaJlA8y6yelew5H7F1wTK/bS3Rl9fVyoNAnydz/Si8y0EACg==`。
- 已读取安装版和 latest 随包技能、L0、MIGRATIONS 及相关菜单/提及实现，latest 额外读取行内插件指南、Todo Schema 和 MentionPlugin。latest 的 Todo 仍为 editable + checked 属性，mention 仍为行内对象；桌面 0.11.21 与 0.11.28 的 `createInlineMentionEmbedConverter` 所读片段一致。
- latest 相对安装版还包含对象动画、字重及菜单/只读链接等变化；本轮没有进行完整升级适配。Schema 全集、行内对象全集、选区/菜单、剪贴板、输入、历史和协同的原升级待办仍保留。正式块 41 项及已适配/部分支持/结构支持/未适配的 13/14/1/13 统计不变。

本轮验证仅为源码、发布包完整性、文档链接和差异检查，不将历史测试或版本号核对作为新增功能已通过的依据。
