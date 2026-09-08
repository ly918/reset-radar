import SwiftUI
import RadarCore

/// Compact overview; provenance and the complete archive live in the history window.
struct CompactResetHistory: View {
    let history: CommunityResetHistory?
    let asOf: Date
    let showDetails: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L10n.tr("Reset 历史记录")).font(.headline)
                Spacer()
                Button(L10n.tr("历史详情"), systemImage: "chevron.right", action: showDetails)
                    .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
                    .help(L10n.tr("查看社区归档与数据来源"))
            }
            HStack {
                Text(L10n.tr("最近收录")).foregroundStyle(.secondary)
                Spacer()
                if let latest = history?.recordedResets(asOf: asOf).last {
                    Text(latest.announcedAt.localized(date: .abbreviated, time: .shortened))
                        .fontWeight(.medium).monospacedDigit()
                } else { Text(L10n.tr("暂无记录")).foregroundStyle(.secondary) }
            }.font(.callout)
                .help(L10n.tr("显示已收录的直接 Reset 公告时间，不等于实际到账时间；归档可能不完整。"))
            HStack(spacing: 8) {
                ForEach([7, 14, 30], id: \.self) { days in
                    VStack(spacing: 4) {
                        Text(history.map { L10n.tr("\($0.recordedResetCount(lastDays: days, asOf: asOf)) 次") } ?? "—")
                            .font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
                        Text(days == 7 ? L10n.tr("最近 1 周") : days == 14 ? L10n.tr("最近 2 周") : L10n.tr("最近 1 个月"))
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity)
                }
            }.padding(.top, 2).help(L10n.tr("按公告时间统计近 7 / 14 / 30 天已收录的直接 Reset，排除预告、额度券和定向补偿。"))
        }
    }
}

struct LatestResetSummary: View {
    let history: CommunityResetHistory
    let asOf: Date
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.tr("最近一次 Reset 记录")).font(.headline)
            if let latest = history.recordedResets(asOf: asOf).last {
                Text(latest.announcedAt.localized(date: .abbreviated, time: .shortened))
                    .font(.title3.weight(.semibold)).monospacedDigit()
                HStack {
                    Text(L10n.tr("最近已收录 · 公告时间")).foregroundStyle(.secondary)
                    Spacer()
                    Link(L10n.tr("原始记录 ↗"), destination: latest.sourceURL)
                }.font(.caption2)
            } else {
                Text(L10n.tr("暂无已收录的直接 Reset")).font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct RecentResetCounts: View {
    let history: CommunityResetHistory
    let asOf: Date
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.tr("近期重置次数")).font(.headline)
            HStack(spacing: 8) {
                ForEach([7, 14, 30], id: \.self) { days in
                    VStack(spacing: 6) {
                        Text(days == 7 ? L10n.tr("最近 1 周") : days == 14 ? L10n.tr("最近 2 周") : L10n.tr("最近 1 个月"))
                            .font(.caption).foregroundStyle(.secondary)
                        Text(L10n.tr("\(history.recordedResetCount(lastDays: days, asOf: asOf)) 次"))
                            .font(.title3.weight(.semibold)).monospacedDigit()
                    }.frame(maxWidth: .infinity).padding(.vertical, 8)
                }
            }
            Text(L10n.tr("近 7 / 14 / 30 天已收录的直接 Reset；归档可能不完整。"))
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct CommunityHistorySummary: View {
    let history: CommunityResetHistory
    var body: some View {
        let resets = history.recordedResets(asOf: Date())
        VStack(alignment: .leading, spacing: 5) {
            Text(L10n.tr("历史 Reset · 社区记录")).font(.headline)
            Text(L10n.tr("\(history.events.count) 条归档 · \(resets.count) 条直接重置记录")).font(.caption)
            if let latest = resets.last {
                Text(L10n.tr("最近记录：") + latest.announcedAt.localized(date: .abbreviated, time: .shortened)).font(.caption)
                Text(L10n.tr("公告时间，非账号到账时间")).font(.caption2).foregroundStyle(.secondary)
            }
            Link(L10n.tr("来源：codex-reset.com"), destination: history.trackerURL).font(.caption)
        }
    }
}

struct CommunityHistoryView: View {
    @ObservedObject var connections: ConnectionModel
    @Environment(\.radarCloseWindow) private var closeWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L10n.tr("历史 Reset")).font(.title2.bold())
                Spacer()
                Button(L10n.tr("关闭"), systemImage: "xmark.circle.fill") { closeWindow(id: "reset-history") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help(L10n.tr("关闭历史窗口（⌘W / Esc）"))
            }
            if let history = connections.history {
                CommunityHistorySummary(history: history)
                Text(L10n.tr("来自公开 tracker 的归档，不来自本次帖子抓取。预告、credit 和定向补偿单独保留。"))
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup(L10n.tr("预测依据与数据限制")) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(L10n.tr("记录间隔候选：\(history.candidateIntervals(asOf: Date()).count) 个；不跨预告和类型不确定的记录。"))
                        Text(L10n.tr("生效时间与连续覆盖未核验，严格核验预测：\(L10n.key(connections.historicalForecast?.reason ?? "数据不足"))。"))
                        Text(L10n.tr("参考概率由本地算法计算，未抓取第三方百分比。按 6 小时分段估计，稀少区段以平均间隔平滑；假设此后没有漏记 Reset，未经回测校准。"))
                        Text(L10n.tr("主面板显示 AI 直接估计；历史参考算法单独计算，未经过回测校准。两者均不代表个人账号重置概率。"))
                        Text(L10n.tr("数据版本：") + history.version)
                        Text(L10n.tr("导入于 ") + history.fetchedAt.localized(date: .abbreviated, time: .shortened))
                    }.font(.caption).foregroundStyle(.secondary).padding(.top, 5)
                }
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(history.events.sorted { $0.announcedAt > $1.announcedAt }) { event in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(L10n.key(event.label)).font(.subheadline.bold())
                                    Spacer()
                                    Link(L10n.tr("原始出处 ↗"), destination: event.sourceURL).font(.caption)
                                }
                                Text(event.announcedAt.localized(date: .abbreviated, time: .standard) + L10n.tr(" · 公告时间"))
                                    .font(.caption)
                                if event.crossCheckURL != nil {
                                    Text(L10n.tr("两个公开 tracker 的公告时间一致")).font(.caption2).foregroundStyle(.secondary)
                                }
                                if event.type == "targeted_compensation" {
                                    Text(L10n.tr("部分用户的补偿，排除于全局重置统计")).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            Divider()
                        }
                    }
                }
                Text(L10n.tr("社区归档标签不等于本应用独立核验；可打开每条原始出处查看。"))
                    .font(.caption2).foregroundStyle(.secondary)
            } else { Text(connections.historyStatus) }
        }.padding(20).frame(width: 540, height: 680).nativeSurface()
    }
}
