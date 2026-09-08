import Foundation

public struct SignalAnalysis: Codable, Sendable {
    public let post_id: String
    public let event_type: String
    public let target_type: String
    public let signal_strength: String
    public let temporal_status: String
    public let classification_confidence: Double
    public let evidence_quote: String
    public let time_expression: String?
    public let relative_window_hours: [Double]?
    public let context_missing: Bool
    public let reason_zh: String
    public func validate(post: Post) -> Bool {
        guard post_id == post.id,
              ["unrelated", "signal", "planned_reset", "reset_claim", "banked_credit", "targeted_compensation", "unknown"].contains(event_type),
              ["global_reset", "banked_credit", "targeted_compensation", "unknown"].contains(target_type),
              ["none", "weak", "moderate", "strong"].contains(signal_strength),
              ["past", "present", "future", "ambiguous"].contains(temporal_status),
              classification_confidence.isFinite, (0...1).contains(classification_confidence),
              !evidence_quote.isEmpty, post.text.contains(evidence_quote) else { return false }
        if let w = relative_window_hours {
            guard w.count == 2, w.allSatisfy({ $0.isFinite && $0 >= 0 }), w[0] <= w[1],
                  let expression = time_expression, post.text.contains(expression),
                  expression.range(of: #"\d+\s*[–-]\s*\d+\s+hours?"#, options: .regularExpression) != nil else { return false }
            // Only accept the explicit numeric range that actually occurs in the source.
            let numbers = expression.components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap(Double.init)
            guard numbers == w else { return false }
        }
        return true
    }
    public func forecastSignal(post: Post, publishedAt: Date, observedAt: Date, trusted: Bool) -> ForecastSignal {
        let weights = ["none": 0.0, "weak": 0.10, "moderate": 0.35, "strong": 0.70]
        let valid = trusted && validate(post: post) && !context_missing && target_type == "global_reset" &&
            temporal_status == "future" && ["signal", "planned_reset"].contains(event_type)
        let w = relative_window_hours
        return ForecastSignal(publishedAt: publishedAt, observedAt: observedAt,
                              weight: weights[signal_strength] ?? 0, confidence: classification_confidence,
                              eligible: valid, window: valid && w?.count == 2 ? w![0]...w![1] : nil)
    }
}
public protocol SignalClassifier: Sendable { func classify(_ posts: [Post]) async throws -> [SignalAnalysis] }
public protocol CredentialStore: Sendable {
    func save(_ value: String, service: String) throws
    func read(service: String) throws -> String?
    func delete(service: String) throws
}
