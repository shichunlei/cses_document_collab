# 编辑与同步解耦审查修复

日期：2026-10-21。按 R1 → R2 → R3 → R4/R5 → R6/R7 顺序处理，保留既有协同和本地编辑装配，不修改 Rust 接口、生成桥接或服务端协议。

## 处理结果

| 编号 | 结果 | 行为与回归 |
|---|---|---|
| R1 / P1 | 已修复 | 初始化失败后清除 initialized 和失败任务，重试重新取得所属文档、恢复缓存并注册；另一个控制器占用时明确失败。会话回调同时核对所有权和当前会话身份，旧回调不能访问后继文档。测试覆盖 A 失败→B 编辑→A 重试受阻且 B 不变→B 关闭→A 成功恢复，以及关闭等待迟到注册、旧回调不影响新文档。 |
| R2 / P1 | 已修复 | convert 仅允许已启用的文字叶子类型间转换。容器、资源、含子节点或混合选区在建立历史边界前整批忽略，不丢内容，不改变选区、修订或历史；结构块仍使用原专用插入入口。测试覆盖表格、嵌套高亮、带子段落的普通段落、混选和容器内文字转换/撤销。 |
| R3 / P2 | 已修复 | 注册失败立即释放部分启动的会话；每轮失败仍交给调用方，内部权限队列记录后恢复。关闭逐项等待并清理，前置失败不再跳过会话和编辑器释放。测试核对失败后立即无监听、恢复注册成功、关闭后无监听。 |
| R4 / P2 | 已修复 | 代码回车与本地粘贴共用原位文字替换事务；多行、CRLF和尾换行保留在同一个代码节点，保留身份、属性及后缀，光标正确且独立撤销/重做。容量超限先拒绝，readonly 不写；普通段落粘贴保留原流程。 |
| R5 / P2 | 已修复 | left 作为基础排版状态允许出现在块数据中，不受对齐操作列表排除。alignments: [] 时标题转换正常；主动设置未启用的 center 仍被命令和事务拒绝。 |
| R6 / P2 | 已修复 | 段落工厂未传 textDirection 时保留 attributes 中的方向；显式参数仍覆盖。测试覆盖方向优先级、RTL段落拆分及撤销；原方向保留用例恢复通过。 |
| R7 | 撤销误报，修正测试 | Transaction.insertTextDelta 本来就设置 afterSelection。新增独立回归在未修改的原粘贴实现上通过，证明连续粘贴光标正常。旧用例把光标移到第10位却断言末尾追加，现改为显式移至末尾；新增用例同时验证中间插入、后缀、光标、富文本和历史。pasteHTML 生产实现及公开签名未改动。 |

原审查对 R7 的实现归因有误，已在[原报告](/System/Volumes/Data/workspace/mobile-collab-demo/docs/verification/editor-decoupling-review-20261021/review.md)更正；原失败日志保留为审查历史，不再作为光标缺陷证据。原实现的新测试日志见 [legacy-paste-original.txt](/System/Volumes/Data/workspace/mobile-collab-demo/docs/verification/editor-decoupling-fixes-20261021/legacy-paste-original.txt)。

另外将本地菜单测试中 H1/H3/H4 等旧文字断言改为稳定的标题入口 Key，适配已完成的标题图标变更，没有修改标题菜单行为。

## 验证

新增 **16 项**有行为断言的回归：协同包12项、AppFlowy4项。完整测试名和结果见 [validation.json](/System/Volumes/Data/workspace/mobile-collab-demo/docs/verification/editor-decoupling-fixes-20261021/validation.json)。

| 范围 | 实际测试结果，排除隐藏加载和钩子 |
|---|---|
| 协同包全量 | 1548通过、43失败；43项按文件和用例名与既有基线完全重合，无新增失败。先前两项标题图标旧断言已通过。 |
| AppFlowy全量 | 919通过、0失败；包含方向修复、新粘贴回归及纠正后的旧用例。 |
| 宿主全量 | 58通过、0失败。 |
| Rust | 102通过、0失败；原生源和桥接签名未变。 |
| 协同/本地关联目标集 | 52通过；最终格式/语法整理后26项目标再验通过。 |
| AppFlowy目标集 | 31通过，包含原先失败的方向与粘贴文件。 |
| 静态分析 | 修改的6个协同文件无问题；协同包全量仅1条既有close_sinks信息；AppFlowy全量无问题；宿主lib/test仅8条既有依赖声明信息，无error/warning。 |
| 格式和差异 | 对修改的手写Dart运行dart format，保留未触达声明的原有格式；git diff --check通过。 |

未把43项已有失败当作通过；协同包全量门禁仍未全绿。其余锁菜单、卡片布局和开关旧失败不在这轮六项实现修复范围，清单见 validation.json 的 package-full.failures。根目录生成构建缓存的既有分析错误未清理，本轮宿主分析范围为lib/test。

本轮未重新运行手机手势、Android/iOS构建、真实联网协同及服务端ACK；自动化通过不能替代这些平台和在线验收。原共用正文、离线预览、全部块配置、键盘菜单配置与既有协同功能继续保留。

## 修改范围和版本

核心实现：CollabController、LocalEditorController、collab_code_editing、AppFlowy paragraphNode；配套4个新测试文件、2个既有测试文件，以及本记录和适配表。文件哈希见 [source-snapshot.json](/System/Volumes/Data/workspace/mobile-collab-demo/docs/verification/editor-decoupling-fixes-20261021/source-snapshot.json)。保留原有未提交工作区改动，未创建提交或PR。

本轮在桌面配置仓库实时查询 latest=0.11.23；桌面根声明/Yarn锁0.11.24、安装0.11.17、历史pnpm锁0.2.78，组合未变。复核随包技能/迁移及相关事务、输入、转换和剪贴板契约；没有升级依赖。正式41块状态保持13已适配/14部分支持/1结构支持/13未适配，.24只读链接等原有版本差异继续待同步或验收。
