# 今日导向 JSON 导出与独立提交分析

日期：2026-10-23。结论：当前编辑器已有完整JSON序列化能力，日导向可通过独立业务HTTP请求提交，不需要加入WS协同。当前只有本地草稿保存，尚未接入导出提交包、提交按钮或业务提交服务。已将当前原生用户@和旧业务引用兼容链路一并纳入分析。本轮只分析，不修改运行时代码或执行业务请求。

## 当前能力与实际边界

1. `DocumentEditorController.editorState.document.toJson()`输出正文树，`Document.fromJson()`支持恢复。树保留段落、列表、基础格式、自定义栏目、行内引用及业务行属性，读取JSON不会发送WS消息。该控制器本身不创建网络、原生文档或数据库。
2. `JournalDraft.toJson()`已有schemaVersion=2、模板版本、草稿id、用户所选日期、UTC创建/修改时间、时区分钟偏移和正文。`LocalJournalController._save()`正在从实时编辑器生成完整JSON并交给宿主文件存储；不需要等WS同步后才能获取内容。
3. 现有通用控制器没有名为exportJson的便捷方法，但公开editorState足以序列化；日导向尚无公开的完整业务导出方法，不能把私有`_draft`或磁盘文件当实时提交入口。直接`toJson()`的结果包含嵌套可变引用，应编码/解码或按模型复制为独立快照，再跨异步边界使用。
4. 日记本地格式是AppFlowy树与宿主业务属性，不是桌面BlockCraft Snapshot，也不是Yjs二进制update；能编码为JSON不等于任何现有后端均可直接接收该结构。

源码与版本证据见[核对快照](json-submit-analysis-20261023.json)。正文示意调用如下，仅导出正文，不含日期/草稿身份等业务封套：

```dart
final content = journal.editor.editorState.document.toJson();
final jsonText = jsonEncode(content);
```

## 建议的宿主实现

保持`仓库根 package`只提供通用编辑与协同。在`example/lib/src/daily_guidance/`增加：

- `exportForSubmit()`：基于当前已完成事务生成不可变快照，包含版本、草稿/业务身份、用户所选记录日期与内容修订。先完成中文合成输入，避免最后一字未提交；不能直接读取500毫秒去抖之前的磁盘稿。
- 业务数据适配器：只提交当前可见栏目，保留显示顺序、列表/格式、@的类型/ID/名称，以及待办/都来帮/领航员的类型/稳定条目ID/完成状态。关闭栏目的恢复备份、内部段落定位标记、栏目版本计数和其他本机状态只保留在草稿，不混入公开提交内容。当前原生用户对象由`EditorUserMention`解释，需保留`cses_inline_mention/cses_mention_id`等身份属性或转换为规范实体；旧`guidance_mention`人员/组织引用也须兼容。不能按`cses_`前缀统一删除，否则会误删真实提及身份。不能使用剪贴板的@姓名纯文本回退作为业务数据，否则实体身份会丢失。
- `DailyGuidanceSubmissionService.submit(payload)`：由宿主复用Common HTTP及账号会话，发送JSON，处理返回的业务ID/版本与错误；不挂载同步绑定、不发送collabUpdate。真实任务/求助/领航创建与通知由业务接口契约决定，不由编辑器根据行标签自动触发。

建议将业务封套与版本化正文分开：封套包含schemaVersion、稳定提交请求ID、recordDate、业务类型及可选更新版本；正文是经清理的有序栏目和富文本/实体数据。字段名只是建议，需按服务端合同落地。人员/企业授权仍使用当前认证会话核验，不在正文中保存认证令牌。

提交时先保存并保留快照与修订，再发业务请求。成功只标记该次快照为已提交；若允许请求期间继续编辑，新修订不能被旧成功响应清空。失败保留本地稿和重试入口；同一次请求重试使用同一请求身份，由服务端配合幂等。关闭页面、切换账号或过期响应不能回写另一份草稿。

## 兼容现有桌面业务接口

桌面`submitForm()`先构建表单提交数据，再将`submitPayload.data/extras`交给`context.save()`；同时补充`form_date`、`orient_type`、`biz_type`、企业/用户/组织字段。桌面展示适配器识别`daily_orient_content`/`daily_result_content`、`help_items`、`navigator_items`及提及元数据。

因此如果移动端复用这套后端，应将本地编辑树转换成约定表单字段；不能直接假定它支持移动端的`local-journal-section`、`guidance_mention`或原始delta。感悟/自检与完整富文本的实际保存字段、最终HTTP路由、必填项、响应版本和业务副作用尚需按服务端及表单定义核对。本轮没有取得足够依据宣称已有接口能原样接收移动快照。

编辑器原始JSON适合本地恢复；提交JSON适合稳定业务合同。应由一次快照派生两者，避免维护两个可分别编辑的正文来源。若服务端希望直接存完整编辑器JSON，则还需约定版本、允许属性/块与实体、读取渲染方和迁移策略。

## 后续验收范围

实施后重点验证：导出后再编辑不改变已捕获payload；中文末次合成不丢字；可见栏目、富文本与@身份完整；关闭栏目不提交但本地仍可恢复；HTTP失败/超时可重试且无重复业务；返回旧成功不清新修订；换账号结果失效；读取服务器返回JSON能复现约定内容。

本轮未改Dart/Rust/生成文件、未新增测试或构建，也未做HTTP写入、设备或WS/在线协同验收。重新确认BlockCraft latest=0.11.28，桌面声明/Yarn锁0.11.28、安装0.11.17、历史pnpm0.2.78；对应发布产物、随包技能/MIGRATIONS与受影响实现哈希未变。未升级依赖，正式块41及13/14/1/13保持；原上游差异仍待同步或验收。

## 原始JSON示例

已使用当前生产`Document`、原生`EditorUserMention`工厂和`JournalDraft.toJson()`生成[完整示例](daily-guidance-sample.json)。包括2026-10-23日期、今日记录/感悟/自检、基础加粗、三个虚构用户提及、待办、都来帮和领航员。双层`document.document`为当前草稿封套加正文封套的真实结构；U+FFFC是提及对象位置，用户身份在属性中。

[生成与校验记录](json-sample-record.json)、[生成源码](json-sample-generator.dart.txt)和[验证输出](json-sample-validation.txt)已归档。示例可由当前程序完整恢复，但不是最终HTTP接口协议。没有读取手机或用户草稿，也没有提交业务数据。仅生成器分析与一项模型往返校验通过，不新增应用/设备验收。
