# Common 头像代理注释核对

日期：2026-10-30。

按当前 `demoMentionAvatarUrl(String? userId) => ctx.faceUri(userId)` 实现核对 Common 的 `runtime/context/context.dart`：null/空字符串生成默认头像地址；以 http 开头的值原样返回；普通 ID 直接拼接 faceDomain、ID 与 timestamp 毫秒缓存参数，不做路径编码。默认头像分支依赖 faceDomain，普通 ID 还依赖 timestamp 的初始化。

仅更新头像函数及同文件相关 Widget 参数/字段文档，移除旧的 CSES_AVATAR_URL、空值返回 null、路径编码和 origin 校验异常说明。保留用户已修改的函数签名与代理实现。当前 Common 返回字符串，包装函数仍保留可空返回类型。

对目标文件执行 dart format（120 行宽）与 flutter analyze --no-pub lib/src/demo/mention_avatar.dart；静态分析通过（No issues found），git diff --check 通过。本轮没有改动行为，不运行或改写旧行为测试；此前 41 项通过记录属于当时的 env 头像实现，不代表当前 Common 头像代理已验收。
