#!/usr/bin/env python3
"""Aggregate exact application payload bytes; excludes TCP/WebSocket framing."""
import collections
import json
from pathlib import Path
import statistics
import sys

output = Path(sys.argv[1])
summary = {}
for mode in ['low', 'many']:
    packets = [json.loads(l) for l in (output / f'{mode}-packets.jsonl').read_text().splitlines()]
    ticks = [json.loads(l) for l in (output / f'{mode}-ticks.jsonl').read_text().splitlines()]
    run = json.loads((output / f'{mode}-client.log').read_text().strip())
    categories = []
    for direction, kind in sorted(set((p['direction'], p['kind']) for p in packets)):
        group = [p for p in packets if (p['direction'], p['kind']) == (direction, kind)]
        categories.append(dict(direction=direction, kind=kind, packets=len(group), bytes=sum(p['bytes'] for p in group), sizes=sorted(set(p['bytes'] for p in group))))
    a = {t['tick']: t['hash'] for t in ticks if t['client'] == 0}
    b = {t['tick']: t['hash'] for t in ticks if t['client'] == 1}
    assert len(a) == len(b) == 768 and a == b
    clients = []
    for i in [0, 1]:
        ts = [t for t in ticks if t['client'] == i]
        gaps = [t['gapMs'] for t in ts[1:]]
        wire = [p for p in packets if p['client'] == i and p['direction'] == 'down' and p['kind'] == 'TickPacket']
        unique = {p['tick']: p for p in wire}
        clients.append(dict(client=i, gapP95Ms=statistics.quantiles(gaps, n=100)[94], gapMaxMs=max(gaps), gapsAbove100Ms=sum(g > 100 for g in gaps), wireTicks=len(wire), uniqueTicks=len(unique), uniqueTickBytes=sum(p['bytes'] for p in unique.values()), duplicateTickBytes=sum(p['bytes'] for p in wire)-sum(p['bytes'] for p in unique.values()), uniqueCommands=sum(p['commands'] for p in unique.values())))
    submissions = sum(p['direction'] == 'up' and p['kind'] == 'SubmitCommand' for p in packets)
    summary[mode] = dict(run=run, categories=categories, clients=clients, all768HashesAgree=True, commands=submissions, commandsPerSimulationSecond=submissions/(768/32), commandsPerWallSecond=submissions/run['elapsed'], totalPayloadBytes={d:sum(p['bytes'] for p in packets if p['direction']==d) for d in ['up','down']}, averagePayloadBytesPerWallSecond={d:sum(p['bytes'] for p in packets if p['direction']==d)/run['elapsed'] for d in ['up','down']})
assert summary['low']['commands'] == summary['many']['commands'] == 384
assert summary['low']['clients'][0]['uniqueTickBytes'] == summary['many']['clients'][0]['uniqueTickBytes']
(output / 'summary.json').write_text(json.dumps(summary, indent=2)+'\n')
print(json.dumps(summary, indent=2))
