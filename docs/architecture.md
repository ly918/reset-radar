# 架构

## macOS 客户端

`NativeWindowController` 用 AppKit `NSStatusItem` 管理菜单栏，使用透明 `NSPanel` 和 `NSGlassEffectView.clear` 承载主面板。SwiftUI 负责页面内容；`ConnectionModel` 管理配置、数据状态、手动操作及可选定时任务。设置、历史和演示共享同一运行模型。

## 数据流

```text
公开网页 → PublicWebParser → PublicWebSnapshot
                              ↓
                    AI 帖子分类 → 原文证据/类型/时间校验
                              ↓
最近帖子 + 当前时间 + 社区历史背景 + 公告计划
                              ↓
                    AIProbabilityForecast
                              ↓
                  有效期/输入一致性/概率范围校验
                              ↓
                     主面板 + 菜单栏 12h
```

`RadarCore` 不依赖第三方 Swift 包。网络、API 协议兼容、Keychain、分类契约、概率校验、历史统计和离线算法在该包内。

主概率来自所配置 AI 的直接估计；本地负责验证有限值、0–1 范围、12h ≤ 24h ≤ 48h 和证据一致性。模型结果有效期及输入身份必须匹配才显示。旧的生存分析基线与信号修正保留用于实验和运行记录，不冒充当前主预测。

## 本机保存

Key 按目标服务隔离保存在 Keychain。JSON 缓存位于应用自己的 Application Support 目录，记录网页、模型结果、预算和运行状态；不进入 Git 或 DMG。默认配置中没有可用凭据。

自动监测约每小时检查，复用相同正文的分类；共享请求预算可推迟请求。关闭应用和休眠期间不运行。社区历史是随应用打包的事实元数据快照，定时任务不会将新帖直接升级为已核验历史。

## 平台边界

UI 与 Keychain 使用 macOS 框架，不能把当前 SwiftUI/AppKit 工程直接打成 Windows EXE。Windows 需要新的界面、系统凭据存储、托盘和打包实现。
