import Foundation
import RadarCore

func announcedPlanTimezoneAndPriority() throws {
    func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    let published = date("2026-09-07T19:24:57Z")
    let now = date("2026-09-07T23:30:00Z")
    func plan(_ expression: String = "6pm PST today", publishedAt: Date = published, asOf: Date = now,
              type: String = "planned_reset", confidence: Double = 0.99, missing: Bool = false,
              hashMatches: Bool = true, quoteMatches: Bool = true) throws -> AnnouncedResetPlan? {
        let source = "We will do a global reset of the usage for all paid subscriptions. Lands around \(expression)."
        let post = try JSONDecoder().decode(PublicWebPost.self, from: JSONSerialization.data(withJSONObject: [
            "id": "555", "text": source, "publishedAt": publishedAt.timeIntervalSinceReferenceDate,
            "sourceURL": "https://x.com/thsottiaux/status/555", "contextMissing": missing]))
        let row = try JSONDecoder().decode(LivePostAnalysis.self, from: JSONSerialization.data(withJSONObject: [
            "contentHash": hashMatches ? post.contentHash : "changed", "analyzedAt": publishedAt.addingTimeInterval(1).timeIntervalSinceReferenceDate,
            "baseURL": "https://provider.example/v1", "model": "synthetic-model", "api": "responses",
            "promptVersion": LivePostAnalysis.currentPromptVersion,
            "result": ["post_id": "555", "event_type": type, "target_type": "global_reset", "signal_strength": "strong",
                "temporal_status": "future", "classification_confidence": confidence,
                "evidence_quote": quoteMatches ? "We will do a global reset" : "fabricated", "time_expression": expression,
                "relative_window_hours": NSNull(), "context_missing": missing, "reason_zh": "Synthetic plan test"]
        ]))
        return AnnouncedResetPlan.from(post: post, analysis: row, asOf: asOf)
    }
    let summer = try plan()!
    expect(summer.scheduledAt == date("2026-09-08T02:00:00Z"))
    expect(summer.alternativeScheduledAt == date("2026-09-08T01:00:00Z"))
    expect(summer.timezoneAmbiguous && summer.within(hours: 24, asOf: now))
    expect(!summer.within(hours: 1, asOf: now))
    expect(summer.status(asOf: date("2026-09-08T01:30:00Z")) == "已到公告时间 · 待确认执行")
    expect(summer.status(asOf: date("2026-09-08T02:01:00Z")) == "公告时间已过 · 待确认执行")
    expect(!summer.within(hours: 24, asOf: date("2026-09-08T02:01:00Z")))
    let tomorrow = try plan("6pm PST tomorrow")!
    expect(tomorrow.scheduledAt == date("2026-09-09T02:00:00Z"))
    expect(!tomorrow.within(hours: 24, asOf: now))
    expect(try plan("6pm PDT today")!.scheduledAt == date("2026-09-08T01:00:00Z"))
    expect(try plan("6pm PT today")!.scheduledAt == date("2026-09-08T01:00:00Z"))
    let winter = try plan(publishedAt: date("2026-01-05T18:00:00Z"), asOf: date("2026-01-05T19:00:00Z"))!
    expect(winter.scheduledAt == date("2026-01-06T02:00:00Z") && winter.alternativeScheduledAt == nil)
    expect(try plan("tonight") == nil)
    expect(try plan("6pm today") == nil)
    expect(try plan("19pm PST today") == nil)
    expect(try plan(type: "banked_credit") == nil)
    expect(try plan(type: "signal") == nil)
    expect(try plan(confidence: 0.7) == nil)
    expect(try plan(missing: true) == nil)
    expect(try plan(hashMatches: false) == nil)
    expect(try plan(quoteMatches: false) == nil)
    expect(try plan(asOf: published.addingTimeInterval(-1)) == nil)
    expect(try plan(asOf: published.addingTimeInterval(49 * 3600)) == nil)
}
