# 双向JSON交换六项审查问题修复

示例文件后续变更：P1修复轮首次使用通用生成开关时重新生成了本页三份示例，同名文件现已不是本页记录的原始字节；原指纹仍保留，未将其改写成历史通过证据，详见[重生成清单](p1-fixes-regenerated-artifacts.json)。本页测试日志、桌面校验记录和结论按原轮次保留。

后续状态：复查确认的RR1/RR2两项P1已完成[修复和完整性验证](p1-fixes.md)，本页保留当时的结论、失败证据与范围。

后续复查：本页记录的29项正式新增回归继续通过，但新反例确认空标题回车转换及硬件Tab嵌套导出仍有完整性遗漏，见[再次审查](review-2.md)；本页保留原修复轮的验证范围和结果。

日期：2026-10-23。对应审查提交189ffad；[原审查与反例](review.md)保留原结论。本轮完成R1～R6全部修复，新增29项正式回归（共享包19、宿主10），不使用原始JSON兜底，不改变尚未实现的高级对象/Vectra/实时业务能力范围。未自动提交或推送。

## 修复与实际覆盖

| 问题 | 修复 | 正式回归 |
|---|---|---|
| R1 类型转换丢字段/身份 | EditorConfiguration.withHost复制完整能力并合并宿主字段/列表容器合同；导入稿沿用help/pilot/task业务字段。类型替换保留bc身份、props/meta/扩展字段；导出类型读取当前原生类型。插入后删除的替换事务延续旧身份，复制块则分配新身份。 | 三类业务转H2、格式编辑、撤销重做、保存重开、JSON双向恢复；普通/代码/引用/三类列表连续转换及空白参数拒绝、配置隔离。 |
| R2 高亮外观导出旧值 | 编码当前callout前缀、文字/背景/边框色，删除属性时清除对应props，不重放旧字段。 | 四类外观修改/清除、反向转换与落盘恢复、清除撤销重做、未知扩展字段保留。 |
| R3 退出列表后复活 | 普通paragraph有明确映射；只有snapshot-*容器读取转换flavour，原生代码/列表等使用实时类型。caption/shape-text/word-art保留特殊角色，显式转普通正文时解除角色。 | todo/bullet/ordered空项退出、重新导出和反向导入、稳定ID/撤销重做；宿主透明栏目内退出待办；艺术字显式转正文。 |
| R4 字重吞掉对象 | 字重和艺术字外观在进入对象装饰器前合成，不提前结束人员/实体/公式渲染链。 | 普通段落与艺术字内的用户、会议、任务、文档提及及LaTeX，共10种实际界面场景；设置600字重/斜体后仍是原生对象，反向导出保留字重。 |
| R5 插入漏检锁 | 独立副本按真实操作顺序预演；插入从实际父节点检查祖先锁，删除检查实际目标及后代。身份冲突修改延迟到完整校验成功后，不污染拒绝的事务参数。 | 文字/末尾插入/删除受锁保护；锁定兄弟前可插入；先删除导致路径移动、同事务先上锁后插入均原子拒绝；失败不改正文或插入节点身份；复制与替换ID不同处理。 |
| R6 新任务卡片丢引用 | 从当前CollabTaskCard资源读取全部字段；KR同源资源也使用当前载体，保留已有引用和扩展属性。 | 正式任务提及转卡片、taskId/title、JSON编码→原生转换→本地恢复→再次导出，转换撤销重做；桌面实际TaskCardBlockSchema工厂属性核对。 |

正式测试：[包内编辑回归](../../../test/blockcraft_json_editing_test.dart)、[宿主回归](../../../example/test/daily_guidance/journal_blockcraft_editing_test.dart)。旧反例仍在原目录归档，未删改原失败日志。

## 最终验证

- 共享包全量1698项通过，1项桌面互通因未提供路径参数跳过；随后为document_bootstrapper_native_test.dart显式提供实际桌面/安装包路径，该文件3项全部通过，包括原跳过项。因此本轮共享包1699个不同测试已通过，不将跳过算通过。
- 宿主test/daily_guidance全目录181项通过；新增编辑/锁/身份回归和既有菜单导入导出全部通过。
- 共享包/宿主受影响目标静态分析无问题，手写修改文件已格式化；git diff --check通过。Android debug构建通过，15个关联生产源文件与APK中kernel完整源码逐字节匹配。
- 生产转换器生成的三份桌面快照均通过实际安装版的Schema/父子规则、Yjs恢复和BlockCraftDoc.exportSnapshot深度一致校验。新任务卡片的schema直接读取桌面TaskCardBlockSchema源声明，只有不参与模型验证的Angular组件引用使用替身；taskId/title与真实createSnapshot工厂输出一致。
- 显式桌面互通测试使用独立临时SQLite和真实FRB/Yjs进程，手机创建数据由桌面读取并返回文本编辑，手机应用后关闭重开仍能恢复。不是在线桌面窗口或业务服务验收。

日志/源码指纹/复现命令见[fixes-validation.json](fixes-validation.json)、[APK源码匹配](fixes-build-validation.json)、[桌面模型验证](fixes-desktop-model-validation.json)。首轮错误断言将既有document预设不开放的t:px误认为开放，已改为核对配置副本与源配置的语义一致；未顺带改变既有字号能力。早期通过记录曾遗漏宿主替换时的ID断言，补齐后修正插入先于删除的身份转移。本轮失败/诊断日志均保留，结论依据最终日志。

## 双向示例

- [fixes-converted-journal.json](fixes-converted-journal.json)：当前生产转换器生成的12块今日导向样例，保留三个人员对象、两个完成待办、栏目/日期及业务字段。
- [fixes-restored-mobile.json](fixes-restored-mobile.json)：当前反向转换后的可持久化手机稿。
- [fixed-journal-roundtrip.json](fixed-journal-roundtrip.json)：真实宿主将help业务行改H2并写入24px粗体，再经保存重开及双向转换验证的桌面快照；业务entry-demo与原块ID保留。
- [fixed-task-card.json](fixed-task-card.json)：真实任务提及转换命令新建的卡片，导出明确包含task-demo及标题。

原converted-journal.json/restored-mobile.json和旧validation.json保持原字节，避免新生成的随机ID使历史哈希失效。示例生成仍使用GENERATE_BLOCKCRAFT_EXAMPLES=true，当前测试输出到本轮新文件。

## 版本与限制

本轮从桌面配置仓库重新查询latest=0.11.30，发布SHA-512与已核验产物一致；声明/Yarn锁0.11.30、实际安装0.11.17、历史pnpm0.2.78。本轮未升级桌面或改其源文件。复读同版L0、数据指南/MIGRATIONS及受影响契约；0.11.30运行仍未重新验收，模型/FRB互通验证使用实际安装的0.11.17。原有组合内容域、gap/斜杠菜单/输入/历史/协同差异待办继续保留。

未新增真机系统文件框、iOS、真实线上双端/业务接口验收；未改原生接口或FRB生成文件。正式42块与13已适配/28部分支持/1结构支持/0未适配统计保持，修复不等于补齐高级对象工具、实时业务源或独立Vectra图正文。
