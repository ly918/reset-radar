import SwiftUI
import RadarCore

struct AnnouncedPlanSummary: View {
    let plan: AnnouncedResetPlan
    let asOf: Date
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L10n.key(plan.status(asOf: asOf)), systemImage: "calendar.badge.clock").font(.headline)
            if plan.within(hours: 24, asOf: asOf) {
                Text(L10n.tr("未来 24 小时：已有明确计划")).font(.title3.bold())
            }
            Text(L10n.tr("原文时间：") + plan.expression).font(.subheadline)
            Text(L10n.tr("按原文时区：") + plan.scheduledAt.localized(date: .abbreviated, time: .shortened) + L10n.tr("（本地时间）"))
                .font(.subheadline.bold())
            if let alternative = plan.alternativeScheduledAt {
                Text(L10n.tr("若 PST 泛指洛杉矶夏令时：") + alternative.localized(date: .abbreviated, time: .shortened) + L10n.tr("。保留这 1 小时时区歧义。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(L10n.key(plan.scope)).font(.caption)
            Text(L10n.tr("AI 已识别明确计划；公告兑现率尚未校准。计划不等于已执行，到点后需核验。"))
                .font(.caption).foregroundStyle(.secondary)
            Link(L10n.tr("查看公告原帖 ↗"), destination: plan.sourceURL).font(.caption)
        }.fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }
}
