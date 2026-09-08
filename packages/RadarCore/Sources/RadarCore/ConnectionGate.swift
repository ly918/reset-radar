import Foundation

public struct ConnectionGate: Codable, Sendable {
    public var day: Int = -1
    public var aiRequests = 0
    public var webRequests = 0
    public var aiRetryAt: Date?
    public var webRetryAt: Date?
    public init() {}
    public func blockingFailure(ai: Bool, now: Date) -> ConnectionFailure? {
        let today = Int(floor(now.timeIntervalSince1970 / 86400))
        if ai && today <= day && aiRequests >= 20 {
            return ConnectionFailure(.dailyRequestLimit, retryAt: Date(timeIntervalSince1970: Double(day + 1) * 86400))
        }
        if let retry = ai ? aiRetryAt : webRetryAt, retry > now {
            return ConnectionFailure(.requestCooldown, retryAt: retry)
        }
        return nil
    }
    public mutating func reserve(ai: Bool, now: Date) throws {
        let today = Int(floor(now.timeIntervalSince1970 / 86400))
        if today > day { day = today; aiRequests = 0; webRequests = 0 }
        if let failure = blockingFailure(ai: ai, now: now) { throw failure }
        if ai { aiRequests += 1; aiRetryAt = now.addingTimeInterval(60) }
        else { webRequests += 1; webRetryAt = now.addingTimeInterval(60) }
    }
    public mutating func deferRetry(ai: Bool, until: Date) {
        if ai { aiRetryAt = max(aiRetryAt ?? .distantPast, until) }
        else { webRetryAt = max(webRetryAt ?? .distantPast, until) }
    }
}
