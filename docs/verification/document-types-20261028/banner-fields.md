# 文档封面仅保留明确字段

日期：2026-10-28。沿用用户对实体简化的要求，移除DocBannerEntity的_extraFields及相关收集、冻结、序列化展开逻辑。

## 实现

- DocBannerEntity只保存title/url/x/y；fromJson直接调用公共构造器，不再维护额外状态或私有JSON构造器，未知键直接忽略。
- 保留封面既有语义：字段缺失/null为null，x/y按num.toDouble转换，toJson省略null；空封面仍输出{}，null封面仍通过专用移除接口处理。已知字段格式错误仍向上传播，没有在本任务中变更该合同。
- 同步DocInfoEntity和模块CLAUDE的封面文档，移除未知封面字段会保留的旧描述。图标、meta及其他实体不属于本次删除范围。
- 更新原API、详情和元数据适配测试，未知字段继续作为输入反例；添加封面写入回归，确认未知fit/plugin不进入业务修改参数。

## 验证

`flutter test --no-pub test/modules/doc/document_api_use_cases_test.dart test/modules/doc/document_list_fields_test.dart test/modules/doc/collaboration/doc_editor_application_service_test.dart test/modules/doc/collaboration/doc_collab_metadata_adapter_test.dart`，**65项通过**，见[测试日志](banner-fields-tests.log)。

5个修改Dart文件已format，目标flutter analyze无问题，见[格式日志](banner-fields-format.log)和[静态检查](banner-fields-analyze.log)。源实体无_extraFields或私有JSON构造器残留，活动模块文档无未知封面保留承诺；两个仓库git diff --check通过，记录相对链接有效。

边界覆盖：仅未知键的对象输出{}、已知/未知混合只输出四字段、空值省略、数字转换、详情和SDK元数据读取/写入、显式移除和权限守卫。未提交本次修改，已有暂存区保留未动；未新增真机、真实业务服务或完整App构建验收。

[封面实体](../../../../cses/cses.saas/lib/modules/doc/domain/entity/doc_banner.dart)；[读写适配回归](../../../../cses/cses.saas/test/modules/doc/collaboration/doc_collab_metadata_adapter_test.dart)。
