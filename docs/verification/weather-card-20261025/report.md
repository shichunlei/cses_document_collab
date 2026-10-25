# 天气卡片移动端适配（2026-10-25）

正式`weather`从简化JSON展示扩展为原生无正文协同块。添加面板和可配置键盘入口均可新建，
与`date-card`等既有未提交改动共存；未提交Git、未升级桌面依赖、未手工修改生成桥接文件。

后续设置展示已按用户要求改为公共底部弹窗，并统一为日期同款左右循环样式切换，见[底部面板调整](bottom-sheet.md)及[样式切换验证](style-navigation.md)。下方原实施测试及APK证据保留当时结论。

## 实施范围

- Dart模型、Rust白名单与void结构校验、AppFlowy正式节点/组件、远端原位投影、独立字段补丁、稳定身份历史。
- 七种布局与六种同源色调；原生Lucide六天气形态替代桌面SVG；外框九种线型、颜色覆盖、图标色、高低温。
- 公共设置弹窗本地草稿/取消/一次应用；改样式重置设计框，改色调清除颜色覆盖，实时/固定日切换。
- `CollabHostServices.loadWeather`公开注入；编辑器不依赖账号/业务客户端。宿主独立Dio、IP粗定位/北京回落与Open-Meteo实时/历史源；十分钟成功缓存、同锚点请求合流、主动刷新绕过缓存，每轮关闭自建客户端。
- 新建入口在查询成功后将固定日和快照一次插入，失败保留占位；固定日手动刷新原子替换frozen、失败保留旧值、可撤销。实时结果永不持久化。
- 撤权、锁、宿主身份、日期/属性变动、节点替换/删除及卸载均隔离迟到结果；公共块锁、段落链接、下方插入、删除及后置正文退格。
- JSON导入正式节点和实时字段导出，清除覆盖不复活旧值；原始未知props/meta继续保留。异常子树保持不透明保护。旧本地snapshot-weather继续只读渲染和保留属性导出，新导入使用正式组件。
- 天气frozen是本轮首个嵌套资源属性；原生序列化递归排序天气JSON，修复不同Yrs副本哈希遍历顺序造成的等价快照伪差异。

## 版本核对

桌面`.npmrc`配置仓库为`http://npm.runtongqiuben.com/`。沙箱初次请求被本地代理权限拒绝，
其过期缓存0.11.27未作为latest。获准后以隔离缓存重新查询，latest为0.11.30，dist SHA1与已获取发布产物一致。
桌面声明/Yarn锁0.11.28，安装0.11.21，历史pnpm0.2.78；未升级。

读取三版随包L0、天气块指南、MIGRATIONS及Schema、7布局/6色调、查询与刷新实现；
关键实现片段指纹一致，见[版本证据](blockcraft-version.json)。发布版相关片段保存为upstream-*.txt。
其他上游差异沿用适配表待同步/验收清单，不宣称全版本兼容。

可重现的正式Yjs与JSON夹具由`tool/generate_weather_fixture.mjs`执行发布Schema/布局声明生成，
含7种定格布局、高亮容器内实时天气、未知属性/元数据及非法void子树。

## 验证

| 验证 | 结果 | 证据 |
|---|---|---|
| 天气块/真实FRB/历史/SQLite/JSON/窄屏/权限/定格切换查询 | 15项通过 | [core-tests.log](core-tests.log) |
| 工具栏天气配置/直达/成功定格一次插入/等待中撤权 | 4项通过，2项为下面关联组子集 | [creation-tests.log](creation-tests.log) |
| 天气、日期、工具栏及多块JSON关联 | 77通过，1项既有失败 | [related-tests.log](related-tests.log) |
| 宿主天气服务及日记JSON/编辑/完整性 | 28项通过 | [host-tests.log](host-tests.log) |
| Rust全量及天气定向 | 200通过，定向3项属于全量子集 | [rust-tests.log](rust-tests.log)、[rust-target-tests.log](rust-target-tests.log) |
| 所属包20个目标/必要关联范围及宿主4个目标静态分析 | 无诊断 | [package-analyze.log](package-analyze.log)、[host-analyze.log](host-analyze.log) |
| Rust fmt/check、宿主动态原生库 | 通过，vendor/yrs保留既有58条编译警告 | [rust-format.log](rust-format.log)、[rust-check.log](rust-check.log)、[native-build.log](native-build.log) |
| Android最终源码调试构建 | 通过；最终源码调试APK包含多ABI原生库 | [android-final-build.log](android-final-build.log) |
| 生成器语法、链接、diff与源码/产物指纹 | 通过；见最终校验清单 | [validation.json](validation.json) |

唯一关联失败为`menu choices cannot reenable disabled block and format capabilities`的旧工具栏空菜单断言；
与日期轮次的[既有失败核查记录](../date-card-20261025/commit-scope.md)相同，本轮未修改其断言或无关工具栏逻辑。
首次关联运行还暴露旧天气展示夹具含frozen却无固定日期；正式组件按桌面契约将其视为实时，因而不展示旧frozen。
已在展示专项夹具明确固定日期后通过，常规JSON往返夹具保持原样；新测试另行断言实时忽略旧frozen。

初轮13项通过日志保留为[initial-core-tests.log](initial-core-tests.log)，后续增加固定日查询等待期间
撤权再恢复、旧本地节点兼容测试后为最终15项。早期截图缺Lucide测试字体，补载真实字体后重新生成；
[最终7布局原生截图](weather-gallery.png)已目视检查，中文、图标与7种布局均可见，这是Flutter测试截图而非真机证据。
窄屏覆盖280逻辑像素、1.0/2.2倍系统字号、7布局×6色调；固定设计框内文字按既有对象方式限制系统放大。

## 限制与待验收

1. 旧固定日块缺失frozen时自动查询仅本地展示，手动刷新才持久化；桌面的无Undo初始化事务仍待同步。
2. 自由定位、组合/缩放/动画、模板draft:*投影/物化及完整对象剪贴板未接入；复杂容器沿用原有保护范围，根级和高亮容器已测试。
3. 外观为原生近似，图标用Lucide；固定框内文字不随系统大字放大，窄屏整体缩小，完整桌面CSS及其字体度量不承诺像素一致。
4. 真机Android/iOS、第三方天气实网及真实在线桌面双向界面尚未验收；确定性传输层测试不代表第三方服务可达。
5. 本轮保持“部分支持”；正式42块、13已适配/28部分支持/1结构支持/0未适配不变。
