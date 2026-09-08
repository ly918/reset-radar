import Foundation
import RadarCore

func directProbabilityDataAndValidation() async throws {
    let posts = try PublicWebParser.parse(syntheticWeb(text: "We will do a global reset. Lands around 6pm PST today."), observedAt: testNow).posts
    func body(_ values: [Double], quote: String = "We will do a global reset.") throws -> String {
        String(data: try JSONSerialization.data(withJSONObject: ["probabilities": values,
            "reason_zh": "Synthetic subjective forecast", "evidence_post_id": "555", "evidence_quote": quote]), encoding: .utf8)!
    }
    let stub = StubConnectionTransport([try chatEnvelope(body([0.80, 0.91, 0.95]))])
    let client = ConnectionClient(transport: stub)
    let value = try await client.forecastProbability(posts: posts, history: nil, plan: nil, asOf: testNow,
        secret: "synthetic-key", model: "synthetic-model", baseURL: "https://provider.example/v1", api: .chatCompletions)
    expect(value.probabilities == [0.80, 0.91, 0.95]) // No multiplier, cap, floor or desired-value override.
    let sent = try JSONSerialization.jsonObject(with: await stub.requests[0].httpBody!) as! [String: Any]
    let messages = sent["messages"] as! [[String: String]]
    expect(messages[1]["content"]!.contains(posts[0].text))
    expect(messages[1]["content"]!.contains(testNow.ISO8601Format()))
    expect(!messages[0]["content"]!.contains(posts[0].text))
    expect(value.matches(posts: posts, now: testNow.addingTimeInterval(3599), model: "synthetic-model",
        baseURL: "https://provider.example/v1", api: .chatCompletions, historyVersion: "unavailable"))
    expect(!value.matches(posts: posts, now: testNow.addingTimeInterval(3600), model: "synthetic-model",
        baseURL: "https://provider.example/v1", api: .chatCompletions, historyVersion: "unavailable"))
    expect(!value.matches(posts: posts, now: testNow.addingTimeInterval(-1), model: "synthetic-model",
        baseURL: "https://provider.example/v1", api: .chatCompletions, historyVersion: "unavailable"))
    expect(!value.matches(posts: posts, now: testNow, model: "changed-model",
        baseURL: "https://provider.example/v1", api: .chatCompletions, historyVersion: "unavailable"))
    let changed = try PublicWebParser.parse(syntheticWeb(text: "changed"), observedAt: testNow).posts
    expect(!value.matches(posts: changed, now: testNow, model: "synthetic-model",
        baseURL: "https://provider.example/v1", api: .chatCompletions, historyVersion: "unavailable"))
    for invalid in [[0.9, 0.2, 0.95], [-0.1, 0.9, 0.99], [0.1, 0.5, 1.1], [0.5, 0.9]] {
        let transport = StubConnectionTransport([try chatEnvelope(body(invalid))])
        do {
            _ = try await ConnectionClient(transport: transport).forecastProbability(posts: posts, history: nil, plan: nil,
                asOf: testNow, secret: "synthetic-key", model: "synthetic-model", baseURL: "https://provider.example/v1", api: .chatCompletions)
            preconditionFailure("invalid probabilities accepted")
        } catch is AnalysisValidationError { }
    }
    let transport = StubConnectionTransport([try chatEnvelope(body([0.2, 0.3, 0.4], quote: "fabricated"))])
    do {
        _ = try await ConnectionClient(transport: transport).forecastProbability(posts: posts, history: nil, plan: nil,
            asOf: testNow, secret: "synthetic-key", model: "synthetic-model", baseURL: "https://provider.example/v1", api: .chatCompletions)
        preconditionFailure("fabricated evidence accepted")
    } catch is AnalysisValidationError { }
}
