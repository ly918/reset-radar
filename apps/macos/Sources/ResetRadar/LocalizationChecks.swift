import Foundation
import RadarCore

@MainActor enum LocalizationChecks {
    private struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    private static func check(_ condition: Bool, line: Int = #line) throws {
        guard condition else { throw Failure(message: "Localization check failed at line \(line)") }
    }
    static func run() throws {
        let suite = "local.resetradar.localization-tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = LanguageSettings(defaults: defaults)
        try check(settings.language == .english)
        settings.language = .simplifiedChinese
        try check(LanguageSettings(defaults: defaults).language == .simplifiedChinese)
        defaults.set("unsupported", forKey: L10n.preferenceKey)
        try check(LanguageSettings(defaults: defaults).language == .english)
        let message: LocalizedMessage = "正在分析 \(5) 条真实帖子…"
        try check(message.rendered(in: .english) == "Analyzing 5 public posts…")
        try check(message.rendered(in: .simplifiedChinese) == "正在分析 5 条真实帖子…")
        let error = LocalizedMessage(key: ConnectionFailure(.unauthorized).errorDescription!)
        let status: LocalizedMessage = "网页更新未完成：" + error
        try check(status.rendered(in: .english) == "Web update incomplete: The key is invalid. Check or replace it.")
        try check(status.rendered(in: .simplifiedChinese).contains("密钥不可用"))
        let source = "This is source text, not a localization key. 中文原文"
        let evidence: LocalizedMessage = "原文证据：\(source)"
        try check(evidence.rendered(in: .english).hasSuffix(source))
        if Bundle.main.bundleURL.pathExtension == "app" {
            try check(L10n.resources.bundleURL.resolvingSymlinksInPath().path.hasPrefix(Bundle.main.bundleURL.resolvingSymlinksInPath().path + "/Contents/Resources/"))
        }
        for language in AppLanguage.allCases {
            try check(L10n.bundle(for: language).bundleURL.lastPathComponent.lowercased() == language.rawValue.lowercased() + ".lproj")
            let url = L10n.bundle(for: language).url(forResource: "Localizable", withExtension: "strings")!
            let data = try Data(contentsOf: url)
            let rows = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: String]
            try check(rows.count >= 360)
            for (key, value) in rows {
                try check(key.components(separatedBy: "%@").count == value.components(separatedBy: "%@").count)
                try check(L10n.key(key, language: language) == value)
            }
        }
        print("PASS: packaged en/zh-Hans catalogs, English default, saved language, fallback, dynamic messages and unchanged source text")
    }
}
