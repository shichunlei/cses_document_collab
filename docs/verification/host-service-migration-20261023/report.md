# 宿主服务目录迁移收尾

日期：2026-10-23。范围为6个服务移动至 `lib/src/service/` 的导入、示例、依赖声明与调用方完整性；不修改业务实现，不创建Git提交。其他工作区改动保留。

## 修改

- 文档创建、元数据、媒体上传、KR、会议卡片、任务卡片共6个服务归入 `lib/src/service/`，原位置删除与新文件按迁移整体暂存。
- `document_host.dart` 的4处服务导入、创建服务的3处业务模型导入改用当前包名的 `package:` 全路径；宿主装配、首页和5份测试引用新位置。
- 6份类级DartDoc使用示例全部更新到新路径；同步当前协同包README和文档创建计划中的服务路径。历史验证证据保留原始路径，不改写历史。
- 上传服务直接使用的 `file_picker`、`mime` 补入宿主pubspec，版本沿用已安装的13.1.0、2.1.0。离线pub get只把这两项从传递依赖改为直接依赖，没有升级版本；pubspec.lock沿用仓库既有忽略规则，不强制纳入版本控制。

六个服务排除导入、DartDoc及空白后的业务实现与迁移前逐一一致，见[迁移映射与指纹](services.json)。没有移动包内服务、改写Schema或修改Rust/桥接实现，不扩大块适配或平台验收范围。

## 验证

| 检查 | 结果 | 证据 |
|---|---|---|
| 六个服务、宿主装配/首页及5份测试的目标分析 | 无问题 | [分析](analyze.txt) |
| 4份服务测试、创建编排、空间列表、首页和宿主FRB/SQLite测试，共8文件 | 109通过，0失败、0跳过，串行执行 | [最终测试](tests.txt) |
| 13份迁移手写文件格式 | 按原有100/120/80列复核，最终0变化 | [最终检查](final-checks.txt) |
| 活动源码、测试、示例、当前README和计划中的旧服务路径 | 0处 | [最终检查](final-checks.txt) |
| 服务目录及document_host跨目录相对导入 | 0处 | [最终检查](final-checks.txt) |
| 直接依赖解析 | 成功，版本保持 | [pub get](pub-get.txt) |

测试使用仓库README指定的 `FRB_DART_LOAD_EXTERNAL_LIBRARY_NATIVE_LIB_DIR="$PWD/rust/target/debug"`，复用现有本机库，未重建Rust。运行 `flutter test --no-pub --concurrency=1`，覆盖上述8个测试文件。

首次两个测试进程并发使用同一测试产物目录产生清理提示；消费者97项通过，但宿主原生12项因未配置本机库路径失败，并触发初始化未完成的tearDown异常。配置库路径并串行复跑后109项全部通过。首次结果保留在[消费者](consumer-tests-first.txt)、[原生宿主](host-native-tests-first.txt)。展示用txt保留终端结果摘要并清理行尾空白；同名 `.txt.raw.gz` 保存完整原始日志，未删除失败依据。

本轮不新增服务业务用例，复用现有回归；KR和媒体服务完成静态分析、宿主装配编译和业务体一致性核查，未验证真实在线查询或OSS上传。不涉及原生接口、版本升级或平台配置，因此未新增设备或平台构建。汇总见[validation.json](validation.json)，当前源码指纹见[source-sha256.json](source-sha256.json)。
