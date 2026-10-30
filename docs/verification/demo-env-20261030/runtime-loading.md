# 启动时直接读取 .env.json

日期：2026-10-30。

按用户后续要求，将构建参数注入改为应用启动时通过 rootBundle 读取 `.env.json`。example/pubspec.yaml 将其声明为 asset，main 在创建登录页前等待配置加载完成。无需 dart-define 参数，普通 `flutter run`、IDE 启动及平台构建直接使用本地文件；首次检出与 CI 构建前仍需由空模板创建文件并填写。

DemoEnvironment 保存只读字符串配置快照，登录页及 Common 配置流程同步读取该快照。不读取进程环境或构建常量，不增加依赖。读取失败、JSON 损坏、根值非对象或字段值非字符串时清空原快照，抛出不含原配置内容的错误，启动入口显示错误并停止创建登录页。空对象不会提供真实账号密码或服务地址兜底，必要 host 校验仍在登录请求前执行。

本地文件继续受 Git 忽略；文件会作为明文应用资源打包，发布时默认账号密码应留空。修改文件后重新运行应用更新资源。测试通过独立 AssetBundle 从 config/test.env.json 加载合成配置，避免读取本机真实凭证；覆盖正常加载、空配置、资源缺失、无效 JSON、非字符串值及清除旧值。

验证命令与结果见 [runtime-validation.json](runtime-validation.json)。未执行真实服务登录、OSS 上传、真机或平台原生构建；`flutter build bundle --debug --no-pub` 仅验证 Dart 编译和资源打包。此前构建参数方案的结论保留于 report.md 和 validation.json。

后续头像函数已由调用方改为代理 Common；对应注释核对见 [Common 头像代理注释](avatar-comments.md)，不沿用本记录的历史头像测试结论。

后续主连接地址也已跟随 Common 上下文，配置项及登录时序调整见 [WebSocket 上下文适配](websocket-context.md)。
