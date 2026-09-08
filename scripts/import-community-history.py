#!/usr/bin/env python3
"""Normalize public tracker metadata; never treat its live feed as verified history."""
import argparse, collections, datetime, hashlib, json
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser()
p.add_argument('snapshot', type=Path, help='Downloaded https://codex-reset.com/api/timeline JSON')
p.add_argument('--cross-check', type=Path)
a = p.parse_args()
raw = a.snapshot.read_bytes()
source = json.loads(raw)
observed = datetime.datetime.now(datetime.timezone.utc).isoformat().replace('+00:00', 'Z')
peer = json.loads(a.cross_check.read_text())['data'] if a.cross_check else []
peer_by_id = {r['id']: r for r in peer}
rows = []
for record in source['events']:
    if record.get('source') != 'archive': continue
    identity = record['id']
    assert identity.isdigit() and record['url'] == f'https://x.com/thsottiaux/status/{identity}'
    announced = record['announced_at']
    datetime.datetime.fromisoformat(announced.replace('Z', '+00:00'))
    group = record['group']
    category = 'unknown'
    if group == 'credits': category = 'banked_credit'
    elif record.get('preview'): category = 'planned_reset'
    elif identity == '2029308599835738218': category = 'targeted_compensation'
    elif group == 'reset' and record.get('scope') == 'global': category = 'global_reset'
    # Boost/unlock entries sometimes contain a reset too. Keep uncertain, do not silently discard or merge.
    cross = peer_by_id.get(identity)
    match = bool(cross and datetime.datetime.fromisoformat(cross['announced_at'].replace('Z', '+00:00')) == datetime.datetime.fromisoformat(announced.replace('Z', '+00:00')))
    rows.append(dict(id=identity, announcedAt=announced, effectiveAt=record.get('effective_at'),
        type=category, sourceType=group, scope=record.get('scope','unknown'), sourceURL=record['url'],
        verification='community_archive', timeBasis='announcement', preview=bool(record.get('preview')),
        crossCheckURL='https://codex-reset.today/api/v1/resets' if match else None))
assert len({r['id'] for r in rows}) == len(rows) and rows
rows.sort(key=lambda r:r['announcedAt'], reverse=True)
data = dict(version='community-archive-2026-09-07-v1', synthetic=False,
    sourceURL='https://codex-reset.com/api/timeline', trackerURL='https://codex-reset.com/timeline',
    fetchedAt=observed, sourceUpdatedAt=source['updated_at'], sourceSHA256=hashlib.sha256(raw).hexdigest(),
    continuousCoverageVerified=False, independentlyVerified=False,
    excludedLiveRows=sum(r.get('source') != 'archive' for r in source['events']),
    events=rows,
    limitations=['Times are source announcement times, not verified effective times.',
      'Community archive labels are retained; independent verification and continuous coverage are not established.',
      'Preview windows, banked credits, targeted compensation and uncertain boost/unlock rows are excluded from direct-reset interval candidates.',
      'The second tracker comparison is limited to its fetched first page; shared timestamps are not independent proof of occurrence.'])
text=json.dumps(data,ensure_ascii=False,indent=2)+'\n'
for path in [ROOT/'data/community-reset-history.json', ROOT/'packages/RadarCore/Sources/RadarCore/Resources/community-reset-history.json']:
    path.write_text(text)
print('Imported archive records:',len(rows),'types:',dict(collections.Counter(r['type'] for r in rows)))
print('Excluded live rows:',data['excludedLiveRows'],'cross-checked timestamps:',sum(bool(r['crossCheckURL']) for r in rows))
