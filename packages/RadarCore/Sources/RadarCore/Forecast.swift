import Foundation

public struct ForecastSignal: Sendable {
    public var publishedAt: Date; public var observedAt: Date
    public var weight: Double; public var confidence: Double
    public var eligible: Bool; public var window: ClosedRange<Double>?
    public init(publishedAt: Date, observedAt: Date, weight: Double = 0.7, confidence: Double = 0.9,
                eligible: Bool = true, window: ClosedRange<Double>? = nil) {
        self.publishedAt = publishedAt; self.observedAt = observedAt; self.weight = weight
        self.confidence = confidence; self.eligible = eligible; self.window = window
    }
}
public struct Forecast: Sendable {
    public let baseline: [Double]; public let probability: [Double]
    public let hourlyMass: [Double]; public let tailHours: [Int]
    public let likelyStartHour: Int?; public let alpha: Double; public let reason: String
    public var available: Bool { probability.count == 3 }
}
public enum ForecastEngine {
    public static let version = "survival-6h-v1-rehearsal.1"
    public static func compute(history: History, asOf: Date, signals: [ForecastSignal] = [], fresh: Bool = true) -> Forecast {
        compute(history: history, asOf: asOf, signals: signals, fresh: fresh, communityReference: false)
    }
    /// Exploratory announcement-based estimate. Never implies verified occurrence or coverage.
    public static func communityReference(history: History, asOf: Date, signals: [ForecastSignal] = []) -> Forecast {
        compute(history: history, asOf: asOf, signals: signals, fresh: false, communityReference: true)
    }
    private static func compute(history: History, asOf: Date, signals: [ForecastSignal], fresh: Bool,
                                communityReference: Bool) -> Forecast {
        func unknown(_ reason: String) -> Forecast {
            Forecast(baseline: [], probability: [], hourlyMass: [], tailHours: [], likelyStartHour: nil, alpha: 0, reason: reason)
        }
        guard !history.unresolved else { return unknown("待核验") }
        guard history.intervals.count >= (communityReference ? 5 : 20), history.intervals.allSatisfy({ $0.isFinite && $0 > 0 }),
              let a = history.age, let anchor = history.anchor, anchor <= asOf else { return unknown("数据不足") }
        guard communityReference || history.currentCovered else { return unknown("覆盖存在缺口") }
        let gaps = history.intervals
        guard communityReference || gaps.filter({ $0 > a }).count >= 5 else { return unknown("尾部参考不足") }
        let pool = 1 - exp(-6 / (gaps.reduce(0, +) / Double(gaps.count)))
        func rate(_ age: Double) -> (Double, Bool) {
            let b = floor(age / 6) * 6
            let n = gaps.filter { $0 > b }.count
            let d = gaps.filter { $0 > b && $0 <= b + 6 }.count
            let h = n < 5 ? pool : (Double(d) + 5 * pool) / (Double(n) + 5)
            return (-log1p(-h) / 6, n < 5)
        }
        var integrated: [Double] = [], tail: [Int] = [], strength: [Double] = []
        for j in 0..<48 {
            var cursor = a + Double(j), area = 0.0, extrapolated = false
            let end = cursor + 1
            while cursor < end - 1e-9 {
                let next = min(end, (floor(cursor / 6) + 1) * 6)
                let (lambda, isTail) = rate(cursor)
                area += lambda * (next - cursor); extrapolated = extrapolated || isTail; cursor = next
            }
            integrated.append(area)
            if extrapolated { tail.append(j) }
            // Evaluate each hourly signal at the hour midpoint; explicit windows are relative to publication.
            let offset = Double(j) + 0.5
            let contribution = signals.compactMap { s -> Double? in
                let currentAge = asOf.timeIntervalSince(s.publishedAt) / 3600
                let age = currentAge + offset
                guard s.eligible, s.confidence.isFinite, s.weight.isFinite,
                      s.confidence >= 0.7, s.confidence <= 1, s.weight >= 0, s.weight <= 0.7,
                      s.observedAt <= asOf, s.publishedAt >= anchor, currentAge >= 0, age <= 48,
                      s.window.map({ $0.contains(age) }) ?? true else { return nil }
                return s.weight * s.confidence * pow(0.5, age / 12)
            }.max() ?? 0
            strength.append(contribution)
        }
        func curve(_ alpha: Double) -> ([Double], [Double]) {
            var total = 0.0, p: [Double] = [], masses: [Double] = []
            for j in 0..<48 {
                let before = exp(-total)
                total += integrated[j] * min(2, exp(alpha * strength[j]))
                masses.append(before - exp(-total))
                if [11, 23, 47].contains(j) { p.append(-expm1(-total)) }
            }
            return (p, masses)
        }
        let base = curve(0).0
        func allowed(_ alpha: Double) -> Bool {
            zip(zip(curve(alpha).0, base), [0.10, 0.15, 0.20]).allSatisfy { $0.0.0 - $0.0.1 <= $0.1 + 1e-12 }
        }
        var lo = 0.0, hi = 1.0
        if allowed(1) { lo = 1 } else {
            for _ in 0..<60 { let mid = (lo + hi) / 2; if allowed(mid) { lo = mid } else { hi = mid } }
        }
        let (p, masses) = curve(lo)
        var best = 0, bestMass = -1.0
        for j in 0...42 {
            let m = masses[j..<(j + 6)].reduce(0, +)
            if m > bestMass + 1e-12 { bestMass = m; best = j }
        }
        let show = p[2] >= 0.4 && bestMass >= p[2] * 0.25 && fresh &&
            !tail.contains(where: { (best..<(best + 6)).contains($0) })
        return Forecast(baseline: base, probability: p, hourlyMass: masses, tailHours: tail,
                        likelyStartHour: show ? best : nil, alpha: lo,
                        reason: communityReference ? "社区记录参考 · 未经校准" : gaps.count < 50 ? "实验性估计 · 数据有限" : "实验性估计")
    }
}
