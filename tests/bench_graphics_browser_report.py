"""Validate real browser sample sets and emit aggregate timing evidence."""
import collections
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/browser-graphics-profile'

def stats(xs):
    xs = sorted(xs)
    def percentile(p):
        k = (len(xs)-1)*p
        i = int(k)
        return round(xs[i] + (xs[min(i+1, len(xs)-1)]-xs[i])*(k-i), 4)
    return {'n': len(xs), 'p50': percentile(.5), 'p95': percentile(.95),
            'p99': percentile(.99), 'max': round(max(xs), 4)}

allrows = []
per_run = {}
for run in range(1,4):
    data = json.loads((OUT / f'run-{run}.json').read_text())
    assert data['viewport'] == [1280,800]
    assert len(data['samples']) == 288
    per_run[str(run)] = {}
    for case in ['low','high']:
        rows = [r for r in data['samples'] if r['case'] == case]
        assert len(rows) == 144
        assert [r['frame'] for r in rows] == list(range(144))
        if case == 'high': assert min(r['ships'] for r in rows) >= 3300
        else: assert max(r['ships'] for r in rows) == 0
        per_run[str(run)][case] = {key: stats([r[key] for r in rows])
          for key in ['cpu_frame_ms','render_ms']}
        allrows.extend(rows)
result = {'viewport':[1280,800], 'runs':3, 'total_frames':len(allrows),
          'per_run':per_run, 'aggregate':{}}
events = []
for case in ['low','high']:
    rows = [r for r in allrows if r['case']==case]
    result['aggregate'][case] = {
      'ships_min': min(r['ships'] for r in rows),
      'ships_max': max(r['ships'] for r in rows),
      'vertices_min':min(r['vertices'] for r in rows),
      'vertices_max':max(r['vertices'] for r in rows),
      **{key: stats([r[key] for r in rows if key != 'simulation_ms' or r['simulation_tick']])
        for key in ['cpu_frame_ms','render_ms','simulation_ms','draw_game_ms',
          'transform_ms','sidebar_ms','submit_ms']}}
    # Trace is derived from measured scope durations, not claimed CDP timestamps.
    for i,r in enumerate(rows):
        t = i * 100000
        for name,dur in [('simulation',r['simulation_ms']),('render',r['render_ms'])]:
            events.append({'name':name,'cat':case,'ph':'X','pid':1,'tid':1 if case=='low' else 2,
              'ts':t,'dur':dur*1000,'args':{'ships':r['ships'],'frame':r['frame']}})
            t += dur*1000
(OUT/'summary.json').write_text(json.dumps(result,indent=2))
(OUT/'measured-scopes.trace.json').write_text(json.dumps({'traceEvents':events,
 'metadata':{'warning':'Scope durations genuine performance.now; synthetic spacing for visualization only'}}))
profile = json.loads((OUT/'browser.cpuprofile').read_text())
nodes = {n['id']:n for n in profile['nodes']}
counts = collections.Counter(profile.get('samples',[]))
top = [{'samples':n,'function':nodes[i]['callFrame']['functionName'],
        'url':nodes[i]['callFrame']['url']} for i,n in counts.most_common(25)]
(OUT/'cpu-top.json').write_text(json.dumps(top,indent=2))
files = [p for p in OUT.iterdir() if p.is_file() and p.name != 'sha256.json']
(OUT/'sha256.json').write_text(json.dumps({p.name:hashlib.sha256(p.read_bytes()).hexdigest()
 for p in files},indent=2))
print(json.dumps(result,indent=2))
print('CPU top',json.dumps(top[:12],indent=2))
