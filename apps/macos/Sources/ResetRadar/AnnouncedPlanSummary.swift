import SwiftUI
import RadarCore

struct AnnouncedPlanSummary: View {
    let plan: AnnouncedResetPlan
    let asOf: Date
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(plan.status(asOf: asOf), systemImage: "calendar.badge.clock").font(.headline)
            if plan.within(hours: 24, asOf: asOf) {
                Text("未来 24 小时：已有明确计划").font(.title3.bold())
            }
            Text("原文时间：" + plan.expression).font(.subheadline)
            Text("按原文时区：" + plan.scheduledAt.formatted(date: .abbreviated, time: .shortened) + "（本地时间）")
                .font(.subheadline.bold())
            if let alternative = plan.alternativeScheduledAt {
                Text("若 PST 泛指洛杉矶夏令时：" + alternative.formatted(date: .abbreviated, time: .shortened) + "。保留这 1 小时时区歧义。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(plan.scope).font(.caption)
            Text("AI 已识别明确计划；公告兑现率尚未校准。计划不等于已执行，到点后需核验。")
                .font(.caption).foregroundStyle(.secondary)
            Link("查看公告原帖 ↗", destination: plan.sourceURL).font(.caption)
        }.fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }
}
