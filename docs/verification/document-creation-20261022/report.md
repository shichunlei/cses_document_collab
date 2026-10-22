# 手机新建正式文档实施与验证记录

日期：2026-10-22。状态：核心代码及本地回归已完成；真实业务服务与在线双端待验收。

提交审查发现的三项问题已修复，新增验证及当前结论见[修复记录](review-fixes.md)。以下保留首次实现时的结果与边界。

后续创建页已增加当前空间文档列表，并将创建按钮移至右上角，详见[空间列表记录](space-document-list.md)。

## 实现范围

- 首页提供新建空白文档入口，使用真实空间列表，支持入口传入空间或文件夹位置。
- 宿主复用Common鉴权进行位置权限预检、HTTP建档、初始块快照保存和权限读取。
- `DocumentBootstrapper.prepareBlank()`以短生命周期原生资源准备正式root和一个空paragraph。
- 初始V1增量与本地初始化标记在同一SQLite事务提交；重试保留相同CRDT身份。
- `PreparedDocument`从同一份原生快照生成HTTP Insert数据，不在Flutter侧另造正文。
- 账号分区记录使用临时文件、flush和同目录rename提交；已取得的docId在落盘失败时仍保留于内存，继续时先补写。
- 并发恢复共享在途任务，创建期间禁止重读；关闭等待在途任务，不保留已结束的恢复Future。
- 创建结果不明时停止自动建档；初始快照结果不明时先回读，缺失或不同正文不盲目重复Insert。
- 迟到创建结果不弹出其他路由；保留“打开文档”入口，并捕获固定控制器、校验清缓存确认时的文档身份。
- 动态docId打开正式控制器，文档切换保留账号主连接；关闭账号等待文档和创建任务释放。
- 正式读取编辑权限，明确拒绝时撤权，离线状态标签区分可编辑与只读；未引入乐观owner缓存。
- 本机新建文档遇到不同CRDT来源的远端根时，在补传前拒绝并保留本地数据；返回稳定冲突代码并停止自动重试。

实现及设计说明见[创建方案](../../mobile-document-creation-plan.md)。文件夹位置通过入口`initialTarget`继承，当前Demo位置列表只列空间，不包含完整文档库或目录管理。

## 版本与生成

| 项目 | 核对结果 |
|---|---|
| 桌面声明 / Yarn锁定 / 安装 | 0.11.24 / 0.11.24 / 0.11.21 |
| 配置仓库latest | 0.11.27 |
| 本轮读取发布产物 | 0.11.24、0.11.27，SHA-512与仓库元数据一致 |
| 空正文契约 | 三版RootBlockSchema、ParagraphBlockSchema及editable快照工厂片段一致 |
| FRB | 使用2.13.0生成器，Dart及Rust依赖保持2.13.0 |

本机默认生成器为2.12.0，本轮安装独立的2.13.0工具执行生成，撤回旧工具自动引入的依赖降级；未替换用户默认工具。
BlockCraft其他升级差异未在本轮适配，不据此宣称0.11.27全量兼容。

## 自动验证结果

| 验证 | 结果与边界 |
|---|---|
| Rust `cargo fmt --check`、`cargo check` | 通过 |
| Rust全部测试 | 106通过，0失败、0跳过；包含4项新建初始化事务、重试与根冲突回归 |
| 宿主目标回归 | 40通过，0失败；包括21项协调器/持久化/页面回归、8项真实Common封装加仿真传输契约、11项关联入口与元数据回归 |
| 协同包目标回归 | 21通过，0失败、0跳过；包括真实FRB/SQLite、初始撤销历史、重开、同一引擎所有权、初始化快照校验及会话冲突停止补传 |
| 0.11.24桌面数据层互通 | 通过，包含在包目标21项中；真实桌面Yjs读取手机增量、接续输入，手机接收并SQLite重开恢复 |
| 0.11.27桌面数据层互通 | 对应原生测试3通过，0失败、0跳过 |
| 宿主修改范围静态分析 | 无问题；包含新建模块、宿主、入口、状态面板、目标测试和设备测试源码 |
| 协同包修改范围静态分析 | 无问题；包含公开准备端口、模型、会话、导出及目标测试 |
| Import边界 | 修改范围无跨目录相对import，宿主与消费者通过协同包公开入口调用 |
| Dart格式、`git diff --check` | 通过；生成物由匹配版本工具生成，未手工维护 |
| Android调试APK | 构建通过，包含原生库；未连接Android设备运行新建流程 |
| iOS原生XCFramework | aarch64真机、aarch64模拟器、x86_64模拟器构建通过 |
| iOS完整App / 设备流程 | 未通过构建前置解析，尚未运行测试断言，见下节 |

桌面互通使用发布包RootBlockSchema实现和桌面安装的真实Yjs进行数据层交换，不是实际桌面窗口验收。
Common测试保留真实请求封装、账号检查和拦截器，但HTTP响应来自测试替身，不连接真实服务。

### 实际执行的目标测试

宿主目录：

```bash
flutter test --no-pub --timeout=90s \
  test/document_creation_coordinator_test.dart \
  test/cses_document_creation_service_test.dart \
  test/collab_demo_page_test.dart \
  test/cses_document_metadata_service_test.dart
```

协同包目录（参数使用本机实际路径；Node需18或更新版本）：

```bash
flutter test --no-pub \
  --dart-define=BOOTSTRAP_NODE_EXECUTABLE=/path/to/node \
  --dart-define=BOOTSTRAP_DESKTOP_ROOT=/path/to/cses-client \
  --dart-define=BOOTSTRAP_PACKAGE_ROOT=/path/to/blockcraft-0.11.24/package \
  test/document_bootstrapper_native_test.dart \
  test/prepared_document_test.dart \
  test/cses_doc_collaboration_session_test.dart \
  test/collab_controller_lifecycle_native_test.dart \
  test/collab_controller_native_test.dart
```

将发布包路径换成0.11.27，对`document_bootstrapper_native_test.dart`另外执行3项真实原生/互通测试。
未提供桌面路径时，互通项显式跳过；本轮互通运行均提供路径，不把跳过记为通过。缺少原生动态库仍直接失败。

## iOS设备验证的限制

已提供[设备隔离流程测试](../../../integration_test/document_creation_device_test.dart)：使用生产创建页、真实FRB/SQLite、正式控制器和编辑页，仅替换业务HTTP及网关，不登录或修改真实账号。

本轮尝试在iPhone 16 Pro模拟器运行。首次启动涉及系统数据迁移，随后现有App的SwiftPM依赖解析持续超过十分钟，未进入应用运行阶段。
停止该次解析后，用`-skipPackageUpdates -onlyUsePackageVersionsFromResolvedFile`复核，仍在90秒有界等待内未完成。
因此不能将iOS原生库构建通过写成完整App构建或设备新建流程通过。

诊断摘要见[iOS解析记录](ios-swiftpm-resolution.txt)。本轮未修改SwiftPM依赖、锁文件或关闭既有插件以绕过问题。

环境恢复后，在宿主目录重新执行：

```bash
flutter test --no-pub integration_test/document_creation_device_test.dart -d IOS_SIMULATOR_ID
```

该隔离测试即使通过，也仍不代表真实服务和在线双端验收通过。

## 扩大静态检查的存量结果

根项目扩大扫描报告25条info，无error/warning：4条既有直接依赖声明提示、19条Cargokit工具源码库注释提示，
以及既有视频Future表达式和既有原生测试StreamController两条提示。
协同包扩大扫描为后两条info。新增异步规则暴露的触达外问题未批量修复或通过排除业务源码隐藏；本次修改范围分析无问题。

根配置只排除生成的`build/**`，没有排除业务模块。本轮为实际新增/使用的宿主依赖和包测试path入口补充直接声明，保留其他工作区依赖改动。

## 待真实服务验收

1. 新账号个人空间初始化、目标createChild能力、建档创建者及权限传播。
2. 一次点击只产生一次`/doc/document/create`；获得docId后失败恢复不重新建档。
3. `/doc/document/edit`对重复Insert、超时回读及缺失默认字段的真实语义。
4. HTTP块快照是否会独立初始化PaaS根；如会，须按权威CRDT来源恢复，不能合并两个独立创建的根。
5. 手机创建后实际桌面窗口打开、双向编辑、断网重连、独立缓存客户端回读和关闭重开。
6. 服务端持久化语义与ACK；当前协议没有正文落库ACK，不将ready显示为服务器已保存。
7. Android、iOS真实设备新建与标题编辑、权限撤回、返回页面及重启续跑。

未知建档结果、快照回读缺失/不同的情况目前采用人工核对策略，不承诺所有超时都可一键自动恢复。
首期不包含模板、离线首次建档或完整文档库管理。不自动删除已经创建的服务端文档。

机器可读结果及源码校验值见[validation.json](validation.json)。没有提交、发布或部署本轮改动。
