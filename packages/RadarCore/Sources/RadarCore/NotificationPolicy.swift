import Foundation

public struct WatchState: Codable, Sendable {
    public var previous: Double?
    public var armed = true
    public var belowSince: Date?
    public var lastWatch: Date?
    public var pending = false
    public init() {}
}
public struct NotificationDecision: Equatable, Sendable {
    public let action: String; public let reason: String
    public init(_ action: String, _ reason: String) { self.action = action; self.reason = reason }
}
public enum NotificationPolicy {
    public static func quiet(at: Date, timeZone: TimeZone) -> Bool {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        let hour = calendar.component(.hour, from: at)
        return hour >= 23 || hour < 8
    }
    public static func watch(state: inout WatchState, p24: Double?, at: Date, mode: RunMode,
                             eligible: Bool = true, quiet: Bool = false, reset: Bool = false,
                             confirmedInBatch: Bool = false, threshold: Double = 0.75) -> NotificationDecision {
        if reset || confirmedInBatch {
            state.previous = p24; state.belowSince = nil; state.pending = false
            state.armed = true
            return NotificationDecision("suppress", "建立状态")
        }
        guard eligible, let p = p24, p.isFinite, (0...1).contains(p) else {
            state.previous = nil; state.belowSince = nil; state.pending = false
            return NotificationDecision("suppress", "数据不可用或降级")
        }
        let previous = state.previous
        state.previous = p
        if p < threshold - 0.10 {
            if state.belowSince == nil { state.belowSince = at }
            if at.timeIntervalSince(state.belowSince!) >= 3 * 3600 { state.armed = true }
        } else { state.belowSince = nil }
        if p < threshold { state.pending = false }
        guard let previous else { return NotificationDecision("suppress", "首份有效预测") }
        let crossed = previous < threshold && p >= threshold
        guard (crossed || state.pending), p >= threshold else { return NotificationDecision("suppress", "未越线") }
        guard state.armed else { state.pending = false; return NotificationDecision("suppress", "本周期已提醒") }
        guard state.lastWatch.map({ at.timeIntervalSince($0) >= 12 * 3600 }) ?? true else {
            state.pending = false; return NotificationDecision("suppress", "12 小时冷却")
        }
        if quiet { state.pending = true; return NotificationDecision("queue", "夜间静默") }
        state.pending = false; state.armed = false; state.lastWatch = at
        return NotificationDecision(mode == .live ? "send" : "preview", mode == .shadow ? "影子决策" : mode == .demo ? "演示预览" : "越线")
    }
    public static func confirmed(event: ResetEvent, handled: inout Set<String>, at: Date,
                                 mode: RunMode, quiet: Bool = false, initialImport: Bool = false,
                                 userConfirmed: Bool = false) -> NotificationDecision {
        let key = event.id + ":" + event.type.rawValue
        guard event.status == .verified, [.globalReset, .bankedCredit, .targetedCompensation].contains(event.type),
              let verified = event.verifiedAt, verified <= at else { return NotificationDecision("suppress", "未核验") }
        guard handled.insert(key).inserted else { return NotificationDecision("suppress", "重复事件") }
        guard !initialImport else { return NotificationDecision("suppress", "首次历史导入") }
        guard !userConfirmed else { return NotificationDecision("suppress", "当前界面已反馈") }
        guard event.precision == .exact, let occurred = event.occurredAt,
              (0...6 * 3600).contains(at.timeIntervalSince(occurred)) else { return NotificationDecision("suppress", "旧事件或时间未知") }
        guard !quiet else { return NotificationDecision("suppress", "夜间静默，不补发") }
        return NotificationDecision(mode == .live ? "send" : "preview", event.type == .bankedCredit ? "可领取重置已公布" : "确认事件")
    }
}
public protocol NotificationSink: Sendable { func submit(_ decision: NotificationDecision) async }
public actor PreviewNotificationSink: NotificationSink {
    public private(set) var decisions: [NotificationDecision] = []
    public init() {}
    public func submit(_ decision: NotificationDecision) { decisions.append(decision) }
}
