import Foundation

public enum ConnectionIssue: String, Sendable {
    case invalidInput, unauthorized, forbidden, quota, rateLimited, requestCooldown, dailyRequestLimit, server, network, timedOut,
         unsafeURL, redirect, invalidResponse, refused, incomplete, noPosts, pageChanged, modelUnavailable
}
public struct ConnectionFailure: Error, LocalizedError, Sendable {
    public let issue: ConnectionIssue
    public let status: Int?
    public let retryAt: Date?
    public init(_ issue: ConnectionIssue, status: Int? = nil, retryAt: Date? = nil) {
        self.issue = issue; self.status = status; self.retryAt = retryAt
    }
    public var errorDescription: String? {
        let message: String
        switch issue {
        case .invalidInput: message = "请填写有效的密钥或模型 ID。"
        case .unauthorized: message = "密钥不可用，请检查或更换。"
        case .forbidden: message = "当前账户缺少此接口或模型的访问权限。"
        case .quota: message = "服务额度不足，请到服务平台检查余额与计费。"
        case .rateLimited: message = "服务限流，请在显示的重试时间之后再试。"
        case .requestCooldown: message = "请求仍在等待期，本次未发送到服务。测试与分析共用请求间隔，请等待倒计时结束。"
        case .dailyRequestLimit: message = "已达到本应用每日 20 次 AI 请求上限，本次未发送到服务。额度按 UTC 日期重置。"
        case .server: message = "服务暂时不可用，请稍后重试。"
        case .network: message = "暂时无法连接，请检查网络后重试。"
        case .timedOut: message = "连接超时，请稍后重试。"
        case .unsafeURL, .redirect: message = "请使用 HTTPS Base URL（本机可用 HTTP），不要包含账号、查询参数或重定向。"
        case .invalidResponse: message = "返回内容未通过校验，未标记为连接成功。"
        case .refused: message = "模型拒绝了测试请求，尚未通过结构化输出测试。"
        case .incomplete: message = "模型输出被截断或未完成，尚未通过测试。"
        case .noPosts: message = "页面未提供可校验的公开帖子，可能需要登录或稍后重试。"
        case .pageChanged: message = "页面结构或作者信息无法校验，已停止导入。"
        case .modelUnavailable: message = "当前模型不可用，请检查模型 ID、权限与结构化输出支持。"
        }
        return message + (status.map { "（HTTP \($0)）" } ?? "")
    }
}
public struct HTTPResult: Sendable {
    public var status: Int; public var headers: [String: String]; public var body: Data
    public init(status: Int, headers: [String: String] = [:], body: Data) {
        self.status = status; self.headers = headers; self.body = body
    }
}
public protocol ConnectionTransport: Sendable { func send(_ request: URLRequest) async throws -> HTTPResult }

public final class OfficialTransport: NSObject, ConnectionTransport, URLSessionTaskDelegate, Sendable {
    private let selectedURL: URL?
    public init(selectedURL: URL? = nil) { self.selectedURL = selectedURL; super.init() }
    public static func allowed(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 else { return false }
        return ["x.com", "api.x.com", "api.openai.com"].contains(url.host?.lowercased() ?? "")
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                           completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil) // No credential forwarding, even between official hosts.
    }
    public func send(_ request: URLRequest) async throws -> HTTPResult {
        guard selectedURL.map({ request.url == $0 }) ?? Self.allowed(request.url) else { throw ConnectionFailure(.unsafeURL) }
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse, data.count <= 2_000_000 else { throw ConnectionFailure(.invalidResponse) }
            var headers: [String: String] = [:]
            for name in ["retry-after", "x-rate-limit-reset", "x-rate-limit-remaining"] {
                if let value = response.value(forHTTPHeaderField: name) { headers[name] = value }
            }
            return HTTPResult(status: response.statusCode, headers: headers, body: data)
        } catch let failure as ConnectionFailure { throw failure }
        catch let error as URLError { throw ConnectionFailure(error.code == .timedOut ? .timedOut : .network) }
        catch { throw ConnectionFailure(.network) }
    }
}

public struct OpenAITestResult: Sendable {
    public let model: String; public let inputTokens: Int?; public let outputTokens: Int?
}
public struct ConnectionClient: Sendable {
    private let transport: (any ConnectionTransport)?
    public init(transport: (any ConnectionTransport)? = nil) { self.transport = transport }
    public static func validate(_ response: HTTPResult, now: Date = Date()) throws {
        if (200..<300).contains(response.status) { return }
        var retryAt: Date?
        if let seconds = response.headers["retry-after"].flatMap(Double.init), seconds.isFinite, seconds >= 0 {
            retryAt = now.addingTimeInterval(seconds)
        } else if let date = response.headers["retry-after"] {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            retryAt = formatter.date(from: date)
        }
        if let reset = response.headers["x-rate-limit-reset"].flatMap(Double.init), reset.isFinite {
            retryAt = max(retryAt ?? now, Date(timeIntervalSince1970: reset))
        }
        let json = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any]
        let error = json?["error"] as? [String: Any]
        let code = error?["code"] as? String ?? ""
        let title = json?["title"] as? String ?? ""
        let issue: ConnectionIssue
        if ["insufficient_quota", "billing_hard_limit_reached"].contains(code) || title == "CreditsDepleted" || response.status == 402 { issue = .quota }
        else if code == "model_not_found" { issue = .modelUnavailable }
        else {
            switch response.status {
            case 300..<400: issue = .redirect
            case 401: issue = .unauthorized
            case 403: issue = .forbidden
            case 429: issue = .rateLimited
            case 500...599: issue = .server
            default: issue = .invalidResponse
            }
        }
        if issue == .rateLimited { retryAt = max(retryAt ?? now.addingTimeInterval(15 * 60), now.addingTimeInterval(60)) }
        throw ConnectionFailure(issue, status: response.status, retryAt: retryAt)
    }
    public func fetchWeb() async throws -> PublicWebSnapshot {
        var request = URLRequest(url: URL(string: "https://x.com/thsottiaux")!)
        request.timeoutInterval = 30
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        let response = try await (transport ?? OfficialTransport()).send(request)
        try Self.validate(response)
        guard let html = String(data: response.body, encoding: .utf8) else { throw ConnectionFailure(.invalidResponse) }
        return try PublicWebParser.parse(html, observedAt: Date())
    }
    public func testOpenAI(secret: String, model: String, baseURL: String = APIEndpoint.defaultURL,
                           api: APIProtocol = .responses) async throws -> OpenAITestResult {
        let schema: [String: Any] = ["type": "object", "properties": ["ok": ["type": "boolean"]],
                                     "required": ["ok"], "additionalProperties": false]
        let result = try await requestJSON(secret: secret, model: model, baseURL: baseURL, api: api,
            instructions: "Connection test only. Return a JSON object with ok set to true.",
            input: "Run the connection test.", schema: schema, name: "connection_test", maxTokens: 512)
        guard let object = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any],
              object.count == 1, let ok = object["ok"] as? NSNumber,
              CFGetTypeID(ok) == CFBooleanGetTypeID(), ok.boolValue else { throw ConnectionFailure(.invalidResponse) }
        return OpenAITestResult(model: model, inputTokens: result.inputTokens, outputTokens: result.outputTokens)
    }
    func requestJSON(secret: String, model: String, baseURL: String, api: APIProtocol,
                     instructions: String, input: String, schema: [String: Any], name: String,
                     maxTokens: Int) async throws -> (data: Data, inputTokens: Int?, outputTokens: Int?) {
        guard !secret.isEmpty, secret.count <= 8192, !secret.contains(where: \.isWhitespace),
              !model.isEmpty, model.count <= 128, !model.hasPrefix("sk-"),
              model.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.:/".contains($0)) }) else {
            throw ConnectionFailure(.invalidInput)
        }
        let endpoint = try APIEndpoint(baseURL)
        let url = endpoint.requestURL(api)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"; request.timeoutInterval = 60
        request.setValue("Bearer " + secret, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any]
        if api == .responses {
            body = ["model": model, "store": false, "max_output_tokens": maxTokens,
                    "instructions": instructions, "input": input,
                    "text": ["format": ["type": "json_schema", "name": name, "strict": true, "schema": schema]]]
        } else {
            let schemaText = String(data: try JSONSerialization.data(withJSONObject: schema), encoding: .utf8)!
            body = ["model": model, "stream": false, "max_tokens": maxTokens,
                    "messages": [["role": "system", "content": instructions + "\nReturn JSON matching this schema: " + schemaText],
                                 ["role": "user", "content": input]],
                    "response_format": ["type": "json_object"]]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let response = try await (transport ?? OfficialTransport(selectedURL: url)).send(request)
        try Self.validate(response)
        guard let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any] else { throw ConnectionFailure(.invalidResponse) }
        let text: String
        if api == .responses {
            guard json["status"] as? String == "completed" else { throw ConnectionFailure(.incomplete) }
            let output = json["output"] as? [[String: Any]] ?? []
            let content = output.flatMap { $0["content"] as? [[String: Any]] ?? [] }
            if content.contains(where: { $0["type"] as? String == "refusal" }) { throw ConnectionFailure(.refused) }
            let texts = content.filter { $0["type"] as? String == "output_text" }.compactMap { $0["text"] as? String }
            guard texts.count == 1 else { throw ConnectionFailure(.invalidResponse) }
            text = texts[0]
        } else {
            guard let choices = json["choices"] as? [[String: Any]], choices.count == 1,
                  let message = choices[0]["message"] as? [String: Any] else { throw ConnectionFailure(.invalidResponse) }
            if let refusal = message["refusal"] as? String, !refusal.isEmpty { throw ConnectionFailure(.refused) }
            guard choices[0]["finish_reason"] as? String == "stop" else { throw ConnectionFailure(.incomplete) }
            guard let value = message["content"] as? String else { throw ConnectionFailure(.invalidResponse) }
            text = value
        }
        let usage = json["usage"] as? [String: Any]
        return (Data(text.utf8), usage?[api == .responses ? "input_tokens" : "prompt_tokens"] as? Int,
                usage?[api == .responses ? "output_tokens" : "completion_tokens"] as? Int)
    }
}
