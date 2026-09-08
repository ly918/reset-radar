import Foundation
import CryptoKit

public struct PublicWebPost: Codable, Identifiable, Sendable, Equatable {
    public let id: String
    public let text: String
    public let publishedAt: Date
    public let sourceURL: URL
    public let contextMissing: Bool
    public var contentHash: String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
}
public struct PublicWebSnapshot: Codable, Sendable {
    public let handle: String
    public let authorID: String
    public let displayName: String
    public let observedAt: Date
    public let posts: [PublicWebPost]
    public let parserVersion: String
    // A rendered profile is a partial sample, never proof of complete historical coverage.
    public var continuousCoverageVerified: Bool { false }
}

/// Parse literal data records from the observed public HTML; never execute page scripts.
/// Deliberately rejects changed layouts instead of inferring content from arbitrary page text.
public enum PublicWebParser {
    public static let version = "x-public-relay-v1-experimental"
    public static func parse(_ html: String, observedAt: Date) throws -> PublicWebSnapshot {
        guard html.utf8.count <= 2_000_000 else { throw ConnectionFailure(.pageChanged) }
        let pattern = try NSRegularExpression(pattern: #"\{__id:"(?:\\.|[^"\\])*",__typename:"(?:\\.|[^"\\])*""#)
        var records: [String: [String: String]] = [:]
        for match in pattern.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let range = Range(match.range, in: html), let end = balancedEnd(html, from: range.lowerBound) else { continue }
            let fields = splitFields(String(html[range.lowerBound...end]))
            if let id = string(fields["__id"]) { records[id] = (records[id] ?? [:]).merging(fields) { _, new in new } }
        }
        let profiles = records.filter { string($0.value["__typename"]) == "UserCore" && string($0.value["screen_name"]) == "thsottiaux" }
        guard let profile = profiles.first, profiles.count == 1,
              let encodedUser = component(profile.key, suffix: ":core"),
              let userID = decodeID(encodedUser, prefix: "User:"),
              let name = string(profile.value["name"]) else { throw ConnectionFailure(.pageChanged) }
        var posts: [PublicWebPost] = []
        for (key, fields) in records where string(fields["__typename"]) == "TBirdData" {
            guard let encodedTweet = component(key, suffix: ":details"),
                  let id = decodeID(encodedTweet, prefix: "Tweet:"),
                  let core = records["client:\(encodedTweet):core"],
                  let authorRef = reference(core["user_results"]),
                  decodeID(authorRef, prefix: "UserResults:") == userID,
                  let main = records[encodedTweet], string(main["rest_id"]) == id,
                  html.contains("href=\"/thsottiaux/status/\(id)\"") || html.contains("href=\"https://x.com/thsottiaux/status/\(id)\"") else { continue }
            guard let milliseconds = fields["created_at_ms"].flatMap(Double.init), milliseconds.isFinite,
                  milliseconds > 0, milliseconds / 1000 <= observedAt.timeIntervalSince1970 + 300,
                  var text = string(fields["full_text"]), !text.isEmpty else { throw ConnectionFailure(.pageChanged) }
            if let noteRaw = main["note_tweet"], noteRaw != "null" {
                guard let noteRef = reference(noteRaw), let note = records[noteRef],
                      let resultRef = reference(note["note_tweet_results"]), let result = records[resultRef],
                      let fullRef = reference(result["result"]), let full = records[fullRef],
                      let fullText = string(full["text"]), !fullText.isEmpty else { throw ConnectionFailure(.pageChanged) }
                text = fullText
            }
            let contextMissing = ["reply_to_results", "quoted_tweet_results"].contains { main[$0].map { $0 != "null" } ?? false }
            posts.append(PublicWebPost(id: id, text: text, publishedAt: Date(timeIntervalSince1970: milliseconds / 1000),
                                       sourceURL: URL(string: "https://x.com/thsottiaux/status/\(id)")!, contextMissing: contextMissing))
        }
        guard !posts.isEmpty else { throw ConnectionFailure(.noPosts) }
        var seen = Set<String>()
        posts = posts.sorted { $0.publishedAt > $1.publishedAt }.filter { seen.insert($0.id).inserted }
        return PublicWebSnapshot(handle: "thsottiaux", authorID: userID, displayName: name, observedAt: observedAt,
                                 posts: posts, parserVersion: version)
    }
    private static func component(_ key: String, suffix: String) -> String? {
        guard key.hasPrefix("client:"), key.hasSuffix(suffix) else { return nil }
        return String(key.dropFirst(7).dropLast(suffix.count))
    }
    private static func decodeID(_ encoded: String, prefix: String) -> String? {
        guard let data = Data(base64Encoded: encoded), let value = String(data: data, encoding: .utf8), value.hasPrefix(prefix) else { return nil }
        let id = String(value.dropFirst(prefix.count))
        return !id.isEmpty && id.allSatisfy({ $0.isASCII && $0.isNumber }) ? id : nil
    }
    private static func string(_ raw: String?) -> String? {
        guard let raw else { return nil }
        return try? JSONDecoder().decode(String.self, from: Data(raw.utf8))
    }
    private static func reference(_ raw: String?) -> String? {
        guard let raw, let open = raw.firstIndex(of: "{"), let end = balancedEnd(raw, from: open) else { return nil }
        return string(splitFields(String(raw[open...end]))["__ref"])
    }
    private static func balancedEnd(_ text: String, from start: String.Index) -> String.Index? {
        var depth = 0, quoted = false, escaped = false
        var i = start
        while i < text.endIndex {
            let c = text[i]
            if quoted {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { quoted = false }
            } else if c == "\"" { quoted = true }
            else if c == "{" { depth += 1 }
            else if c == "}" { depth -= 1; if depth == 0 { return i } }
            i = text.index(after: i)
        }
        return nil
    }
    private static func splitFields(_ object: String) -> [String: String] {
        let text = object.dropFirst().dropLast()
        var fields: [String: String] = [:], piece = "", quoted = false, escaped = false, depth = 0
        func append(_ piece: String) {
            guard let colon = piece.firstIndex(of: ":") else { return }
            let key = piece[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = piece[piece.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            fields[key] = value
        }
        for c in text {
            if quoted {
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { quoted = false }
            } else if c == "\"" { quoted = true }
            else if c == "{" || c == "[" { depth += 1 }
            else if c == "}" || c == "]" { depth -= 1 }
            else if c == "," && depth == 0 { append(piece); piece = ""; continue }
            piece.append(c)
        }
        append(piece)
        return fields
    }
}
