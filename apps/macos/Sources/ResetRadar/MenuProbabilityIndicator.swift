import SwiftUI
import Combine

struct MenuProbabilityAppearance {
    let probability: Double?
    init(_ probability: Double?) {
        self.probability = probability.flatMap { $0.isFinite && (0...1).contains($0) ? $0 : nil }
    }
    var symbol: String {
        guard let probability else { return "questionmark.circle" }
        switch probability {
        case ..<0.20: return "cloud"
        case ..<0.50: return "cloud.sun"
        case ..<0.80: return "sun.haze"
        default: return "sun.max.fill"
        }
    }
    var value: String { probability.map { "\(Int(($0 * 100).rounded()))%" } ?? "—" }
    var description: String {
        probability == nil ? "未来 12 小时：尚未评估或结果已过期" : "未来 12 小时重置概率 \(value) · AI 估计，未经校准"
    }
}

/// Refresh presentation/expiry only; this timer never fetches data or calls AI.
/// TimelineView inside a MenuBarExtra label can trigger a SwiftUI update loop.
@MainActor final class MenuBarClock: ObservableObject {
    @Published var now = Date()
    private var timer: AnyCancellable?
    init() {
        timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
            .sink { [weak self] date in self?.now = date }
    }
}
