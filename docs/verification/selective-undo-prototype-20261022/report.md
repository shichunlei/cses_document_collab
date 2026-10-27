# Rust/Yrs 选择性撤销与持久化原型

后续接入状态见[第三阶段：FRB与Flutter历史/选区](frb-editor-history.md)；下文保留本阶段当时的实现和验证结论。

日期：2026-10-22。范围：用户要求的第一阶段 Rust/Yrs 历史与持久化原型，以及协同选择性撤销和落盘失败回归。

本页保留第一阶段实现、源码哈希及验证结论；原型的后续结构、格式、权限和检查点变更见[第二阶段记录](structure-format-locks.md)。下文限制与文字 ID 校正方案描述的是第一阶段快照，不代表后续源码仍采用该方案。

## 交付边界

新增 `rust/src/history_prototype.rs` 与独立测试文件，通过 `cfg(test)` 或显式 `history-prototype` feature 编译。默认 Flutter/Cargokit 构建不包含该模块。模块在 `crate::api` 之外，没有新增 FRB 接口、修改生成文件或切换现有编辑入口。

原型使用真实 Yrs（Cargo.lock 实际 0.27.4；声明兼容范围 0.27.3）及 rusqlite，操作正式 `blocks[id].children: Y.Text`。支持本地 UTF-16 文字替换、选择性 undo/redo、远端 V1 增量及 SQLite 内容恢复。本地 origin 进入当前会话历史，远端与缓存 origin 不进入历史、不清空 redo；每次替换是一组，新本地修改清空 redo，空操作不清空。

`HistoryPrototype` 独占自己的 Doc、UndoManager 和连接，须使用专用实验数据库，不能挂接正在运行的正式引擎。数据库沿用 `document_updates(document_id, payload)` 分区模型，重开恢复内容，当前版本不持久化跨会话撤销栈。模块没有网络发送能力；成功返回的 `v1_update` 才可交给未来同步适配层。

## 原子持久化流程

1. 只读当前 CRDT 与两个历史栈，构建候选 Doc/UndoManager。
2. 在候选上执行本地编辑、远端应用、撤销或重做，捕获真实 V1 事件；删除集合变化不能仅靠 state vector 判定。
3. 在 SQLite 事务中写入增量，等待 COMMIT 成功。远端缺失依赖的原始增量即使暂未投影，也先持久化，确保重开后可继续集成。
4. 成功后整体替换正文和两个历史栈，再返回可发布结果。失败丢弃候选，原始 CRDT 字节、向量、两个 StackItem 栈、接受计数与已有数据库行保持精确不变。

本轮使用真实 SQLite 注入 BEFORE INSERT 失败和延迟外键约束 COMMIT 失败，并以第二连接持写锁触发 busy。失败后移除故障重试，校验双方收敛和重新打开的内容。没有用内存 mock 代替持久化验证。

## 历史候选构建与探索失败

仅复制 V1 快照与公开 StackItem 不够：V1 没有保存 Yrs 私有 `Item.redone` 链。“插入 X → 删除 X → 撤销删除 → 再撤销插入”会漏掉已恢复字符。测试保留了这个底层限制的可执行复现。

最初探索重放已接受动作来重建候选，在远端往本地插入片段中间补字后发现，重新执行历史可能因内部遍历顺序产生不同 CRDT 标识，被一致性校验拒绝。该历史失败保留于 [exploratory-replay-failure.txt](exploratory-replay-failure.txt)，不是最终实现的通过记录。最终代码移除了动作重放路径。

当前候选直接复制完整 V1 状态；复制公开栈前，利用仍带 native redone 关联的源 Doc 的 StickyIndex，把可见、已恢复的文字历史 ID 映射到当前字符身份。零宽、已删除或无法解析的 ID 保持原值，避免错误映射到相邻远端字符。源状态仅被只读访问，候选失败不消费原栈。原型仅开放文字替换，不据此声明完整结构/格式历史已经安全迁移。

## 回归结果

| 验证 | 结果 | 证据 |
|---|---|---|
| Rust 格式检查 | 通过 | [rust-format.txt](rust-format.txt) |
| 默认 Rust 静态检查 | 通过 | [rust-check.txt](rust-check.txt) |
| 显式原型 feature 静态检查 | 通过 | [rust-prototype-check.txt](rust-prototype-check.txt) |
| Rust 全量测试 | 137 通过，0 失败/忽略，含新增 30 项原型回归 | [rust-tests.txt](rust-tests.txt) |
| 默认宿主原生库构建 | 通过，未启用原型 feature | [rust-build.txt](rust-build.txt) |
| Flutter 协同原生/生命周期、远端历史及离线编辑目标测试 | 28 通过，0 失败/跳过 | [flutter-regressions.txt](flutter-regressions.txt) |

Rust 命令与退出码见 [rust-checks.json](rust-checks.json)，最终手写源码哈希与验证范围见 [validation.json](validation.json)。Flutter 原生测试使用本轮默认构建的宿主原生库，不是缺库跳过。

新增回归包含：远端前缀/片段中间插字、其他块变化保留本地历史；本地删除撤销保留远端插字；远端删除文字或整块后不误复活；远端更新保留 redo、自身回声不重复捕获；连续删除与多轮 undo/redo；远端加粗后整段删除与恢复时逐字符格式相等；删除型增量落盘；乱序依赖落盘与重开；未知 props/meta 保留；UTF-16 emoji 与非法范围；无效增量；数据库文档分区；本地/远端/undo/redo 各自 INSERT 和 COMMIT 失败共八项；真实数据库占用。另有四个固定种子共 400 步双端混合操作，每步检查双方文字相等且远端插入的字符计数不丢失。

Flutter 目标命令在 `仓库根 package` 中执行：

```sh
flutter test --no-pub --reporter expanded \
  test/collab_controller_native_test.dart \
  test/collab_controller_lifecycle_native_test.dart \
  test/collab_remote_history_test.dart \
  test/local_editor_controller_test.dart \
  test/local_editor_input_test.dart \
  test/local_editor_command_regression_test.dart
```

## 版本核对

桌面项目 `/System/Volumes/Data/workspace/cses-client` 的 `.npmrc` 指向 `http://npm.runtongqiuben.com/`。本轮 npm 查询曾返回 0.11.23；随后直接向该配置仓库请求重新验证元数据，确认 latest=0.11.27，并重新下载发布产物校验 SHA-512。根声明与 Yarn 锁为 0.11.24，当前实际安装为 0.11.17，历史 pnpm 锁为 0.2.78；没有升级桌面依赖。证据见 [blockcraft-registry.json](blockcraft-registry.json)。

已读取安装版、声明版及 latest 随包技能、MIGRATIONS 与受影响 DocUndoManager 实现，重点核对本地 origin 捕获、相对位置书签、历史锁预检及 IME 分组。latest 发布产物相较桌面采用版还有菜单/只读链接与 CSES UI peer 等变化，未将其视作本轮移动端适配完成。41 块及 13 已适配/14 部分支持/1 结构支持/13 未适配统计保持，见 [块适配文档](../../block-adaptation.md)。

## 限制与下一阶段

- 尚未接入 FRB、协同适配层、编辑器历史端口和手机工具栏。手机收到远端正文后清空旧路径历史的现有行为，本轮未替换。
- 结构变更、本地格式命令、行内对象编辑、授权/锁预检、选区书签恢复、IME 用户意图分组及异常结构校验仍待实现。远端格式保留的回归不等同于格式命令完整支持。
- 每次候选复制完整 CRDT，历史 ID 校正按记录范围遍历；`skip_gc` 保留墓碑，尚无容量上限/压缩/耗时指标。生产接入前须完成规模性能验证及边界策略。
- 当前仅内容持久化，跨重启历史不恢复；没有协议变更、服务端 ACK、真实在线桌面或物理手机验收，也没有新增 Android/iOS App 构建结论。
- 本轮未修改 Dart 源码，无需新增 Dart 格式/分析；未修改 FRB 源签名，无需再生成桥接。工作区原有公共入口排序及其他任务文档保留，未提交或暂存。

下一阶段先对结构/格式历史与锁权限建立同样的原子提交契约，再暴露稳定原生历史端口及 FRB 接口，最后接入编辑器和选区恢复；在此之前保持原协同与离线路径。
