# 移动端文档类型解析与打开分流

日期：2026-10-28。覆盖SaaS宿主和本仓库Demo；保留原有未提交/已暂存改动，没有提交或暂存本次修改。

## 实际行为

- SaaS基础文档、详情、列表、目录与搜索结果解析并序列化原始 `documentType` 和 `meta`；未知类型和扩展字段保留，缺失/null保持未知，不制造text。meta顶层浅复制且不可修改，目录树转换与局部复制保留两字段。
- 所有现有列表/收藏/共享/搜索/文档链接继续调用原公共详情路由。路由先保留既有创建恢复检查，再加载权威详情并核对URL环境、ID和会话，之后按类型打开；正文构建器在检查通过前不会调用。不同文档/链接隔离预检服务，标签仅保留URL摘要。
- `text` 且没有外部editor/附件声明：进入原WebView详情，其协同编辑按钮仍进入独立原生页。
- `attachment`及历史image/video/audio/pdf/excel/word/other：有合法HTTP(S)地址则交现有资源模块；旧text带attachmentType同样按文件打开。拒绝无地址/非法协议/含用户名密码的地址；附件标题移除路径分隔符，自动打开一次，可手动重试，失败不回退文本。
- inspiration/sheets/mindmap/whiteboard/ppt、未知/缺失类型、外部editor及无有效地址的附件：显示未支持/资料缺失说明，不创建WebView/原生正文。此处没有新增Office/画布/导图等编辑引擎。
- 原生详情再次在 `DocEditorApplicationService.load` 校验权威类型，在解析缓存路径和创建正文引擎之前拒绝非文本；直接原生深链不能绕过。现有权限复核路径遇到类型变化时卸载关闭正文。
- Demo列表保留类型/meta，访问预检以详情为准，只允许明确text且没有外部编辑器/附件声明。复用当前文档也重新预检；失败不释放旧文档、不写正文。Demo没有独立文件查看页，因此附件明确拒绝在文本编辑器打开。

## 主要源码

- [SaaS类型决策](../../../../cses/cses.saas/lib/modules/doc/domain/value_object/doc_document_open_target.dart)
- [权威详情预检](../../../../cses/cses.saas/lib/modules/doc/application/service/doc_document_open_service.dart)
- [公共打开页面](../../../../cses/cses.saas/lib/modules/doc/presentation/open/page.dart)
- [实际路由串接](../../../../cses/cses.saas/lib/modules/doc/routes/pages.dart)
- [原生入口校验](../../../../cses/cses.saas/lib/modules/doc/application/service/doc_editor_application_service.dart)
- [SaaS回归](../../../../cses/cses.saas/test/modules/doc/document_type_routing_test.dart)
- [Demo解析](../../../example/lib/src/demo/document_creation/document_list_page.dart)
- [Demo详情预检](../../../example/lib/src/service/cses_document_creation_service.dart)

## 验证证据

1. 先写反例：SaaS复现类型/meta丢失及外部editor被原生正文放行（8通过/2失败），Demo复现sheets被放行（14通过/1失败）。见[原SaaS反例](saas-before.log)及[原Demo反例](demo-before.log)。
2. SaaS整个受影响文档模块：`FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR=/System/Volumes/Data/workspace/cses_document_collab/rust/target/debug flutter test --no-pub test/modules/doc`，**154项通过**，包含真实FRB/SQLite关闭/重开与同源初始根协议测试。见[完整日志](saas-module-tests.log)。最终补充页面复用切换类型的1项回归，专项16项通过（其中15项与模块检查重复），合计155个不同SaaS测试通过，见[复用回归](saas-page-reuse-tests.log)。
3. Demo目标三个文件：`flutter test --no-pub test/cses_document_creation_service_test.dart test/document_creation_coordinator_test.dart test/document_space_list_test.dart`，**70项通过**。见[日志](demo-tests.log)。
4. SaaS目标16个手写/测试文件静态检查和Demo目标6文件静态检查均无问题，最终页面复用保护的2文件分析也无问题，见[目标检查](saas-target-analyze.log)及[最终页面检查](saas-page-reuse-analyze.log)；已对实际修改文件运行dart format，两个仓库git diff --check通过。SaaS模块级扩展静态检查另发现并行工作中 `doc_engine_retry_test.dart:1` 的1项unnecessary_import提示，该文件不属于本次修改，保留未动；见[扩展静态检查](saas-module-analyze.log)。
5. 扩展测试首次未指定原生库目录导致1项失败，按仓库README补齐FRB环境后通过；实际路由测试首次未初始化Config.envType，补齐测试环境后通过。两次失败分别保留于[缺原生库记录](saas-native-library-missing.log)和[路由夹具记录](saas-route-fixture-missing-env.log)，没有跳过或放宽断言。

主要边界用例已覆盖：五种模型类型/meta精确保留、缺失/null/错误外壳、目录树复制、全部主类型与七种历史文件类型、旧text附件、未知editor、非法URL、跨环境/ID冲突、账号切换、页面退出迟到结果、组件复用期间先卸载旧正文、实际路由串接、非文本不创建原生控制器、当前文档复用仍预检。

建议后续真机覆盖各类型点击/返回、附件系统打开失败重试、账号切换时迟到响应，以及旧部署缺少documentType时的明确提示；本轮自动化不替代上述验收。

## 范围与限制

- 未做物理设备、完整App构建或真实业务/桌面在线验收；资源页面测试注入文件打开回调，不宣称各种Office文件或系统播放器均已实机通过。
- 所有类型都以详情接口实际返回为准：旧部署若详情没有documentType，将提示类型信息缺失；不再用text默认值掩盖服务端缺字段。
- meta嵌套JSON保留为只读协议值借用，没有新增未知对象的业务解释。SaaS/WebView、Demo和原生编辑器各自的已有能力限制仍在。
- 类型模型/分流属于宿主业务；没有修改共享包正文Schema、FRB、Rust、桌面依赖或42种块状态。
- 本轮按桌面配置仓库查询latest失败ENOTFOUND，最新稳定版待核对；声明/Yarn0.11.31、安装0.11.17、历史pnpm0.2.78，未升级。结合已读安装版/.31技能、MIGRATIONS和本轮app指南核对宿主分流；既有版本差异和移动端42及13/28/1/0保持。
