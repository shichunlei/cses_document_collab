# 今日导向列表直接互转修复

日期：2026-10-22。用户反馈无序、有序和Todo列表不能直接互换，必须先转成普通段落。

## 原因与复现

日记正文的真实结构是 `page → local-journal-section → list`。T菜单和Todo直达按钮的列表→列表分支调用 `changeCollabListType`，其父节点校验原来只接受根级和高亮块，日记栏目因此被提前拒绝。普通段落→列表走另一个转换分支，所以先转普通段落能够绕过该缺陷。

此前包级互转测试使用根层列表，上一轮页面用例只验证普通段落→Todo，没有覆盖日记栏目中的列表互转。新增真实 `LocalJournalPage` 用例后，修复前六个方向全部失败，见[红测试](list-conversion-before.txt)。

## 修复范围

- `EditorConfiguration.listConversionContainerTypes`显式授权无Delta的宿主结构父类型，构造时复制并冻结，默认空；日记仅声明自己的栏目类型。通用包不硬编码日记业务名称。
- 仅列表类型转换使用新增授权，并要求所有选中列表属于同一父节点；跨栏目、未知未授权容器、真正嵌套列表或正文混选继续整体拒绝。
- Enter、Backspace和缩进沿用原范围。转换继续复用既有一次事务，保留正文、富文本、原生提及、层级、光标及撤销重做。
- 进入Todo默认未勾选，离开Todo移除勾选属性；同类Todo不重建或清除现有勾选。
- 本轮生产代码仅修改通用配置、列表父节点选择与日记配置三处，不改Rust、生成接口、文档Schema、草稿格式或依赖。

## 验证

| 检查 | 结果 |
|---|---|
| 真实页面 | 新增10项通过：六方向T菜单互转、无序/有序→Todo快捷按钮、同类Todo幂等、连续互转及逐步Undo/Redo。[日志](list-conversion-page-tests.txt)。 |
| 新包级边界 | 14项通过：配置冻结、六向含原生@/粗体、正反多项与连续历史、未授权/跨父/嵌套拒绝、其他列表命令不扩权、根层/高亮兼容。[日志](list-conversion-custom-container-tests.txt)。 |
| 包关联回归 | 本轮共475项通过：新14项、配置/互转/缩进/Enter/Backspace 369项、工具栏/焦点/原生编号92项；[列表关联](list-conversion-package-list-tests.txt)、[工具栏与原生](list-conversion-package-toolbar-native-tests.txt)。0失败/0跳过。 |
| 日记全目录 | 137项通过，0失败/0跳过，含新增10项；[日志](list-conversion-journal-tests.txt)。 |
| 静态分析/格式/diff | [宿主目标分析](list-conversion-journal-analyze.txt)及[包4目标分析](list-conversion-package-analyze.txt)均无问题；本轮5个手写Dart文件按既有80/120列[格式复核](list-conversion-format-check.txt)通过，git diff --check通过。 |
| Android | 当前调试APK重新构建成功，[日志](list-conversion-android-build.txt)；包括本轮3处生产改动在内的19个相关生产源完整字节均嵌入APK，[源与产物校验](list-conversion-source-apk.json)。 |

## 版本核对与限制

分析前通过桌面配置的仓库独立缓存实时查询，latest仍为 **0.11.28**，integrity与前轮已校验发布产物一致；桌面声明/Yarn锁 **0.11.28**，实际安装 **0.11.21**。复核随包技能、迁移说明及列表/Todo实现，未升级桌面依赖。正式块41项及13/14/1/13统计保持；上游原版本兼容待办保持。

本轮界面回归使用真实Flutter组件和模拟键盘，不代表物理设备、真实在线双端或iOS真机验收。保留上一轮[菜单实施](keyboard-toolbar-implementation.md)的测试与源码/产物历史，不用本轮结果追溯修改当时结论。

[源码指纹与结构化结果](list-conversion-validation.json)保留修复前后来源。测试最初使用不存在的栈length getter导致编译失败，修正测试后得到有效六项红测试，保留[首次编译日志](list-conversion-test-first-compile.txt)，不将该编译错误混作功能复现结果。
