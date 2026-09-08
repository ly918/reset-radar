# 历史数据出处

2026-09-07，从 [codex-reset.com 公开 API](https://codex-reset.com/api/timeline) 导入归档元数据，来源页面为 [timeline](https://codex-reset.com/timeline)。导入脚本为 `scripts/import-community-history.py`。

`community-reset-history.json` 保存实际获取时间、源更新时间、响应 SHA-256、事件 ID、公告时间、类型、出处和使用限制。已独立于动态抓取接入本地应用与算法输入。

- API 返回 64 条，50 条 `source=archive` 入库，14 条 `source=live` 排除。
- 50 条中，28 条社区标记的直接 Reset、6 条 credit、9 条预告、1 条定向补偿、6 条 boost/unlock 类型待核验。
- `2029308599835738218` 的来源描述涉及约 9% Plus/Pro 用户，按定向补偿排除于全局重置。
- 原归档部分 boost/unlock 同时提到 reset，暂不擅自改成直接重置；9 条 preview 不变为已发生。
- [codex-reset.today 的公开记录 API](https://codex-reset.today/api/v1/resets) 本轮只比较其首页 20 条记录，7 条共同 ID 的公告时间一致。两站引用相同原帖，不构成独立事件事实核验。
- 50 条的 `effective_at` 均为空。源明确区分公告/确认时间与实际生效时间；本应用不补造生效时间。
- 不跨越预告或类型待核验条目的候选公告间隔有 18 个；当前连续覆盖和实际生效时间尚未核验，不作为可信完整间隔发布概率。

`reset-events.json` 仍为独立核验后的正式事件集，当前为空；这与已经导入的社区历史是两个层次。没有把社区标签改写成本应用已独立核验，也没有混入 Demo。

使用的均为事实元数据与来源链接，不复制 tracker 全文摘要、图表或预测值。仓库仅包含上述事实元数据与来源链接；第三方内容不纳入项目 MIT 授权，详见 LICENSE-DATA.md。
