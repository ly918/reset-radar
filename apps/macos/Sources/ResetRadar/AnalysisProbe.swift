import Foundation
import RadarCore

/// Explicit local diagnostic invocation only. Never prints headers or raw model content.
struct AnalysisProbeTransport: ConnectionTransport {
    func send(_ request: URLRequest) async throws -> HTTPResult {
        let result = try await OfficialTransport(selectedURL: request.url).send(request)
        print("DIAGNOSTIC HTTP \(result.status)")
        let json = (try? JSONSerialization.jsonObject(with: result.body)) as? [String: Any]
        if let error = json?["error"] as? [String: Any] {
            let text = (error["message"] as? String ?? "").lowercased()
            // Whitelisted markers diagnose schema/parameter compatibility without server text or keys.
            let markers = ["schema", "minitems", "maxitems", "minimum", "maximum", "minlength", "enum",
                           "required", "additionalproperties", "type", "strict", "max_tokens", "max_output_tokens",
                           "response_format", "text.format", "unsupported", "invalid", "array", "object", "string"]
            print("DIAGNOSTIC error markers: " + markers.filter { text.contains($0) }.joined(separator: ","))
        }
        if let output = json?["output"] as? [[String: Any]] {
            print("DIAGNOSTIC output items: \(output.count); completed=\(json?["status"] as? String == "completed")")
            let texts = output.flatMap { $0["content"] as? [[String: Any]] ?? [] }
                .filter { $0["type"] as? String == "output_text" }.compactMap { $0["text"] as? String }
            if let text = texts.first, let data = text.data(using: .utf8),
               let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                print("DIAGNOSTIC results array exists=\(object["results"] is [[String: Any]])")
                if let rows = object["results"] as? [[String: Any]] {
                    for (i, row) in rows.enumerated() {
                        print("DIAGNOSTIC row \(i + 1) timeNull=\(row["time_expression"] is NSNull) timeEmpty=\((row["time_expression"] as? String)?.isEmpty ?? false)")
                    }
                }
            }
        }
        return result
    }
}
