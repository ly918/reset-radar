import Foundation
import CryptoKit

public enum APIProtocol: String, CaseIterable, Sendable {
    case responses, chatCompletions
    public var label: String { self == .responses ? "Responses · JSON Schema" : "Chat Completions · JSON" }
    public var path: String { self == .responses ? "responses" : "chat/completions" }
}

/// A user-selected API base, with no embedded credentials or query parameters.
public struct APIEndpoint: Sendable, Equatable {
    public static let defaultURL = "https://api.openai.com/v1"
    public let baseURL: URL
    public init(_ input: String) throws {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, !raw.contains(where: { $0.isWhitespace || $0.isNewline }),
              !raw.contains("\\"), !raw.contains("%"),
              var parts = URLComponents(string: raw), let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.port.map({ (1...65535).contains($0) }) ?? true else { throw ConnectionFailure(.unsafeURL) }
        parts.scheme = parts.scheme?.lowercased(); parts.host = host.lowercased()
        let loopback = ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host.lowercased())
        guard parts.scheme == "https" || (parts.scheme == "http" && loopback),
              !parts.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw ConnectionFailure(.unsafeURL)
        }
        if (parts.scheme == "https" && parts.port == 443) || (parts.scheme == "http" && parts.port == 80) { parts.port = nil }
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        for suffix in ["/chat/completions", "/responses"] where parts.path.hasSuffix(suffix) {
            parts.path.removeLast(suffix.count)
        }
        if parts.path.isEmpty { parts.path = "/v1" }
        guard let url = parts.url else { throw ConnectionFailure(.unsafeURL) }
        baseURL = url
    }
    public func requestURL(_ api: APIProtocol) -> URL { baseURL.appendingPathComponent(api.path) }
    public var credentialNamespace: String {
        let prefix = "local.resetradar.credentials.v1"
        // Keep existing official credentials readable; never reuse them for another base URL.
        if baseURL.absoluteString == Self.defaultURL { return prefix }
        return prefix + ".endpoint." + SHA256.hash(data: Data(baseURL.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
