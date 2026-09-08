import SwiftUI
import AppKit
import RadarCore

enum DemoScenario: String, CaseIterable, Identifiable {
    case overview = "完整展示 · 固定演示值"
    case calculated = "合成历史 · 实际计算"
    case insufficient = "历史样本不足"
    case unconfigured = "未配置连接"
    case offline = "断网 / 缓存过期"
    case rateLimited = "接口限流"
    case billing = "服务额度不足"
    case candidate = "疑似发生 · 待核验"
    case banked = "发现 Banked credit"
    case empty = "无历史记录"
    var id: String { rawValue }
}

@MainActor final class DemoModel: ObservableObject {
    @Published var scenario: DemoScenario = .overview
    @Published var now = Date(timeIntervalSince1970: 1_788_777_600) // Fixed clock: 2026-09-07 10:40 UTC.
    @Published var feedback: LocalizedMessage = "离线就绪 · 未产生网络请求"
    @Published var preview: LocalizedMessage = "尚无通知预览"
    @Published var ledger: EventLedger
    @Published var snapshotCount = 0
    let start: Date
    var watchState = WatchState()
    init() {
        let now = Date(timeIntervalSince1970: 1_788_777_600)
        start = now
        ledger = EventLedger(events: Self.makeEvents(now))
    }
    static func makeEvents(_ now: Date) -> [ResetEvent] {
        var time = now.addingTimeInterval(-36 * 3600)
        var result: [ResetEvent] = []
        for i in 0...30 {
            result.append(ResetEvent(id: "demo-reset-\(i)", occurredAt: time, observedAt: time,
                                     verifiedAt: time, source: L10n.tr("本地合成记录 demo-reset-\(i)")))
            time = time.addingTimeInterval(-Double(48 + (i * 17) % 120) * 3600)
        }
        result.append(ResetEvent(id: "demo-credit", type: .bankedCredit,
                                 occurredAt: now.addingTimeInterval(-4 * 3600), observedAt: now.addingTimeInterval(-3 * 3600),
                                 verifiedAt: now.addingTimeInterval(-3 * 3600), scope: L10n.tr("演示套餐 · 可稍后领取"),
                                 source: L10n.tr("本地合成记录 demo-credit")))
        return result
    }
    var events: [ResetEvent] {
        let subset = [.empty, .unconfigured].contains(scenario) ? [] : scenario == .insufficient ? Array(ledger.events.prefix(4)) : ledger.events
        return subset.filter { $0.status == .verified }.sorted {
            ($0.occurredAt ?? .distantPast) > ($1.occurredAt ?? .distantPast)
        }
    }
    var history: History {
        var events = ledger.events
        if [.insufficient, .unconfigured, .empty].contains(scenario) { events = scenario == .insufficient ? Array(events.prefix(4)) : [] }
        var value = History.build(events: events, coverage: [Coverage(start: start.addingTimeInterval(-365 * 86400), end: now)], asOf: now, scope: "demo-global")
        if scenario == .candidate && !events.contains(where: { $0.id == "demo-candidate" && $0.status != .candidate }) { value.unresolved = true }
        return value
    }
    var forecast: Forecast {
        ForecastEngine.compute(history: history, asOf: now,
                               signals: [ForecastSignal(publishedAt: start.addingTimeInterval(-3600), observedAt: start, window: 2...6)],
                               fresh: scenario != .offline)
    }
    var signalLabel: String {
        if scenario == .unconfigured { return L10n.tr("未分析") }
        if now.timeIntervalSince(start.addingTimeInterval(-3600)) >= 6 * 3600 { return L10n.tr("计划窗口已过 · 示例") }
        return L10n.tr("Strong · 示例")
    }
    var values: [String] {
        if scenario == .overview { return ["46%", "72%", "88%"] }
        if scenario == .offline { return ["—", "—", "—"] }
        return forecast.available ? forecast.probability.map { "\(Int(($0 * 100).rounded()))%" } : ["—", "—", "—"]
    }
    var status: String {
        switch scenario {
        case .overview: return "固定演示值 · 非真实预测"
        case .offline: return "数据过期 · 缓存仍可查看"
        case .rateLimited: return "模拟 429 · 等待服务重试时间"
        case .billing: return "模拟额度不足 · 在线分析暂停"
        case .unconfigured: return "AI 未配置 · 动态未配置"
        case .banked: return "可领取重置已公布 · 不改变 Drought"
        default: return L10n.key(forecast.reason)
        }
    }
    var drought: String {
        guard let hours = history.age else { return L10n.tr("未知") }
        return L10n.tr("\(Int(hours) / 24)天 \(Int(hours) % 24)小时")
    }
    func advance() { now = now.addingTimeInterval(6 * 3600); snapshotCount += 1; feedback = "测试时钟 +6h · 本地重算完成" }
    func refresh() { snapshotCount += 1; feedback = "离线重算完成 · 模型调用 0 次" }
    func confirm() {
        if !ledger.events.contains(where: { $0.id == "demo-candidate" }) {
            ledger = EventLedger(events: ledger.events + [ResetEvent(id: "demo-candidate", status: .candidate,
                                occurredAt: now.addingTimeInterval(-1800), observedAt: now, source: L10n.tr("合成公告：Codex limits have now been reset."))])
        }
        ledger.resolve(id: "demo-candidate", status: .verified, at: now)
        snapshotCount += 1; feedback = "演示事件已核验 · 锚点已重建 · 仅界面反馈"
    }
    func retract() {
        ledger.resolve(id: "demo-candidate", status: .retracted, at: now)
        snapshotCount += 1; feedback = "确认已撤回 · 恢复前一锚点 · 审计已保留（本次运行）"
    }
    func previewWatch() {
        watchState = WatchState()
        _ = NotificationPolicy.watch(state: &watchState, p24: 0.70, at: now, mode: .demo)
        let decision = NotificationPolicy.watch(state: &watchState, p24: 0.78, at: now, mode: .demo)
        preview = "\(LocalizedMessage(key: decision.reason))：未来 24 小时估计概率升至 78%。\n固定阈值场景，仅应用内预览。"
    }
}

@main struct ResetRadarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windows: NativeWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--run-real-cycle") {
            Task {
                let model = ConnectionModel()
                _ = await model.runCycle(forceFetch: true, allowCredentialInteraction: true)
                print(model.runtimeStatus)
                let forecast = model.currentProbability(asOf: Date())
                print("REAL CYCLE: community records=\(model.history?.events.count ?? 0), analyses=\(model.analyses.count), AI probability available=\(forecast != nil)")
                if let forecast { print("AI 12/24/48: \(forecast.probabilities)") }
                exit(forecast == nil ? 1 : 0)
            }
            return
        }
        if args.contains("--diagnose-analysis") {
            Task {
                let model = ConnectionModel(client: ConnectionClient(transport: AnalysisProbeTransport()))
                let started = Date()
                await model.analyzeRealPosts()
                print(model.analysisStatus.description)
                exit(model.analyses.values.contains { $0.analyzedAt >= started } ? 0 : 1)
            }
            return
        }
        if args.contains("--refresh-live-posts") {
            Task {
                let model = ConnectionModel()
                let started = Date()
                await model.fetchWeb()
                print(model.webStatus)
                guard let snapshot = model.snapshot, snapshot.observedAt >= started else { exit(1) }
                print("LIVE POSTS: \(snapshot.posts.count); source: \(snapshot.posts[0].sourceURL.absoluteString)")
                print("Saved real public posts to the app cache; no AI credentials read or AI requests sent.")
                exit(0)
            }
            return
        }
        if let index = args.firstIndex(of: "--render-previews"), args.count > index + 1 {
            do { try RenderPreviews.run(directory: args[index + 1]); exit(0) }
            catch { fputs("Preview rendering failed\n", stderr); exit(1) }
        }
        let checkSurface = args.contains("--check-native-window")
        let connections = ConnectionModel(preview: checkSurface)
        let controller = NativeWindowController(model: DemoModel(), connections: connections)
        windows = controller
        if checkSurface {
            do { try controller.validateSurface(); exit(0) }
            catch { fputs("::error::Native window validation failed: \(error.localizedDescription)\n", stderr); exit(1) }
        }
        if args.contains("--start-monitoring") {
            Task { await connections.authorizeAndStartMonitoring(forceAnalysis: args.contains("--reanalyze-latest")) }
        } else if UserDefaults.standard.bool(forKey: "connection.monitoring") {
            connections.startMonitoring()
        }
        if args.contains("--show-panel") {
            DispatchQueue.main.async { controller.showPanel() }
        }
    }
}

struct DemoBadge: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "testtube.2")
            Text(L10n.tr("Demo · 演示数据")).fontWeight(.semibold)
            Spacer()
            Text(L10n.tr("离线")).foregroundStyle(.secondary)
        }.font(.caption).padding(.horizontal, 10).padding(.vertical, 7)
            .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
            .accessibilityElement(children: .combine)
    }
}

struct RadarPanel: View {
    @ObservedObject var model: DemoModel
    @Environment(\.radarOpenWindow) private var openWindow
    @State private var allPosts = false
    @State private var allResets = false
    @State private var evidence: String?
    @State private var showPreview = false
    @State private var why = false
    let posts = ["We plan to reset Codex limits in 2–6 hours.", "A new reset credit is available to claim later.", "Shipping a small editor improvement today.", "Thanks for the feedback on the new interface."]
    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                HStack {
                    Text("Reset Radar").font(.headline)
                    Spacer()
                    Button { activate("settings") } label: { Image(systemName: "gearshape") }.help(L10n.tr("设置"))
                        .accessibilityLabel(L10n.tr("打开设置"))
                }
                DemoBadge()
            }.padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(spacing: 5) {
                        Text(model.values[1]).font(.system(size: 48, weight: .medium, design: .rounded)).monospacedDigit()
                            .accessibilityLabel(L10n.tr("未来24小时估计概率 \(model.values[1])，演示数据"))
                        Text(L10n.tr("未来 24 小时")).font(.subheadline)
                        Text(model.status).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        HStack {
                            horizon("12h", model.values[0]); Spacer(); horizon("24h", model.values[1]); Spacer(); horizon("48h", model.values[2])
                        }.padding(.horizontal, 28).padding(.top, 12)
                    }.frame(maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(L10n.tr("可能时段")).font(.subheadline.weight(.semibold))
                        if model.scenario == .overview {
                            Text(L10n.tr("明日 00:00–06:00 · 固定演示时段")).font(.caption).foregroundStyle(.secondary)
                        } else if let start = model.forecast.likelyStartHour, model.scenario != .offline {
                            Text(L10n.tr("\(model.now.addingTimeInterval(Double(start) * 3600).localized(date: .abbreviated, time: .shortened)) 起 6 小时 · 本地时间"))
                                .font(.caption).foregroundStyle(.secondary)
                        } else { Text(L10n.tr("尚无清晰时间窗口")).font(.caption).foregroundStyle(.secondary) }
                    }
                    DisclosureGroup(L10n.tr("为什么这样显示"), isExpanded: $why) {
                        Text(model.scenario == .overview ? L10n.tr("本页 46% / 72% / 88% 是界面演示值。请在底部切换到“合成历史 · 实际计算”查看本地算法输出。") : L10n.tr("合成已完成间隔 \(model.history.intervals.count) 个；尾部外推 \(model.forecast.tailHours.count) 小时。未知状态不显示为 0%。参数尚未用真实历史校准。"))
                            .font(.caption).foregroundStyle(.secondary).padding(.top, 5)
                    }.font(.caption)
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        HStack { Text("Tibo Signal").font(.subheadline.weight(.semibold)); Spacer(); Text(model.signalLabel).font(.caption).foregroundStyle(.secondary) }
                        Text(model.scenario == .unconfigured ? L10n.tr("连接未配置，暂无实时信号。以下仅为合成文本。") : L10n.tr("虚构计划：在未来数小时调整 Codex 用量")).font(.caption)
                        Button { evidence = L10n.tr("虚构作者 · demo-post-001\n\n\(posts[0])\n\n此为本地合成文本，不是 Tibo 的真实发言，没有原帖链接。") } label: {
                            Text("“\(posts[0])”").font(.caption).lineLimit(2).multilineTextAlignment(.leading)
                        }.buttonStyle(.plain).foregroundStyle(.secondary)
                        Text(L10n.tr("合成帖子 · 点击查看证据")).font(.caption2).foregroundStyle(.tertiary)
                    }
                    if model.scenario == .candidate {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L10n.tr("疑似已重置 · 需要核验")).font(.subheadline.weight(.semibold))
                            Text(L10n.tr("合成公告：Codex limits have now been reset.\n类型：global reset；时间：测试时钟前30分钟；范围：演示全局。"))
                                .font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button(L10n.tr("核验已发生")) { model.confirm() }.disabled(model.ledger.events.contains { $0.id == "demo-candidate" && $0.status != .candidate })
                                Button(L10n.tr("撤回确认")) { model.retract() }.disabled(!model.ledger.events.contains { $0.id == "demo-candidate" && $0.status == .verified })
                            }
                        }.padding(10).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Reset Drought").font(.subheadline.weight(.semibold))
                        Text(model.drought).font(.title3.monospacedDigit())
                        if let percentile = model.history.percentile {
                            Text(L10n.tr("长于 \(Int(percentile))% 的已记录历史间隔 · 合成样本")).font(.caption).foregroundStyle(.secondary)
                        } else { Text(L10n.tr("距最近已知重置 · 样本不足时不显示百分位")).font(.caption).foregroundStyle(.secondary) }
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        Text(L10n.tr("Recent from Tibo · 虚构帖子")).font(.subheadline.weight(.semibold))
                        ForEach(Array(posts.prefix(allPosts ? 10 : 3).enumerated()), id: \.offset) { i, post in
                            Button { evidence = L10n.tr("demo-post-\(i + 1) · 合成文本\n\n\(post)\n\n没有真实来源 URL，不发出网络请求。") } label: {
                                HStack(alignment: .top) { Text(post).lineLimit(2).multilineTextAlignment(.leading); Spacer(); Text("\(i + 1)h").foregroundStyle(.tertiary) }
                            }.buttonStyle(.plain).font(.caption)
                        }
                        Button(allPosts ? L10n.tr("收起") : L10n.tr("展开更多")) { allPosts.toggle() }.font(.caption)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        HStack { Text("Recent Resets").font(.subheadline.weight(.semibold)); Spacer(); Text(L10n.tr("合成已核验记录")).font(.caption2).foregroundStyle(.secondary) }
                        if model.events.isEmpty { Text(L10n.tr("暂无已核验重置记录")).font(.caption).foregroundStyle(.secondary) }
                        ForEach(Array(model.events.prefix(allResets ? 50 : 5))) { event in
                            Button { evidence = L10n.tr("\(event.id)\n\n类型：\(event.type.rawValue)\n适用范围：\(event.scope)\n来源：\(event.source)\n\n仅用于本地演示，未写入真实数据集。") } label: {
                                HStack(alignment: .top) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(event.type == .bankedCredit ? L10n.tr("Banked credit · 可稍后领取") : "Global reset")
                                        Text(event.occurredAt?.localized(date: .abbreviated, time: .shortened) ?? L10n.tr("时间未知")).foregroundStyle(.secondary)
                                    }; Spacer(); Image(systemName: "doc.text.magnifyingglass").foregroundStyle(.secondary)
                                }
                            }.buttonStyle(.plain).font(.caption)
                        }
                        if model.events.count > 5 { Button(allResets ? L10n.tr("收起记录") : L10n.tr("查看全部 \(model.events.count) 条")) { allResets.toggle() }.font(.caption) }
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.tr("本地预演控制")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Picker(L10n.tr("场景"), selection: $model.scenario) { ForEach(DemoScenario.allCases) { Text(L10n.key($0.rawValue)).tag($0) } }.labelsHidden()
                        HStack {
                            Button(L10n.tr("推进 6 小时")) { model.advance() }
                            Button(L10n.tr("通知预览")) { model.previewWatch(); showPreview = true }
                        }.font(.caption)
                        Text(model.now.localized(date: .abbreviated, time: .shortened) + L10n.tr(" · 测试时钟")).font(.caption2).foregroundStyle(.secondary)
                    }
                }.padding(.horizontal, 20).padding(.vertical, 12)
            }
            Divider()
            HStack {
                Text(model.feedback).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 4)
                Button(L10n.tr("刷新")) { model.refresh() }.font(.caption)
                Button(L10n.tr("退出")) { NSApplication.shared.terminate(nil) }.font(.caption)
            }.padding(.horizontal, 16).padding(.vertical, 12)
        }.frame(width: 380, height: 640).nativeSurface()
            .sheet(item: Binding(get: { evidence.map(Evidence.init) }, set: { evidence = $0?.text })) { item in
                VStack(alignment: .leading, spacing: 16) {
                    DemoBadge(); Text(L10n.tr("来源与证据")).font(.headline)
                    Text(item.text).font(.body).textSelection(.enabled)
                    Button(L10n.tr("完成")) { evidence = nil }.keyboardShortcut(.defaultAction)
                }.padding(24).frame(width: 340)
            }
            .sheet(isPresented: $showPreview) {
                VStack(alignment: .leading, spacing: 16) {
                    DemoBadge(); Label("Reset Watch", systemImage: "cloud.sun").font(.headline)
                    Text(model.preview); Text(L10n.tr("系统通知提交次数：0")).font(.caption).foregroundStyle(.secondary)
                    Button(L10n.tr("完成")) { showPreview = false }.keyboardShortcut(.defaultAction)
                }.padding(24).frame(width: 340)
            }
    }
    struct Evidence: Identifiable { let text: String; var id: String { text } }
    private func horizon(_ name: String, _ value: String) -> some View {
        VStack(spacing: 4) { Text(name).font(.caption).foregroundStyle(.secondary); Text(value).font(.subheadline.weight(.medium)).monospacedDigit() }
    }
    private func activate(_ id: String) { openWindow(id: id); NSApp.activate(ignoringOtherApps: true) }
}

struct OnboardingView: View {
    @AppStorage("demo.onboardingStep") private var step = 1
    @Environment(\.dismiss) private var dismiss
    @Environment(\.radarOpenWindow) private var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            DemoBadge()
            Text("\(step) / 3").font(.caption).foregroundStyle(.secondary)
            Image(systemName: step == 1 ? "cloud.sun" : step == 2 ? "key" : "checkmark.circle").font(.system(size: 34)).foregroundStyle(.secondary)
            Text(step == 1 ? L10n.tr("少刷 X，看看 Reset 天气。") : step == 2 ? L10n.tr("连接 AI") : L10n.tr("连接动态与完成")).font(.title2.weight(.semibold))
            Text(step == 1 ? L10n.tr("菜单栏常驻 · 公开信息估计 · 本机保存\n当前是离线技术预演，所有帖子和概率都为演示。") : step == 2 ? L10n.tr("AI 未配置。此轮可跳过并体验离线演示。\n真实连接请到设置的“真实连接”页配置；此向导只演示离线流程。") : L10n.tr("动态未配置 · AI 已跳过\n当前不会实时观察 Tibo，也不会提交系统通知。"))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(L10n.tr("预测在本机计算；后续启用 AI 时，公开帖文会发送至 OpenAI，API 可能单独收费。"))
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            HStack {
                if step > 1 { Button(L10n.tr("上一步")) { step -= 1 } }
                Button(L10n.tr("先体验")) { openWindow(id: "rehearsal"); dismiss() }
                Spacer()
                Button(step == 3 ? L10n.tr("开始使用") : step == 2 ? L10n.tr("暂时跳过") : L10n.tr("开始设置")) {
                    if step < 3 { step += 1 } else { openWindow(id: "rehearsal"); dismiss() }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 500, height: 400).nativeSurface()
    }
}

struct DemoSettingsView: View {
    @ObservedObject var model: DemoModel
    @Environment(\.radarOpenWindow) private var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            DemoBadge()
            Text(L10n.tr("设置与预演")).font(.title2.weight(.semibold))
            Form {
                Section(L10n.tr("通用")) {
                    LabeledContent(L10n.tr("运行模式"), value: L10n.tr("Demo · 仅本地演示"))
                    Picker(L10n.tr("演示场景"), selection: $model.scenario) { ForEach(DemoScenario.allCases) { Text(L10n.key($0.rawValue)).tag($0) } }
                    LabeledContent(L10n.tr("自动检查"), value: L10n.tr("Demo 关闭；测试时钟手动推进"))
                }
                Section(L10n.tr("连接")) {
                    LabeledContent("OpenAI", value: L10n.tr("在“真实连接”页配置"))
                    LabeledContent(L10n.tr("X 数据源"), value: L10n.tr("已提供实验性免 Token 网页采集"))
                }
                Section(L10n.tr("通知与隐私")) {
                    LabeledContent(L10n.tr("系统通知"), value: L10n.tr("Demo 禁止 · 仅应用内预览"))
                    Text(L10n.tr("演示面板保持离线；“真实连接”页由你手动发起请求，结果与演示数据分开保存。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
            HStack {
                Button(L10n.tr("三步向导")) { openWindow(id: "onboarding"); NSApp.activate(ignoringOtherApps: true) }
                Button(L10n.tr("打开预演面板")) { openWindow(id: "rehearsal"); NSApp.activate(ignoringOtherApps: true) }
                Spacer(); Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? L10n.tr("开发构建")).font(.caption).foregroundStyle(.secondary)
            }
        }.padding(22).frame(width: 560, height: 490)
    }
}
