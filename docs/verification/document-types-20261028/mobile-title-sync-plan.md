# 手机文档名称同步补齐方案

日期：2026-10-28。基于[手机适配核查](mobile-title-sync.md)与[桌面链路](title-sync.md)，本轮仅方案和归档，不修改产品实现。

## 目标与范围

补齐SaaS首页列表、目录及详情的名称同步，复用Common现有CSES主WS。包含首页“浏览过/编辑过/点赞过”、已加载的收藏/共享/目录条目、原生详情头部/AppBar/更多菜单名称，以及现有WebView详情的原生标题。改名继续使用原HTTP接口，业务名称不进入正文Yjs或撤销历史。

本轮不扩展为全部文档库实时能力，不实现新的服务器协议或客户端全局文档镜像。删除/移除消息只清理受影响条目并沿现有详情访问复核处理；不由名称消息授予正文编辑权。

## 参考其他模块

- [CsesPageWebSocketAdapter](../../../../cses/cses.saas/lib/shared/presentation/realtime/cses_page_websocket_adapter.dart)：借用Common、页面实例ID、首次订阅与中心化重连恢复。新文档业务订阅必须onlyListen=false；该适配器默认true，不能直接沿用默认值。
- [会议初始化协调器](../../../../cses/cses.saas/lib/modules/meeting/presentation/live/coordinator/lifecycle/meeting_initialization_coordinator.dart)：事件dispatcher与页面业务恢复分开，reconnectParams交给Common，不在回调中再subscribe。
- [会议弹幕实时端口](../../../../cses/cses.saas/lib/modules/meeting/application/port/i_meeting_barrage_realtime_port.dart)与[适配器](../../../../cses/cses.saas/lib/modules/meeting/infrastructure/realtime/meeting/meeting_barrage_adapter.dart)：Application依赖业务端口，Infrastructure解析外部协议。弹幕使用IM连接，这里只借鉴分层方式；文档仍使用CSES主连接。
- [WebSocketPageId](../../../../cses/cses.saas/lib/shared/presentation/realtime/websocket_page_id.dart)：唯一注册身份；文档侧通过Composition Root注入ID创建器，不让Application依赖Presentation。

新文档适配器使用Common的可等待registerListenersAsync/unregisterListenersAsync，遵循现有共享适配器的语义。无需改造通用页面适配器或主连接生命周期，不创建/关闭Socket；冷连接如需warm up，仍委托Common既有入口。

## 分层与资源归属

1. Application新增最小文档实时端口与编排服务；Infrastructure新增Document协议适配器，解析recentChanged/metadataChanged/childrenChanged的明确字段。页面Logic只消费已验证的名称/移除事件，Binding负责组装。
2. 同一账号/企业/环境/会话复用一个doc实时订阅管理器，登记到SessionResourceRegistry，切账号/企业前等待关闭。它维护订阅引用，不持有全局文档实体缓存。
3. 按channel/topic/instance复用底层登记。首页、详情、收藏同时关注同一文档时只注册一条Document/docId/空instance；最后一个关注者释放才unsubscribe。Common当前按pageId发送注销，不能让各页面独立注册同一业务路由后各自unsubscribe。
4. 每个页面获得可等待释放的关注句柄，分页新增、筛选切换、目录展开/折叠按差量增减；仅关注已加载条目，不扫描全库。异步注册后页面已关闭时立即释放，旧回调不能回写新页面。
5. SDK继续负责通用业务头部状态；SaaS负责Document消息、身份、列表和宿主快照。SDK不导入Common或SaaS。

## 订阅矩阵

所有业务订阅channel=Document、instance为空，params={}；reconnectParams={isReconnect:true}，onlyListen=false，失败即时发送不入离线队列。正文collab独立instance保持原流程。

| 消费范围 | topic | 消息及应用方式 |
|---|---|---|
| 首页浏览过/编辑过 | 当前userId | recentChanged；按ID合并名称，沿本人openedAt/edited/personalEditedAt判断列表归属与排序，不使用全局editedAt推断本人编辑。 |
| 首页空间根与展开目录 | 空间ID/文件夹ID | childrenChanged更新子项名称；metadataChanged更新所订阅目录自身名称。 |
| 点赞过、收藏、共享等已加载条目 | 已加载的各文档ID | metadataChanged；按ID只更新名称，不因收到消息将不属于当前筛选的文档插入列表。分页/切换范围释放无用关注。 |
| 原生与WebView详情 | 当前文档ID | metadataChanged；共享同一个文档关注，更新宿主名称及头部/原生AppBar/更多动作参数。 |

userId主题只代表本人recent记录，不是覆盖点赞/收藏/全部可见文档的通配订阅。搜索等其他列表可复用同一已加载条目关注能力，不在本轮新增全库推送协议。

## 本地改名和远端改名统一应用

- 本地列表菜单、原生编辑器头部、更多菜单改名都经既有Application写入；成功ACK后发布同一DocNameChanged事件，失败不发布。事件发布点位于应用写入边界，不能只在某个页面回调补发；原生头部的MetadataAdapter也要覆盖。
- WS消息在Infrastructure校验nodeId/data.id/name存在及类型、订阅归属和接收身份，再转为相同业务名称事件。remove消息不要求name，不按空字符串覆盖名称。
- 列表按ID不可变替换名称，保留当前列表的行为状态、分页和其他字段；标题排序场景沿已有排序策略。去掉改名后重复整表刷新，以即时名称事件为主，重连/真实冲突才补读。
- 原生DocCollabHost同时更新snapshot与SDK header，避免编辑器标题已更新、更多菜单仍读旧snapshot。SDK在DocumentMetadataController补一个通用的“应用宿主权威元数据补丁”公开入口：检查文档ID/存活状态，不发HTTP，不触发写权限门禁，不写正文/历史；本轮仅用于name。现有load/update接口和消费者保持兼容。
- WebView详情更新原生appBarTitle及更多菜单名称；网页内部由其现有Document订阅负责。需要验证网页内部标题和原生标题一致，不为每条名称消息reload整份网页。
- 不触碰正在输入的改名草稿；远端变化更新已提交展示值并提示冲突，用户确认前复核基准名称，避免旧草稿无提示覆盖新标题。

## 顺序、重连与异常

- eventId结合action/topic/nodeId做有界去重；version仅在当前物理连接代次及对应路由内比较，重连清空。Common负责自动重订阅，doc回调只发出需补读信号，禁止再次手动subscribe。
- 先安装监听再初读；查询期间记录名称变化，HTTP响应返回后重放相应补丁，防止旧详情/列表覆盖推送。重复刷新合并，同文档只有一个补读任务。
- 本地改名在途遇到远端名称变化时记录冲突；ACK不直接覆盖已观察到的冲突结果，完成后合并一次权威详情补读。HTTP ACK和WS投递序号不能直接比较，version不是数据库版本。
- 重连/前台恢复重读当前列表和详情，保留现有分页/目录恢复策略并合并重复触发；不逐条推送发HTTP，不为名称更新调用会撤下正文编辑能力的整套refreshAccess。
- 身份变化立即失效旧监听/在途结果，清理去重和待重放状态。无效消息记录诊断，不把解析失败当作空名称；服务端移除/访问失效沿现有撤下详情流程，不由缓存恢复授权。

## 实施顺序与验收

1. 先实现协议适配、doc会话级订阅复用与生命周期测试，再接首页recent/目录和已加载条目关注。
2. 统一本地ACK名称事件，接入原生宿主、SDK头部补丁和WebView原生标题，补齐所有现有改名入口。
3. 测试相同topic多页面退出、空instance与正文instance隔离、分页/筛选/切空间、重复/乱序、初读竞争、保存冲突、重连低序号、切账号与迟到响应；验证更新名称不丢收藏/点赞、不重置正文选区或撤销。
4. 在共享包、SaaS、必要的Common消费者分别运行目标测试/分析与格式检查；Demo覆盖公共API兼容。若不修改Common，不为文档功能新增Common业务代码。
5. 在最终jqdl宿主构建并进行真机/桌面双向验收：手机停留首页时桌面改名、详情内桌面改名、手机各入口改名、返回来源列表、断网重连、前后台与切账号。记录真实接口持久化和双端可见结果，不能用模拟消息或单元测试替代。

## 本轮状态与版本

方案已完成，尚未实施，不新增测试通过声明。只检查文档链接与git diff --check；此前67项回归仍为上一轮证据。

本轮桌面配置仓库latest查询ECONNRESET，最新稳定版待核对。重新读取桌面声明/Yarn锁已为0.11.33，安装仍0.11.17；这是外部工作区当前状态，本轮没有升级。安装版与留存0.11.31随包L0/数据说明/MIGRATIONS已读；本地未找到0.11.33发布包，其随包文档/迁移和与当前桌面声明的差异待核对，不能沿用.31宣称已覆盖.33。方案不修改块协议，42及13/28/1/0统计不变，既有上游差异继续待同步。
