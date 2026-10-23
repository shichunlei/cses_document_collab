# 都来帮、领航员使用原生人员提及

日期：2026-10-23。范围为今日导向两个业务动作的人员选择、对象格式与本地生命周期；保留其他工作区修改。

## 行为

- 都来帮、领航员使用编辑器原生 `@用户` 单选面板，同普通正文 @ 共用宿主目录、搜索、头像与权限保护；不再打开旧组织树或提供部门选项。
- 确认后另起对应业务行，保存原生 U+FFFC 人员对象、真实用户 ID、姓名及 `mentionType=user` 原始属性，尾随空格；来源正文保留，后续继续输入。
- 取消不写正文。完整退场前暂缓本地事务，保留编辑权限监听；返回后复核账号、文档、修订与节点。账号切走再切回仍拒绝旧结果，关闭后不恢复输入。
- 既有组织引用和旧草稿继续读取、渲染和保存，不做破坏性迁移。旧 `insertPeople` 的 help/pilot 路径也拒绝组织，合法人员转为原生对象；历史 task 和句内兼容格式保持。

## 实现边界

协同包公开 `pickEditorMentionUser` 复用现有人员选择与撤权保护，但不自动插入；`EditorUserMention.createDelta` 与原生插入共用同一对象工厂。宿主 `insertUserEntry` 使用一条独立历史事务创建业务行，保存原始选区供撤销恢复，不借用包内实现路径。页面删除旧组织目录注入，保留原生人员目录注入。

## 版本核对

本轮已在桌面项目配置的包仓库独立缓存实时查询 latest=0.11.28；桌面声明/Yarn锁=0.11.28、安装=0.11.21，未升级。发布归档 SHA-512 与元数据一致。读取两版随包技能、MIGRATIONS 和相关提及实现；确认后对象插入片段哈希一致，保存 mentionId/user 类型与尾随空格的语义不变，见 [版本依据](native-business-mentions-version.json)。正式块统计41及13/14/1/13不变，既有动画、字重、右键/只读UI与其他兼容待办保持。

## 验证

| 范围 | 结果 | 证据 |
|---|---|---|
| 宿主今日导向全目录及 CsesMentionDirectory | 152通过，无失败/跳过 | [完整日志](native-business-mentions-host-tests.txt) |
| 最终修改后的动态日记、真实键盘工具栏 | 34通过，包含额外6项取消/账号往返/旧组织草稿回归；与上一行有重叠，不累加 | [最终目标日志](native-business-mentions-extra-tests.txt) |
| 协同包原生提及、公开接口、键盘动作 | 31通过，无失败/跳过 | [包日志](native-business-mentions-package-tests.txt) |
| 宿主5文件、包4文件静态分析 | 无问题 | [宿主](native-business-mentions-host-analyze.txt)、[包](native-business-mentions-package-analyze.txt) |
| 9个修改手写文件格式、diff及旧入口检索 | 通过 | [最终检查](native-business-mentions-final-checks.txt) |

覆盖新业务行原生属性/人员限制、保留原文、取消不写、暂停期间迟到输入拒绝、独立撤销重做及选区、保存重开、预览、账号往返拒绝，以及真实目录仅包含人员。历史业务行部门引用有显式兼容用例。原生日记剪贴板与输入回归随全目录执行。

首次包测试有1项新工厂比较夹具失败：裸 EditorState 没有本地对象命令执行上下文，改用真实 DocumentEditorController 后31项通过；首次宿主分析指出闭包权限判断不能替代显式 mounted 检查，已补齐。首次失败日志保留：[包](native-business-mentions-package-tests-first.txt)、[分析](native-business-mentions-host-analyze-first.txt)。

本轮未修改生成物或原生接口，未新增 App 构建、设备安装、Android/iOS真机及真实在线双端验收。已有构建和设备记录不代表本轮代码已安装。生产和测试源码指纹见 [SHA-256](native-business-mentions-source-sha256.json)，检验汇总见 [JSON](native-business-mentions-validation.json)。
