import SwiftUI
import RadarCore

struct AIProbabilitySummary: View {
    @ObservedObject var connections: ConnectionModel
    let asOf: Date
    @State private var showingDetails = false

    var body: some View {
        let result = connections.currentProbability(asOf: asOf)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L10n.tr("Reset 概率预测")).font(.headline)
                Spacer()
                Button(L10n.tr("预测详情"), systemImage: "info.circle") { showingDetails.toggle() }
                    .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
                    .help(L10n.tr("查看预测依据、模型与局限"))
                    .popover(isPresented: $showingDetails) { details.padding(20).frame(width: 340) }
            }
            HStack(spacing: 8) {
                ForEach([1, 0, 2], id: \.self) { index in
                    let hours = [12, 24, 48][index]
                    VStack(spacing: 6) {
                        Text(L10n.tr("未来 \(hours) 小时")).font(.caption).foregroundStyle(.secondary)
                        Text(result.map { "\(Int(($0.probabilities[index] * 100).rounded()))%" } ?? "—")
                            .font(.system(size: index == 0 ? 34 : 26, weight: .semibold, design: .rounded)).monospacedDigit()
                            .foregroundStyle(index == 0 ? RadarPalette.gold : Color.primary)
                            .frame(height: 42)
                    }.frame(maxWidth: .infinity).frame(height: 84)
                        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 14))
                }
            }
            HStack {
                Text(connections.probabilitySummary(asOf: asOf))
                    .foregroundStyle(connections.credentialAccessRequired && result == nil ? Color.orange : Color.secondary)
                    .lineLimit(2)
                Spacer()
                Button(connections.busyAI ? L10n.tr("评估中…") : connections.credentialAccessRequired ? L10n.tr("授权并评估") : L10n.tr("重新评估"), systemImage: "arrow.clockwise") {
                    Task { await connections.predictProbability() }
                }.buttonStyle(.plain)
                    .disabled(connections.busyAI || connections.busyWeb || connections.snapshot == nil || connections.gate.blockingFailure(ai: true, now: asOf) != nil)
            }.font(.caption)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.tr("下一次 Reset 概率")).font(.headline)
            if let result = connections.currentProbability(asOf: asOf) {
                Text(result.reason.replacingOccurrences(of: "as_of", with: L10n.tr("评估时刻")))
                    .textSelection(.enabled)
                if (result.reasonLanguage ?? "zh-Hans") != L10n.language.rawValue {
                    Text(L10n.tr("已保存的解释保留原语言；再次分析会使用当前语言。")).foregroundStyle(.secondary)
                }
                Text(L10n.tr("\(result.model) · \(result.asOf.localized(date: .abbreviated, time: .shortened)) 评估"))
                    .foregroundStyle(.secondary)
            } else {
                Text(connections.probabilityStatus)
                if connections.probabilityForecast != nil {
                    Text(L10n.tr("已有结果已过期或输入已变化，需重新评估。"))
                }
            }
            Text(L10n.tr("模型根据最近公告与历史背景估计全局 Reset 概率，尚未经过回测校准，不代表个人账号必然重置。"))
                .foregroundStyle(.secondary)
            if let plan = connections.announcedPlan(asOf: asOf) {
                Divider()
                AnnouncedPlanSummary(plan: plan, asOf: asOf)
            }
            if let failure = connections.gate.blockingFailure(ai: true, now: asOf), let retry = failure.retryAt {
                Text(L10n.tr("可再次请求：") + retry.localized(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
            }
        }.font(.callout).fixedSize(horizontal: false, vertical: true)
    }
}
