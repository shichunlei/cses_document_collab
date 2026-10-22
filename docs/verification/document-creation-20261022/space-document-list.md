# 创建页空间文档列表

日期：2026-10-22。状态：已落地，关联测试、目标静态检查及Android构建通过；未暂存或提交。

后续审查发现1项恢复完成与空间响应乱序的P2，复现及建议见[审查记录](space-document-list-review.md)；以下保留实现时的验证结果。

该P2随后已修复，最新目标回归与构建结果见[修复记录](space-document-list-p2-fix.md)。

后续独立的位置并发重试P2也已修复，当前55项目标验证见[并发重试修复](space-document-list-retry-fix.md)。

## 行为

- 创建按钮固定在AppBar右上角。创建中禁用并显示处理状态；继续已有创建与打开已完成结果仍使用该入口。
- 选定空间后展示该位置的可见直接子文档，默认按创建时间倒序、每页20条。展示标题、所有者及最新可用修改时间；空标题显示“无标题文档”。
- 列表支持刷新、加载更多、空列表和失败重试；追加及刷新失败均保留已显示条目，重试保持正确页码，分页按文档ID去重。
- SliverList惰性构建并按目标保存滚动位置；空间切换或组件退出后忽略旧响应，账号检查由已绑定Common适配器执行。
- 已有创建操作使用记录中的固定空间或文件夹，列表与展示位置一致；列表失败不阻断独立的新建命令。
- 未知结果的核对勾选和“结束此次记录”保留在正文区域，右上角创建保持禁用，避免误触新建。

本轮是只读元数据清单，不新增已有文档打开、文件夹导航或文档库管理；不改变正文和协同模型。

## 客户端与Java接口依据

参考当前工作区源码；客户端HEAD `235b0073bd`，Java HEAD `9b0b673e1a`，具体文件哈希见[机器记录](space-document-list.json)。两个参考仓库未修改。

| 来源 | 依据 |
|---|---|
| cses-client `packages/docs/src/entity-catalog/entity.service.ts:258` | getDocList查询空间/文件夹下的文档；POST /doc/document/list；父节点字段id；owner缺省时不发送 |
| Java `DocDocumentController.java:163` / `ComplexIdQuery.java` | /doc/document/list接收id及分页参数 |
| Java `FilterQuery.java` / `PageQuery.java` | createdAt默认倒序；pageNumber从1开始，pageSize默认20 |
| Java `DocNodesQuery.java:39` | 文档类型及ParentId精确过滤，附加当前会话可见性条件；不是整个空间递归查询 |
| Java `DocumentQueryHandler.java:164` / `DocumentItemView.java` | 返回items与totalCount；非空分页未设置hasMore、pageNumber或pageSize，因此以请求偏移和totalCount推导下一页 |

请求形状：

```json
{"id":"当前空间或文件夹ID","pageNumber":1,"pageSize":20,"timeSort":"createdAt"}
```

## 实现与验证

- 宿主Common HTTP适配器增加loadDocuments，继续复用现有Dio鉴权及错误分类，不创建网络客户端。
- 新增DocumentListEntry/DocumentListPage不可变模型及独立DocumentSpaceList Sliver组件，宿主通过显式loadDocuments回调注入页面。
- 更新宿主、页面调用方及设备测试夹具，创建协调器、包级API、原生代码和FRB签名保持原状。
- 74项关联回归通过，0失败、0跳过。新增覆盖接口字段、hasMore缺省、异常数据与账号变化、分页去重、下一页/刷新失败重试、迟到响应、卸载、大字及惰性构建、右上角入口与固定恢复位置。
- 目标静态分析无问题；10个修改手写Dart文件格式复核无变化，git diff --check通过。
- Android调试APK构建通过，并核对6个修改/新增应用Dart源文件均完整嵌入当前构建产物，与工作区一致。
- 本轮未修改协同包/Rust，没有重复执行与列表UI无关的包内全量及Rust测试；沿用之前报告的历史结果，不将其记作本轮新增验收。

验证摘要见[输出](space-document-list-validation.txt)。首次运行有两项测试定位/等待条件需同步：右侧按钮坐标改按逻辑像素判断；Sliver滚动到核对勾选后等待布局帧再点击。未放宽新建次数、固定目标、恢复状态或异常断言。

## 边界及版本

真实业务服务返回、物理设备及在线双端未验收。设备清单未发现Android设备；iOS完整App之前受SwiftPM解析阻塞，本轮未重试该环境问题。设备测试源码已同步新回调，但本轮未执行设备断言。

桌面配置仓库再次查询latest=0.11.27；桌面声明/Yarn锁定/实际安装为0.11.24/0.11.24/0.11.21。复核随包技能、MIGRATIONS及宿主创建/数据契约，未升级依赖或修改Schema/输入/选区/历史/协同。41块及13/14/1/13统计和其余上游待办保持。
