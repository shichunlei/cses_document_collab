# Demo Gateway 切换 Common 新接口（2026-10-27）

## 范围与实现

本轮只调整 example 的 CommonCsesCollabGateway 及其文档/测试，不接入 SaaS，
不引入协同正文组件、基础编辑限制或原生路由。此前 Common 能力及其他工作区改动保留。

- 通过 Common 网络公开入口调用 registerListenersAsync(immediateOnly: true, params: {})。
- 平台订阅与重连恢复统一由 Common 管理；Gateway 的连接状态流仅转发事件，多监听者不重复订阅。
- trySendWithPage 即时发送，不产生离线队列；失败保留原协同会话的向量重同步策略。
- collabLeave/unsubscribe 关闭订阅前置；会话发送网络退出后，Gateway 等待 localOnly 注销，
  不重复 unsubscribe、不关闭共享主连接、不移除其他Gateway的页面登记。
- 删除生产适配器中的lock屏障、onlyListen手工恢复与自有协议路由封装。
  Gateway仅保留自身登记票据，隔离注销重开及迟到的注册失败。

## 验证

- example目标21项全部通过：新Gateway 7项、既有Common回环2项、宿主原生生命周期12项。
  见 example-gateway-tests.txt；完整输出压缩保存于 example-gateway-tests.log.gz。
- 核心会话/控制器14项全部通过，见 example-core-tests.txt / example-core-tests.log.gz。
- example 4个目标文件 flutter analyze --no-pub 无问题，见 example-gateway-analyze.txt。
- 新测试最初缺少AppFlowy事务扩展的公开入口导致编译失败，补齐直接依赖入口后重跑通过；
  没有修改AppFlowy、Rust或桥接生成物。
- 对修改Dart文件执行format；全局检索生产Gateway确认无lock.synchronized、onlyListen、
  sendMessageWithResult或手动发送subscribe残留；git diff --check通过。

新增回环测试覆盖：多监听者、首次与重连订阅/join顺序、离线与同步失败不入队、
在线退出仅一次unsubscribe、在途注册取消/重开、跨适配器所有权隔离。
真实FRB用例从同源空文档开始，验证在线输入→断网输入→重连完整补传，关闭后通过另一份
SQLite上的只读控制器读取同一V1状态，确认正文一致且只读握手上行为空update。
测试对端只保存握手完整状态并回放，不实现业务后台或服务端保存ACK。

## 命令与边界

从example目录：

```sh
FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR="$PWD/../rust/target/debug" flutter test --no-pub \
  test/common_cses_collab_gateway_test.dart test/cses_ws_gateway_integration_test.dart test/document_host_native_test.dart
flutter analyze --no-pub lib/src/demo/common_cses_collab_gateway.dart \
  test/common_cses_collab_gateway_test.dart test/cses_ws_gateway_integration_test.dart test/document_host_native_test.dart
```

从根包执行同样的原生库环境后运行test/cses_doc_collaboration_session_test.dart和
 test/collab_controller_lifecycle_native_test.dart。

本机已有debug原生库，FRB内容签名校验及真实调用成功；本轮没有原生源或接口改动，未重建。
仅使用模拟登录和回环协议服务，未连接真实业务后台、真机或真实桌面窗口，不新增平台构建结论。
BlockCraft配置仓库latest查询失败（ENOTFOUND），桌面声明/Yarn0.11.31、安装0.11.17、
历史pnpm0.2.78。核对安装版与本机0.11.31发布包随包技能/迁移、数据模型及移动会话实现；
未升级、未修改块适配范围或统计。版本与源码指纹见example-gateway-validation.json。
