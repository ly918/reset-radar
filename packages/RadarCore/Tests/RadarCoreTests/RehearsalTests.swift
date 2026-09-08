import Foundation
import RadarCore

let testNow = Date(timeIntervalSince1970: 1_788_777_600)
func sampleHistory(_ gaps: [Double] = Array(repeating: 72, count: 30), age: Double = 36,
                   covered: Bool = true, unresolved: Bool = false) -> History {
    History(intervals: gaps, anchor: testNow.addingTimeInterval(-age * 3600),
            currentCovered: covered, unresolved: unresolved, asOf: testNow)
}

func unknownGates() {
    for h in [sampleHistory(Array(repeating: 72, count: 19)), sampleHistory(covered: false),
              sampleHistory(unresolved: true), sampleHistory(age: 72), sampleHistory([.nan])] {
        expect(!ForecastEngine.compute(history: h, asOf: testNow).available)
    }
}
func fixedAnalyticalVectorAndFractionalBin() {
    let result = ForecastEngine.compute(history: sampleHistory(age: 35.5), asOf: testNow)
    // All intervals 72h; before the event bin, n=30,d=0, so the first 24h share the same rate.
    let pool = 1 - exp(-6.0 / 72)
    let lambda = -log1p(-(5 * pool / 35)) / 6
    expect(abs(result.baseline[0] - (1 - exp(-12 * lambda))) < 1e-12)
    expect(abs(result.baseline[1] - (1 - exp(-24 * lambda))) < 1e-12)
    expect(result.tailHours.contains(37))
}
func monotonicityCapsAndMassConservation() {
    for age in stride(from: 0.5, through: 110.5, by: 5) {
        let h = sampleHistory((0..<60).map { Double(24 + $0 * 3) }, age: age)
        let s = ForecastSignal(publishedAt: testNow, observedAt: testNow, confidence: 1)
        let r = ForecastEngine.compute(history: h, asOf: testNow, signals: [s])
        expect(r.available)
        expect(r.probability[0] >= 0 && r.probability[0] <= r.probability[1])
        expect(r.probability[1] <= r.probability[2] && r.probability[2] <= 1)
        for i in 0..<3 { expect(r.probability[i] - r.baseline[i] <= [0.10, 0.15, 0.20][i] + 1e-10) }
        expect(abs(r.hourlyMass.reduce(0, +) - r.probability[2]) < 1e-12)
    }
}
func signalEligibilityDuplicationAndDecay() {
    let h = sampleHistory(age: 60)
    let s = ForecastSignal(publishedAt: testNow, observedAt: testNow)
    let base = ForecastEngine.compute(history: h, asOf: testNow)
    let one = ForecastEngine.compute(history: h, asOf: testNow, signals: [s])
    let many = ForecastEngine.compute(history: h, asOf: testNow, signals: Array(repeating: s, count: 10))
    expect(one.probability == many.probability)
    expect(one.probability[1] > base.probability[1])
    for invalid in [ForecastSignal(publishedAt: testNow.addingTimeInterval(-49 * 3600), observedAt: testNow),
                    ForecastSignal(publishedAt: testNow, observedAt: testNow.addingTimeInterval(1)),
                    ForecastSignal(publishedAt: testNow, observedAt: testNow, confidence: 0.69),
                    ForecastSignal(publishedAt: testNow, observedAt: testNow, eligible: false)] {
        expect(ForecastEngine.compute(history: h, asOf: testNow, signals: [invalid]).probability == base.probability)
    }
    let decayed = ForecastSignal(publishedAt: testNow.addingTimeInterval(-24 * 3600), observedAt: testNow)
    expect(ForecastEngine.compute(history: h, asOf: testNow, signals: [decayed]).probability[1] < one.probability[1])
}
func explicitWindowAndNoClearWindow() {
    let h = sampleHistory(age: 36)
    let s = ForecastSignal(publishedAt: testNow, observedAt: testNow, window: 24...30)
    let r = ForecastEngine.compute(history: h, asOf: testNow, signals: [s])
    expect(r.probability[0] == r.baseline[0] && r.probability[1] == r.baseline[1])
    expect(ForecastEngine.compute(history: h, asOf: testNow, fresh: false).likelyStartHour == nil)
    expect(ForecastEngine.compute(history: sampleHistory(Array(repeating: 1000, count: 30)), asOf: testNow).likelyStartHour == nil)
}
func historyCoverageCreditAndRetraction() {
    let old = ResetEvent(id: "old", occurredAt: testNow.addingTimeInterval(-72 * 3600), observedAt: testNow.addingTimeInterval(-72 * 3600), verifiedAt: testNow.addingTimeInterval(-72 * 3600))
    let recent = ResetEvent(id: "new", occurredAt: testNow.addingTimeInterval(-12 * 3600), observedAt: testNow.addingTimeInterval(-12 * 3600), verifiedAt: testNow.addingTimeInterval(-12 * 3600))
    let credit = ResetEvent(id: "credit", type: .bankedCredit, occurredAt: testNow, observedAt: testNow, verifiedAt: testNow)
    let coverage = [Coverage(start: old.occurredAt!, end: testNow)]
    var ledger = EventLedger(events: [old, recent, credit])
    func history(_ events: [ResetEvent], _ coverage: [Coverage]) -> History {
        History.build(events: events, coverage: coverage, asOf: testNow, scope: "demo-global")
    }
    expect(history(ledger.events, coverage).anchor == recent.occurredAt)
    expect(history(ledger.events, []).intervals.isEmpty)
    ledger.resolve(id: "new", status: .retracted, at: testNow)
    expect(history(ledger.events, coverage).anchor == old.occurredAt)
    expect(ledger.audit.count == 1)
    let late = ResetEvent(id: "late", occurredAt: testNow, observedAt: testNow, verifiedAt: testNow.addingTimeInterval(1))
    expect(history([old, late], coverage).anchor == old.occurredAt)
    let unknown = ResetEvent(id: "unknown", occurredAt: nil, observedAt: testNow, verifiedAt: testNow, precision: .unknown)
    expect(history([old, unknown], coverage).anchor == nil)
}
func candidateCannotAutoConfirmAndDateCannotAnchor() {
    let event = ResetEvent(id: "candidate", status: .candidate, occurredAt: testNow, observedAt: testNow)
    let h = History.build(events: [event], coverage: [], asOf: testNow, scope: "demo-global")
    expect(h.unresolved && h.anchor == nil)
    var ledger = EventLedger(events: [event])
    ledger.resolve(id: event.id, status: .retracted, at: testNow)
    expect(ledger.events[0].status == .candidate)
    ledger.resolve(id: event.id, status: .verified, at: testNow)
    expect(ledger.events[0].status == .verified)
}
func watchCrossingHysteresisCooldownAndRestart() throws {
    var state = WatchState()
    expect(NotificationPolicy.watch(state: &state, p24: 0.8, at: testNow, mode: .demo).action == "suppress")
    _ = NotificationPolicy.watch(state: &state, p24: 0.7, at: testNow, mode: .demo)
    expect(NotificationPolicy.watch(state: &state, p24: 0.8, at: testNow, mode: .demo).action == "preview")
    state = try JSONDecoder().decode(WatchState.self, from: JSONEncoder().encode(state))
    _ = NotificationPolicy.watch(state: &state, p24: 0.7, at: testNow, mode: .demo)
    expect(NotificationPolicy.watch(state: &state, p24: 0.8, at: testNow, mode: .demo).reason == "本周期已提醒")
    _ = NotificationPolicy.watch(state: &state, p24: 0.6, at: testNow, mode: .demo)
    _ = NotificationPolicy.watch(state: &state, p24: 0.6, at: testNow.addingTimeInterval(3 * 3600), mode: .demo)
    expect(NotificationPolicy.watch(state: &state, p24: 0.8, at: testNow.addingTimeInterval(4 * 3600), mode: .demo).reason == "12 小时冷却")
    _ = NotificationPolicy.watch(state: &state, p24: 0.7, at: testNow.addingTimeInterval(12 * 3600), mode: .demo)
    expect(NotificationPolicy.watch(state: &state, p24: 0.8, at: testNow.addingTimeInterval(12 * 3600), mode: .shadow).reason == "影子决策")
}
func quietQueueMissingDataAndReset() {
    var s = WatchState()
    _ = NotificationPolicy.watch(state: &s, p24: 0.7, at: testNow, mode: .demo)
    expect(NotificationPolicy.watch(state: &s, p24: 0.8, at: testNow, mode: .demo, quiet: true).action == "queue")
    expect(NotificationPolicy.watch(state: &s, p24: 0.8, at: testNow, mode: .demo).action == "preview")
    _ = NotificationPolicy.watch(state: &s, p24: nil, at: testNow, mode: .demo)
    expect(NotificationPolicy.watch(state: &s, p24: 0.9, at: testNow, mode: .demo).action == "suppress")
    expect(NotificationPolicy.watch(state: &s, p24: 0.9, at: testNow, mode: .demo, reset: true).action == "suppress")
    expect(NotificationPolicy.watch(state: &s, p24: 0.9, at: testNow, mode: .demo, confirmedInBatch: true).action == "suppress")
}
func quietUsesLocalTimeAndDST() {
    let iso = ISO8601DateFormatter()
    let la = TimeZone(identifier: "America/Los_Angeles")!
    expect(NotificationPolicy.quiet(at: iso.date(from: "2026-03-08T09:30:00Z")!, timeZone: la))
    expect(NotificationPolicy.quiet(at: iso.date(from: "2026-03-08T10:30:00Z")!, timeZone: la))
    expect(!NotificationPolicy.quiet(at: iso.date(from: "2026-03-08T15:00:00Z")!, timeZone: la))
}
func confirmedDedupeImportAndUnknownTime() {
    var handled = Set<String>()
    let e = ResetEvent(id: "new", type: .bankedCredit, occurredAt: testNow, observedAt: testNow, verifiedAt: testNow)
    expect(NotificationPolicy.confirmed(event: e, handled: &handled, at: testNow, mode: .demo).reason == "可领取重置已公布")
    expect(NotificationPolicy.confirmed(event: e, handled: &handled, at: testNow, mode: .demo).reason == "重复事件")
    handled = []
    expect(NotificationPolicy.confirmed(event: e, handled: &handled, at: testNow, mode: .demo, initialImport: true).action == "suppress")
    handled = []
    expect(NotificationPolicy.confirmed(event: e, handled: &handled, at: testNow, mode: .demo, userConfirmed: true).action == "suppress")
    handled = []
    expect(NotificationPolicy.confirmed(event: e, handled: &handled, at: testNow, mode: .demo, quiet: true).action == "suppress")
}

actor FailingPages: TiboDataSource {
    var fail = true
    var calls = 0
    func fetch(since: String?, page: String?) async throws -> PostPage {
        calls += 1
        if page == nil { return PostPage(posts: [Post(id: "10000000000000000001", text: "first")], next: "page2") }
        if fail { fail = false; throw SourceError.network }
        return PostPage(posts: [Post(id: "9999999999999999999", text: "second")], next: nil)
    }
}
func failedPaginationNeverAdvancesWatermarkAndJobsSurvive() async throws {
    let coordinator = SyncCoordinator(source: FailingPages())
    do { try await coordinator.sync(); preconditionFailure("expected page-two failure") } catch SourceError.network { }
    let failed = await coordinator.state
    expect(failed.committed == nil && failed.cursor == "page2" && failed.incomplete)
    expect(await coordinator.posts.count == 1)
    try await coordinator.sync()
    let complete = await coordinator.state
    expect(complete.committed == "10000000000000000001" && !complete.incomplete)
    expect(await coordinator.posts.count == 2)
    expect(await coordinator.analysisJobs.count == 2)
    try await coordinator.sync()
    expect(await coordinator.posts.count == 2)
}
actor InfinitePages: TiboDataSource {
    func fetch(since: String?, page: String?) async throws -> PostPage {
        let next = (Int(page ?? "0") ?? 0) + 1
        return PostPage(posts: [Post(id: String(next), text: "synthetic")], next: String(next))
    }
}
func pageLimitKeepsCursor() async throws {
    let coordinator = SyncCoordinator(source: InfinitePages())
    try await coordinator.sync()
    let state = await coordinator.state
    expect(state.incomplete && state.cursor == "5" && state.committed == nil)
    try await coordinator.sync()
    expect(await coordinator.posts.count == 10)
}
actor SlowPage: TiboDataSource {
    var calls = 0
    func fetch(since: String?, page: String?) async throws -> PostPage {
        calls += 1
        try await Task.sleep(for: .milliseconds(30))
        return PostPage(posts: [], next: nil)
    }
}
func concurrentRefreshCoalesces() async throws {
    let source = SlowPage()
    let tested = SyncCoordinator(source: source)
    try await withThrowingTaskGroup(of: Void.self) { group in
        for _ in 0..<10 { group.addTask { try await tested.sync() } }
        try await group.waitForAll()
    }
    expect(await source.calls == 1)
}

func classificationContractsAndRejection() throws {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { root.deleteLastPathComponent() }
    let data = try Data(contentsOf: root.appendingPathComponent("tests/fixtures/classification-cases.json"))
    let document = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let cases = document["cases"] as! [[String: Any]]
    for item in cases {
        let post = Post(id: item["id"] as! String, text: item["text"] as! String)
        let expected = item["expected"] as! [String: Any]
        let analysis = try JSONDecoder().decode(SignalAnalysis.self, from: JSONSerialization.data(withJSONObject: expected))
        expect(analysis.validate(post: post))
        let signal = analysis.forecastSignal(post: post, publishedAt: testNow, observedAt: testNow, trusted: true)
        if analysis.event_type == "reset_claim" || analysis.context_missing || analysis.target_type != "global_reset" {
            expect(!signal.eligible)
        }
        var bad = expected
        bad["evidence_quote"] = "invented evidence not in source"
        let invalid = try JSONDecoder().decode(SignalAnalysis.self, from: JSONSerialization.data(withJSONObject: bad))
        expect(!invalid.validate(post: post))
    }
    let first = cases[0]
    var badRange = first["expected"] as! [String: Any]
    badRange["relative_window_hours"] = [1, 9]
    let invalidRange = try JSONDecoder().decode(SignalAnalysis.self, from: JSONSerialization.data(withJSONObject: badRange))
    expect(!invalidRange.validate(post: Post(id: first["id"] as! String, text: first["text"] as! String)))
}

func expect(_ result: Bool, file: StaticString = #file, line: UInt = #line) {
    precondition(result, "Rehearsal assertion failed", file: file, line: line)
}
@main struct RehearsalRunner {
    static func main() async throws {
        if CommandLine.arguments.contains("--check-keychain") { try isolatedKeychainRoundTrip(); return }
        if CommandLine.arguments.contains("--probe-web") {
            let client = ConnectionClient()
            let first = try await client.fetchWeb()
            let second = try await client.fetchWeb()
            let firstIDs = Set(first.posts.map(\.id)), secondIDs = Set(second.posts.map(\.id))
            print("LIVE WEB: first=\(first.posts.count), second=\(second.posts.count), overlap=\(firstIDs.intersection(secondIDs).count), authorID=\(first.authorID), completeCoverage=false")
            print("Latest source: \(first.posts[0].sourceURL.absoluteString), publishedAt=\(first.posts[0].publishedAt.ISO8601Format())")
            print("No credentials, cookies or model calls used.")
            return
        }
        let cases: [(String, () throws -> Void)] = [
            ("unknown gates", unknownGates),
            ("analytical vector and fractional bin", fixedAnalyticalVectorAndFractionalBin),
            ("monotonicity, caps and mass conservation", monotonicityCapsAndMassConservation),
            ("signal eligibility, duplication and decay", signalEligibilityDuplicationAndDecay),
            ("explicit window and unclear window", explicitWindowAndNoClearWindow),
            ("coverage, credit and retraction", historyCoverageCreditAndRetraction),
            ("candidate state and precision", candidateCannotAutoConfirmAndDateCannotAnchor),
            ("watch hysteresis, cooldown and serialization", watchCrossingHysteresisCooldownAndRestart),
            ("quiet queue, gaps and reset", quietQueueMissingDataAndReset),
            ("timezone and DST", quietUsesLocalTimeAndDST),
            ("confirmed deduplication and import", confirmedDedupeImportAndUnknownTime),
            ("classification evidence and semantic eligibility", classificationContractsAndRejection)
        ]
        for (name, run) in cases { try run(); print("PASS: \(name)") }
        try await failedPaginationNeverAdvancesWatermarkAndJobsSurvive(); print("PASS: pagination failure and recovery")
        try await pageLimitKeepsCursor(); print("PASS: page limit and continuation")
        try await concurrentRefreshCoalesces(); print("PASS: concurrent refresh coalescing")
        try webParserContracts(); print("PASS: public HTML parser, identity, exact text, dates and rejection")
        try webParserLongPostAndContext(); print("PASS: long text resolution and missing context")
        try connectionHTTPAndOriginRules(); print("PASS: HTTP errors, redaction and allowed origins")
        try budgetUTCAndPersistence(); print("PASS: UTC request budget, serialization and cooldown")
        try await openAIResponseValidationAndDataFlow(); print("PASS: Responses request and structured result validation")
        try await anonymousWebRequest(); print("PASS: anonymous web request without cookies or credentials")
        try customEndpointsAndCredentialScopes(); print("PASS: custom URL normalization, local proxy and credential scopes")
        try await customChatRequestAndValidation(); print("PASS: third party Chat Completions requests and rejection")
        try await livePostClassificationDataFlow(); print("PASS: post analysis data flow, source evidence and invalid result rejection")
        try localCooldownIsNotProviderRateLimit(); print("PASS: local wait, daily budget and provider 429 distinguished; expiry and counts")
        try await optionalTimeNormalizationAndStrictEvidence(); print("PASS: optional time normalization, source validation and explicit diagnostics")
        try communityHistoryImportAndPredictionGates(); print("PASS: public archive metadata import and prediction gates")
        try announcedPlanTimezoneAndPriority(); print("PASS: announced plan timezone, publication day, expiry and evidence eligibility")
        try await directProbabilityDataAndValidation(); print("PASS: direct model probability unchanged, source validation, horizons and cache invalidation")
        print("ALL 29 CHECK GROUPS PASSED; synthetic API inputs and public history metadata snapshot")
    }
}
