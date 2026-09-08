#!/usr/bin/env python3
"""Dependency-free fixture integrity checks; not a general JSON Schema validator or model evaluation."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
fixture = json.loads((ROOT / 'tests/fixtures/classification-cases.json').read_text())
schema = json.loads((ROOT / 'schemas/signal-analysis.schema.json').read_text())
cases = fixture['cases']
assert len(cases) >= 30
assert len({c['id'] for c in cases}) == len(cases)
assert len({c['category'] for c in cases}) == 11
assert fixture['model_run'] is False
for case in cases:
    result = case['expected']
    assert case['synthetic'] is True
    assert set(result) == set(schema['required'])
    assert result['post_id'] == case['id']
    assert result['evidence_quote'] and result['evidence_quote'] in case['text']
    assert 0 <= result['classification_confidence'] <= 1
    for name, rule in schema['properties'].items():
        if 'enum' in rule:
            assert result[name] in rule['enum']
    if result['relative_window_hours'] is not None:
        assert result['relative_window_hours'] == [2, 6]
        assert result['time_expression'] in case['text']
real = json.loads((ROOT / 'data/reset-events.json').read_text())
assert real['synthetic'] is False and real['events'] == [] and real['coverage'] == []
assert json.loads((ROOT / 'config/sources.json').read_text())['author_id'] is None
print(f'PASS: {len(cases)} synthetic label contracts, 11 categories, exact evidence; no real model evaluation')
print('PASS: independently verified event set remains empty; community records are separate')

for source in ['schemas/signal-analysis.schema.json', 'prompts/signal_classifier_v1.md']:
    assert (ROOT / source).read_bytes() == (ROOT / 'packages/RadarCore/Sources/RadarCore/Resources' / Path(source).name).read_bytes()
print('PASS: bundled classification prompt and schema match repository contracts')

community = json.loads((ROOT / 'data/community-reset-history.json').read_text())
assert community['synthetic'] is False and len(community['events']) == 50
assert len({row['id'] for row in community['events']}) == 50
assert community['continuousCoverageVerified'] is False
assert (ROOT / 'data/community-reset-history.json').read_bytes() == (ROOT / 'packages/RadarCore/Sources/RadarCore/Resources/community-reset-history.json').read_bytes()
print('PASS: 50 real community archive rows bundled separately from independently verified events')
