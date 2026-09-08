import SwiftUI
import Foundation

/// A message keeps its key and arguments so an in-flight request's status can
/// change language without rerunning that request or translating source posts.
struct LocalizedMessage: ExpressibleByStringLiteral, ExpressibleByStringInterpolation, CustomStringConvertible, Equatable {
    indirect enum Argument: Equatable { case value(String), message(LocalizedMessage), date(Date) }
    let key: String
    var arguments: [Argument] = []
    init(stringLiteral value: String) { key = value }
    init(key: String) { self.key = key }
    init(stringInterpolation: StringInterpolation) {
        key = stringInterpolation.key; arguments = stringInterpolation.arguments
    }
    struct StringInterpolation: StringInterpolationProtocol {
        var key = ""
        var arguments: [Argument] = []
        init(literalCapacity: Int, interpolationCount: Int) {}
        mutating func appendLiteral(_ value: String) { key += value }
        mutating func appendInterpolation<T>(_ value: T) { key += "%@"; arguments.append(.value(String(describing: value))) }
        mutating func appendInterpolation(_ value: Date) { key += "%@"; arguments.append(.date(value)) }
        mutating func appendInterpolation(_ value: LocalizedMessage) { key += "%@"; arguments.append(.message(value)) }
    }
    var description: String { rendered(in: L10n.language) }
    func rendered(in language: AppLanguage) -> String {
        let parts = L10n.key(key, language: language).components(separatedBy: "%@")
        guard parts.count == arguments.count + 1 else { return L10n.key(key, language: language) }
        return arguments.enumerated().reduce(parts[0]) { result, item in
            let value: String
            switch item.element { case .value(let raw): value = raw; case .message(let message): value = message.rendered(in: language); case .date(let date): value = date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Locale(identifier: language.rawValue))) }
            return result + value + parts[item.offset + 1]
        }
    }
    static func + (lhs: Self, rhs: Self) -> Self { "\(lhs)\(rhs)" }
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en", simplifiedChinese = "zh-Hans"
    var id: String { rawValue }
    var name: String { self == .english ? "English" : "简体中文" }
}

enum L10n {
    static let preferenceKey = "app.language"
    static var language: AppLanguage {
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--preview-language"), ProcessInfo.processInfo.arguments.count > index + 1,
           let value = AppLanguage(rawValue: ProcessInfo.processInfo.arguments[index + 1]) { return value }
        return AppLanguage(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "") ?? .english
    }
    static var locale: Locale { Locale(identifier: language.rawValue) }
    static let resources: Bundle = {
        if Bundle.main.bundleURL.pathExtension == "app" {
            guard let url = Bundle.main.url(forResource: "ResetRadar_ResetRadar", withExtension: "bundle"), let bundle = Bundle(url: url) else {
                preconditionFailure("Missing packaged localization resources")
            }
            return bundle
        }
        return Bundle.module
    }()
    static func bundle(for language: AppLanguage) -> Bundle {
        guard let path = resources.path(forResource: language.rawValue, ofType: "lproj"), let bundle = Bundle(path: path) else { return resources }
        return bundle
    }
    static func key(_ key: String, language: AppLanguage = L10n.language) -> String {
        bundle(for: language).localizedString(forKey: key, value: key, table: "Localizable")
    }
    static func tr(_ message: LocalizedMessage) -> String { message.description }
}

@MainActor final class LanguageSettings: ObservableObject {
    static let shared = LanguageSettings(initialLanguage: L10n.language)
    private let defaults: UserDefaults
    @Published var language: AppLanguage {
        didSet { defaults.set(language.rawValue, forKey: L10n.preferenceKey) }
    }
    init(defaults: UserDefaults = .standard, initialLanguage: AppLanguage? = nil) {
        self.defaults = defaults
        language = initialLanguage ?? AppLanguage(rawValue: defaults.string(forKey: L10n.preferenceKey) ?? "") ?? .english
    }
}

struct LocalizedRoot<Content: View>: View {
    @ObservedObject private var settings = LanguageSettings.shared
    let content: Content
    var body: some View {
        content.environment(\.locale, Locale(identifier: settings.language.rawValue)).id(settings.language)
    }
}

extension Text {
    init(_ message: LocalizedMessage) { self.init(verbatim: message.description) }
}
extension Date {
    func localized(date: Date.FormatStyle.DateStyle, time: Date.FormatStyle.TimeStyle) -> String {
        formatted(Date.FormatStyle(date: date, time: time).locale(L10n.locale))
    }
}
