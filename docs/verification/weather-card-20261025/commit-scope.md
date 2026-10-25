# 天气适配提交核查（2026-10-25）

提交覆盖正式weather协同节点/字段历史/JSON、7种原生布局和6色调、宿主真实源接口与Demo适配、插入/刷新/锁/删除、底部设置、固定居中预览/左右循环/名称，以及测试、夹具、技能规则和历轮功能证据。

以日期适配已独立提交的HEAD为基线，仅暂存天气范围。共用适配表和验证索引按内容拆分，保留未提交的内容分类文档及其索引条目、根file_picker版本改动；不夹带无关业务改动，不推送远端。

桌面配置仓库本轮重新执行npm view，latest=0.11.30；桌面声明/Yarn0.11.28、安装0.11.21，未升级。
本次没有改变天气桌面契约；三版随包技能、MIGRATIONS和天气实现沿用本日[版本指纹](style-navigation-version.json)。

提交前复验结果及暂存源码指纹见[本轮校验](commit-validation.json)。前轮[Android构建](android-final-build.log)保留原范围，后续面板/箭头调整已由Widget测试验证，不新增宣称平台/真机/真实在线双端通过。
旧工具栏禁用能力用例的已知失败仍见[原报告](report.md)，没有修改其断言或清理无关源码。

天气继续部分支持；旧固定日缺失frozen的无Undo初始化、自由布局/组合/动画、模板及完整对象剪贴板、真机/iOS/真实在线双端等限制保留。

## 提交前复验

- 天气界面/历史/JSON、固定预览与左右循环、底部面板及公共弹窗共36项通过，见[日志](commit-flutter-tests.log)。
- 宿主天气源解析、缓存合流/刷新绕过、失败和资源释放3项通过，见[日志](commit-host-tests.log)。
- 使用本工作树重新构建原生库，真实FRB/原生历史/SQLite重开2项通过，见[桥接日志](commit-native-tests.log)和[构建日志](commit-native-build.log)。
- Rust fmt/check通过，crate全量200项通过，含天气三个正式Yjs夹具用例；vendor既有58条编译警告保留，见[测试](commit-rust-tests.log)、[格式](commit-rust-format.log)、[检查](commit-rust-check.log)。
- 提交范围包内21个Dart目标静态分析无诊断，见[分析](commit-analyze.log)。宿主4目标和天气创建4项沿用当前同源指纹的前轮通过记录。

本次新增归档日志清理了行尾空格和EOF空行；凡有调整均同时保存原始字节的.raw.gz备份，
映射和前后SHA-256见[归档记录](commit-log-normalization.json)。历史失败与限制、正文和源/产物指纹保持。
