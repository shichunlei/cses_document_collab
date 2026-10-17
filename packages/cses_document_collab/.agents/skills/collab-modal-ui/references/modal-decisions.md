# 弹窗场景、最终决策与验证索引

需要定位业务调用方、对照这轮修改的最终要求或选择回归范围时读取。源码路径相对包根目录；实现是默认值的当前来源，用户后续要求可以覆盖这里的产品选择。

## 公共组件与设计基线

公共实现：`lib/src/ui/modal/collab_modal.dart`。当前设计值如下，新增调用方复用组件即可，不复制这些数值另建主题。

| 项目 | 已确认基线 |
|---|---|
| 主色/浅底 | 亮色 `#6558D9` / `#F0EDFF`；暗色 `#B0A5FF` / `#302947` |
| 危险色 | 亮色 `#CC4E62`；暗色 `#FF94A4`，同时作用于可用文字与图标 |
| 表面/边线 | 亮色 `#FFFFFF` / `#ECECF2`；暗色 `#202126` / `#383941` |
| 圆角 | 底部24、居中20、锚点13、输入10、按钮11逻辑像素 |
| 标题图标 | 38像素槽、19像素图标；不额外重复无障碍名称 |
| 标题/说明 | 底部18、居中17、说明11；主标题可换行，说明单行省略 |
| 操作区 | 水平20、按钮间距10、按钮最小高度42；左侧自然宽度，右侧贴右 |
| 常规/紧凑菜单行 | 最小高度51 / 42；锚点使用紧凑主题 |
| 锚点宽度 | 共用默认265；编号、绘图视图/类型/模板指定220 |

底部外壳当前最大高度637并受屏幕90%、键盘及父约束限制；高度小于360进入紧凑模式、隐藏说明和拖动条。`expand` 默认 false；展开模式只让正文占满剩余高度。底部正常留白与系统安全区取最大值，不累加；不要把某次机型截图的绝对像素硬编码进去。

## 业务位置与最终要求

| 场景 | 入口/内容实现（均在 `lib/src/editor/`） | 已确认规则 |
|---|---|---|
| 块更多操作 | `collab_block_actions.dart` | 下方插入用 `listEnd`；删除整行红色；保留稳定身份、远端快照和权限失效保护 |
| 图片/视频更多 | `collab_image_block.dart`、`collab_video_block.dart`、`collab_media_block_base.dart` | 视频必须有“删除视频”；图片编辑弹窗不再重复提供整块删除；删除沿用原事务和资源释放 |
| 链接/网页卡片 | `collab_link_actions.dart` | 头部完整URL单行省略；删除卡片图标及文字红色；资源操作与视图选项之间有浅色分割线；下方插入用 `listEnd` |
| 文档/会议/任务提及 | `collab_inline_entity_mention.dart` | “删除提及”与块菜单同样使用红色整行操作，保留预览禁用；不删除实体业务数据 |
| 图标/封面来源 | `document_header.dart`、`editor_media_source_sheet.dart` | 图标的移除在底部左侧，与完成/保存同栏；Tab切换保留草稿，上传取消和权限核对不交给外壳 |
| 封面位置 | `document_header.dart` 的 `_BannerPositionSheet` | 图片内上下拖动，提示“按住图片上下拖动，调整封面位置”；无滑条/百分比，保存才提交，取消不写入 |
| 高亮颜色/表情 | `collab_callout_block.dart`、`collab_color_picker.dart`、`collab_emoji_picker.dart` | 保留完整色板、自定义颜色、搜索/分类/最近表情；表情移除在左下与完成同栏，外置后补齐忙碌/错误边界 |
| 编号菜单 | `collab_ordered_marker.dart` | 220宽、列表图标、当前项勾选；使用序号本身作为锚点，不改正文/原生编号规则 |
| 绘图视图 | `collab_mermaid_block.dart` | 同款220宽浮层、标题和关闭入口，三种模式带图标及当前勾选；仅切换共享mode，不改源码 |
| 绘图类型/模板 | `collab_mermaid_sheet.dart` | 同款220宽可滚动浮层；类型插入前缀，模板替换本地全文，保存前不写共享源码 |
| 公式/分割线 | `collab_formula_sheet.dart`、`collab_divider_settings.dart` | 删除红色；公式草稿确认与分割线外观即时生效是不同契约，不因外壳相同而合并 |
| 表格行列/单元格 | `collab_table_controls.dart`、`collab_table_sheet.dart` | 行列用公共锚点菜单，单元格操作用底部面板；保留最后行/列禁删及稳定范围保护 |
| 代码名称/语言 | `collab_code_menu.dart` | 复用公共锚点菜单；语言列表保持滚动，不随编号菜单一起全局收窄 |
| 文字链接/资源/图片属性 | `editor_selection_actions.dart`、`collab_resource_settings.dart`、`collab_image_editor.dart` | 居中弹窗；文字链接移除红色，取消不写入；图片/资源沿用字段验证和冲突机制 |

其他消费者可按公共展示函数检索，不根据本表遗漏就新建另一套外壳。

## 本轮过程留下的复用经验

1. 先梳理底部/居中/锚点三类，再按设计还原公共外壳，随后逐项迁移业务；统一的是展示，原选区、草稿、上传、权限及协同事务没有迁入UI基础层。
2. 迁移后逐入口核对完整性，发现并补上视频删除，提及删除与块删除统一。删除不止是一个红色图标，还涉及末块补空段落、独立撤销及资源释放，不能用纯样式验收替代。
3. 图标和高亮表情的移除从内容区移到底部 `leadingAction`。表情原先由选择器捕获异常，迁出时同步补齐防重入和错误提示，避免按钮外置后产生未处理异步异常。
4. 展开面板短内容时，loose正文留下的剩余高度落到按钮下方。修复为仅 `expand: true` 使用 tight，并用真实MediaQuery尺寸和短/长内容、安全区、键盘组合定位；没有靠额外底部padding修补。
5. 副标题长URL改为共用层单行省略；链接视图与资源动作分组；所有删除/移除使用同一danger色。不要截断传给复制/打开/保存的原URL。
6. 编号从265收窄到220后，绘图视图、类型、模板也迁入同款浮层。通过可选width保持其他消费者默认值，五项内容增加滚动，而非全局压缩菜单。
7. 封面位置在早期设计还原时曾加滑条，用户最终要求去掉；最终以图片拖动和明确手势提示为准。Figma/掘金的品牌Logo讨论后用户决定暂不引入；类型占位已随包内图标统一为Lucide通用设计/文章图标，不列为品牌迁移待办。

这些事实用于指导相似改动，不能要求每次小图标调整重做整轮迁移或全部设备验收。

## 按影响选择既有验证

| 影响范围 | 优先读取/运行的测试（均在 `test/`） |
|---|---|
| 共用外壳、头尾、路由、键盘与宽度 | `collab_modal_test.dart` |
| 图标/封面/拖动/业务头部 | `document_header_test.dart`、`editor_media_source_sheet_test.dart` |
| 高亮颜色/表情及外置移除 | `collab_callout_block_test.dart`、`collab_color_emoji_picker_test.dart` |
| 链接与提及菜单 | `collab_link_actions_test.dart`、`collab_entity_mention_test.dart` |
| 视频/图片删除入口 | `collab_video_update_test.dart`、`collab_image_test.dart` |
| 编号及绘图下拉/草稿 | `collab_ordered_test.dart`、`collab_mermaid_test.dart` |
| 表格锚点/底部操作 | `collab_table_test.dart` |
| 公式/文字链接和划词会话 | `mobile_selection_menu_test.dart` |
| 分割线、资源、任务卡片 | `collab_divider_test.dart`、`collab_resource_block_test.dart`、`collab_task_card_test.dart` |

只读、撤权恢复、远端换源/删除/重排、取消、异常提示、撤销/重做按实际触及的业务边界选用；复用已有效的测试，不为每次样式改动复制整套用例。消费者默认值不变时，选代表性回归即可。

根仓库历史过程记录位于 `docs/verification/modal-ui-20261017.json`、`docs/verification/modal-delete-actions-20261017.json`；包独立迁出后记录可不可用不影响本文操作。旧HTML设计预览、历史测试计数和旧PNG不代表后续代码已验证；交付时报告本次实际命令和结果。
