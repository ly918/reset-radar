import Foundation

public enum AnalysisLanguage: String, Codable, Sendable {
    case english = "en", simplifiedChinese = "zh-Hans"
    var instruction: String {
        "Write the explanation in reason_zh in " + (self == .english ? "English" : "Simplified Chinese") + ". The field name is retained for compatibility. Keep source evidence and time expressions verbatim in their original language."
    }
}

public struct AnalysisValidationError: Error, LocalizedError, Sendable {
    public let check: String
    public let row: Int?
    public var errorDescription: String? {
        "分析结果未通过校验" + (row.map { "（第 \($0) 条）" } ?? "") + "：" + check + "。连接测试状态不受影响。"
    }
}

public struct LivePostAnalysis: Codable, Sendable {
    public var reasonLanguage: String? = nil
    public let contentHash: String
    public let result: SignalAnalysis
    public let analyzedAt: Date
    public let baseURL: String
    public let model: String
    public let api: String
    public let promptVersion: String?
    public static let currentPromptVersion = "signal-classifier-v1.1-exact-time"
    /// For the explicitly unverified community reference only, not the verified prediction.
    public func referenceSignal(post: PublicWebPost, asOf: Date) -> ForecastSignal? {
        guard contentHash == post.contentHash, result.post_id == post.id, !post.contextMissing,
              promptVersion == Self.currentPromptVersion, analyzedAt <= asOf, post.publishedAt <= asOf,
              asOf.timeIntervalSince(post.publishedAt) <= 48 * 3600 else { return nil }
        let signal = result.forecastSignal(post: Post(id: post.id, text: post.text), publishedAt: post.publishedAt,
                                          observedAt: analyzedAt, trusted: true)
        guard signal.eligible, signal.confidence >= 0.7, signal.weight > 0 else { return nil }
        if let window = signal.window, window.upperBound <= asOf.timeIntervalSince(post.publishedAt) / 3600 { return nil }
        return signal
    }
}

extension ConnectionClient {
    static func analysisResource(_ name: String, extension ext: String) throws -> URL {
        let bundle: Bundle
        if Bundle.main.bundleURL.pathExtension == "app" {
            guard let url = Bundle.main.url(forResource: "RadarCore_RadarCore", withExtension: "bundle"),
                  let packaged = Bundle(url: url) else { throw ConnectionFailure(.invalidResponse) }
            bundle = packaged
        } else { bundle = .module }
        guard let url = bundle.url(forResource: name, withExtension: ext, subdirectory: "Resources") else {
            throw ConnectionFailure(.invalidResponse)
        }
        return url
    }
    public static func validateAnalysisResources() throws {
        _ = try JSONSerialization.jsonObject(with: Data(contentsOf: analysisResource("signal-analysis.schema", extension: "json")))
        let prompt = try String(contentsOf: analysisResource("signal_classifier_v1", extension: "md"), encoding: .utf8)
        guard !prompt.isEmpty else { throw ConnectionFailure(.invalidResponse) }
    }
    public func analyzePosts(_ posts: [PublicWebPost], secret: String, model: String,
                             baseURL: String, api: APIProtocol, reasonLanguage: AnalysisLanguage = .simplifiedChinese) async throws -> [LivePostAnalysis] {
        guard !posts.isEmpty, posts.count <= 5, Set(posts.map(\.id)).count == posts.count,
              posts.reduce(0, { $0 + $1.text.utf8.count }) <= 60_000 else { throw ConnectionFailure(.invalidInput) }
        let schemaURL = try Self.analysisResource("signal-analysis.schema", extension: "json")
        var itemSchema = try JSONSerialization.jsonObject(with: Data(contentsOf: schemaURL)) as! [String: Any]
        itemSchema.removeValue(forKey: "$schema"); itemSchema.removeValue(forKey: "$id")
        if var properties = itemSchema["properties"] as? [String: [String: Any]] {
            for key in properties.keys where properties[key]?["enum"] != nil { properties[key]?["type"] = "string" }
            itemSchema["properties"] = properties
        }
        let schema: [String: Any] = ["type": "object", "properties": ["results": ["type": "array", "items": itemSchema]],
                                     "required": ["results"], "additionalProperties": false]
        let promptURL = try Self.analysisResource("signal_classifier_v1", extension: "md")
        let instructions = try String(contentsOf: promptURL, encoding: .utf8) + "\nReturn {\"results\":[...]} with exactly one result per supplied post. Retain context_missing when the source marks it true." + "\n" + reasonLanguage.instruction
        let data = try JSONSerialization.data(withJSONObject: posts.map { post in
            ["post_id": post.id, "text": post.text, "published_at": post.publishedAt.ISO8601Format(),
             "context_missing": post.contextMissing] as [String: Any]
        })
        let response = try await requestJSON(secret: secret, model: model, baseURL: baseURL, api: api,
            instructions: instructions, input: String(data: data, encoding: .utf8)!, schema: schema,
            name: "post_signals", maxTokens: 4096)
        var results = try Self.validateAnalyses(response.data, posts: posts, baseURL: baseURL, model: model, api: api)
        for index in results.indices { results[index].reasonLanguage = reasonLanguage.rawValue }
        return results
    }
    static func validateAnalyses(_ data: Data, posts: [PublicWebPost], baseURL: String,
                                 model: String, api: APIProtocol) throws -> [LivePostAnalysis] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys) == ["results"], let rows = root["results"] as? [[String: Any]] else {
            throw AnalysisValidationError(check: "缺少 results 数组或顶层字段错误", row: nil)
        }
        guard rows.count == posts.count else { throw AnalysisValidationError(check: "返回帖子数量与输入不一致", row: nil) }
        let required: Set<String> = ["post_id", "event_type", "target_type", "signal_strength", "temporal_status",
            "classification_confidence", "evidence_quote", "time_expression", "relative_window_hours", "context_missing", "reason_zh"]
        var seen = Set<String>()
        var results: [LivePostAnalysis] = []
        let canonical = try APIEndpoint(baseURL).baseURL.absoluteString
        for (index, originalRow) in rows.enumerated() {
            var row = originalRow
            func invalid(_ message: String) -> AnalysisValidationError { AnalysisValidationError(check: message, row: index + 1) }
            guard Set(row.keys) == required else { throw invalid("字段缺失或包含额外字段") }
            // Empty optional time text represents absence, never a forecast window.
            if let expression = row["time_expression"] as? String, expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               row["relative_window_hours"] is NSNull { row["time_expression"] = NSNull() }
            guard let missing = row["context_missing"] as? NSNumber, CFGetTypeID(missing) == CFBooleanGetTypeID(),
                  let confidence = row["classification_confidence"] as? NSNumber, CFGetTypeID(confidence) != CFBooleanGetTypeID(),
                  let result = try? JSONDecoder().decode(SignalAnalysis.self, from: JSONSerialization.data(withJSONObject: row)) else {
                throw invalid("字段类型错误")
            }
            guard let post = posts.first(where: { $0.id == result.post_id }), seen.insert(post.id).inserted else { throw invalid("帖子 ID 不匹配或重复") }
            guard !result.evidence_quote.isEmpty, post.text.contains(result.evidence_quote) else { throw invalid("证据不是原帖的精确连续原文") }
            guard result.validate(post: Post(id: post.id, text: post.text)) else { throw invalid("分类枚举、置信度或数字时间区间不符合约定") }
            guard !post.contextMissing || result.context_missing else { throw invalid("未保留原帖缺上下文标记") }
            guard !result.reason_zh.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw invalid("缺少分析理由") }
            guard result.time_expression.map({ !$0.isEmpty && post.text.contains($0) }) ?? true else { throw invalid("时间表述不在原文中；必须逐字引用或返回 null") }
            results.append(LivePostAnalysis(contentHash: post.contentHash, result: result, analyzedAt: Date(),
                                            baseURL: canonical, model: model, api: api.rawValue, promptVersion: LivePostAnalysis.currentPromptVersion))
        }
        return results
    }
}
