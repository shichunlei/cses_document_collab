# 表情数据来源

同步桌面实际Callout/图标使用的 `@cses/ui 4.35.6` CsEmojiPickerComponent：其引擎为 `@ctrl/ngx-emoji-mart 9.2.0`（Unicode 14目录），中文名称、别名与拼音来自同版UI发布产物的CLDR release-48数据。保留目录顺序，去除废弃别名，输出1812个默认表情及1350个肤色序列；不复制图片、运行时代码或业务记录。

原始数据许可见同目录MIT及Unicode-3.0文件。同步输入SHA-256记录于生成文件头部。

重新生成：

```sh
node tool/sync_desktop_emoji_catalog.mjs /path/to/cses-client
```
