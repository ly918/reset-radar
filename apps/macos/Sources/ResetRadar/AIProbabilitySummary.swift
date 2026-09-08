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
                Text("Reset 概率预测").font(.headline)
                Spacer()
                Button("预测详情", systemImage: "info.circle") { showingDetails.toggle() }
                    .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("查看预测依据、模型与局限")
                    .popover(isPresented: $showingDetails) { details.padding(20).frame(width: 340) }
            }
            HStack(spacing: 8) {
                ForEach([1, 0, 2], id: \.self) { index in
                    let hours = [12, 24, 48][index]
                    VStack(spacing: 6) {
                        Text("未来 \(hours) 小时").font(.caption).foregroundStyle(.secondary)
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
                Button(connections.busyAI ? "评估中…" : connections.credentialAccessRequired ? "授权并评估" : "重新评估", systemImage: "arrow.clockwise") {
                    Task { await connections.predictProbability() }
                }.buttonStyle(.plain)
                    .disabled(connections.busyAI || connections.busyWeb || connections.snapshot == nil || connections.gate.blockingFailure(ai: true, now: asOf) != nil)
            }.font(.caption)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("下一次 Reset 概率").font(.headline)
            if let result = connections.currentProbability(asOf: asOf) {
                Text(result.reason.replacingOccurrences(of: "as_of", with: "评估时刻"))
                    .textSelection(.enabled)
                Text("\(result.model) · \(result.asOf.formatted(date: .abbreviated, time: .shortened)) 评估")
                    .foregroundStyle(.secondary)
            } else {
                Text(connections.probabilityStatus)
                if connections.probabilityForecast != nil {
                    Text("已有结果已过期或输入已变化，需重新评估。")
                }
            }
            Text("模型根据最近公告与历史背景估计全局 Reset 概率，尚未经过回测校准，不代表个人账号必然重置。")
                .foregroundStyle(.secondary)
            if let plan = connections.announcedPlan(asOf: asOf) {
                Divider()
                AnnouncedPlanSummary(plan: plan, asOf: asOf)
            }
            if let failure = connections.gate.blockingFailure(ai: true, now: asOf), let retry = failure.retryAt {
                Text("可再次请求：" + retry.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
            }
        }.font(.callout).fixedSize(horizontal: false, vertical: true)
    }
}
