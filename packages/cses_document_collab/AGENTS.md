# 包内开发约定

本文件适用于 `cses_document_collab` 包全目录，补充根仓库 `AGENTS.md`，不豁免其 DartDoc、依赖边界、生命周期、版本核对和验证要求。

## 弹窗与锚点菜单

新增、迁移、还原或修复本包底部弹窗、居中弹窗及下拉/锚点菜单时，先读取并应用 [collab-modal-ui skill](.agents/skills/collab-modal-ui/SKILL.md)，再按所涉场景读取其参考文件。

- 复用 `lib/src/ui/modal/collab_modal.dart`，保持业务会话、权限、草稿和资源所有权边界。
- 用户最新的明确要求优先于 skill 里的默认产品规则；不要把历史中间方案重新当作目标。
- 本 skill 存放于包内，包目录是单独工作区时也可使用；无需安装到用户全局目录。显式调用名称为 `$collab-modal-ui`，未被会话技能目录发现时按上面的路径直接读取。
- 普通页面、网页设计预览和不涉及弹窗的协同/原生逻辑不因本约定强制加载该 skill。
