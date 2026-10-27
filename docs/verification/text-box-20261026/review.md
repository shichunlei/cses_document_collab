# 文本框提交审查

审查日期：2026-10-27。目标：`e928e796ee101ad04da8515c4dd30256cdb842f9`（移动端文本框基础编辑与协同）。仅新增审查用例和证据，未修改产品代码、提交或安装应用，未访问在线文档。原有AppFlowy依赖和日成果JSON改动保留。

后续状态：R1/R2/R3已在同日完成[修复及回归](fixes.md)。下方结论保留审查时的失败事实；原审查用例随后扩展为正式修复回归，不以其新内容覆盖旧日志或原指纹。

## 结论

确认1项P1和2项P2，均未修复。基础适配仍为“部分支持”，42种及13已适配/28部分支持/1结构支持/0未适配统计保持。原实施中的竖排、浮动、装饰、自适应测量等明确待办不作为本轮新增缺陷。

### R1 / P1：框内未知行内对象阻断整篇文档的快照提交

位置：`rust/src/api/blockcraft.rs:381–387`。

正式文本框允许的paragraph子块若包含未来插件的行内对象，投影会按既有恢复规则将该段落保留为`unsupported`，父框仍投影为`text-box`。新增`validate_columns`却不允许这个未变动的占位子块；每次全快照提交都返回`INVALID_TEXT_BOX`，即使用户仅修改框外的合法段落。

独立真实FRB/Yrs/SQLite反例：在已发布工厂生成的Yjs夹具`box-body`插入`{futurePlugin: 'preserve-opaque-data'}`，确认其投影为unsupported，再只改根级`tail`段落，原生拒绝提交。将同一未知段落移到根级的对照用例通过。不是未知对象修改被拒，而是其他正文也无法保存。

应区分“原有且未改动的占位子块”和“新造的非法子块”，沿用既有不透明内容保护；不能因一个受保护段落使全篇回到不可写。

### R2 / P2：实际添加面板绕过文本框子块白名单

位置：新增限制`lib/src/editor/editor_shortcut_toolbar.dart:1653`；未覆盖的调用链为`_AddBlockSheet._applyAndClose`→`applyBlockShortcut`。

本次只给T类型菜单的`applyEditorBlockStyle`增加父级限制，实际“添加→代码块”仍走没有同样校验的`applyBlockShortcut`。在文本框正文末尾操作会成功插入code子块，使树变成`paragraph, code`，整框随即因构建器校验失败回退为不支持内容。空段落也会被直接转换为不允许的类型。

独立命令用例确认其返回true；真实Widget面板点击确认产生非法后代。纯内存编辑器保留这棵非法树；原生路径会拒绝该结构并恢复，用户收到错误且无法完成本次操作。应在共用插入/转换边界校验当前父容器，并同步隐藏或禁用无效入口。

### R3 / P2：纯预览继承编辑时的框内滚动位置

位置：`lib/src/editor/collab_text_box_block.dart:126–130`。

编辑与预览共用同一个`PageStorageKey('text-box-scroll-$id')`。长文本固定框在编辑时滚动到250逻辑像素后切换preview，内部offset仍为250；预览同时使用NeverScrollableScrollPhysics且整篇IgnorePointer，用户看不到首屏正文，也无法滚回顶部。桌面固定框的只读裁切应从起点展示，预览结果不应随此前编辑滚动而变化。

独立Widget反例读取到预览offset=250（期望0）。应给预览独立的滚动状态或在切换时归零，同时按需要保留编辑模式自己的位置。

## 验证及来源

- 既有`collab_text_box_test.dart`及`text_box_native_integration_test.dart`13项全部通过，见[复跑日志](review-existing-tests.log)。这些用例未覆盖上述反例，旧通过结论不扩大到本轮发现。
- 新增`test/text_box_review_test.dart`共5项：1项根级未知对象对照通过；4项正确行为断言失败，分别覆盖R1、R3、R2共用命令和R2真实面板。见[最终反例日志](review-probes.log)。失败为待修复产品行为，不标记为已通过。
- 新增审查用例已format并运行目标analyze；记录见`review-analyze.log`。初轮夹具漏传FRB必填参数、将PageStorageKey误写为ValueKey，以及面板Future作用域/帧等待问题均为审查夹具问题，已修正后才确认最终结果；初轮日志仅保留过程，不作为缺陷证据。
- 两份新增Yjs夹具源于仓库已发布Schema工厂夹具`rust/tests/fixtures/blockcraft-text-box.update`。`review-unknown-inline.update`在`box-body`的Y.Text索引1插入未知对象；`review-unknown-inline-root.update`再把该段落从框内移到根级，其他块保留，作为位置对照。
- 通过桌面配置仓库重新查询latest=0.11.31，integrity与上一轮已核对产物一致；桌面声明/Yarn0.11.30，安装0.11.17，历史pnpm0.2.78。复读随包技能/MIGRATIONS及Schema子块限制、固定框只读投影和移动输入/添加/投影/历史实现。版本未升级，其他已记录兼容待办保持。
- 未新增Android/iOS构建、物理设备或真实在线双端验收；当前审查使用既有宿主原生库、真实FRB/Yrs/SQLite及Widget层。记录及指纹见[审查验证](review-validation.json)。
