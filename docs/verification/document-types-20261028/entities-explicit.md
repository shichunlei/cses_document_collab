# doc实体明确字段检查与清理

日期：2026-10-28。按用户要求检查doc模块其他实体，统一移除未知顶层字段兜底保留，仅解析明确声明字段。

## 检查与改动

- 遍历domain/entity下全部16个手写Dart文件，字面_extraFields已经没有残留。发现DocBlockEntity仍通过_source缓存整份原始JSON并回传未知顶层键，属于等价逻辑，已一并移除。
- DocBlockEntity仅解析/输出id、flavour、nodeType、props、meta、text、content、children、parentId、mode十个声明字段；未知顶层键忽略。仅记录这十个键的存在性，不保存原始值，以保持部分更新中缺失与显式null不同的既有语义。
- props/meta/content、DocEntity.meta和权限settings.fields均为明确声明的JSON/集合协议字段，其内部数据保留；集合递归冻结、Delta/子块顺序、未知flavour/mode字符串及数值不被改写。评论内容兼容处理中的临时Map不会保存未知顶层字段，不属于额外字段缓存。
- 更新块DTO及读取/编辑请求测试，输入继续含未知顶层键作为反例，期望为独立的已声明字段Map；插件样例放在明确props字段内部，验证内部数据与不可变性保留。
- 复测发现DocBehaviorEntity的comment被改为直接num强转，导致既有“非法类型用0”的回归失败；本轮仅将该处改为内联有限num匹配/default0，保留当前无辅助缓存/无场景分流的实现。
- 同步SaaS模块CLAUDE及块DTO契约文档；不变更共享协同包、桌面依赖、Schema、FRB或Rust实现。

## 验证

- 先补单项反例，原实现把plugin/futureField继续输出，测试失败复现，见[原反例](entities-explicit-before.log)。
- 首轮关联回归99通过/1失败，唯一失败为上述comment错误类型强转，见[首轮日志](entities-explicit-first-tests.log)；修正后7组目标回归**100项通过**，包含文档API、列表、行为实体、类型分流、新建编排、SQLite存储和真实原生初始协议，见[最终日志](entities-explicit-tests.log)。
- 运行命令：`FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR=/System/Volumes/Data/workspace/cses_document_collab/rust/target/debug flutter test --no-pub test/modules/doc/document_api_use_cases_test.dart test/modules/doc/document_list_fields_test.dart test/modules/doc/doc_behavior_entity_test.dart test/modules/doc/document_type_routing_test.dart test/modules/doc/collaboration/doc_creation_service_test.dart test/modules/doc/collaboration/doc_creation_store_test.dart test/modules/doc/collaboration/doc_creation_protocol_native_test.dart`。
- 全部实体目录及关联新建/存储消费者静态检查无问题，实际修改的3个Dart文件已format，见[分析日志](entities-explicit-analyze.log)、[格式日志](entities-explicit-format.log)。
- 16个实体文件检索无_extraFields/_source，两个仓库git diff --check通过，记录链接有效。字段清单见[机器记录](entities-explicit-validation.json)。

边界覆盖未知顶层键、仅未知键、未知键中的非JSON对象、十个明确字段的显式null、缺失/空集合、嵌套JSON保留与冻结、请求过滤、原生映射和恢复一致性。建议后续真实业务确认新出现的块顶层协议字段正式补入实体声明；本轮没有新增真机、真实服务或完整App构建验收。

## BlockCraft核对

按桌面配置仓库查询latest失败ENOTFOUND，最新稳定版待核对。桌面声明/Yarn0.11.31、安装0.11.17、历史pnpm0.2.78，未升级。读取安装包和本机留存0.11.31的L0/数据说明/MIGRATIONS，结合受影响SaaS DTO和原生映射链路确认props/meta/children等声明数据继续保留；缓存版本不作为实时latest依据。既有42种块及13/28/1/0不变，既有上游差异继续待同步。

[块实体](../../../../cses/cses.saas/lib/modules/doc/domain/entity/doc_block.dart)；[请求与解析回归](../../../../cses/cses.saas/test/modules/doc/document_api_use_cases_test.dart)。原有暂存区保持未动，未提交本次修改。
