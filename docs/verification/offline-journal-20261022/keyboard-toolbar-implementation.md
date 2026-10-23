# 今日导向键盘菜单实施与验证

日期：2026-10-22。按用户明确的原生 @、原生 Todo 和四个自定义入口实施；[实施前方案](keyboard-toolbar-plan.md)保留当时源码状态，不作为当前能力或验收结论。

## 最终行为

- 键盘上方按顺序显示 T、Aa、@、Todo、感悟、领航员、都来帮、自检。菜单单行横向滚动，收起键盘固定最右；移除页面下方重复的 Wrap。
- Todo 与 T 菜单共用转换事务，保留正文、格式、选区和列表层级；重复点击现有 Todo 不清空勾选或新增空历史。
- @ 按钮及键入 @ 共用编辑器原生单用户提及；独立的账号目录和头像服务由宿主注入。日记校验、渲染、IME、可读姓名复制/剪切、保存重开和预览同时识别新原生对象与旧自定义引用。
- 感悟、自检复用唯一栏目添加/恢复，存在时隐藏添加项；领航员、都来帮继续复用宿主组织多选及业务行插入。旧业务待办继续读取，新待办使用原生 Todo。
- 四个业务动作通过公开 `EditorKeyboardAction` 和 `EditorInteractionShell.keyboardActions` 注入；通用包不依赖日记业务。普通输入不因工具栏机制重建整个正文，只在栏目存在状态改变时更新添加项。
- 预览不显示编辑菜单；新旧数据仍保存在原账号的本地草稿，未增加业务派单、通知或协同连接。

## 实现与审查修复

包内新增原生用户提及的公开解析、装饰和触发接口，装饰器使用当前实例的服务。`DocumentEditorController`统一解析对象命令，移除协同适配器重复解析；本地会话提交可被宿主首次校验的局部增量，不持久化命令元属性。

审查和真实交互测试补齐以下保护，均保留对应回归：

1. 模态插入时保存源选区与落点，撤销/重做恢复光标及输入连接。
2. 富文本内键入 @ 允许正常继承样式，不因完整 Delta 比较差异漏开选择器。
3. 插入后比较完整预期 Delta，宿主拒绝已有同用户对象替换时不误报成功。
4. 自定义选人期间 `JournalSurface` 尊重宿主冻结，避免 AppFlowy 重建时擅自解冻并在 build 中通知工具栏。
5. 选择器完全退场后按 UI 选区事件恢复输入；账号切换永久冻结旧会话，迟到结果不写入，也不恢复旧账号键盘。

## 验证结果

| 验证 | 结果与依据 |
|---|---|
| 日记全目录 | 126 项通过，包含新增原生对象和当时的 5 个完整页面场景；[日志](keyboard-toolbar-journal-tests.txt)。 |
| 最终完整页面 | 6 项通过：320/常规字、390/2倍字号滚动与自检、领航员/都来帮来源保留及键盘恢复、原生选人账号失效、原生 @→撤销/重做→Todo→预览→保存；[日志](keyboard-toolbar-page-tests.txt)。这些场景与全目录结果有重叠，不相加统计。 |
| 工具栏目标 | 49 项通过，含排序、禁用、重复点击互斥、迟到异常、Todo 内容/勾选/历史；[日志](keyboard-toolbar-actions-tests.txt)。 |
| 原生对象关联 | 10 文件 68 项通过，含新 9 项公共 API 回归及真实 FRB 用户/实体/公式、裸控制器和既有对象 UI；[日志](keyboard-toolbar-native-tests.txt)。 |
| 协同包全量 | 1645 项通过，1 项因未提供桌面互通参数而跳过；[全量日志](keyboard-toolbar-package-tests.txt)。唯一跳过项显式提供 latest 发布包与 Node 24 后，所属 3 项全部通过，[补跑日志](keyboard-toolbar-desktop-interop-tests.txt)；不把数据层互通视作真实双端界面验收。 |
| 静态分析 | 日记源码及测试无问题，[日志](keyboard-toolbar-journal-analyze.txt)；包内全部 15 个目标无问题，[日志](keyboard-toolbar-package-analyze.txt)；最终含字体加载的页面测试也[分析无问题](keyboard-toolbar-page-analyze.txt)。 |
| Android | 调试 APK 构建成功，[日志](keyboard-toolbar-android-build.txt)；18 个本轮生产源码的完整字节均嵌入当前 APK，[源与产物校验](keyboard-toolbar-source-apk.json)。 |
| 本机测试库 | 按 README 重建当前 Rust 动态库成功，未修改 Rust 源码或生成接口；[日志](keyboard-toolbar-native-build.txt)。 |
| 界面检查 | 加载中文及 Lucide 实际字体的 2 项截图导出测试通过，[日志](keyboard-toolbar-screenshot-tests.txt)；下方四份真实 Flutter 图片已目视核对工具栏起止、文字可读和固定收起位置。 |

截图只包含虚构测试资料，使用测试视口和模拟键盘 Insets，不代表物理设备键盘或真实网络选人验收。390/2倍字号下日期头部的既有换行不计为本轮工具栏变化。

- [320 起点](keyboard-toolbar-320-start.png)、[320 末端](keyboard-toolbar-320-end.png)。
- [390/2倍字号起点](keyboard-toolbar-390-start.png)、[390/2倍字号末端](keyboard-toolbar-390-end.png)。

## 首轮失败与环境说明

- 本机旧 Rust 动态库与现有桥接 hash 不一致，首轮全量中已有 3 个原生套件初始化失败；主动停止全量重建后，真实 FRB 目标全部通过。[首轮日志](keyboard-toolbar-package-first-run.txt)保留 hash 差异及主动 SIGINT 引起的 finalization 信息，后者不计为新功能缺陷。
- 日记首轮 121 项通过但包含旧底部入口断言、惰性目标属性断言和新测试虚拟时间未推进导致的失败/中断，保留[首轮日志](keyboard-toolbar-journal-first-run.txt)。随后同步新交互测试并修复实际冻结冲突，最终全目录通过。
- [页面审查失败](keyboard-toolbar-page-review-failures.txt)保留实际冻结冲突、原生历史光标问题及选择框后缺少一帧重建的测试问题；最终六场景已复验通过。
- 首轮 SDK 缓存写权限/CPU 信息沙箱限制后，使用授权的本地 Flutter/Dart 执行验证。归档日志只去除 ANSI 控制符和行尾空格，保留失败与中断语义。

- 新增代码首次编译曾使用不存在的栈 getter，修正后完成验证，保留[编译日志](keyboard-toolbar-first-compile.txt)。补跑互通先因测试进程继承旧 Node、随后一次可执行路径填写错误而受阻，分别保留[旧 Node 日志](keyboard-toolbar-desktop-interop-first-run.txt)与[路径错误日志](keyboard-toolbar-desktop-interop-path-error.txt)；指定通过 process.execPath 确认的 Node 24 路径后 3 项通过。未更改互通脚本或断言。

## 版本与边界

实施前再次通过桌面 `.npmrc` 配置仓库独立缓存查询：latest **0.11.28**，桌面声明/Yarn 锁 **0.11.28**、实际安装 **0.11.21**。发布包 SHA-512 与本轮元数据一致，已复核安装版和发布版随包技能、MIGRATIONS、Todo/提及/菜单实现；[版本与来源指纹](keyboard-toolbar-version.json)。未升级桌面依赖，未把本地入口接入视作完整桌面升级兼容完成。

正式块 41 项及 13/14/1/13 能力统计保持。上游对象动画等原待同步项保持；本轮没有新增真实桌面双端、服务器持久化 ACK、真实组织接口或 iOS 真机验收。设备探测曾报告 Android 属性读取失败，最终 ADB 已找不到此前设备，因此未安装当前 APK或声明真机交互通过。

[格式检查](keyboard-toolbar-format-check.txt)按文件既有 80/120 列分别复核，本轮 24 个手写 Dart 文件均无需格式变更；文档链接、旧入口检索和 git diff --check 通过。已保留任务开始前的视频源码及 Android 启动排查记录，未提交 Git。

最终[结构化验证结果](keyboard-toolbar-validation.json)与[源码 SHA-256](keyboard-toolbar-source-sha256.json)用于对照本轮证据。

后续排查发现，本轮没有覆盖日记自定义栏目下的“列表→列表”直接互转；当时页面用例只验证了普通段落→Todo。该遗漏及容器授权修复见[后续列表互转修复](list-conversion-fix.md)。本页测试、源码与APK摘要保留为当时快照，后续构建与验证以新记录为准。
