# 离线、协同及宿主业务共用编辑器

日期：2026-10-23。按用户要求，日导向、通用离线、协同和制图入口统一通过`DocumentEditorView`装配正文与`EditorInteractionShell`；业务留在宿主，共享包只提供通用编辑和协同契约。

## 共用与配置边界

- 删除日导向自己的AppFlowyEditor、菜单/快捷键列表和复制粘贴处理；`JournalSurface`只提供纸张皮肤、行线、栏目结构、业务前缀和业务行回车扩展。普通文字及空列表回车不再由宿主另写一套。
- 删除公共视图按localOnly/usesRichDocument另建纯文字渲染器的分支；相同能力配置使用同一套块构建、文字装饰、输入、选择和菜单。在线/离线仅决定外部存储和协同绑定，视图不创建WS/SQLite，也不更换宿主草稿协议。
- `EditorConfiguration`统一控制块、字符格式、标题级别、工具栏及嵌套规则。`progressiveHeadingMenu`默认true，所有编辑器从H1～H3逐级到H6；非连续配置选择下一已启用项，重新打开/换块/回正文保持同一规则。需要直接展开须显式设置false。`structuralIndentation: false`关闭原生真实嵌套；显式容器名单决定平面列表转换/缩进/Enter/行首Backspace。
- `EditorViewConfiguration`统一注入blockBuilders/style/characterShortcuts/keyboardActions。集合不可变，回调及业务依赖由宿主拥有；渲染回调取得视图私有builder，不复制通用命令。改变皮肤不替换正文、借用滚动资源和撤销历史；更换会话会重建交互身份，异步剪贴板结果不进入其他文档。
- 标题T菜单、键盘命令和Markdown复用同一块属性转换，保留业务元数据、对齐、文字方向及背景；剪贴板快捷键统一调用当前会话端口。只读保留选择/复制、关闭编辑工具栏，预览关闭输入/选择，两种数据来源一致。

公开入口与最小示例见[包README](../../../packages/cses_document_collab/README.md#共用编辑视图与场景配置)。日导向保留原v1/v2草稿恢复、当前v2保存结构、日期、动态栏目、@、都来帮/领航员、行线、封面与编辑/预览排版；业务HTTP JSON提交和WS协同链路仍分别属于原宿主/绑定，不因共用视图而混合。

## 验证与证据

- [宿主169项](shared-editor-host-verified-tests.txt)通过，包含文件存储与日导向全目录。[共享包完整1674项](shared-editor-package-verified-tests.txt)通过，1项既有桌面互通用例因未提供BOOTSTRAP_DESKTOP_ROOT/BOOTSTRAP_PACKAGE_ROOT显式跳过，未将其视为通过。
- 新增6项真实公共视图测试覆盖不可变配置、同配置两种数据上下文的命令集合及菜单行为、标题键盘/Markdown属性保留、非连续标题可达、只读/预览规则与皮肤切换的资源/历史保留；新增2项配置容器空列表Enter/撤销测试。均包含在1674项内；[65项目标消费者回归](shared-editor-parity-complete-tests.txt)为中间子集，不另累计。
- [宿主分析](shared-editor-host-complete-analyze.txt)及[共享包与直接消费者分析](shared-editor-package-complete-analyze.txt)无问题。修改的手写Dart已按原风格格式化；旧日导向私有快捷键、旧State类和旧私有转换函数在生产/测试代码无残留，跨包调用只通过公开入口，diff检查通过。
- [最终Android构建](shared-editor-final-android-build.txt)成功，APK内所有本次生产Dart源码逐字节匹配，封面图片字节也匹配，见[源码、产物与版本指纹](shared-editor.json)。未安装手机，未新增真机、iOS或在线双端/服务端ACK验收。

## 首轮失败及修正

[首轮宿主](shared-editor-host-first-tests.txt)10项失败均与迁移后的测试定位有关：旧日导向私有快捷键Key已消失，预览改为保留禁用的通用外壳；改为验证共同命令标识及实际enabled状态后[169项](shared-editor-host-second-tests.txt)通过。最终收敛普通列表回车后再次通过上述宿主全量回归。

新增对照用例初稿使用未公开的toggleH3名称和不存在的历史栈length/items；修正为公开事件标识和真实历史项身份，保留[初稿](shared-editor-parity-tests.txt)及[次稿](shared-editor-parity-second-tests.txt)失败日志。[第一次包全量](shared-editor-package-full-tests.txt)仅协同页的代码回车第二优先级断言失败；将新Markdown处理放在既有段落/代码回车之后，保持原代码输入优先级，未修改该消费者断言；[目标65项](shared-editor-parity-complete-tests.txt)及最终全量通过。早期静态检查的花括号和多余非空断言已修正，保留[原分析](shared-editor-package-analyze.txt)及[后续分析](shared-editor-package-verified-analyze.txt)。

## BlockCraft版本及适配范围

本轮实时查询桌面配置仓库latest=0.11.29，桌面声明/Yarn锁0.11.28、安装0.11.17、历史pnpm0.2.78。校验发布包integrity并读取0.11.29随包L0、MIGRATIONS、格式/工具栏技能及受影响发布实现，版本证据见[标题展开记录](progressive-heading.md)。0.11.28→0.11.29的发布实现仅增加用户插图后的gap光标与图片Enter分流，未改变本轮标题/文字格式；该图片差异明确待移动端同步及验收，本轮未升级依赖。

正式块仍为41，13已适配/14部分支持/1结构支持/13未适配。段落/标题及列表的公共装配与配置范围更新至主表；原Schema、块/行内对象、选区、剪贴板、输入/历史与协同的其他版本差异继续按原清单待同步/待验收，不能把本轮统一核心当作完整0.11.29兼容完成。
