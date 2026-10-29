# 精简搜索结果字段核对

日期：2026-10-28。依据用户提供的搜索item结构逐项核对；测试使用虚构ID与成员信息。

## 结论

本份响应的12个顶层字段当前均已覆盖，无需新增实体字段：

- `id/name/nodeType/documentType/spaceId/spaceName/createdAt/updatedAt`：通过搜索实体及其列表/目录父类读取。
- `creator/owner/updater`：显式恢复CompanyStructureBean，包含公司、组织、部门、人员身份、名称及isUser/user兼容；updater沿用前轮归入公共列表的字段，不重复声明。
- `icon:{}`：沿用没有可用图标的null语义，不伪造图标。

Repository搜索入口将items直接映射为DocSearchResultEntity，页面消费该实体，未发现中间映射丢字段。

本样例不返回highlight、banner、behavior、localUser、editor、openedAt、editedAt等字段，按现有模型保留null/0/false，不把缺失字段视为接口错误，也不补造业务值。序列化继续保留父级默认字段及成员既有精简输出合同，不把toJson当成原始接口字节备份。

## 本轮改动

- 补充DocSearchResultEntity.fromJson的精简响应与缺省值契约文档；未修改运行时解析或序列化实现。
- 在已有document_list_fields_test.dart中新增3项：完整精简搜索字段解析、精确输出Map、文档/文件夹nodeType独立及null/数值转换。更新人与所有者使用不同虚构身份，确认不会混用。

## 验证

`flutter test --no-pub test/modules/doc/document_list_fields_test.dart test/modules/doc/document_type_routing_test.dart test/modules/doc/document_api_use_cases_test.dart`，**65项通过**，见[测试日志](search-fields-tests.log)。目标2文件dart format与flutter analyze无问题，见[格式日志](search-fields-format.log)及[静态检查](search-fields-analyze.log)；两个仓库git diff --check通过。

边界已覆盖：空icon、缺失highlight及列表附加字段、三个完整成员、updater与owner不同、nodeType=folder且documentType=null、num转int及精确序列化键集合。建议后续在真机搜索页核对无高亮/空图标与不同更新人记录；本轮未新增真机、真实HTTP服务或完整App构建验收。

[搜索实体](../../../../cses/cses.saas/lib/modules/doc/domain/entity/doc_search_result.dart)；[专项回归](../../../../cses/cses.saas/test/modules/doc/document_list_fields_test.dart)。
