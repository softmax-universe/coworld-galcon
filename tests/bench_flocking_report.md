# Deterministic movement / launch benchmark

Frozen baseline: HEAD 14329097b2cf01c1969415dd4bc719901601fbc4, replay/gameplay 14. Source archive, source hashes, immutable baseline executable, raw JSON and logs: `/Users/me/.hermes/cache/scratch/galcon-sim-v15`.

Native release Nim 2.2.10, seed 20261106; existing bench_many_ships_sim.nim unchanged; 512 warm ticks + 128 samples; 128 planets, 16 owners; high fixture stocks 1,000,000 per planet, accepted launch 100,000 each. Both versions reach 3968 airborne ships and 128 pending orders at sample start. This is an artificial production-launch stress fixture, not an ordinary match.

Sequential repeated run (avoids competing compilation/test load). Times are measured CPU milliseconds, not FPS:

| workload | v14 mean | v14 p95 | v15 mean | v15 p95 |
|---|---:|---:|---:|---:|
| low session | 2.879 | 12.092 | 0.234 | 0.453 |
| low world | 0.041 | 0.042 | 0.086 | 0.187 |
| low replay | 0.136 | 0.232 | 0.093 | 0.157 |
| high session | 34.781 | 120.927 | 4.705 | 7.554 |
| high world | 6.185 | 13.676 | 4.949 | 6.444 |
| high replay | 15.794 | 42.106 | 5.389 | 7.339 |

Session includes bot order application, replay hash recording and checkpoints. World excludes order_ns; replay includes playback order application plus hash verification. The new local steering adds world work; reducing repeated pending-FIFO scans primarily benefits full session/replay work. Do not claim isolated movement speedup. Changed gameplay means post-warm positions/hashes differ; this is controlled identical-input fixture comparison, not an identical-state microbenchmark.

Verified full native tests/tests.nim (without headless), existing 16-seat command/peer/replay checks, escrow/capture/full pool/seek tests, five spatial strategies and historical golden 9960303572208390231. New regression: 24 opposing friendly movers, >80 px net progress each in 160 ticks (old 22/24; new 24/24). Ring drain emits 13 ships in one tick across two destinations. Frozen 512-tick v14 recording SHA256 734cbae9964cc6353f8c974028b42c2d95eda86c6572c98b92023cfe7808007f validates every old hash and v15 resave, final hash 2096991766765028424.

Replay/gameplay 15 stores legacyMovement explicitly; old tapes select old hard collision and launch draining; hashes are not rewritten for v6+ tapes. New scratch arrays are derived from hashed current/previous positions and rebuilt before steering; no additional persistent per-ship state, frame RNG or wire entities. New acceptance returns reserved count immediately but emits at tick boundary, once for whole queue. Destination sharing rotates deterministic starting order each tick.

Limitations: no browser/WASM/native render clip, no broad jitter/angular-variance metric or network byte benchmark rerun. Enemy non-pass mode intentionally keeps hard enemy contacts. Cohesion deliberately omitted to avoid destination orbit.
