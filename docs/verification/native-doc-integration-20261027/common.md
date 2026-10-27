# Common 接入前置能力验证（2026-10-27）

用户已确认先完成 Common 可等待登记、注销及不入队即时发送，验证后继续原生文档接入。

## 实现

Common 新增 registerListenersAsync/unregisterListenersAsync、trySendMessage/trySendWithPage；
immediateOnly 登记的订阅/恢复/发送/退出禁止入队。默认旧接口保留排队、首次/重连参数及自动退出。
票据同步失效，等待锁的旧注册取消；关闭清理旧监听，同名页面重开隔离。
trySendWithPage 默认确保本代订阅发送，退出命令显式关闭该前置；localOnly 注销只释放本地登记。
重连后新登记的首次订阅失败重试保持首次参数；已先通过反例复现再修复。旧入口的预期登记取消不记为错误。

## 验证

- Common 目标39项通过，含16项新测试；真实回环连接验证会议和直播旧入口的首次订阅、重连参数、自动退出及共享连接保持。见 common-target-tests.log。
- Common 三文件目标静态检查通过；能力边界脚本和 git diff --check 通过。
- SaaS 会议协议、用户信息和直播弹幕17项通过；现有实时适配器与会议命令适配器静态检查通过。
- 扩展回归发现既有 websocket_envelope_log_summary_test 的正文脱敏断言与已提交实现（保留完整正文）冲突；该函数与 HEAD 的 SHA256 均为75479efb52740c8a9a487ae95482b45e7f20f7e4052d1ef22e75bcbb66d3ee70。本次未修改该语义。最终扩展回归40通过/1失败，整组不记为通过，失败保留在 common-expanded-regression.log。
- Common 既有暂存 analysis_options.yaml/pubspec.yaml 及 SaaS 的 pubspec.yaml 改动保持未动，没有暂存本次文件。

## 范围与复跑

测试对端只绑定127.0.0.1，不连接真实业务服务器，不替代真机会议/直播或真实桌面协同验收。
Common 的新测试位于 test/network/websocket/cses_websocket_registration_test.dart；本目录保留审查副本。
在 Common 执行 flutter test --no-pub test/network/websocket/cses_websocket_registration_test.dart 可复跑新16项。
后续协同包与SaaS记录继续归档本目录。当前记录不表示原生文档接入已完成。

## 范围收回

用户随后明确暂不开展协同包可嵌入正文、基础编辑限制及 SaaS 原生路由/会话接入。
已撤回协同包4个手写文件及新增正文组件的全部试改；SaaS没有新增接入代码。
保留Common实现及本阶段验证。撤回前试改运行的54项测试有53通过/1失败（页面头部宽度），
仅存 withdrawn-collab-trial-tests.log 为过程证据，不将其计入Common验收或声明后续接入通过。
原有docs/block-adaptation.md工作区改动保持未动。

归档文本日志已去除终端颜色和行尾空白，保留原时间、结果、失败与限制；压缩的回环输出保持原有归档。
