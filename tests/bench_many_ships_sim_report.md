# Galcon deterministic many-ship CPU profile

## Outcome

On Apple M4 Pro / macOS 15.1.1, native Nim 2.2.10 `-d:release -d:headless`:

| Scope (release run 1; ms) | p50 | p95 | p99 | max |
|---|---:|---:|---:|---:|
| Low world.advance | 0.0139 | 0.0150 | 0.0184 | 0.0339 |
| Low full session, 16 classic bots/history | 0.0997 | 0.1193 | 0.1460 | 0.1843 |
| High world.advance only | 1.7995 | 2.3768 | 2.4815 | 2.9970 |
| High full session, 16 classic bots/history | 2.1425 | 9.4696 | 16.0671 | 25.4588 |
| High replay + hash + checkpoint | 2.1138 | 9.6592 | 18.8220 | 50.8289 |

32 Hz budget = 31.25 ms. Full-session p99 across three release runs: 15.90–16.23 ms; no full-session samples exceeded the budget (1,536 high ticks). High replay had 2 over-budget ticks across three runs; world.advance had 3 (largest 65.16 ms). These isolated wall-time tails happened in runs with thousands of involuntary context switches; they are not proof of a deterministic CPU hot path. Native results do NOT establish WASM/browser timings, rendering performance, network cadence, or the user's particular lag cause.

High fleet samples assert >=3,500 active ships on every measured tick: 3,526–3,968 before ticks, ending at 3,525. 128 planets occupy the other pool slots, so 3,968 ships is the actual 4,096-body cap. Genuine launch() queues initially have 128 entries and grow to the 1,024-entry bound. High samples include real collisions, 2,128 accumulated hostile impacts and 1,181 captures by tick 1,024, with capture/cancellation behavior left intact. Initial/final hash pairs match all three release runs and the trace build. Low fleet is 0–8 active, with eight real hostile arrivals. Same seeded 128-planet/16-player geometry, but low fixture deliberately sets production=0 and stock=8 to prevent bots immediately filling the world; high has large stocks and ordinary production. This is a stress contrast, not a clean causal single-variable fleet-count experiment.

## Attribution (actual Fluffy trace, high session, ms)

| Phase | mean | p95 | p99 |
|---|---:|---:|---:|
| Collisions | 1.0641 | 1.2176 | 1.2518 |
| Movement | 0.0646 | 0.0749 | 0.0865 |
| Spatial index | 0.0148 | 0.0155 | 0.0180 |
| Production | 0.0071 | 0.0091 | 0.0106 |
| Arrivals | 0.0037 | 0.0059 | 0.0070 |
| advance remainder: drain + winner/tick bookkeeping | 0.7231 | 1.0950 | 1.1453 |
| All 16 bot decisions INCLUDING their launches | 1.2936 | 7.3330 | 13.9206 |
| Replay recordTick, including fingerprint | 0.0762 | 0.0825 | 0.0932 |

The striking tail is NOT safely attributable to BASIC interpreter work alone. The paired world-only run reapplies the exact recorded accepted bot orders outside world.advance timing. That launch-application phase alone has p95 7.10 ms / p99 14.31 ms (run 1), closely matching the full bot aggregate tail. Source inspection explains this: every successful launch() calls drainLaunches(), which retries the entire current FIFO, and advance() drains it again. Queue-heavy bot-issued batches can therefore multiply drain/spawnClear/freeBody work. This is evidence for order/launch queue pressure, not a proposed or applied optimization. There is no standalone production drain span, so its contribution inside advance is reported only as an exclusive remainder alongside winner bookkeeping, never falsely labeled an exact drain measurement.

The benchmark's `world` tick_ns explicitly EXCLUDES applying orders, hashing, and checkpointing; its separate order_ns, record_ns, checkpoint_ns fields prevent that cheaper scope being confused with a full session. Session and replay timings INCLUDE their normal full pipelines. Every world-only tick checks its resulting fingerprint against the live-session tape; replayTick checks every tick itself. High bot count: 16 classic policies, 512 decisions each per run. Low policies also execute but have insufficient stock to launch. This benchmark does not measure arbitrary user-provided policies or replay file serialization/IO.

## Hash / checkpoints / memory

High standalone hashing at the exact initial saturated state: median ~0.072–0.073 ms/hash; measured throughput 13,415–13,709 hashes/sec over 16,384 hashes/run. Low median ~0.0081 ms/hash. Hash batches are intentionally static state, not advances; hash-row budget counts are not simulation misses.

World fixed object: 435,568 bytes, plus planets/sequences. Four real production checkpoint boundaries occur at 640/768/896/1,024, each cloning roughly 490.7 KB of occupied heap; measured clone/capture spans in paired runs ~0.055–0.110 ms. Not a dominant CPU tail here. At most five checkpoints retained in this 512-tick window; this does NOT exercise the 64-checkpoint thinning boundary or long-match retained-memory plateau. Release process peak RSS 25.0–27.8 MB (OS time reports bytes), peak memory footprint ~34.8 MB. Those are whole-process values including benchmark sample storage, bots, tapes and paired worlds, not game-only browser memory.

Fluffy measures elapsed monotonic native CPU-region spans, not statistical CPU samples or thread CPU time: scheduler interference remains in tails. Trace build additionally uses -d:nimTypeNames to capture allocation/deallocation/memory counters. Uninstrumented release runs are the main latency result. No WASM build, browser test, network service, optimization, deploy, or commit was performed.

## Reproduce

From `/Users/me/p/coworld-galcon` (dependencies/config must resolve as in source manifest):

```sh
ROOT=/Users/me/.hermes/cache/scratch/galcon-many-ships-sim
nim c --hints:off -d:release -d:headless --nimcache:$ROOT/cache-release --out:$ROOT/bench-release tests/bench_many_ships_sim.nim
/usr/bin/time -l $ROOT/bench-release $ROOT/release-1 512 512
# Repeat release-2 and release-3 with the SAME binary.
nim c --hints:off -d:release -d:headless -d:nimTypeNames -d:ProfileTracePath=manual --nimcache:$ROOT/cache-trace --out:$ROOT/bench-trace tests/bench_many_ships_sim.nim
/usr/bin/time -l $ROOT/bench-trace $ROOT/trace 512 512
python3 tests/bench_many_ships_sim_report.py $ROOT
```

Positional args: output directory, sample ticks, warmup ticks. For the validated workload use exactly `512 512`. Assertions intentionally reject a future fixture whose fleet falls below the claimed high bound. Optional `-d:simProbe` only explores warmup counts; not a benchmark result.

## Evidence

All artifacts: `/Users/me/.hermes/cache/scratch/galcon-many-ships-sim/`
- `summary.json`: full p50/p95/p99/max, budget misses, phase statistics, top ten ticks and trace event counts.
- `samples.csv`: 16,384 raw rows = 4 runs × 2 cases × 4 modes × 512 samples.
- `{release-1,release-2,release-3,trace}/{low,high}-samples.json`: raw timing/count/memory rows.
- `trace/{low,high}-{session,world,replay,hash}-{0..7}.json`: 64 genuine Chrome/Perfetto-compatible Fluffy files. Each exactly 64 bench.tick spans; each capture <10,000 events. Session chunks also assert 64 step and 1,024 decide spans. Total 4,096 bench spans; hash chunks contain 32 hash operations per span.
- `*-state.json`: deterministic hashes and fixture state counters.
- `release-*.log`, `trace-run.log`: actual OS timing/RSS counters.
- `bench-release`, `bench-trace`, `binary-fingerprints.json`: frozen executables with SHA256.
- `frozen-sources.tar.gz`, `source-fingerprints.json`: pre-final-build source snapshot/hashes, including dirty game sources and local dependency Nim paths (broad snapshot; no dependency writes). All core simulation files were rehashed unchanged after the measurements.

Only new `tests/bench_many_ships_sim.nim`, `tests/bench_many_ships_sim_report.py`, and this report were written in the repository. Existing unrelated dirty files were preserved.
