# 提交前最终核对

日期：2026-10-30。

本轮最终方案：启动时从 example/.env.json asset 读取默认账号密码、API、文档站点及媒体 CDN 后缀；头像 URL 代理 Common ctx.faceUri，主连接地址读取 ctx.websocketHost，登录完成后校验。配置模板保留空值，本机配置继续忽略。未增加依赖，普通 flutter run 不需要 dart-define 参数。

提交前将旧 env 头像断言同步为 Common 的默认头像、直接 URL、原始 ID 拼接与时间戳规则；人员卡片创建者和人员选择器测试显式初始化合成的 Common 头像上下文。当前 README 清除旧 CSES_AVATAR_URL 引用。保留工作区中已确认的 Common 代理实现和已有历史验证记录。

最终对 18 个修改文件及相关消费者运行静态分析，无问题；9 个目标测试文件共 44 项测试全部通过。git diff --check 通过，本机 example/.env.json 确认被 Git 忽略。具体命令见 [commit-validation.json](commit-validation.json)。

本次没有执行真实服务登录、OSS 上传、平台原生构建或真机协同验收。此前 build bundle 验证属于运行时资源读取阶段，历史报告保留原结论；本次最终回归以本记录为准。
