import SwiftUI
import AppKit
import RadarCore

/// Render only this app's own view hierarchy. This does not capture the desktop or automate the UI.
@MainActor enum RenderPreviews {
    static func run(directory: String) throws {
        try ConnectionClient.validateAnalysisResources()
        print("PASS: classifier prompt and schema loaded from packaged resources")
        let destination = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let indicatorValues: [Double?] = [nil, 0.10, 0.35, 0.65, 0.88]
        for value in indicatorValues {
            let name = MenuProbabilityAppearance(value).symbol
            guard NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil else {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
        try render(VStack(alignment: .leading, spacing: 20) {
            Text("菜单栏图标 · 未来 12 小时").font(.headline)
            HStack(spacing: 24) {
                ForEach(indicatorValues.indices, id: \.self) { index in
                    let item = MenuProbabilityAppearance(indicatorValues[index])
                    VStack(spacing: 12) {
                        Image(systemName: item.symbol).font(.system(size: 24)).symbolRenderingMode(.monochrome)
                        Text(item.value).monospacedDigit()
                    }.frame(maxWidth: .infinity)
                }
            }
            Text("仅展示图标分档，不修改真实预测。过期结果显示未知图标。").font(.caption).foregroundStyle(.secondary)
        }.padding(20), to: destination.appendingPathComponent("menu-indicators.png"), width: 500, height: 175, dark: false)
        for (name, scenario, dark) in [
            ("panel-light", DemoScenario.overview, false),
            ("panel-dark", .overview, true),
            ("insufficient", .insufficient, false),
            ("offline", .offline, false),
            ("unconfigured", .unconfigured, false),
            ("calculated", .calculated, false),
            ("candidate", .candidate, false),
            ("empty", .empty, false)
        ] {
            let model = DemoModel(); model.scenario = scenario
            let view = RadarPanel(model: model).environment(\.colorScheme, dark ? .dark : .light)
            try render(view, to: destination.appendingPathComponent(name + ".png"), width: 380, height: 640, dark: dark)
        }
        try render(RadarSettings(model: DemoModel(), connections: ConnectionModel(preview: true)), to: destination.appendingPathComponent("settings.png"), width: 660, height: 780, dark: false)
        let cooldown = ConnectionModel(preview: true)
        try cooldown.gate.reserve(ai: true, now: Date())
        try render(RadarSettings(model: DemoModel(), connections: cooldown), to: destination.appendingPathComponent("settings-cooldown.png"), width: 660, height: 780, dark: false)
        let cache = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ResetRadar/Shadow/web-preview.json")
        if let data = try? Data(contentsOf: cache), let snapshot = try? JSONDecoder().decode(PublicWebSnapshot.self, from: data) {
            let connections = ConnectionModel(preview: true)
            let analysisFile = cache.deletingLastPathComponent().appendingPathComponent("post-analyses.json")
            if let data = try? Data(contentsOf: analysisFile), let rows = try? JSONDecoder().decode([LivePostAnalysis].self, from: data) {
                connections.analyses = Dictionary(rows.map { ($0.result.post_id, $0) }, uniquingKeysWith: { _, new in new })
                if let row = rows.first {
                    connections.modelID = row.model; connections.baseURL = row.baseURL
                    connections.api = APIProtocol(rawValue: row.api) ?? .responses
                }
            }
            connections.snapshot = snapshot; connections.webStatus = "真实公开网页缓存 · " + snapshot.observedAt.ISO8601Format()
            if let data = try? Data(contentsOf: cache.deletingLastPathComponent().appendingPathComponent("ai-probability.json")),
               let value = try? JSONDecoder().decode(AIProbabilityForecast.self, from: data) {
                connections.probabilityForecast = value
                connections.modelID = value.model; connections.baseURL = value.baseURL
                connections.api = APIProtocol(rawValue: value.api) ?? .responses
            }
            try render(WebFeedView(connections: connections), to: destination.appendingPathComponent("real-posts.png"), width: 380, height: 640, dark: false)
            try render(WebFeedView(connections: connections), to: destination.appendingPathComponent("real-posts-dark.png"), width: 380, height: 640, dark: true)
        }
        let historyModel = ConnectionModel(preview: true)
        try render(CommunityHistoryView(connections: historyModel), to: destination.appendingPathComponent("history.png"), width: 540, height: 680, dark: false)
        try render(RadarSettings(model: DemoModel(), connections: historyModel).environment(\.colorScheme, .dark), to: destination.appendingPathComponent("settings-dark.png"), width: 660, height: 780, dark: true)
        try render(OnboardingView(), to: destination.appendingPathComponent("onboarding.png"), width: 500, height: 400, dark: false)
    }
    private static func render<V: View>(_ view: V, to url: URL, width: Int, height: Int, dark: Bool) throws {
        let host = NSHostingView(rootView: view
            .environment(\.colorScheme, dark ? .dark : .light)
            .background(dark ? Color(nsColor: .init(white: 0.12, alpha: 1)) : Color.white))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.appearance = host.appearance
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        defer { window.orderOut(nil) }
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url)
        print("RENDERED \(url.lastPathComponent)")
    }
}
