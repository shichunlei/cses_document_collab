# image_composer 迁至宿主

日期：2026-10-24。本轮承接[分层分析](layering-analysis.md)，按“`cses_document_collab`只负责核心编辑器与协同同步，业务功能留宿主”的边界实施制图功能迁移。未调整块Schema、FRB ABI、原生实现或桌面依赖。

## 实施范围

| 原包内内容 | 当前宿主实现或处理 |
|---|---|
| `src/image_composer/image_composer_controller.dart` | [宿主功能控制器](../../../lib/src/image_composer/image_composer_controller.dart)，仅通过公开包API组合本地编辑和预览 |
| `src/image_composer/image_composer_page.dart` | [宿主页面](../../../lib/src/image_composer/image_composer_page.dart)，保留标题、工具栏、模板、布局、预览及键盘行为 |
| `src/image_composer/show_image_composer.dart` / `showCollabImageComposer` | [宿主路由入口](../../../lib/src/image_composer/show_image_composer.dart) / `showImageComposer` |
| `src/model/collab_image_template.dart` / `CollabImageTemplate` / `collabImageTemplates` | [宿主模板](../../../lib/src/image_composer/image_composer_template.dart) / `ImageComposerTemplate` / `imageComposerTemplates`，仍为原五种本地模板 |
| `src/editor/local_editor_view.dart` | 删除专属于制图的薄包装；页面和输入测试直接组合公开`DocumentEditorView` |
| `test/image_composer_page_test.dart` | [宿主页面测试](../../../test/image_composer/image_composer_page_test.dart)，通过公开行为验证，不再导入包内锁服务 |
| `test/image_composer_operations_test.dart` | 保留包内通用测试，改名[local_editor_operations_test.dart](../../../packages/cses_document_collab/test/local_editor_operations_test.dart) |
| `test/image_composer_native_isolation_test.dart` | 改名[local_editor_native_isolation_test.dart](../../../packages/cses_document_collab/test/local_editor_native_isolation_test.dart)，改用通用控制器创建本地正文与只读快照 |

移除了包的制图入口及模板导出、制图专属分析配置，同步Demo调用、当前README和包内职责规范。宿主已有直接依赖，无需新增依赖或改锁文件。没有为搬迁增加包公开出口，也没有让包反向依赖宿主。

本轮未增加保存或图片导出。正文/预览由宿主功能控制器创建并顺序释放；注入的服务仍由宿主持有。预览卸载后再释放其会话，路由完整退场后关闭正文，返回编辑继续使用原正文和历史。开始时页面已有的`createState()`省略显式返回类型改动在新位置保留。入口移出属于公开API移除，不保留反向兼容转发；仓库内调用已同步，仓库外消费者未在本轮环境验证。

## 验证

- [宿主197项](host-tests.log)全部通过：迁入的3项页面测试、今日导向消费者及文件草稿存储回归。
- [包内58项](package-tests-final.log)全部通过：本地输入/历史/命令、通用视图配置、全部离线块的既有目标范围、独立预览和真实原生文档隔离。原生隔离使用现有本机动态库；本轮没有原生源码或ABI变化，未重建原生库。
- [最终宿主分析](host-analyze-final.log)覆盖`lib test integration_test`，无问题；[包内目标分析](package-analyze-targets.log)覆盖公开入口与全部修改/改名的包内测试，无问题。
- [包全量分析](package-analyze.log)无error/warning，但有21条未触及代码的info：19条Cargokit文件级文档提示、1条视频Future提示和1条旧原生测试Sink提示。保留原配置和原代码，没有将其宣称为全量零诊断。
- 修改的手写Dart执行了`dart format`；沿用文件原有80/120列风格，Demo中与本轮无关的既有混合换行保留。扫描业务旧名、旧实现路径、宿主对包内部的导入及包对宿主的反向引用，结果见[validation.json](validation.json)。文档/JSON和相对链接、`git diff --check`在收尾核对。

未新增Android/iOS构建、物理设备或在线桌面双端验收，不用Widget测试替代这些验收。

## 首轮问题与修正

[首轮包测试](package-tests.log)在通用表格预览夹具清理阶段停滞，已中止，不作为通过结果。[分步诊断日志](shared-view-probe.log)及[探针源码](shared-view-probe.dart.txt)确认编辑、插表、预览和视图卸载均完成，等待`local.close()`时停住。修正夹具：视图卸载后，用`tester.runAsync`等待预览与正文订阅关闭，最终58项目标测试通过；产品关闭实现未改。

诊断调用虽然传了`--timeout 30s`，等待仍未自动结束，确认定位后中止探针。两次被中止命令的退出码均不能替代完整测试通过标志。首次宿主分析在80列格式化后出现2条大括号info，保留[首轮分析](host-analyze.log)；沿用原有换行后最终分析无问题。格式化初次遇到Flutter SDK缓存写入限制，直接SDK调用另遇到macOS CPU探测崩溃，随后在获准的正常环境完成格式化/分析/测试。

## 版本依据与保留范围

本轮重新查询桌面配置仓库，`latest=0.11.30`，发布包shasum/integrity与已检查的缓存产物一致；桌面当前声明/Yarn锁定`0.11.28`，安装`0.11.21`，历史pnpm`0.2.78`。重读安装/最新技能、迁移及导出相关实现，证据见[migration-version.json](migration-version.json)。未执行桌面升级，未重新验收全部Schema、块/行内对象、选区/菜单、剪贴板、输入、历史及协同差异；原待同步项保持。块清单和42种、13/28/1/0统计保持。

分析阶段记录、原路径源指纹和失败日志均保留；历史验证文档中的旧API/源码路径表示其当时的实现，不批量改写历史证据。当前使用说明与分析报告的可点击源码链接已更新。

## 保留在包内的编辑器类型块与扩展

按用户进一步明确的范围，文档头尾、会议、KR、任务等属于编辑器类型块或扩展，本轮继续保留包内，不列为待拆分项：

- `CollaborativeEditorPage`继续装配`DocumentHeader`及`DocumentFeedbackFooter`；`CollabController`继续持有既有元数据和反馈控制器，不改变文档头尾的功能与归属。
- 会议、任务、KR及其必要模型、展示、操作和协议兼容继续在包内维护，现有加载与宿主能力注入契约保持。

本轮迁移限定为`image_composer`这一独立应用功能。上述块与扩展没有代码改动，既有编辑与协同职责保持；宿主服务继续通过公开契约显式注入。此边界已同步至[包内规范](../../../packages/cses_document_collab/AGENTS.md)。
