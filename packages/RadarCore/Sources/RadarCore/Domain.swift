import Foundation

public protocol RadarClock: Sendable { var now: Date { get } }
public struct FixedClock: RadarClock { public var now: Date; public init(now: Date) { self.now = now } }
public enum RunMode: String, Codable, Sendable { case demo, shadow, live }
public enum EventType: String, Codable, Sendable {
    case globalReset = "global_reset", bankedCredit = "banked_credit"
    case targetedCompensation = "targeted_compensation", plannedReset = "planned_reset", unknown
}
public enum EventStatus: String, Codable, Sendable { case candidate, verified, rejected, retracted }
public enum TimePrecision: String, Codable, Sendable { case exact, interval, date, unknown }
public struct ResetEvent: Codable, Identifiable, Sendable {
    public var id: String
    public var type: EventType
    public var status: EventStatus
    public var occurredAt: Date?
    public var observedAt: Date
    public var verifiedAt: Date?
    public var precision: TimePrecision
    public var scope: String
    public var source: String
    public init(id: String, type: EventType = .globalReset, status: EventStatus = .verified,
                occurredAt: Date?, observedAt: Date, verifiedAt: Date? = nil,
                precision: TimePrecision = .exact, scope: String = "demo-global", source: String = "synthetic") {
        self.id = id; self.type = type; self.status = status; self.occurredAt = occurredAt
        self.observedAt = observedAt; self.verifiedAt = verifiedAt; self.precision = precision
        self.scope = scope; self.source = source
    }
}
public struct Coverage: Codable, Sendable {
    public var start: Date; public var end: Date
    public init(start: Date, end: Date) { self.start = start; self.end = end }
    public func contains(_ start: Date, _ end: Date) -> Bool { self.start <= start && self.end >= end }
}
public struct History: Sendable {
    public var intervals: [Double]; public var anchor: Date?; public var currentCovered: Bool
    public var unresolved: Bool
    public var age: Double?
    public var percentile: Double? {
        guard intervals.count >= 20, let age else { return nil }
        return 100 * Double(intervals.filter { $0 < age }.count) / Double(intervals.count)
    }
    public init(intervals: [Double], anchor: Date?, currentCovered: Bool, unresolved: Bool, asOf: Date) {
        self.intervals = intervals; self.anchor = anchor; self.currentCovered = currentCovered
        self.unresolved = unresolved; self.age = anchor.map { max(0, asOf.timeIntervalSince($0) / 3600) }
    }
    public static func build(events: [ResetEvent], coverage: [Coverage], asOf: Date, scope: String) -> History {
        let observed = events.filter { $0.observedAt <= asOf && $0.scope == scope && $0.type == .globalReset }
        let unresolved = observed.contains { $0.status == .candidate }
        let verified = observed.filter { $0.status == .verified && ($0.verifiedAt.map { $0 <= asOf } ?? false) }
        // Unknown/date-only events interrupt precision; do not bridge across them or retain an older exact anchor.
        let imprecise = verified.filter { $0.precision != .exact || $0.occurredAt == nil }
        let exact = verified.filter {
            $0.precision == .exact && $0.occurredAt != nil && $0.occurredAt! <= asOf &&
            $0.occurredAt! >= asOf.addingTimeInterval(-365 * 86400)
        }.sorted { $0.occurredAt! < $1.occurredAt! }
        var gaps: [Double] = []
        var seen = Set<String>()
        let unique = exact.filter { seen.insert($0.id).inserted }
        for (left, right) in zip(unique, unique.dropFirst()) {
            let a = left.occurredAt!, b = right.occurredAt!
            if b > a && coverage.contains(where: { $0.contains(a, b) }) && imprecise.isEmpty {
                gaps.append(b.timeIntervalSince(a) / 3600)
            }
        }
        let anchor = imprecise.isEmpty ? unique.last?.occurredAt : nil
        return History(intervals: gaps, anchor: anchor,
                       currentCovered: anchor.map { a in coverage.contains { $0.contains(a, asOf) } } ?? false,
                       unresolved: unresolved, asOf: asOf)
    }
}
public struct EventLedger: Sendable {
    public private(set) var events: [ResetEvent]
    public private(set) var audit: [String] = []
    public init(events: [ResetEvent]) { self.events = events }
    public mutating func resolve(id: String, status: EventStatus, at: Date) {
        guard let i = events.firstIndex(where: { $0.id == id }) else { return }
        let old = events[i].status
        guard (old == .candidate && [.verified, .rejected].contains(status)) ||
              (old == .verified && status == .retracted) else { return }
        events[i].status = status
        if status == .verified { events[i].verifiedAt = at }
        audit.append("\(id):\(old.rawValue)->\(status.rawValue)@\(at.timeIntervalSince1970)")
    }
}
