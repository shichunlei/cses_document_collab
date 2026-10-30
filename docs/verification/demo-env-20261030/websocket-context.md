# WebSocket 地址跟随 Common 上下文

日期：2026-10-30。

按用户已修改的 `DemoEnvironment.websocketUrl => ctx.websocketHost` 对齐注释和登录时序。Getter 返回 Common 当前连接地址，登录上下文未解析时可为 null，不再将其描述为 env 必填项。Common 通过登录响应 webConfig 或自身环境配置解析主连接地址。

configureCommon 先于 /User/login 执行，因此移除这里对 websocketUrl 的强制解包、提前校验和对 Config.webSocket 的回写，避免首次登录的空值异常，也避免旧账号的 ctx 地址污染下次登录的回退配置。保留 CsesAccountLogin 在 resolveContext 后对身份和 WS 地址的完整校验。

从空模板、测试配置和本机忽略配置移除 CSES_WEBSOCKET_URL。更新当前 README 的字段说明与 Common 环境回退语义，同时移除已不再使用的头像 env 说明。环境测试删除旧的 env 头像断言，增加登录前 getter 为 null、随 ctx 更新、重复配置不回写旧主连接地址的验证。旧 env 注入与头像测试报告保留历史状态，不作为当前实现验收。

验证结果见 [websocket-validation.json](websocket-validation.json)。本轮不运行真实服务登录或真机协同验收。
