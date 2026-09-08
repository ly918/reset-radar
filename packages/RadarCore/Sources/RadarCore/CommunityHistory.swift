import Foundation

public struct CommunityResetRecord: Codable, Identifiable, Sendable {
    public let id: String
    public let announcedAt: Date
    public let effectiveAt: Date?
    public let type: String
    public let sourceType: String
    public let scope: String
    public let sourceURL: URL
    public let verification: String
    public let timeBasis: String
    public let preview: Bool
    public let crossCheckURL: URL?
    public var isRecordedReset: Bool { type == "global_reset" && scope == "global" && !preview && verification == "community_archive" }
    public var label: String {
        ["global_reset": "社区记录 · 直接 Reset", "banked_credit": "Reset credit", "planned_reset": "重置预告",
         "targeted_compensation": "定向补偿", "unknown": "额度调整 · 类型待核验"][type] ?? "待核验"
    }
}
public struct CommunityResetHistory: Codable, Sendable {
    public let version: String
    public let synthetic: Bool
    public let sourceURL: URL
    public let trackerURL: URL
    public let fetchedAt: Date
    public let sourceUpdatedAt: Date
    public let sourceSHA256: String
    public let continuousCoverageVerified: Bool
    public let independentlyVerified: Bool
    public let excludedLiveRows: Int
    public let events: [CommunityResetRecord]
    public let limitations: [String]
    public static func decode(_ data: Data) throws -> Self {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let date = fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid history timestamp"))
            }
            return date
        }
        let value = try decoder.decode(Self.self, from: data)
        guard !value.synthetic, !value.events.isEmpty, Set(value.events.map(\.id)).count == value.events.count,
              value.events.allSatisfy({ $0.sourceURL.absoluteString == "https://x.com/thsottiaux/status/" + $0.id &&
                  $0.id.allSatisfy(\.isNumber) && !$0.id.isEmpty && $0.announcedAt <= value.fetchedAt &&
                  $0.verification == "community_archive" && $0.timeBasis == "announcement" }) else {
            throw ConnectionFailure(.invalidResponse)
        }
        return value
    }
    public static func bundled() throws -> Self {
        try decode(Data(contentsOf: ConnectionClient.analysisResource("community-reset-history", extension: "json")))
    }
    public func recordedResets(asOf: Date) -> [CommunityResetRecord] {
        guard fetchedAt <= asOf else { return [] }
        return events.filter { $0.isRecordedReset && $0.announcedAt <= asOf && $0.announcedAt >= asOf.addingTimeInterval(-365 * 86400) }
            .sorted { $0.announcedAt < $1.announcedAt }
    }
    /// Rolling elapsed days, based on archived announcement timestamps, not calendar weeks/months.
    public func recordedResetCount(lastDays: Int, asOf: Date) -> Int {
        guard lastDays > 0 else { return 0 }
        let start = asOf.addingTimeInterval(-Double(lastDays) * 86400)
        return recordedResets(asOf: asOf).filter { $0.announcedAt >= start }.count
    }
    /// Announcement gaps are candidates only. Never bridge a preview or uncertain event.
    public func candidateIntervals(asOf: Date) -> [Double] {
        let records = recordedResets(asOf: asOf)
        let barriers = events.filter { ["planned_reset", "unknown"].contains($0.type) }
        return zip(records, records.dropFirst()).compactMap { left, right in
            guard right.announcedAt > left.announcedAt,
                  !barriers.contains(where: { left.announcedAt < $0.announcedAt && $0.announcedAt < right.announcedAt }) else { return nil }
            return right.announcedAt.timeIntervalSince(left.announcedAt) / 3600
        }
    }
    /// Explicitly pass community inputs to the same engine, with the coverage gate closed.
    /// Neither record count nor an announcement timestamp establishes occurrence/coverage.
    public func forecast(asOf: Date, signals: [ForecastSignal] = []) -> Forecast {
        let history = History(intervals: candidateIntervals(asOf: asOf), anchor: recordedResets(asOf: asOf).last?.announcedAt,
                              currentCovered: false, unresolved: false, asOf: asOf)
        return ForecastEngine.compute(history: history, asOf: asOf, signals: signals, fresh: false)
    }
    public static let referenceVersion = "community-announcement-survival-ai-v2"
    public func referenceForecast(asOf: Date, signals: [ForecastSignal] = []) -> Forecast {
        let history = History(intervals: candidateIntervals(asOf: asOf), anchor: recordedResets(asOf: asOf).last?.announcedAt,
                              currentCovered: false, unresolved: false, asOf: asOf)
        return ForecastEngine.communityReference(history: history, asOf: asOf, signals: signals)
    }
}
