import SwiftUI
import AppKit
import RadarCore

@MainActor final class ConnectionModel: ObservableObject {
    @Published var savedAI = false
    @Published var modelID = ""
    @Published var baseURL = APIEndpoint.defaultURL
    @Published var api: APIProtocol = .responses
    @Published var history: CommunityResetHistory?
    @Published var historyStatus = "历史记录尚未加载"
    @Published var analyses: [String: LivePostAnalysis] = [:]
    @Published var analysisStatus = "尚未分析真实帖子"
    @Published var probabilityForecast: AIProbabilityForecast?
    @Published var probabilityStatus = "尚未请求 AI 概率预测"
    @Published private(set) var credentialAccessRequired = false
    @Published private(set) var probabilityRequestFailed = false
    @Published var aiStatus = "未配置"
    @Published var webStatus = "无需 X Token · 尚未抓取"
    @Published var busyAI = false
    @Published var busyWeb = false
    @Published var snapshot: PublicWebSnapshot?
    @Published var showRealFeed = true
    @Published var gate = ConnectionGate()
    @Published var monitoring = false
    @Published var runtimeStatus = "自动检查未启动"
    @Published var nextCheck: Date?
    private var monitorTask: Task<Void, Never>?
    private var sessionCredential: (endpoint: String, secret: String)?
    private let preview: Bool
    private let client: ConnectionClient
    private let folder: URL
    init(preview: Bool = false, client: ConnectionClient = ConnectionClient()) {
        self.preview = preview
        self.client = client
        folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ResetRadar/Shadow", isDirectory: true)
        do {
            history = try CommunityResetHistory.bundled()
            historyStatus = "已载入 \(history!.events.count) 条社区历史记录"
        } catch { historyStatus = "历史数据文件无法读取，概率保持未知" }
        guard !preview else { return }
        modelID = UserDefaults.standard.string(forKey: "connection.modelID") ?? ""
        baseURL = UserDefaults.standard.string(forKey: "connection.baseURL") ?? APIEndpoint.defaultURL
        api = APIProtocol(rawValue: UserDefaults.standard.string(forKey: "connection.api") ?? "") ?? .responses
        if let data = try? Data(contentsOf: folder.appendingPathComponent("ai-probability.json")),
           let saved = try? JSONDecoder().decode(AIProbabilityForecast.self, from: data) { probabilityForecast = saved }
        if let data = try? Data(contentsOf: folder.appendingPathComponent("request-budget.json")),
           let saved = try? JSONDecoder().decode(ConnectionGate.self, from: data) { gate = saved }
        if let data = try? Data(contentsOf: folder.appendingPathComponent("web-preview.json")),
           let saved = try? JSONDecoder().decode(PublicWebSnapshot.self, from: data),
           Date().timeIntervalSince(saved.observedAt) >= 0, Date().timeIntervalSince(saved.observedAt) < 7 * 86400 {
            snapshot = saved; showRealFeed = (UserDefaults.standard.object(forKey: "connection.showReal") as? Bool) ?? true
            if let stored = try? Data(contentsOf: folder.appendingPathComponent("post-analyses.json")),
               let rows = try? JSONDecoder().decode([LivePostAnalysis].self, from: stored) {
                for row in rows where saved.posts.contains(where: { $0.id == row.result.post_id && $0.contentHash == row.contentHash }) {
                    analyses[row.result.post_id] = row
                }
                if !analyses.isEmpty { analysisStatus = "已加载本机分析记录 · 待人工核验" }
            }
            webStatus = "已加载本机缓存 · \(saved.observedAt.formatted(date: .abbreviated, time: .shortened)) 抓取"
        }
    }
    private func readAISecret(allowInteraction: Bool) async throws -> String? {
        let endpoint = try APIEndpoint(baseURL).baseURL.absoluteString
        if let cached = sessionCredential, cached.endpoint == endpoint { return cached.secret }
        let store = try credentials()
        let secret: String?
        do {
            secret = try await Task.detached { try store.read(.openai, allowInteraction: allowInteraction) }.value
            credentialAccessRequired = false
        } catch {
            if let failure = error as? KeychainFailure, failure.requiresAuthorization {
                credentialAccessRequired = true
            }
            throw error
        }
        if let secret { sessionCredential = (endpoint, secret) }
        return secret
    }
    func authorizeAndStartMonitoring(forceAnalysis: Bool = false) async {
        guard !preview, !busyAI else { return }
        busyAI = true
        runtimeStatus = "等待系统钥匙串授权，公开帖子与已保存分析仍可查看"
        do {
            _ = try await readAISecret(allowInteraction: true)
        } catch { aiStatus = safeMessage(error) }
        busyAI = false
        startMonitoring(forceAnalysis: forceAnalysis)
    }
    func startMonitoring(forceAnalysis: Bool = false) {
        guard !preview, monitorTask == nil else { return }
        monitoring = true
        UserDefaults.standard.set(true, forKey: "connection.monitoring")
        monitorTask = Task { [weak self] in
            var first = true
            while !Task.isCancelled {
                guard let self else { return }
                let next = await self.runCycle(forceFetch: first, forceAnalysis: first && forceAnalysis)
                first = false
                self.nextCheck = next
                do { try await Task.sleep(for: .seconds(max(1, next.timeIntervalSinceNow))) }
                catch { return }
            }
        }
    }
    func stopMonitoring() {
        monitorTask?.cancel(); monitorTask = nil; monitoring = false; nextCheck = nil
        runtimeStatus = "自动检查已暂停"
        if !preview { UserDefaults.standard.set(false, forKey: "connection.monitoring") }
    }
    func runCycle(forceFetch: Bool = false, forceAnalysis: Bool = false, allowCredentialInteraction: Bool = false) async -> Date {
        let now = Date()
        guard !preview else { return now.addingTimeInterval(3600) }
        guard !busyAI, !busyWeb else { runtimeStatus = "已有请求进行中，稍后检查"; return now.addingTimeInterval(60) }
        if forceFetch || snapshot.map({ now.timeIntervalSince($0.observedAt) >= 3600 }) ?? true {
            if let wait = gate.blockingFailure(ai: false, now: now)?.retryAt { runtimeStatus = "等待网页请求间隔"; return wait }
            runtimeStatus = "正在更新真实公开帖子"
            let started = Date()
            await fetchWeb()
            guard let snapshot, snapshot.observedAt >= started else {
                runtimeStatus = "网页更新未完成：" + webStatus
                return max(gate.webRetryAt ?? now, now.addingTimeInterval(3600))
            }
        }
        guard !Task.isCancelled else { return now.addingTimeInterval(3600) }
        let model = try? validModel()
        let canonical = try? APIEndpoint(baseURL).baseURL.absoluteString
        let posts = Array(snapshot?.posts.prefix(5) ?? [])
        let needsAnalysis = forceAnalysis || posts.contains { post in
            guard let row = analyses[post.id] else { return true }
            return row.contentHash != post.contentHash || row.model != model || row.baseURL != canonical ||
                row.api != api.rawValue || row.promptVersion != LivePostAnalysis.currentPromptVersion
        }
        if needsAnalysis && model != nil && ((try? credentials().contains(.openai)) ?? false) {
            if let wait = gate.blockingFailure(ai: true, now: Date())?.retryAt {
                runtimeStatus = "帖子已更新，等待 AI 请求间隔或每日额度"; return wait
            }
            runtimeStatus = "正在计算真实帖子分析"
            await analyzeRealPosts(allowCredentialInteraction: allowCredentialInteraction)
            runtimeStatus = analysisStatus
        } else {
            runtimeStatus = needsAnalysis ? "网页已更新 · AI 配置待完成" : "真实数据运行中 · 相同正文复用已保存分析"
        }
        if !posts.isEmpty && currentProbability(asOf: Date()) == nil && model != nil {
            if let wait = gate.blockingFailure(ai: true, now: Date())?.retryAt {
                probabilityStatus = "等待共享请求间隔后计算 AI 概率"; runtimeStatus = probabilityStatus; return wait
            }
            await predictProbability(allowCredentialInteraction: allowCredentialInteraction)
            runtimeStatus = probabilityStatus
        }
        do {
            let forecast = historicalForecast
            let reference = referenceForecast(asOf: Date())
            let plan = announcedPlan(asOf: Date())
            let report: [String: Any] = ["as_of": Date().ISO8601Format(), "mode": "real_local",
                "algorithm_version": ForecastEngine.version, "history_version": history?.version ?? "unavailable",
                "community_records": history?.events.count ?? 0, "interval_candidates": history?.candidateIntervals(asOf: Date()).count ?? 0,
                "probability_available": forecast?.available ?? false, "probabilities": forecast?.probability ?? [],
                "reason": forecast?.reason ?? "数据不足",
                "primary_display": "ai_probability",
                "ai_probabilities": currentProbability(asOf: Date())?.probabilities ?? [],
                "ai_probability_reason": currentProbability(asOf: Date())?.reason ?? probabilityStatus,
                "ai_probability_calibrated": false,
                "announced_plan": plan.map { ["post_id": $0.id, "source_url": $0.sourceURL.absoluteString,
                    "time_expression": $0.expression, "scheduled_at": $0.scheduledAt.ISO8601Format(),
                    "alternative_scheduled_at": $0.alternativeScheduledAt?.ISO8601Format() ?? "",
                    "status": $0.status(asOf: Date()), "scope": $0.scope,
                    "delivery_probability_calibrated": false] as [String: Any] } ?? [:],
                "community_reference": ["version": CommunityResetHistory.referenceVersion,
                    "available": reference?.available ?? false, "probabilities": reference?.probability ?? [],
                    "reason": reference?.reason ?? "历史未加载", "calibrated": false,
                    "uses_ai_signal_adjustment": true, "model": modelID,
                    "eligible_signal_count": referenceSignals(asOf: Date()).count,
                    "baseline": reference?.baseline ?? [], "time_basis": "announcement"] as [String: Any],
                "post_count": posts.count, "analysis_count": analyses.count,
                "status": runtimeStatus, "system_notifications": false]
            try save(JSONSerialization.data(withJSONObject: report, options: .prettyPrinted), filename: "latest-runtime.json")
        } catch { runtimeStatus = "本轮数据已处理，但运行记录保存失败" }
        return nextAutomaticCheck(asOf: Date())
    }
    private func nextAutomaticCheck(asOf now: Date) -> Date {
        // Wake at the prediction's expiry or announcement boundary, rather than
        // an hour after the preceding network call finished.
        guard !credentialAccessRequired else { return now.addingTimeInterval(3600) }
        var deadlines = [now.addingTimeInterval(3600)]
        if let value = currentProbability(asOf: now) {
            deadlines.append(value.asOf.addingTimeInterval(3600))
        }
        if let plan = announcedPlan(asOf: now), plan.latest > now { deadlines.append(plan.latest) }
        return max(now.addingTimeInterval(1), deadlines.min()!)
    }
    func probabilitySummary(asOf: Date) -> String {
        if currentProbability(asOf: asOf) != nil { return "AI 估计 · 未校准" }
        if busyAI { return "正在评估下一次 Reset…" }
        if credentialAccessRequired { return "AI 密钥需要授权" }
        if let failure = gate.blockingFailure(ai: true, now: asOf) {
            if failure.issue == .dailyRequestLimit { return "今日 AI 额度已用完" }
            return "等待 AI 请求间隔"
        }
        if probabilityRequestFailed { return "评估失败 · 查看详情" }
        if probabilityForecast != nil { return "旧预测已过期，需重新评估" }
        return "尚未评估下一次 Reset"
    }
    var historicalForecast: Forecast? { history?.forecast(asOf: Date()) }
    func currentProbability(asOf: Date) -> AIProbabilityForecast? {
        guard let snapshot, asOf.timeIntervalSince(snapshot.observedAt) < 3 * 3600,
              let value = probabilityForecast,
              value.matches(posts: Array(snapshot.posts.prefix(5)), now: asOf, model: modelID,
                baseURL: baseURL, api: api, historyVersion: history?.version ?? "unavailable") else { return nil }
        if let plan = announcedPlan(asOf: asOf), value.asOf < plan.latest && asOf > plan.latest { return nil }
        return value
    }
    func predictProbability(allowCredentialInteraction: Bool = true) async {
        guard !preview, !busyAI, !busyWeb, let snapshot, !snapshot.posts.isEmpty else { return }
        busyAI = true; probabilityRequestFailed = false
        defer { busyAI = false }
        do {
            let model = try validModel()
            guard let secret = try await readAISecret(allowInteraction: allowCredentialInteraction) else {
                probabilityStatus = "请先保存 AI 服务 Key"; return
            }
            try reserve(ai: true)
            probabilityStatus = "AI 正在评估未来 12 / 24 / 48 小时概率…"
            let now = Date()
            let result = try await client.forecastProbability(posts: Array(snapshot.posts.prefix(5)), history: history,
                plan: announcedPlan(asOf: now), asOf: now, secret: secret, model: model, baseURL: baseURL, api: api)
            try save(JSONEncoder().encode(result), filename: "ai-probability.json")
            probabilityForecast = result
            probabilityStatus = "AI 概率预测完成 · 数值与原文校验通过"
        } catch {
            probabilityRequestFailed = true
            probabilityStatus = handle(error, ai: true)
        }
    }
    func referenceSignals(asOf: Date) -> [ForecastSignal] {
        let canonical = try? APIEndpoint(baseURL).baseURL.absoluteString
        let anchor = history?.recordedResets(asOf: asOf).last?.announcedAt ?? .distantFuture
        return (snapshot?.posts ?? []).compactMap { post in
            guard post.publishedAt >= anchor, let row = analyses[post.id], row.model == modelID,
                  row.baseURL == canonical, row.api == api.rawValue else { return nil }
            return row.referenceSignal(post: post, asOf: asOf)
        }
    }
    func referenceForecast(asOf: Date) -> Forecast? {
        history?.referenceForecast(asOf: asOf, signals: referenceSignals(asOf: asOf))
    }
    func announcedPlan(asOf: Date) -> AnnouncedResetPlan? {
        let canonical = try? APIEndpoint(baseURL).baseURL.absoluteString
        let anchor = history?.recordedResets(asOf: asOf).last?.announcedAt ?? .distantPast
        return (snapshot?.posts ?? []).compactMap { post -> AnnouncedResetPlan? in
            guard post.publishedAt >= anchor, let row = analyses[post.id], row.model == modelID,
                  row.baseURL == canonical, row.api == api.rawValue else { return nil }
            return AnnouncedResetPlan.from(post: post, analysis: row, asOf: asOf)
        }.max { $0.publishedAt < $1.publishedAt }
    }
    var requestTarget: String { (try? APIEndpoint(baseURL).requestURL(api).absoluteString) ?? "请输入有效 Base URL" }
    private func credentials() throws -> KeychainCredentials {
        KeychainCredentials(namespace: try APIEndpoint(baseURL).credentialNamespace)
    }
    func configurationChanged() {
        sessionCredential = nil
        savedAI = false; aiStatus = "配置已修改 · 需保存并重新测试"
        refreshCredentialStatus()
    }
    func refreshCredentialStatus() {
        guard !preview else { return }
        do {
            savedAI = try credentials().contains(.openai)
            if savedAI && aiStatus == "未配置" { aiStatus = "此地址已有密钥 · 本次启动尚未测试" }
        } catch { savedAI = false }
    }
    private func persistConfiguration() throws {
        let endpoint = try APIEndpoint(baseURL)
        UserDefaults.standard.set(endpoint.baseURL.absoluteString, forKey: "connection.baseURL")
        UserDefaults.standard.set(modelID.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "connection.modelID")
        UserDefaults.standard.set(api.rawValue, forKey: "connection.api")
    }
    func saveAI(_ value: String) -> Bool {
        guard !preview, !busyAI else { return false }
        do {
            _ = try validModel()
            let store = try credentials()
            if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { try store.save(value, for: .openai); sessionCredential = nil }
            guard try store.contains(.openai) else { aiStatus = "请填写此服务的 API Key"; return false }
            try persistConfiguration()
            savedAI = true; aiStatus = "配置已保存，Key 位于本机钥匙串 · 尚未测试"
            return true
        } catch { aiStatus = safeMessage(error); return false }
    }
    func deleteAI() {
        guard !preview, !busyAI else { return }
        do { try credentials().delete(.openai); sessionCredential = nil; savedAI = false; aiStatus = "此地址的密钥已从钥匙串删除" }
        catch { aiStatus = safeMessage(error) }
    }
    private func validModel() throws -> String {
        let model = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, model.count <= 128, !model.hasPrefix("sk-"),
              model.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.:/".contains($0)) }) else {
            throw ConnectionFailure(.invalidInput)
        }
        return model
    }
    func testAI() async {
        guard !preview, !busyAI else { return }
        busyAI = true; defer { busyAI = false }
        do {
            let model = try validModel()
            let loaded = try await readAISecret(allowInteraction: true)
            guard let secret = loaded else { savedAI = false; aiStatus = "请先保存此服务的 API Key"; return }
            try persistConfiguration()
            try reserve(ai: true)
            aiStatus = "正在请求所填服务 · 只发送固定测试文本"
            let result = try await client.testOpenAI(secret: secret, model: model, baseURL: baseURL, api: api)
            aiStatus = "连接与 JSON 测试通过 · \(result.model)\n输入 \(result.inputTokens.map(String.init) ?? "未知") / 输出 \(result.outputTokens.map(String.init) ?? "未知") tokens；尚未评测帖子分类质量。"
        } catch { aiStatus = handle(error, ai: true) }
    }
    func analyzeRealPosts(allowCredentialInteraction: Bool = true) async {
        guard !preview, !busyAI, !busyWeb else { return }
        guard let snapshot, !snapshot.posts.isEmpty else { analysisStatus = "请先抓取真实帖子"; return }
        let posts = Array(snapshot.posts.prefix(5))
        guard posts.reduce(0, { $0 + $1.text.utf8.count }) <= 60_000 else { analysisStatus = "帖子正文超过本轮 60 KB 上限，未发送请求"; return }
        busyAI = true; defer { busyAI = false }
        do {
            let model = try validModel()
            let loaded = try await readAISecret(allowInteraction: allowCredentialInteraction)
            guard let secret = loaded else { savedAI = false; analysisStatus = "请先保存此服务的 API Key"; return }
            try persistConfiguration()
            try reserve(ai: true)
            analysisStatus = "正在分析 \(posts.count) 条真实帖子…"
            let rows = try await client.analyzePosts(posts, secret: secret, model: model, baseURL: baseURL, api: api)
            try save(JSONEncoder().encode(rows), filename: "post-analyses.json")
            analyses = Dictionary(uniqueKeysWithValues: rows.map { ($0.result.post_id, $0) })
            useRealFeed()
            analysisStatus = "\(rows.count) 条真实帖子分析完成 · 证据校验通过，结论待人工核验"
        } catch { analysisStatus = handle(error, ai: true) }
    }
    func fetchWeb() async {
        guard !preview, !busyWeb, !busyAI else { return }
        busyWeb = true; defer { busyWeb = false }
        do {
            try reserve(ai: false)
            webStatus = "正在读取 x.com/thsottiaux · 无 Token / Cookie"
            let result = try await client.fetchWeb()
            try save(JSONEncoder().encode(result), filename: "web-preview.json")
            snapshot = result; showRealFeed = true
            analyses = analyses.filter { id, row in result.posts.contains { $0.id == id && $0.contentHash == row.contentHash } }
            analysisStatus = analyses.isEmpty ? "已取得真实帖子 · 尚未分析" : "保留正文未变的分析记录 · 待人工核验"
            UserDefaults.standard.set(true, forKey: "connection.showReal")
            webStatus = "读取 \(result.posts.count) 条真实帖子 · 仅当前页面样本，覆盖不完整"
        } catch { webStatus = handle(error, ai: false) }
    }
    func returnToDemo() { showRealFeed = false; if !preview { UserDefaults.standard.set(false, forKey: "connection.showReal") } }
    func useRealFeed() { showRealFeed = true; if !preview { UserDefaults.standard.set(true, forKey: "connection.showReal") } }
    func clearWebCache() {
        guard !preview, !busyWeb, !busyAI else { return }
        do {
            let file = folder.appendingPathComponent("web-preview.json")
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            let analysisFile = folder.appendingPathComponent("post-analyses.json")
            if FileManager.default.fileExists(atPath: analysisFile.path) { try FileManager.default.removeItem(at: analysisFile) }
            let probabilityFile = folder.appendingPathComponent("ai-probability.json")
            if FileManager.default.fileExists(atPath: probabilityFile.path) { try FileManager.default.removeItem(at: probabilityFile) }
            probabilityForecast = nil; probabilityStatus = "尚未请求 AI 概率预测"
            snapshot = nil; analyses = [:]; analysisStatus = "尚未分析真实帖子"; webStatus = "网页缓存已清除"
        } catch { webStatus = safeMessage(error) }
    }
    private func reserve(ai: Bool) throws {
        var next = gate
        try next.reserve(ai: ai, now: Date())
        try save(JSONEncoder().encode(next), filename: "request-budget.json") // Persist before issuing any request.
        gate = next
    }
    private func save(_ data: Data, filename: String) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = folder.appendingPathComponent(filename)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private func handle(_ error: Error, ai: Bool) -> String {
        if let failure = error as? ConnectionFailure, let retry = failure.retryAt {
            gate.deferRetry(ai: ai, until: retry)
            do { try save(JSONEncoder().encode(gate), filename: "request-budget.json") }
            catch { return "无法保存重试状态，已停止请求。请检查本机存储权限。" }
            return (failure.errorDescription ?? "连接未完成") + "\n可重试：\(retry.formatted(date: .abbreviated, time: .standard))"
        }
        return safeMessage(error)
    }
    private func safeMessage(_ error: Error) -> String {
        if let failure = error as? ConnectionFailure { return failure.errorDescription ?? "连接未完成" }
        if let failure = error as? AnalysisValidationError { return failure.errorDescription ?? "分析结果未通过校验" }
        if let failure = error as? KeychainFailure {
            if failure.requiresAuthorization { return "AI 密钥需要重新授权。点击“授权并评估”，在 macOS 钥匙串提示中允许访问；若仍失败，请在设置中重新保存 Key。" }
            if failure.status == -25308 { return "后台无法读取钥匙串。请点击测试连接，并在系统提示中允许本应用访问后再运行分析。" }
            return failure.errorDescription ?? "钥匙串操作未完成"
        }
        return "本机保存或读取未完成，请检查磁盘与文件权限后重试。"
    }
}

struct RadarSettings: View {
    @ObservedObject var model: DemoModel
    @ObservedObject var connections: ConnectionModel
    @Environment(\.radarCloseWindow) private var closeWindow
    @State private var connectionTab = true
    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text("设置").font(.headline)
                Spacer()
                Button("关闭", systemImage: "xmark.circle.fill") { closeWindow(id: "settings") }
                    .buttonStyle(.plain).help("关闭设置（⌘W / Esc）")
                    .accessibilityIdentifier("close-settings")
            }.padding(.bottom, 8)
            Picker("设置分组", selection: $connectionTab) {
                Text("真实运行").tag(true)
                Text("离线预演").tag(false)
            }.pickerStyle(.segmented).labelsHidden()
            if connectionTab { ConnectionSettingsView(connections: connections) }
            else { DemoSettingsView(model: model) }
        }.padding(14).frame(maxWidth: .infinity, maxHeight: .infinity)
            .groupBoxStyle(NativeSectionStyle()).nativeSurface()
    }
}

struct ConnectionSettingsView: View {
    @ObservedObject var connections: ConnectionModel
    @State private var secret = ""
    @Environment(\.radarOpenWindow) private var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("真实运行与连接", systemImage: "network").font(.title2.weight(.semibold))
            Text("保存密钥不会发出请求；点击抓取、测试或分析才连接对应服务。")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("每小时自动检查真实数据", isOn: Binding(get: { connections.monitoring }, set: { enabled in
                if enabled { connections.startMonitoring() } else { connections.stopMonitoring() }
            }))
            Text(connections.runtimeStatus).font(.caption).foregroundStyle(.secondary)
            if let next = connections.nextCheck {
                Text("下次检查：" + next.formatted(date: .omitted, time: .standard)).font(.caption2).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("网页采集（实验）").font(.headline)
                            Text("目标：@thsottiaux · 无需 X Token").font(.subheadline)
                            Text("只读取公开主页，不读取浏览器登录信息。取得的少量帖子不能证明历史覆盖完整。")
                                .font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button(connections.busyWeb ? "正在抓取…" : "抓取公开网页") { Task { await connections.fetchWeb() } }
                                    .disabled(connections.busyWeb || connections.busyAI)
                                if connections.snapshot != nil {
                                    Button("查看真实帖子") { connections.useRealFeed(); openWindow(id: "web-feed"); NSApp.activate(ignoringOtherApps: true) }
                                    Button("清除网页缓存") { connections.clearWebCache() }.disabled(connections.busyWeb || connections.busyAI)
                                }
                            }
                            Text(connections.webStatus).font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("AI 服务 · 支持第三方").font(.headline)
                            TextField("Base URL，例如 https://api.example.com/v1", text: $connections.baseURL)
                                .textFieldStyle(.roundedBorder).disabled(connections.busyAI)
                                .accessibilityLabel("API Base URL")
                                .onChange(of: connections.baseURL) { _, _ in connections.configurationChanged() }
                            Picker("接口类型", selection: $connections.api) {
                                ForEach(APIProtocol.allCases, id: \.self) { Text($0.label).tag($0) }
                            }.pickerStyle(.segmented).disabled(connections.busyAI)
                                .onChange(of: connections.api) { _, _ in connections.configurationChanged() }
                            Text("请求地址：" + connections.requestTarget).font(.caption2).foregroundStyle(.secondary)
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            SecureField(connections.savedAI ? "已有密钥；输入新 Key 可替换" : "粘贴此服务的 API Key", text: $secret)
                                .textFieldStyle(.roundedBorder).disabled(connections.busyAI)
                                .accessibilityLabel("API Key 安全输入框")
                            TextField("模型 ID，支持 provider/model 格式", text: $connections.modelID)
                                .textFieldStyle(.roundedBorder).disabled(connections.busyAI)
                                .onChange(of: connections.modelID) { _, _ in connections.configurationChanged() }
                            HStack {
                                Button("保存 URL、Key 与模型") { if connections.saveAI(secret) { secret = "" } }
                                    .disabled(connections.busyAI)
                                Button("删除已保存密钥") { connections.deleteAI(); secret = "" }.disabled(connections.busyAI)
                            }
                            AIRequestActions(connections: connections, hasUnsavedKey: !secret.isEmpty)
                        }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    HStack {
                        Text(connections.historyStatus).font(.caption)
                        Spacer()
                        Button("查看历史 Reset") { openWindow(id: "reset-history"); NSApp.activate(ignoringOtherApps: true) }
                    }
                    Text("密钥只存本机钥匙串，不写入配置或日志。网页结果独立保存在本机；系统通知保持关闭。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("离线演示面板") { connections.returnToDemo(); openWindow(id: "rehearsal"); NSApp.activate(ignoringOtherApps: true) }
                Spacer(); Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "开发构建").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(14).onAppear { connections.refreshCredentialStatus() }.onDisappear { secret = "" }
    }
}

struct WebFeedView: View {
    @ObservedObject var connections: ConnectionModel
    @Environment(\.radarOpenWindow) private var openWindow
    @State private var showingStatus = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Text("Reset Radar").font(.title3.weight(.semibold))
                Spacer()
                if connections.busyWeb || connections.busyAI {
                    ProgressView().controlSize(.small)
                }
                Button("刷新网页", systemImage: "arrow.clockwise") { Task { await connections.fetchWeb() } }
                    .disabled(connections.busyWeb || connections.busyAI)
                    .help("刷新最近帖子")
                Button("设置", systemImage: "gearshape") { showWindow("settings") }.help("设置")
                Menu {
                    Button("运行详情") { showingStatus = true }
                    Button("历史记录") { showWindow("reset-history") }
                    Divider()
                    Button("离线演示") { connections.returnToDemo() }
                    Button("退出 Reset Radar") { NSApp.terminate(nil) }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize().help("更多")
            }.labelStyle(.iconOnly).buttonStyle(.plain)

            TimelineView(.periodic(from: .now, by: 60)) { context in
                AIProbabilitySummary(connections: connections, asOf: context.date)
            }
            Divider()
            TimelineView(.periodic(from: .now, by: 60)) { context in
                CompactResetHistory(history: connections.history, asOf: context.date) { showWindow("reset-history") }
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("最近帖子").font(.headline)
                    Spacer()
                    if let snapshot = connections.snapshot {
                        Text("@" + snapshot.handle).font(.caption).foregroundStyle(.secondary)
                            .help("页面报告的作者：\(snapshot.displayName)，ID：\(snapshot.authorID)；身份待独立核验。仅当前页样本。")
                    }
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if let snapshot = connections.snapshot, !snapshot.posts.isEmpty {
                            ForEach(snapshot.posts) { post in
                                RealPostRow(post: post, analysis: connections.analyses[post.id])
                                if post.id != snapshot.posts.last?.id { Divider() }
                            }
                        } else {
                            Text("暂无帖子，点击右上角刷新。")
                                .font(.callout).foregroundStyle(.secondary).padding(.vertical, 20)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }.frame(maxHeight: .infinity)
            Button { showingStatus = true } label: {
                HStack(spacing: 5) {
                    Circle().fill(connections.monitoring ? Color.green : Color.secondary).frame(width: 5, height: 5)
                    Text(connections.monitoring ? "自动更新" : "手动更新")
                    Spacer()
                    if let snapshot = connections.snapshot {
                        if Date().timeIntervalSince(snapshot.observedAt) > 3 * 3600 {
                            Text("帖子缓存已过期").foregroundStyle(.orange)
                        } else {
                            Text(snapshot.observedAt.formatted(date: .omitted, time: .shortened) + " 更新")
                        }
                    }
                }.font(.caption).foregroundStyle(.secondary)
            }.buttonStyle(.plain).help("查看运行状态")
                .popover(isPresented: $showingStatus) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("运行详情").font(.headline)
                        Text(connections.webStatus)
                        Text(connections.runtimeStatus)
                        Text("帖子仅覆盖抓取页面，历史归档也可能不完整。")
                            .foregroundStyle(.secondary)
                    }.font(.callout).padding(20).frame(width: 320)
                }
        }.padding(20).frame(width: 380, height: 640)
            .nativeSurface()
    }
    private func showWindow(_ id: String) {
        openWindow(id: id); NSApp.activate(ignoringOtherApps: true)
    }
}

private struct RealPostRow: View {
    let post: PublicWebPost
    let analysis: LivePostAnalysis?
    @State private var expanded = false
    private func signalLabel(_ type: String) -> String {
        ["unrelated": "无关", "signal": "潜在信号", "planned_reset": "重置计划", "reset_claim": "声称已重置",
         "banked_credit": "存储额度", "targeted_compensation": "定向补偿", "unknown": "不确定"][type] ?? "不确定"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(post.publishedAt.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
                Spacer()
                if let row = analysis, row.contentHash == post.contentHash,
                   !["unrelated", "unknown"].contains(row.result.event_type) {
                    Text("AI分析·" + signalLabel(row.result.event_type))
                        .foregroundStyle(row.result.event_type == "planned_reset" ? RadarPalette.gold : Color.accentColor)
                        .help("AI 分类，尚待核验")
                }
            }.font(.caption)
            Text(post.text).font(.system(size: 13)).lineLimit(expanded ? nil : 3)
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Button(expanded ? "收起" : "展开") { expanded.toggle() }.buttonStyle(.plain)
                Spacer()
                Link("原帖 ↗", destination: post.sourceURL)
            }.font(.caption).foregroundStyle(.secondary)
            if expanded {
                if post.contextMissing {
                    Text("回复或引用上下文未完整获取").font(.caption).foregroundStyle(.secondary)
                }
                if let row = analysis, row.contentHash == post.contentHash {
                    DisclosureGroup("AI 分析依据") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(row.result.reason_zh)
                            Text("原文证据：" + row.result.evidence_quote)
                            Text(row.model + " · " + row.analyzedAt.formatted(date: .abbreviated, time: .shortened))
                                .foregroundStyle(.secondary)
                        }.textSelection(.enabled).padding(.top, 6)
                    }.font(.caption)
                }
            }
        }
    }
}

private struct AIRequestActions: View {
    @ObservedObject var connections: ConnectionModel
    let hasUnsavedKey: Bool
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let failure = connections.gate.blockingFailure(ai: true, now: context.date)
            let blocked = failure != nil || connections.busyAI || hasUnsavedKey || connections.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            VStack(alignment: .leading, spacing: 10) {
                Button(connections.busyAI ? "请求进行中…" : "测试连接") { Task { await connections.testAI() } }
                    .disabled(blocked)
                if let failure, let retry = failure.retryAt {
                    if failure.issue == .dailyRequestLimit {
                        Text("今日 20 次请求额度已用完").font(.caption)
                    } else {
                        Text("测试与分析共用等待期 · 剩余 \(max(0, Int(ceil(retry.timeIntervalSince(context.date))))) 秒").font(.caption)
                    }
                    Text("可再次请求：" + retry.formatted(date: .abbreviated, time: .standard)).font(.caption).foregroundStyle(.secondary)
                }
                Text("测试发送固定短文本；分类和概率预测发送最近 5 条帖子的正文与时间，概率预测还包含历史间隔背景。Key 只发送至所填地址。三种操作共用每日 20 次额度，间隔至少 60 秒。")
                    .font(.caption).foregroundStyle(.secondary)
                Text(connections.aiStatus).font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Button("分析真实帖子（最多 5 条）") { Task { await connections.analyzeRealPosts() } }
                    .disabled(blocked || connections.busyWeb || connections.snapshot == nil)
                Text(connections.analysisStatus).font(.caption).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
