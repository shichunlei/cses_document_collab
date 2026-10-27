# 实施与验证记录分类索引

本目录保存按功能归档的实施、审查、修复与验收记录，以及对应 JSON、日志、截图和设备层级证据。目录采用已有的 `<功能主题>-YYYYMMDD/` 形式；下方分组仅用于导航，不增加目录层级或迁移已有分类。

## 归档规则

1. 创建记录前先查本索引，优先使用已有功能目录。同一功能、同一轮工作的实施记录与验证证据放在一起；不同日期的新一轮工作可另建功能日期目录。
2. 根目录只放索引和目录规范，不新增散放的报告、JSON、截图或日志。不按 `reports/`、`json/`、`screenshots/` 等文件类型另建全局分类。
3. 已有分类目录名、位置和归属保持不变。实施、审查、修复或设备验收已有独立目录时继续沿用；`screenshots/` 保留历史内容，新截图归入对应功能目录。
4. 新目录使用小写英文、短横线分隔的功能主题和八位日期，例如 `document-creation-20261022/`。报告可命名为 `report.md`、`review.md`、`validation.json`，截图和日志使用能识别场景的文件名；历史文件名保留。
5. 跨功能验证按主要目标归档，在相关目录或文档中交叉引用，避免复制证据。新增功能目录时，在同次改动中更新本索引对应分组。
6. 文档链接使用相对路径；JSON 可用相对记录目录或仓库根目录的明确路径。移动文件时同步修正文档、JSON 和包内规范引用，并检查旧路径、链接目标和证据完整性。
7. 归档仅调整组织与路径，不更改历史日期、验证结论、失败、限制或源码/产物哈希，也不代表重新完成技术验收。后续执行同时遵循根目录 [AGENTS.md](../../AGENTS.md) 的归档规范。

## 功能索引

### 文档创建与文档信息

- [document-json-export-20261023](document-json-export-20261023)（[桌面文档 JSON 格式分析与示例](document-json-export-20261023/report.md)）

- [host-service-migration-20261023](host-service-migration-20261023)（[宿主服务目录迁移收尾](host-service-migration-20261023/report.md)）

- [document-cover-drag-20261016](document-cover-drag-20261016)
- [document-creation-20261022](document-creation-20261022)（[文档列表与今日导向合并验证](document-creation-20261022/journal-merge.md)）
- [document-feedback-20261015](document-feedback-20261015)
- [document-header-image-cache-20261016](document-header-image-cache-20261016)

### 编辑器架构、配置与离线能力

- [block-adaptation-audit-20261027](block-adaptation-audit-20261027)（[42块正式协同/JSON路径、功能完整性与版本核查](block-adaptation-audit-20261027/report.md)；[逐块矩阵](block-adaptation-audit-20261027/block-matrix.json)；[旧有序列表heading导出修复](block-adaptation-audit-20261027/ordered-heading-export.md)）

- [image-composer-20261024](image-composer-20261024)（[image_composer 业务分层与最小迁移边界分析](image-composer-20261024/layering-analysis.md)；[宿主迁移与验证](image-composer-20261024/migration.md)；[迁移审查](image-composer-20261024/review.md)）

- [blockcraft-json-exchange-20261023](blockcraft-json-exchange-20261023)（[今日导向与桌面JSON双向转换、原生渲染和示例验证](blockcraft-json-exchange-20261023/report.md)；[189ffad审查与6项缺陷](blockcraft-json-exchange-20261023/review.md)；[六项修复与双向验证](blockcraft-json-exchange-20261023/fixes.md)；[再次审查与2项遗漏](blockcraft-json-exchange-20261023/review-2.md)；[两项P1修复与文件往返验证](blockcraft-json-exchange-20261023/p1-fixes.md)）

- 今日导向导出：[转换为桌面BlockCraft JSON的保留范围与实施分析](offline-journal-20261023/blockcraft-export-analysis.md)（归属既有offline-journal-20261023目录）。

- [selective-undo-prototype-20261022](selective-undo-prototype-20261022)（[结构、格式与锁权限第二阶段](selective-undo-prototype-20261022/structure-format-locks.md)；[FRB、编辑器与选区第三阶段](selective-undo-prototype-20261022/frb-editor-history.md)；[第三阶段审查](selective-undo-prototype-20261022/review.md)；[2项P1与3项P2修复](selective-undo-prototype-20261022/review-fixes.md)）
- [offline-journal-design-20261022](offline-journal-design-20261022)
- [offline-journal-20261023](offline-journal-20261023)（[菜单三项审查修复](offline-journal-20261023/review-fixes.md)、[业务行原生人员提及](offline-journal-20261023/native-business-mentions.md)、[JSON导出与独立业务提交分析](offline-journal-20261023/json-submit-analysis-20261023.md)、[顶部雪山封面](offline-journal-20261023/cover-header.md)、[恢复完整文字格式菜单](offline-journal-20261023/format-toolbar.md)、[标题逐级展开](offline-journal-20261023/progressive-heading.md)、[统一编辑器与配置](offline-journal-20261023/shared-editor.md)、[提交范围复核](offline-journal-20261023/commit-scope.md)）
- [offline-journal-20261022](offline-journal-20261022)（[审查](offline-journal-20261022/review.md)；[4项输入/行线修复](offline-journal-20261022/fixes.md)；[日期排版](offline-journal-20261022/date-layout.md)；[列表对齐](offline-journal-20261022/list-alignment.md)；[v6视频对照、宿主业务分层与后续方案](offline-journal-20261022/video-plan.md)；[宿主迁移与动态内容实施](offline-journal-20261022/host-implementation.md)；[动态引用审查](offline-journal-20261022/dynamic-review.md)；[引用输入与剪贴板修复](offline-journal-20261022/dynamic-fixes.md)；[键盘菜单方案](offline-journal-20261022/keyboard-toolbar-plan.md)；[菜单实施与验证](offline-journal-20261022/keyboard-toolbar-implementation.md)；[列表直接互转修复](offline-journal-20261022/list-conversion-fix.md)；[菜单与列表审查](offline-journal-20261022/toolbar-list-review.md)）
- [editor-add-visibility-20261020](editor-add-visibility-20261020)
- [editor-add-visibility-device-20261021](editor-add-visibility-device-20261021)
- [editor-configuration-20261020](editor-configuration-20261020)
- [editor-decoupling-20261020](editor-decoupling-20261020)
- [editor-decoupling-fixes-20261021](editor-decoupling-fixes-20261021)
- [editor-decoupling-review-20261021](editor-decoupling-review-20261021)
- [image-composer-20261020](image-composer-20261020)
- [offline-all-blocks-20261020](offline-all-blocks-20261020)
- [offline-all-blocks-device-20261020](offline-all-blocks-device-20261020)

### 键盘工具栏与添加菜单

- [paragraph-layout-spacing-20261024](paragraph-layout-spacing-20261024)（[段落布局按钮间距恢复](paragraph-layout-spacing-20261024/report.md)）

- [heading-menu-h6-20261021](heading-menu-h6-20261021)
- [heading-menu-icons-20261021](heading-menu-icons-20261021)
- [keyboard-toolbar-configuration-20261021](keyboard-toolbar-configuration-20261021)
- [keyboard-toolbar-device-20261021](keyboard-toolbar-device-20261021)
- [toolbar-icons-20261017](toolbar-icons-20261017)

### 文字格式、标题与选区

- [heading-level-limit-20261025](heading-level-limit-20261025)（[标题H1~H6全链路限制与验证](heading-level-limit-20261025/report.md)；[审查与2项P1/1项P2](heading-level-limit-20261025/review.md)；[两个P1修复与验证](heading-level-limit-20261025/p1-fixes.md)）

- [editor-spacing-20261024](editor-spacing-20261024)（[公共行间距、字间距与离线宿主接入](editor-spacing-20261024/report.md)；[2026-10-25审查](editor-spacing-20261024/review-20261025.md)）

- [shared-font-size-20261024](shared-font-size-20261024)（[协同默认字号入口与公共配置修复](shared-font-size-20261024/report.md)；[横向字号子菜单](shared-font-size-20261024/horizontal-menu.md)；[恢复默认字号](shared-font-size-20261024/reset-default.md)；[字号与间距审查](shared-font-size-20261024/review.md)；[十二档字号预设](shared-font-size-20261024/presets-20261025.md)）

- [default-text-color-20261021](default-text-color-20261021)
- [default-text-color-device-20261021](default-text-color-device-20261021)
- [editor-regressions-and-heading-device-20261016](editor-regressions-and-heading-device-20261016)
- [editor-review-fixes-device-20261016](editor-review-fixes-device-20261016)
- [heading-typography-20261016](heading-typography-20261016)
- [mobile-selection-menu-20261016](mobile-selection-menu-20261016)
- [paragraph-style-20261016](paragraph-style-20261016)
- [selection-format-review-fixes-20261016](selection-format-review-fixes-20261016)
- [text-paragraph-indent-20261016](text-paragraph-indent-20261016)

### 提及、会议、任务与 KR

- [card-tap-actions-20261026](card-tap-actions-20261026)（[人员、天气、日期卡片去额外外框与整卡操作](card-tap-actions-20261026/report.md)，[刷新入口移入操作面板](card-tap-actions-20261026/weather-refresh.md)；[锁标跟随卡片本体](card-tap-actions-20261026/card-lock-layout.md)，跨功能证据统一归档于此。）

- [person-card-20261025](person-card-20261025)（[人员卡片正式节点、原生设置与协同验证](person-card-20261025/report.md)）

- [entity-mention-20261015](entity-mention-20261015)
- [kr-adaptation-20261019](kr-adaptation-20261019)
- [meeting-card-20261015](meeting-card-20261015)
- [meeting-copy-number-20261019](meeting-copy-number-20261019)
- [meeting-four-rows-20261017](meeting-four-rows-20261017)
- [meeting-task-menu-header-20261017](meeting-task-menu-header-20261017)
- [mention-integration-20261015](mention-integration-20261015)
- [opaque-inline-recovery-20261015](opaque-inline-recovery-20261015)
- [task-card-20261015](task-card-20261015)
- [user-mention-20261014](user-mention-20261014)
- [user-mention-name-only-20261015](user-mention-name-only-20261015)

### 公式与代码绘图

- [formula-sync-20261014](formula-sync-20261014)
- [formula-unified-20261020](formula-unified-20261020)
- [inline-formula-20261014](inline-formula-20261014)
- [mermaid-20261016](mermaid-20261016)
- [mermaid-20261017](mermaid-20261017)

### 表格、代码块与分隔块

- [text-box-20261026](text-box-20261026)（[文本框正式容器、手机基础编辑与原生历史](text-box-20261026/report.md)；[提交审查与三项缺陷](text-box-20261026/review.md)；[三项修复与回归](text-box-20261026/fixes.md)）

- [columns-20261026](columns-20261026)（[columns/column正式投影、手机布局、列操作及原生历史](columns-20261026/report.md)；[审查与两项缺陷](columns-20261026/review.md)；[两项修复与验证](columns-20261026/fixes.md)）

- [weather-card-20261025](weather-card-20261025)（[天气卡片正式接入、宿主数据源及验证](weather-card-20261025/report.md)；[天气设置底部弹窗](weather-card-20261025/bottom-sheet.md)；[与日期统一样式切换](weather-card-20261025/style-navigation.md)；[提交范围核查](weather-card-20261025/commit-scope.md)）

- [date-card-20261025](date-card-20261025)（[日期卡片正式接入、原生展示与验证](date-card-20261025/report.md)；[桌面自由定位分析与移动方案](date-card-20261025/placement-plan.md)；[日期块审查与三项缺陷](date-card-20261025/review.md)；[三项修复与底部设置面板](date-card-20261025/fixes-and-bottom-sheet.md)；[预览吸顶与左右切换](date-card-20261025/sticky-preview-and-styles.md)；[提交范围核查](date-card-20261025/commit-scope.md)）

- [code-block-20261019](code-block-20261019)
- [divider-20261020](divider-20261020)
- [page-divider-20261018](page-divider-20261018)
- [table-20261016](table-20261016)
- [table-adaptation-20261015](table-adaptation-20261015)
- [table-web-block-split-20261017](table-web-block-split-20261017)

### 图片、音视频与附件

- [attachment-card-20261016](attachment-card-20261016)
- [audio-task-loading-height-20261018](audio-task-loading-height-20261018)
- [image-block-merge-20261017](image-block-merge-20261017)
- [image-svg-20261016](image-svg-20261016)
- [image-tap-20261019](image-tap-20261019)
- [image-video-block-split-20261017](image-video-block-split-20261017)
- [media-copy-links-20261019](media-copy-links-20261019)
- [media-more-menu-20261016](media-more-menu-20261016)
- [resource-block-split-20261017](resource-block-split-20261017)
- [shared-media-timeline-20261016](shared-media-timeline-20261016)
- [video-card-20261018](video-card-20261018)
- [video-focus-20261019](video-focus-20261019)
- [video-progress-20261016](video-progress-20261016)

### 上传与宿主集成

- [attachment-picker-upload-20261014](attachment-picker-upload-20261014)
- [audio-picker-upload-20261014](audio-picker-upload-20261014)
- [common-login-upload-20261014](common-login-upload-20261014)
- [direct-context-upload-20261014](direct-context-upload-20261014)
- [markdown-import-phone-20261015](markdown-import-phone-20261015)

### 公共弹窗、菜单、图标与卡片

- [block-menu-icons-20261019](block-menu-icons-20261019)
- [card-layout-test-update-20261021](card-layout-test-update-20261021)
- [color-emoji-unification-20261016](color-emoji-unification-20261016)
- [emoji-picker-20261019](emoji-picker-20261019)
- [mobile-card-pointer-20261016](mobile-card-pointer-20261016)
- [modal-components-split-20261020](modal-components-split-20261020)
- [modal-delete-actions-20261017](modal-delete-actions-20261017)
- [modal-ui-20261017](modal-ui-20261017)
- [package-lucide-icons-20261017](package-lucide-icons-20261017)
- [paragraph-links-20261019](paragraph-links-20261019)
- [row-menu-migration-20261020](row-menu-migration-20261020)
- [switch-locator-verification-20261021](switch-locator-verification-20261021)
- [unified-card-layout-20261017](unified-card-layout-20261017)

### 锁定与只读展示

- [block-lock-corner-20261019](block-lock-corner-20261019)
- [block-lock-preview-20261019](block-lock-preview-20261019)
- [callout-emoji-lock-20261020](callout-emoji-lock-20261020)
- [callout-media-lock-corner-20261020](callout-media-lock-corner-20261020)
- [line-lock-card-20261020](line-lock-card-20261020)
- [resource-lock-ui-20261020](resource-lock-ui-20261020)

### 包级审查、兼容性与提交核查

- [package-example-layout-20261027](package-example-layout-20261027/)（[根 package / example 结构迁移与验证](package-example-layout-20261027/report.md)；[结构迁移审查与三项入口问题](package-example-layout-20261027/review.md)；[三项 P2 修复与命令验证](package-example-layout-20261027/p2-fixes.md)；[修复后再次审查](package-example-layout-20261027/review-2.md)）

- [native-bridge-sync-20261022](native-bridge-sync-20261022)
- [block-class-audit-20261017](block-class-audit-20261017)
- [commit-readiness-20261022](commit-readiness-20261022)（[2026-10-23未提交代码复核](commit-readiness-20261022/remaining-code-review-20261023.md)）
- [package-review-20261017](package-review-20261017)
- [saas-package-compatibility-20261022](saas-package-compatibility-20261022)

### 历史公共截图

- [screenshots](screenshots)

## 整理记录

- 2026-10-22：将根目录散放的 212 个记录与证据文件按功能归档，保留原有 24 个分类目录及其文件位置；同步相关引用，建立本索引和后续归档规则。此次整理未重新执行历史功能验证。
