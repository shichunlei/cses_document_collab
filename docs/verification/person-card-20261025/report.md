# 移动端人员卡片接入

日期：2026-10-25。`person-card` 从 JSON 专用展示接入正式协同节点，适配状态仍为“部分支持”。正式块总数 42，已适配/部分支持/结构支持/未适配统计仍为 13/28/1/0。

## 实现范围

- 正式无正文、无子块节点，接通 Dart/AppFlowy 与 Rust/Yrs 的投影、白名单校验、字段补丁、远端原位更新和稳定身份历史；非法子内容保持占位与原始数据，非法写入整次拒绝。
- 添加菜单及可配置键盘直达新增“人员卡片”。支持根级与高亮容器插入、整块选择、更多菜单、锁/解锁、复制段落链接、下方插入、删除及后置段落行首退格。
- `person` 严格按桌面 JSON **字符串**读取和保存，含姓名、可选头像、拼音、部门职务；读取不改写旧值，也不自动刷新资料。未知 props/meta 和原字符串保留。
- 新增公开 `CollabPersonCardData` 与可选 `CollabHostServices.loadPersonCardCreator`。仅新插入时调用；宿主持有资料和请求，权限、身份或选区失效后丢弃结果。Demo 正式文档和今日导向注入当前登录人员姓名、公开头像及会话部门；会话未提供拼音时不推测拼音。未配置或资料缺失使用桌面“文档创建人”占位。
- 原生横排、横排拼音、竖排展示；头像形状/大小、部门的隐藏/自动/上方/右侧/下方、颜色、实线/虚线/点线/双线边框及各样式分角色字号。沿用 `sc`、`fsr/fsp/fsc`，新建显式 `sc:1`，旧缺省倍率从宽度推导。
- 公共底部设置：固定居中预览、左右循环切换与名称；设置区独立滚动，取消/应用固定底部。草稿取消或下滑不写正文，应用一次字段事务；切回原样式恢复作者宽高和缺省字段，无变化应用正常关闭。观察到锁、撤权、节点、宿主或属性变化后旧草稿失效。
- JSON 导入生成正式人员节点；保留旧 `snapshot-person-card` 的同源只读展示和归档属性导出。

## 版本依据

桌面 `/Users/shichunlei/workspace/cses-client/.npmrc` 的 `@ccc` 仓库为 `http://npm.runtongqiuben.com/`。本轮实时查询 latest=0.11.30；声明与 Yarn 锁 0.11.28，实际安装 0.11.21，历史 pnpm 锁 0.2.78，未升级桌面。初次查询受沙箱代理访问限制，提权重试成功。

读取安装、声明与最新三版的随包 L0、人员块指南、MIGRATIONS 和实现；人员 Schema、三样式目录、定格 JSON、字号与内容倍率辅助实现的源码指纹一致。最新 tarball SHA1 与仓库 dist 匹配。详情见 [blockcraft-version.json](blockcraft-version.json)。Schema、属性、块选择/菜单、JSON、历史与协同已覆盖本轮范围；其他版本能力继续以适配表的待办为准。未改变 FRB 源接口或 ABI，未手改生成文件，已重建宿主原生动态库。

## 验证证据

- [feature-tests.log](feature-tests.log)：人员模型、字段历史/重排、插入/退格恢复、JSON未知字段、草稿、锁与撤权、三样式长文本、FRB/Yrs/SQLite、底部布局共 18 项通过。
- [toolbar-tests.log](toolbar-tests.log)：52 项通过，包含人员直达插入、一次撤销及异步资料加载撤权隔离；1 项既有失败。使用 HEAD 原版配置/工具栏/测试临时复跑相同用例，仍失败，结束后恢复全部工作内容，见 [toolbar-baseline.log](toolbar-baseline.log)。失败为 `menu choices cannot reenable disabled block and format capabilities`：原用例关闭其他布局却未关闭默认 `lineHeight`，与人员卡片无关；未顺带修改该逻辑或原断言。
- [related-tests.log](related-tests.log)：JSON、协同适配器、能力配置和锁装饰 38 项通过。旧全类型夹具生成器已修正 `person` 字符串协议并重新生成，保留历史时间，生成结果见 [json-fixture-generation.log](json-fixture-generation.log)。首次旧夹具展示失败保留于 [initial-related-tests.log](initial-related-tests.log)。
- [host-tests.log](host-tests.log)：宿主定格快照与今日导向 JSON 消费者 7 项通过。
- Rust 全部 202 项通过，含新增投影/原子校验和双 Yjs 实例并发字段合并，见 [rust-tests.log](rust-tests.log)。`cargo fmt --check`、`cargo check`、`cargo build` 通过；vendored yrs 的既有警告保留。
- 布局覆盖 390×844、320×568/1.5倍字、320×720/2.2倍字、640×360/120高键盘；验证固定预览/头尾、独立滚动、三样式循环及下滑丢弃草稿。[真实 Flutter 设置截图](person-card-style-navigation.png)使用 STHeiti 字体，属于 Widget 渲染证据。

初始测试夹具漏传 `blockType` 和错误使用 `FixedSizeStack` 长度匹配器均已修正；首次关联工具栏失败及早期广范围分析中的既有视频 `unawaited_futures` 提示保留在 [initial-tests.log](initial-tests.log) 与 [initial-analyze.log](initial-analyze.log)，不据此宣称全包无问题。最终目标包/宿主静态检查均无问题，`git diff --check`通过；Android调试APK构建成功（145.6秒，重建4个Rust目标）。新夹具生成后宿主6项JSON消费者再次通过，见 [host-codec-final.log](host-codec-final.log)。最终检查见 [validation.json](validation.json)。

## 剩余范围

未实现对象自由定位/层级/组合、八向拖动缩放、手动宽高/倍率面板、动画、模板 `draft:*` 物化、基于原文档创建人补齐旧空卡片、完整桌面剪贴板交换和实时组织目录资料查询。当前宿主定格的是插入操作时提供的登录资料；需要原文档创建人时应由宿主在该端口解析，不能用当前账号假定替代。

原生外观按桌面协议近似还原，默认头像为本地 Lucide 占位；固定对象文字保持设计字号，不跟随系统大字放大。未验收物理 Android/iOS 设备、iOS App 或真实服务端在线双端/重连/ACK。双副本 Rust 合并和 SQLite 重开不等于上述在线验收。

## 提交核查

2026-10-25提交前重新查询配置仓库latest仍为0.11.30，桌面声明/锁定/安装仍为0.11.28/0.11.28/0.11.21；未升级。功能实现和上述测试范围保持，只整理本次新增import分组并重新验证宿主静态检查。提交包含人员卡片实现、消费者、夹具生成源/产物与完整证据日志；排除既有file_picker版本改动、内容分类目录及其两处索引。工具栏基线复现使用的原HEAD为`ee17e71`。

日志入库时仅清理行尾空格及文件尾空白行以通过diff检查，保留测试输出、失败和结论。
