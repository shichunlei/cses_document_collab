# 独立离线日记审查（2026-10-22）

结论：确认1项P1和3项P2。快捷键粘贴可能将丢失原文后的空正文保存；固定栏目边界、空列表回车及段尾空行横格存在缺口。建议先修复这些问题再提交。

后续修复与新增回归见[修复记录](fixes.md)。以下保留审查时的源码位置、失败和验收边界。

## 范围与依据

审查独立离线日记页面、控制器、三栏结构校验、横格绘制、宿主文件存储与首页入口，并追踪其实际调用的AppFlowy快捷键和输入处理。未修改生产代码、依赖、Rust原型或设备上的用户日记。9个生产文件与实施验收快照的SHA-256一致，见[版本及源码检查](review-version-source-check.json)。原有[实施与真机验收](report.md)结论保留，本记录补充此前用例未覆盖的边界。

本轮按桌面配置的包仓库重新查询，`@ccc/blockcraft latest=0.11.27`；桌面根声明/Yarn锁0.11.24、实际安装0.11.17、历史pnpm锁0.2.78，未升级。复核对应随包技能、块指南、MIGRATIONS及受影响日期/内容区域和移动输入实现；latest完整性标识与本轮已校验发布产物一致。原有菜单/只读链接/UI peer等差异仍待相应兼容验收。本地三栏不作为桌面render-unit/date-card的适配完成依据，41块与13/14/1/13统计保持。

## 发现

### J1 · P1 · 快捷键粘贴链接会删除选中的原文并保存空内容

- 位置：`lib/src/journal/journal_surface.dart:106-111`。
- 条件：选中“原来的记录”，通过外接键盘的粘贴快捷键粘贴`https://example.com`。
- 实际：通用`pasteCommand`先通过`deleteSelectionIfNeeded`单独提交删除，再将URL转成含`href`的文本；日记仅允许四种基础行内格式，后续插入被事务保护拒绝。结果选中原文和待粘贴链接都不在正文，随后保存的是空delta。普通中文粘贴对照通过。
- 依据：`paste_command.dart`的`pastePlainText`删除与链接识别流程，以及[补充复现日志](review-probes.txt)内保存快照。此复现针对通用键盘快捷键；移动浮动菜单另用原子纯文本事务，未将其列为相同缺陷。
- 建议：日记粘贴统一使用配置支持的纯文本入口，在同一事务中删除选区和插入内容；提交前校验整个替换结果，拒绝插入时保留原文。

### J2 · P2 · 栏目首行退格会把正文合并到上一栏目

- 位置：`lib/src/journal/local_journal_controller.dart:166-176`，触发入口为`JournalSurface`保留的通用`backspaceCommand`。
- 条件：感悟有“感悟正文”，自检有“自检首行”和“自检第二行”；光标在自检首行开头按退格。
- 实际：感悟变成“感悟正文自检首行”，自检仅剩第二行。通用退格会寻找前一个文字节点，事务保护只检查各操作位于合法二级路径和最后每栏非空，未阻止跨栏目合并。因此标题虽保留，内容归属被改变；若自检只有一行，结构校验恰好拒绝，原有最少一行测试不能覆盖此条件。
- 建议：在栏目边界拦截退格/前向删除，或对事务约束其跨栏目移动语义；允许栏目内正常合并，保留固定栏目之间的正文归属。

### J3 · P2 · 空待办按回车不会退出列表

- 位置：`lib/src/journal/journal_surface.dart:91-92`。
- 条件：将日记中的一段改成待办，清空文字后按回车。补充用例通过实际页面的`KeyboardServiceWidgetState.textInputService.apply`进入生产输入链。
- 实际：仍为`todo_list`，其delta变成`"\n"`，没有转回普通段落。唯一回车事件`collabParagraphEnter`在空列表上委托`outdentCollabListAtStart`，而后者的`_isFlatListParent`只识别根和callout，拒绝`local-journal-section`父容器；没有其他回车事件接管，最终退化为同一待办内部插入换行。相同父容器判断也影响空有序/无序列表。
- 建议：为日记固定容器提供适用的空列表退出行为，或让公共列表命令通过明确的可编辑容器契约支持该父节点；补齐日记内空列表回车回归。

### J4 · P2 · 段尾软换行漏画当前空行的横格

- 位置：`lib/src/journal/journal_ruled_content.dart:184-199`。
- 条件：正文为`第一行\n`，即按Shift+Enter后光标落到段尾空行。
- 实际：真实日记页面的横格纵坐标为`[32,96]`，缺少64位置的当前空行。`getBoxesForSelection`不为尾部空行生成文字选择框；现有兜底仅在所有框都为空时绘制段落底线，而外层补行从完整正文高度再加一个行高开始，恰好跳过尾部空行。编辑/预览共用该绘制器。
- 建议：按完整文字行度量补齐尾部空行，不能仅靠非空文字的选择框；补测单个及连续尾部软换行、缩放和编辑/预览。

## 验证与复现

| 检查 | 结果 | 证据 |
|---|---|---|
| 包内既有日记/页面/行线用例 | 15通过 | [日志](review-baseline-package-test.txt) |
| 宿主文件存储/首页既有用例 | 6通过 | [日志](review-baseline-host-test.txt) |
| 补充审查探针 | 普通中文粘贴对照1通过；上述4项期望行为断言失败 | [日志](review-probes.txt) |
| 补充探针格式与静态分析 | 已格式化；无分析问题 | [分析](review-probes-analyze.txt) |
| 源码一致性 | 9个生产文件均匹配实施快照 | [JSON](review-version-source-check.json) |
| 差异与归档链接 | `git diff --check`通过；报告相对链接均存在 | 本记录完成前检查 |

探针源码以[文本附件](review_probes_test.dart.txt)归档，避免将期望失败的审查用例加入默认测试发现。复现时将其复制到包内临时测试文件，以遵循包内测试访问本包实现的边界：

```sh
cp docs/verification/offline-journal-20261022/review_probes_test.dart.txt test/_journal_review_probes_test.dart
cd .
flutter test --no-pub --reporter expanded --timeout 20s test/_journal_review_probes_test.dart
```

完成后删除临时`test/_journal_review_probes_test.dart`。探针使用内存存储，不读写真实账号文件。早期探针搭建曾遇到测试工具调用参数错误和等待超时；修正参数并调整挂载方式后，最终5项均运行完毕，上述4个失败为行为断言，非搭建异常。

本轮没有重新构建APK、安装设备包或执行真机操作；不将单元/Widget复现扩大为真实外接键盘/iOS设备验收。生产源码未变，原有静态检查和Android构建保留为既有证据，未宣称本轮重新通过。此次范围不含其他任务正在维护的选择性撤销原型。
