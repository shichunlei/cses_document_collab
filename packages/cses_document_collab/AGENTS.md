# 包内开发约定

本文件适用于 `cses_document_collab` 包全目录，补充根仓库 `AGENTS.md`，不豁免其 DartDoc、依赖边界、生命周期、版本核对和验证要求。

## 弹窗与锚点菜单

新增、迁移、还原或修复本包底部弹窗、居中弹窗及下拉/锚点菜单时，先读取并应用 [collab-modal-ui skill](.agents/skills/collab-modal-ui/SKILL.md)，再按所涉场景读取其参考文件。

- 复用 `lib/src/ui/modal/collab_modal.dart`，保持业务会话、权限、草稿和资源所有权边界。
- 用户最新的明确要求优先于 skill 里的默认产品规则；不要把历史中间方案重新当作目标。
- 本 skill 存放于包内，包目录是单独工作区时也可使用；无需安装到用户全局目录。显式调用名称为 `$collab-modal-ui`，未被会话技能目录发现时按上面的路径直接读取。
- 普通页面、网页设计预览和不涉及弹窗的协同/原生逻辑不因本约定强制加载该 skill。

## UI 图标

本包 `lib/` 下手写展示代码的图标统一使用 `lucide_icons_flutter`，选择前核对当前安装版本的声明；保留原语义、状态配色、尺寸与交互。Figma/掘金使用通用类型图标，暂不引入品牌Logo。宿主注入的头像/界面仍由宿主决定，不通过本包反向修改宿主或SDK内部控件；测试夹具不因这条约定强制替换注入图标。

## 列表行与开关行

- 本包全目录（含源码、测试夹具与示例）禁止使用 Flutter `ListTile` 系列组件，包括 `ListTile`、`SwitchListTile`、`CheckboxListTile`、`RadioListTile` 等；不得通过包装、别名或继承间接使用，也不新增相关 SDK 主题配置。
- 列表行以 `Row` 自定义布局；菜单操作复用 `lib/src/ui/modal/collab_modal.dart` 的 `CollabMenuRow`，开关设置复用 `CollabSwitchRow`。继续使用原生 `Switch`、`Checkbox`、`Radio` 等基础控件。
- `CollabSwitchRow` 仅允许开关本体切换，不提供整行点击或切换回调；点击标题、副标题、图标及空白区域不得触发切换。状态及业务回调由调用方持有。
- 自定义行须保留禁用态、选中态、危险操作配色、键盘与无障碍语义，并适配窄屏及系统大字；测试通过稳定 Key 或实际行为验证，开关操作定位行内的 `Switch`。
