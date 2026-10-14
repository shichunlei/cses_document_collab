# AppFlowy Editor 示例

## CSES 会议描述 Demo

在本目录运行：

```sh
flutter pub get
flutter run -d macos
# 也可连接 Android 设备后运行 flutter run -d <设备 ID>
```

打开应用左侧菜单中的 **CSES Meeting Description**。页面从
`assets/meeting/docDescription.json` 加载会议文档树；该文件是
`cses.saas/docs/docDescription.json` 的副本。文字可直接编辑；手机端显示文字格式
工具栏。“添加块”支持段落、列表、代码、分割线、高亮块及所有样例媒体类型。
图片、音视频、附件、书签和嵌入块可通过卡片上的编辑图标修改属性，也可删除。
通过“查看 JSON”或“复制服务端 JSON”取得当前会议协议格式的文档；点击
“重载样例”会恢复初始内容。

转换逻辑在 `lib/meeting/meeting_document_adapter.dart`：文字块映射为 AppFlowy
的段落、标题、列表、待办、引用和代码块；原始节点的 ID、属性、元数据与文本分段
保存在编辑节点中，未修改节点导出时保持原样。自定义组件展示样例中的高亮块、
分割线、图片、音视频、附件、书签和嵌入链接。媒体卡片可打开原始链接；
属性修改与块增删均经 AppFlowy 事务执行，可使用编辑器撤销操作。

这个 Demo 验证本地编辑器与会议 JSON 的读取、编辑和导出，不连接会议接口或
文件上传。音视频使用外部链接，Figma/掘金块使用链接卡片；上标、下标等样式的
协议属性会保留，但当前页面未提供对应的排版控件。胶带分割线也以普通线条预览。

运行目标测试：

```sh
flutter test test/meeting_document_adapter_test.dart test/meeting_description_demo_test.dart test/meeting_description_mobile_test.dart
```
