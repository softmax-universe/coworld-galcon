"""Validate bounded Fluffy graphical captures and summarize measured milliseconds."""
import collections
import hashlib
import json
import math
from pathlib import Path
import sys
root = Path(sys.argv[1] if len(sys.argv) > 1 else 'build/graphics-profile')
rows = json.loads((root / 'samples.json').read_text())
summary = {'metadata': json.loads((root / 'metadata.json').read_text()), 'cases': {}, 'artifacts': {}}
def pct(values, p):
    values = sorted(values)
    i = (len(values)-1)*p
    a = math.floor(i)
    b = math.ceil(i)
    return round((values[a]*(b-i)+values[b]*(i-a) if a != b else values[a])/1000, 5)
for label in ['low', 'high', 'high-history-card']:
    samples = [r for r in rows if r['case'] == label]
    assert len(samples) == 144
    scopes = collections.defaultdict(list)
    counts = []
    for chunk in range(6):
        path = root / f'{label}-{chunk}.json'
        events = json.loads(path.read_text())['traceEvents']
        assert len(events) < 10000, (path, len(events))
        assert sum(e['name'] == 'cpu_frame_excluding_gpu_wait_and_present' for e in events) == 24
        counts.append(len(events))
        for e in events:
            scopes[e['name']].append(e['dur'])
    summary['cases'][label] = {
        'frames': len(samples), 'ships_min': min(r['ships'] for r in samples),
        'ships_max': max(r['ships'] for r in samples),
        'ticks': [min(r['tick'] for r in samples), max(r['tick'] for r in samples)],
        'vertices_min': min(r['vertices'] for r in samples),
        'vertices_max': max(r['vertices'] for r in samples),
        'chunk_event_counts': counts,
        'scopes_ms': {name: {'n': len(v), 'p50': pct(v,.50), 'p95': pct(v,.95), 'p99': pct(v,.99)} for name,v in scopes.items()}}
assert summary['cases']['high']['ships_min'] >= 3000
assert summary['cases']['high-history-card']['ships_min'] >= 3000
for path in sorted(root.iterdir()):
    if path.name in ['summary.json', 'report.md']: continue
    if path.is_file():
        summary['artifacts'][path.name] = {'bytes': path.stat().st_size, 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
(root / 'summary.json').write_text(json.dumps(summary, indent=2)+'\n')
for label, case in summary['cases'].items():
    print(label, f"ships={case['ships_min']}..{case['ships_max']}")
    for name in ['cpu_frame_excluding_gpu_wait_and_present','render_cpu','ship_geometry','effect_sprites','background_and_planet_sprites','board_vertex_transform','sidebar_ui','drawCard','silky_endUi_upload_submit','advance*','simulation_step','glFinish_completion_wait_not_gpu_timer','swapBuffers_vsync_off']:
        print(' ',name,case['scopes_ms'].get(name))
print('Verified 432 frames; 18 uncapped traces; summary:',root/'summary.json')
