# Demo 环境配置迁移

日期：2026-10-30。

本记录保留首次构建环境注入方案的历史结论。后续已按用户要求改为启动时读取资源，当前实施与验证见 [运行时读取配置](runtime-loading.md)。

默认登录账号、密码改为 CSES_DEFAULT_USERNAME / CSES_DEFAULT_PASSWORD 构建环境变量，缺省为空。API、WebSocket 回退、文档站点、头像和上传 CDN 后缀通过 DemoEnvironment 读取；Common 的公开配置字段在每次登录请求前覆盖，不再以 EnvType.pre 决定实际服务地址。服务端登录响应提供的 WebSocket 地址仍优先。

本地原值迁入 example/.env.json（权限 0600，Git 忽略），仓库提供空值 example/.env.example.json；测试使用 example/config/test.env.json 的合成地址。Flutter 原生 --dart-define-from-file 加载 JSON，无新增依赖。主 README 与 Demo README 的运行、构建命令同步更新。默认凭证会进入构建产物，发布时应留空。

必要服务配置缺失、协议无效、origin 含路径、查询、凭证或 fragment 时在请求前失败，错误只显示变量名。头像未配置时显示姓名首字，CDN 后缀未配置时在上传副作用前失败。第三方天气 API、公共封面素材及仓库/元数据链接仍沿用固定资源协议；未修改仓库外 Common 的环境枚举及其他宿主。

验证：14 个目标文件静态分析无问题；带 env 的 39 项回归通过；不传 env 的 2 项边界测试通过；git diff --check 通过，旧 PRE/头像业务地址已从 example/lib 清除。完整命令、首次无效测试目标导致的失败及未验收范围见 [validation.json](validation.json)。未运行真实登录、OSS 上传、平台构建或真机验收。
