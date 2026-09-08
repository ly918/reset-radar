# 隐私与网络行为

Reset Radar 不要求登录 OpenAI 账号，不读取个人 Codex 用量，也不收集浏览器 Cookie。

应用会访问配置的公开数据源，并在用户配置 AI 后，将最近帖子正文、发布时间和必要的历史背景发送给该服务。Key 只发送到配置的地址；兼容接口不代表该服务由 OpenAI 运营。用户应自行选择信任的服务。

API Key 保存于 macOS Keychain；服务地址、模型配置保存于应用偏好设置；网页与模型结果保存于本机 Application Support。项目没有接入遥测或第三方统计 SDK，不上传本机缓存到本项目的服务器。

用户可在设置中删除已保存 Key、清除帖子缓存和暂停自动检查。卸载 `.app` 不会自动删除偏好设置、Application Support 或 Keychain 数据。

公开问题报告中请勿粘贴 API Key、Cookie、Authorization 请求头或未脱敏日志。若发现凭据泄漏，先在服务商处撤销并更换凭据，再处理仓库历史。
