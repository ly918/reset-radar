import Foundation

/// A model-classified announcement, not a calibrated probability or an executed reset.
public struct AnnouncedResetPlan: Codable, Sendable, Identifiable {
    public let id: String
    public let sourceURL: URL
    public let publishedAt: Date
    public let expression: String
    public let scheduledAt: Date
    public let alternativeScheduledAt: Date?
    public let timezoneAmbiguous: Bool
    public let scope: String
    public var earliest: Date { min(scheduledAt, alternativeScheduledAt ?? scheduledAt) }
    public var latest: Date { max(scheduledAt, alternativeScheduledAt ?? scheduledAt) }
    public func status(asOf: Date) -> String {
        if asOf > latest { return "公告时间已过 · 待确认执行" }
        if asOf >= earliest { return "已到公告时间 · 待确认执行" }
        return "已公告重置计划"
    }
    public func within(hours: Double, asOf: Date) -> Bool {
        asOf <= latest && latest <= asOf.addingTimeInterval(hours * 3600)
    }
    public static func from(post: PublicWebPost, analysis: LivePostAnalysis, asOf: Date) -> Self? {
        let result = analysis.result
        guard analysis.contentHash == post.contentHash, analysis.promptVersion == LivePostAnalysis.currentPromptVersion,
              analysis.analyzedAt <= asOf, post.publishedAt <= asOf,
              asOf.timeIntervalSince(post.publishedAt) <= 48 * 3600,
              !post.contextMissing, !result.context_missing,
              result.validate(post: Post(id: post.id, text: post.text)),
              result.event_type == "planned_reset", result.target_type == "global_reset",
              result.temporal_status == "future", result.signal_strength == "strong",
              result.classification_confidence >= 0.9,
              let expression = result.time_expression, post.text.contains(expression),
              let times = parse(expression, publishedAt: post.publishedAt) else { return nil }
        return Self(id: post.id, sourceURL: post.sourceURL, publishedAt: post.publishedAt, expression: expression,
                    scheduledAt: times.0, alternativeScheduledAt: times.1, timezoneAmbiguous: times.1 != nil,
                    scope: post.text.localizedCaseInsensitiveContains("all paid subscriptions") ? "所有付费订阅（以原帖为准）" : "适用范围见原帖")
    }
    // Resolve 'today' in the stated source timezone on publication day, never the viewer's day.
    // PST is literal UTC-8. In summer preserve a distinct LA/PT alternative instead of silently changing it.
    static func parse(_ expression: String, publishedAt: Date) -> (Date, Date?)? {
        let pattern = #"^\s*(?:around\s+)?(1[0-2]|[1-9])(?::([0-5][0-9]))?\s*(am|pm)\s*(PST|PDT|PT|UTC|GMT)\s+(today|tomorrow)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: expression, range: NSRange(expression.startIndex..., in: expression)) else { return nil }
        func group(_ index: Int) -> String {
            Range(match.range(at: index), in: expression).map { String(expression[$0]) } ?? ""
        }
        guard let hour12 = Int(group(1)) else { return nil }
        let hour = hour12 % 12 + (group(3).lowercased() == "pm" ? 12 : 0)
        let minute = Int(group(2)) ?? 0
        let zoneName = group(4).uppercased()
        let dayOffset = group(5).lowercased() == "tomorrow" ? 1 : 0
        func date(in zone: TimeZone) -> Date? {
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: publishedAt) else { return nil }
            var parts = calendar.dateComponents([.year, .month, .day], from: day)
            parts.hour = hour; parts.minute = minute; parts.second = 0
            return calendar.date(from: parts)
        }
        let zone: TimeZone
        switch zoneName {
        case "PST": zone = TimeZone(secondsFromGMT: -8 * 3600)!
        case "PDT": zone = TimeZone(secondsFromGMT: -7 * 3600)!
        case "PT": zone = TimeZone(identifier: "America/Los_Angeles")!
        default: zone = TimeZone(secondsFromGMT: 0)!
        }
        guard let primary = date(in: zone) else { return nil }
        let alternative = zoneName == "PST" ? date(in: TimeZone(identifier: "America/Los_Angeles")!) : nil
        return (primary, alternative == primary ? nil : alternative)
    }
}
