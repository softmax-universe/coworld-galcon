#!/usr/bin/env python3
"""Build and run native real-input two-client UI regression, isolated relay/home.

python3 tests/mp_e2e_run.py --relay /path/to/gameserver
Never uses/restarts a live service. Evidence is kept under build/mp-e2e/<run>/.
Requires Nim dependencies and native OpenGL (macOS GUI session).
"""
import argparse
import datetime
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import time
import urllib.request


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--relay', required=True, type=Path)
    parser.add_argument('--skip-build', action='store_true')
    parser.add_argument('--clients', type=int, choices=[2,3], default=2)
    parser.add_argument('--fixture', default='mp_e2e_native', choices=['mp_e2e_native', 'test_cosmetic_ready_ui', 'test_same_room_rematch'])
    parser.add_argument('--timeout', type=int, default=120)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    output = root / 'build/mp-e2e' / datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f')
    output.mkdir(parents=True)
    binary = root / 'build' / args.fixture
    if not args.skip_build:
        with (output / 'compile.log').open('w') as log:
            result = subprocess.run(['nim', 'c', '-d:release', f'-d:ClientCount={args.clients}', f'--nimcache:build/{args.fixture}-nimcache',
                                     f'--out:{binary}', f'tests/{args.fixture}.nim'],
                                    cwd=root, stdout=log, stderr=subprocess.STDOUT, timeout=300)
        if result.returncode:
            print((output / 'compile.log').read_text())
            return result.returncode
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        port = s.getsockname()[1]
    home = output / 'home'
    home.mkdir()
    env = dict(os.environ, HOME=str(home), GALCON_MP_ISOLATED_HOME=str(home),
               GALCON_MP_SERVER=f'ws://127.0.0.1:{port}/ws', GALCON_MP_OUTPUT=str(output))
    command = [str(args.relay.resolve()), '--port', str(port), '--address', '127.0.0.1']
    started = time.monotonic()
    with (output / 'relay.log').open('w') as relay_log:
        relay = subprocess.Popen(command, cwd=root, stdout=relay_log, stderr=subprocess.STDOUT)
        result = None
        try:
            for _ in range(100):
                if relay.poll() is not None:
                    raise RuntimeError('Isolated relay exited: ' + (output / 'relay.log').read_text())
                try:
                    with urllib.request.urlopen(f'http://127.0.0.1:{port}/healthz', timeout=.3) as response:
                        if response.status == 200:
                            break
                except OSError:
                    time.sleep(.05)
            else:
                raise RuntimeError('Isolated relay health timed out')
            with (output / 'client.log').open('w') as log:
                result = subprocess.run([str(binary)], env=env, cwd=root,
                                        stdout=log, stderr=subprocess.STDOUT, timeout=args.timeout)
            print((output / 'client.log').read_text())
        finally:
            relay.terminate()
            try:
                relay.wait(timeout=5)
            except subprocess.TimeoutExpired:
                relay.kill()
                relay.wait(timeout=5)
            summary = {'frontend': 'native Windy/Silky production View.frame, not browser',
                       'clients': args.clients,
                       'relay': str(args.relay.resolve()), 'port': port, 'relay_pid': relay.pid,
                       'relay_stopped': relay.poll() is not None,
                       'returncode': result.returncode if result else None,
                       'seconds': round(time.monotonic()-started, 2)}
            (output / 'result.json').write_text(json.dumps(summary, indent=2)+'\n')
            print('Evidence:', output)
            print(json.dumps(summary))
    return result.returncode if result else 1


if __name__ == '__main__':
    sys.exit(main())
