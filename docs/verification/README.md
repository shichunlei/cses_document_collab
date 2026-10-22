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

- [document-cover-drag-20261016](document-cover-drag-20261016/)
- [document-creation-20261022](document-creation-20261022/)
- [document-feedback-20261015](document-feedback-20261015/)
- [document-header-image-cache-20261016](document-header-image-cache-20261016/)

### 编辑器架构、配置与离线能力

- [editor-add-visibility-20261020](editor-add-visibility-20261020/)
- [editor-add-visibility-device-20261021](editor-add-visibility-device-20261021/)
- [editor-configuration-20261020](editor-configuration-20261020/)
- [editor-decoupling-20261020](editor-decoupling-20261020/)
- [editor-decoupling-fixes-20261021](editor-decoupling-fixes-20261021/)
- [editor-decoupling-review-20261021](editor-decoupling-review-20261021/)
- [image-composer-20261020](image-composer-20261020/)
- [offline-all-blocks-20261020](offline-all-blocks-20261020/)
- [offline-all-blocks-device-20261020](offline-all-blocks-device-20261020/)

### 键盘工具栏与添加菜单

- [heading-menu-h6-20261021](heading-menu-h6-20261021/)
- [heading-menu-icons-20261021](heading-menu-icons-20261021/)
- [keyboard-toolbar-configuration-20261021](keyboard-toolbar-configuration-20261021/)
- [keyboard-toolbar-device-20261021](keyboard-toolbar-device-20261021/)
- [toolbar-icons-20261017](toolbar-icons-20261017/)

### 文字格式、标题与选区

- [default-text-color-20261021](default-text-color-20261021/)
- [default-text-color-device-20261021](default-text-color-device-20261021/)
- [editor-regressions-and-heading-device-20261016](editor-regressions-and-heading-device-20261016/)
- [editor-review-fixes-device-20261016](editor-review-fixes-device-20261016/)
- [heading-typography-20261016](heading-typography-20261016/)
- [mobile-selection-menu-20261016](mobile-selection-menu-20261016/)
- [paragraph-style-20261016](paragraph-style-20261016/)
- [selection-format-review-fixes-20261016](selection-format-review-fixes-20261016/)
- [text-paragraph-indent-20261016](text-paragraph-indent-20261016/)

### 提及、会议、任务与 KR

- [entity-mention-20261015](entity-mention-20261015/)
- [kr-adaptation-20261019](kr-adaptation-20261019/)
- [meeting-card-20261015](meeting-card-20261015/)
- [meeting-copy-number-20261019](meeting-copy-number-20261019/)
- [meeting-four-rows-20261017](meeting-four-rows-20261017/)
- [meeting-task-menu-header-20261017](meeting-task-menu-header-20261017/)
- [mention-integration-20261015](mention-integration-20261015/)
- [opaque-inline-recovery-20261015](opaque-inline-recovery-20261015/)
- [task-card-20261015](task-card-20261015/)
- [user-mention-20261014](user-mention-20261014/)
- [user-mention-name-only-20261015](user-mention-name-only-20261015/)

### 公式与代码绘图

- [formula-sync-20261014](formula-sync-20261014/)
- [formula-unified-20261020](formula-unified-20261020/)
- [inline-formula-20261014](inline-formula-20261014/)
- [mermaid-20261016](mermaid-20261016/)
- [mermaid-20261017](mermaid-20261017/)

### 表格、代码块与分隔块

- [code-block-20261019](code-block-20261019/)
- [divider-20261020](divider-20261020/)
- [page-divider-20261018](page-divider-20261018/)
- [table-20261016](table-20261016/)
- [table-adaptation-20261015](table-adaptation-20261015/)
- [table-web-block-split-20261017](table-web-block-split-20261017/)

### 图片、音视频与附件

- [attachment-card-20261016](attachment-card-20261016/)
- [audio-task-loading-height-20261018](audio-task-loading-height-20261018/)
- [image-block-merge-20261017](image-block-merge-20261017/)
- [image-svg-20261016](image-svg-20261016/)
- [image-tap-20261019](image-tap-20261019/)
- [image-video-block-split-20261017](image-video-block-split-20261017/)
- [media-copy-links-20261019](media-copy-links-20261019/)
- [media-more-menu-20261016](media-more-menu-20261016/)
- [resource-block-split-20261017](resource-block-split-20261017/)
- [shared-media-timeline-20261016](shared-media-timeline-20261016/)
- [video-card-20261018](video-card-20261018/)
- [video-focus-20261019](video-focus-20261019/)
- [video-progress-20261016](video-progress-20261016/)

### 上传与宿主集成

- [attachment-picker-upload-20261014](attachment-picker-upload-20261014/)
- [audio-picker-upload-20261014](audio-picker-upload-20261014/)
- [common-login-upload-20261014](common-login-upload-20261014/)
- [direct-context-upload-20261014](direct-context-upload-20261014/)
- [markdown-import-phone-20261015](markdown-import-phone-20261015/)

### 公共弹窗、菜单、图标与卡片

- [block-menu-icons-20261019](block-menu-icons-20261019/)
- [card-layout-test-update-20261021](card-layout-test-update-20261021/)
- [color-emoji-unification-20261016](color-emoji-unification-20261016/)
- [emoji-picker-20261019](emoji-picker-20261019/)
- [mobile-card-pointer-20261016](mobile-card-pointer-20261016/)
- [modal-components-split-20261020](modal-components-split-20261020/)
- [modal-delete-actions-20261017](modal-delete-actions-20261017/)
- [modal-ui-20261017](modal-ui-20261017/)
- [package-lucide-icons-20261017](package-lucide-icons-20261017/)
- [paragraph-links-20261019](paragraph-links-20261019/)
- [row-menu-migration-20261020](row-menu-migration-20261020/)
- [switch-locator-verification-20261021](switch-locator-verification-20261021/)
- [unified-card-layout-20261017](unified-card-layout-20261017/)

### 锁定与只读展示

- [block-lock-corner-20261019](block-lock-corner-20261019/)
- [block-lock-preview-20261019](block-lock-preview-20261019/)
- [callout-emoji-lock-20261020](callout-emoji-lock-20261020/)
- [callout-media-lock-corner-20261020](callout-media-lock-corner-20261020/)
- [line-lock-card-20261020](line-lock-card-20261020/)
- [resource-lock-ui-20261020](resource-lock-ui-20261020/)

### 包级审查、兼容性与提交核查

- [block-class-audit-20261017](block-class-audit-20261017/)
- [commit-readiness-20261022](commit-readiness-20261022/)
- [package-review-20261017](package-review-20261017/)
- [saas-package-compatibility-20261022](saas-package-compatibility-20261022/)

### 历史公共截图

- [screenshots](screenshots/)

## 整理记录

- 2026-10-22：将根目录散放的 212 个记录与证据文件按功能归档，保留原有 24 个分类目录及其文件位置；同步相关引用，建立本索引和后续归档规则。此次整理未重新执行历史功能验证。
