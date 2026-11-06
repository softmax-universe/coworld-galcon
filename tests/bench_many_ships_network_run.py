#!/usr/bin/env python3
"""Isolated native real-WebSocket traffic audit. Build binaries as in README report."""
import json
import os
from pathlib import Path
import socket
import subprocess
import time
import urllib.request

ROOT = Path('/Users/me/p/coworld-galcon')
SCRATCH = Path('/Users/me/.hermes/cache/scratch')
output = SCRATCH / ('galcon-wire-' + time.strftime('%Y%m%d-%H%M%S'))
output.mkdir()
with socket.socket() as sock:
    sock.bind(('127.0.0.1', 0))
    port = sock.getsockname()[1]
relay_log = (output / 'relay.log').open('w')
relay = subprocess.Popen([str(SCRATCH / 'galcon-wire-relay'), '--port', str(port), '--address', '127.0.0.1'], stdout=relay_log, stderr=subprocess.STDOUT)
results = []
try:
    for _ in range(100):
        try:
            urllib.request.urlopen(f'http://127.0.0.1:{port}/healthz', timeout=.3).close()
            break
        except OSError:
            time.sleep(.05)
    for mode in ['low', 'many']:
        home = output / (mode + '-home')
        home.mkdir()
        env = dict(os.environ, HOME=str(home), GALCON_WIRE_SERVER=f'ws://127.0.0.1:{port}/ws', GALCON_WIRE_OUTPUT=str(output))
        result = subprocess.run([str(SCRATCH / 'galcon-wire-client'), mode], cwd=ROOT, env=env, capture_output=True, text=True, timeout=80)
        (output / (mode + '-client.log')).write_text(result.stdout + result.stderr)
        print(mode, result.returncode, result.stdout, result.stderr, flush=True)
        results.append({'mode': mode, 'returncode': result.returncode})
        if result.returncode:
            break
finally:
    relay.terminate()
    try:
        relay.wait(timeout=5)
    except subprocess.TimeoutExpired:
        relay.kill()
        relay.wait(timeout=5)
    relay_log.close()
    (output / 'run.json').write_text(json.dumps({'port': port, 'pid': relay.pid, 'relayStopped': relay.poll() is not None, 'results': results}, indent=2))
    print('OUTPUT', output, flush=True)
