# Actual browser/WASM many-ships profile

## Result
Measured actual production `drawGame`, sidebar, Silky upload/submit and genuine `World.launch`/`World.advance` in Chromium 156 / WebGL2 / ANGLE Metal Apple M4 Pro. No native timings are relabeled as browser timings. Clock is an EM_JS adapter calling `performance.now()` only in this browser-only test harness; shared Fluffy is untouched.

Three identical 1280×800 physical-pixel runs, DPR 1, 144 low + 144 high frames/run: **864 measured frames**, 216 simulation ticks per case. All three runs' `(case,tick,ships,pendingLaunches,fingerprint)` sequences match exactly. Low: 0 airborne ships; high: **3905–3968 actual airborne ships**, reaching the full available body capacity (4096 bodies minus 128 planets). Pre-submit NormalLayer vertices: low 9114; high 77868–79002. Screenshots show genuinely crowded rendered playfields.

| CPU milliseconds | low p50 | low p95 | high p50 | high p95 | high p99 |
|---|---:|---:|---:|---:|---:|
| frame: simulation + render | 1.4 | 2.7 | 6.1 | 11.1 | 13.238 |
| render | 1.3 | 2.6 | 3.3 | 8.1 | 8.569 |
| simulation, tick frames only | 0.2 | 0.4 | 5.3 | 8.0 | 8.785 |
| drawGame + UI begin/clear | 0.9 | 2.0 | 2.6 | 6.145 | 6.8 |
| board vertex transform | 0.1 | 0.3 | 0.3 | 1.0 | 1.169 |
| sidebar | 0.1 | 0.2 | 0.0 | 0.1 | 0.1 |
| upload/submit | 0.2 | 0.4 | 0.3 | 1.0 | 1.269 |

High CPU-frame p95 per run: **11.185 / 10.285 / 11.785 ms**; high render p95: **8.1 / 5.995 / 8.2 ms**. Worst observed high frame 24.2 ms. Timer quantization is approximately 0.1 ms; zero-valued tiny sections are below that resolution, not free.

## Bottleneck evidence and boundaries
- Near-cap simulation tick cost is greater than typical per-frame rendering cost. It occurs every second rendered frame in this controlled harness.
- Rendering's dominant measured section is CPU construction of game geometry, not sidebar or WebGL submit. Separate near-cap CDP CPU sampling corroborates production `drawTriangle`, `collide`, `moveBodies`, `clipRect`, `emitLaunch` and vertex-buffer append work. The raw CPU profile includes idle time from explicit pacing and one screenshot operation; its sample counts are not percentages of gameplay frame time.
- This is **not** GPU elapsed time or end-to-end display frame latency. No glFinish; WebGL may defer work. `sleep(16)` is explicit yielding, not requestAnimationFrame FPS; stored start intervals include screenshot/JSON/pacing overhead and must not be presented as FPS.
- Seed 424242, 128 planets, alternating owners, stock 10000 each, enemy ships pass through, farthest-planet launch waves of 500. This is an explicit stress fixture, not an ordinary bot match. Production world stepping + effects + summary only: no bot/session/checkpoint/network/catch-up. Consequently this does not rule out full-session or network bottlenecks.
- Native figures from the parent investigation are separate measurements with different warmup/time windows. The supplied native 3.8 ms CPU-frame p95 versus browser 11.1 ms is directional only, **not** a controlled platform multiplier. Native render 1.6 ms and browser 8.1 ms p95 likewise are not an apples-to-apples speed ratio.
- Initial 3300-ship capture is preserved under `initial-3300/`, including its cold/warm variability; it is not mixed into the final near-cap summary.

## Artifacts
`build/browser-graphics-profile/`:
- `run-{1,2,3}.json`: raw per-frame performance.now measurements, real ship counts, fingerprints.
- `run-{1,2,3}-{low,high}.png`: actual canvas screenshots captured at frame 120, outside measured scope.
- `summary.json`: validated aggregate and per-run percentile results.
- `browser.cpuprofile`: actual CDP sampling profile from a separate near-cap run.
- `cpu-top.json`, `browser-environment.json`, `sha256.json`.
- `measured-scopes.trace.json`: Chrome-trace-compatible durations; spacing is synthetic and explicitly marked, not CDP event chronology.

## Exact build/reproduction
Run from `/Users/me/p/coworld-galcon`:

```sh
PATH=/opt/homebrew/opt/python@3.13/libexec/bin:/opt/homebrew/bin:$PATH \
GALCON_WEB=/Users/me/.hermes/cache/scratch/galcon-browser-profile \
/Users/me/.nimby/nim/bin/nim c -d:release -d:emscripten tests/bench_graphics_browser.nim
/opt/homebrew/bin/python3.13 -m http.server 18763 --bind 127.0.0.1 \
  --directory /Users/me/.hermes/cache/scratch/galcon-browser-profile
```

Set Chromium CDP `Emulation.setDeviceMetricsOverride` to width 1280, height 800, deviceScaleFactor 1, mobile false. Open `http://127.0.0.1:18763/galcon.html` three fresh navigations; wait for `window.galconStage === 'done'`. Save `window.galconBench` as `run-N.json`, and base64-decode `window.galconShots.low/high` into PNG files. `window.galconBench` is the actual final browser memory readback. Collect optional CDP Profiler at 250 µs after stage becomes high, stop at done. Run `python3.13 tests/bench_graphics_browser_report.py` to validate and aggregate. Screenshots were inspected visually.

## Scope / issues
Only added `tests/bench_graphics_browser.nim`, `tests/bench_graphics_browser_report.py`, this report, and build artifacts. No production/shared-library edit, optimization, deploy, commit, or production LAN asset/server change. Dedicated scratch output avoided `build/web`. Emscripten's python initially resolved to Apple's 3.9 and failed; prepending Homebrew Python 3.13 fixed it. EM_JS const-char prototype mismatch was fixed inside the harness. Vertex count is intentionally sampled before `endUi` clears the layer. Local dedicated profiling server is stopped after collection.
