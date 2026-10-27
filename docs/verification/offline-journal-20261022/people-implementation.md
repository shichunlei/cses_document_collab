# 今日导向宿主组织选人实现与验证

日期：2026-10-22。此记录属于今日导向迁移与动态业务能力这一轮工作；不改变历史设备验收结论。

## 归属与接口

新增宿主文件 `example/lib/src/daily_guidance/guidance_people.dart`，没有向 `仓库根 package` 增加业务目录、选人或今日导向 API。

- `GuidancePerson` 保存真实人员或部门的稳定 ID、名称快照、类型及可选部门名称；目录树可携带子节点。唯一身份为 `type:id`，同名人员不会被合并，人员与部门可拥有相同原始 ID。提供 JSON 往返转换，拒绝非法类型、身份和子树。
- `GuidanceDirectory.load()` 是宿主可注入目录端口；生产实现 `CsesGuidanceDirectory` 借用 Common 登录上下文与 HTTP，读取 `/Company/readAllChildren`，参数 `orgId`、`isReadUser: true`，保留真实组织树，不生成假用户。后台解析，按身份去重，异常响应拒绝整次加载；成功缓存只活在同一实例，失败清除缓存以便重试。
- `showGuidancePeoplePicker` 提供组织钻取、真实层级面包屑、跨组织名称/部门搜索、多选、部门整体引用和已选移除。确认一次返回多个引用，不将部门展开为全部人员，不携带组织子树进入引用结果，不直接操作编辑器。

## 异步与交互边界

目录实例绑定账号、企业和会话，请求前、响应后、后台解析后及缓存读取时校验；失效不泄露旧身份组织。弹窗捕获同一身份，在打开、确认、退场结束以及存活期间的权限检查处拒绝过期结果；撤销后旧弹窗不能因权限恢复而重新写回。返回等待 `ModalRoute.completed`，取消、会话切换、权限撤销均返回 null。

输入和权限检查定时器由弹窗状态创建与释放，关闭或查询变化使迟到结果失效。组织加载和搜索失败提供明确重试入口，空目录与无匹配单独显示。列表惰性构建，未使用 `ListTile`，正文可换行，键盘和大字时内容区可滚动；大型搜索索引在后台处理。

## 验证

仅针对本模块的手写文件执行：

- `dart format example/lib/src/daily_guidance/guidance_people.dart example/test/daily_guidance/guidance_people_test.dart`：通过，最终 0 个文件需要调整。
- `flutter analyze --no-pub example/lib/src/daily_guidance/guidance_people.dart example/test/daily_guidance/guidance_people_test.dart`：No issues found。
- `flutter test --no-pub example/test/daily_guidance/guidance_people_test.dart`：11 项通过，[完整日志](people-tests.log)。
- `git diff --check`：通过。

测试覆盖 JSON、真实 Common HTTP 树解析和认证头、同名/跨类型身份、缓存、失败及非法子树重试、请求期间会话切换、多选和部门整选、跨部门搜索、搜索结果钻取后的真实面包屑、关闭取消、权限撤销与恢复、退场期间会话切换、关闭后的迟到请求，以及大字/键盘约束无布局异常。

首次测试中“退场期间切换会话”的用例在勾选后未刷新按钮启用状态，确认实际上没有触发；补齐测试帧后单独重跑和整组回归均通过。此问题属于测试驱动时序，没有因此改动生产权限判断。

## 验证限制

未在本轮连接企业真实网络或真机验证人员目录与弹窗，生产 HTTP 边界通过 Common 的测试传输验证。是否拥有业务写权限由宿主传入 `canEdit`，不是由选人目录推断。编辑器插入、业务行渲染及草稿迁移由本轮其余实现与集成测试负责，本记录不将目录测试视为这些链路已经验收。
