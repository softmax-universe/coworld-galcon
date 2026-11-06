# Galcon wire audit: real isolated WebSocket relay

## Result
Increasing legitimate launched fleets from a peak 263 to 1,231 active ships did NOT increase the authoritative gameplay stream: both cases sent 384 fleet commands and exactly 69,120 unique TickPacket payload bytes per receiving client over 768 ticks. All 768 post-tick hashes agreed between the two clients within each case. No ship positions, planet positions, planet garrison snapshots, or entity arrays are encoded by this gameplay protocol.

## Method / limitations
Built current dirty-tree native gameserver and benchmark into separate scratch binaries/caches; ran localhost relay on an ephemeral port (not 9911). Two independent RoomClient/NetworkMatch worlds in one native OS process, using actual Windy WebSockets, no renderer, no Connection smoothing. Same seed 8, 16 seats split evenly between clients, 69 planets, Rules B defaults, duration 768 ticks, idle BASIC policies to avoid confounding bot activity. Every 32 ticks each player submits one legitimate fixed-count fleet order from an owned planet to a distant enemy planet. Low count=1, many count=1,000,000 (normal world.launch clamps to available real stocks and emits through normal pending launch queue). No stock/entity injection. Command placement can depend on current ownership; rate/count and byte widths are identical. Guest deliberately stops applying ticks for 0.9 seconds after tick 192 while continuing socket processing, to test bounded catch-up. This is a local native transport test, NOT a browser/rendering or WAN latency test. Gap metrics are application tick-application intervals (including deliberate suspension), not ping or pure network delay. Receipt fallback is eager in this harness; production Connection waits 100ms before Received.

## Exact results (all bytes application binary payload, excludes WS/TCP/IP framing)

| Metric | Low | Many |
|---|---:|---:|
| elapsed match wall seconds | 27.07614775 | 27.0022295 |
| peak active ships | 263 | 1231 |
| commands / simulation second | 16 | 16 |
| commands / wall second | 14.1822243 | 14.2210479 |
| SubmitCommand packets / total bytes | 384 / 36864 | 384 / 36864 |
| unique TickPacket count / bytes PER CLIENT | 768 / 69120 | 768 / 69120 |
| TickPacket received count BOTH clients (duplicates included) | 1556 | 1551 |
| TickPacket total bytes BOTH clients | 139680 | 139320 |
| duplicate TickPacket bytes BOTH clients | 1440 | 1080 |
| Catchup / CaughtUp pairs BOTH clients | 1494 | 1487 |
| AppliedTick packets BOTH clients | 3029 | 3022 |
| ReportHash packets BOTH clients | 50 | 50 |
| total uplink bytes BOTH clients, setup included | 351822 | 350870 |
| total downlink bytes BOTH clients, setup included | 265972 | 265153 |
| uplink bytes/wall second BOTH clients | 12993.7982 | 12994.1122 |
| downlink bytes/wall second BOTH clients | 9823.1108 | 9819.6706 |
| tick-gap p95 host / guest ms | 41.413 / 41.566 | 41.141 / 41.310 |
| max tick-gap host / guest ms | 208.437 / 906.493 | 260.385 / 904.743 |
| >100ms tick gaps host / guest | 2 / 3 | 2 / 3 |
| final within-case shared hash | 4328669569096091766 | 8023190606459044517 |

Each case ended normally, 768/768 exact per-tick hash comparisons agree, periodic recording hash sequences equal. Final hashes are intentionally different ACROSS cases because orders/ships differ.

## Exact schema audit / scaling
Current shared codec is `polyworld/src/polyworld/rooms.nim` (there is no separate roomcodec.nim). Protocol version 4, fixed header 64 bytes: magic/version/kind/delivery/match, four uint64 timing fields and uint32 RTT/jitter. Galcon identity gameplay=13, protocol=2 in this build.

- Galcon fleet payload: four u32 values `{kind (1 absolute / 2 percent), sourcePlanetIndex, targetPlanetIndex, value}` = 16 bytes. The value is one count or percentage, NOT a list of ships. Galcon chat: kind u32 + length-prefixed UTF-8 string = 8+text bytes.
- SubmitCommand: header + seat u32 + sequence u64 + payload length u32 + payload = 80+payload = **96 bytes** for fleet.
- TickPacket: header + tick u32 + commandCount u32 + commands; each command is participant u32 + seat u32 + sequence u64 + payload length u32 + payload = 20+payload. Thus **72+36*N** bytes for N fleet commands; observed sizes **72** and **648** (16 commands). Each recipient receives every ordered command: fanout scales with recipient count and submission rate, not active ship count.
- AppliedTick and Catchup = **68** bytes; CaughtUp = **72**; ReportHash and FinishMatch = **76** (tick u32 + hash u64). Ready/Prepared/StartMatch/BeginMatch = **76** (revision u32 + initial hash u64). Received = **72**. Keepalive = **64**. CommandAck = **76**, only issued for a retransmitted already-received sequence in current relay; NEW commands are acknowledged by inclusion in TickPacket (none of these benchmark runs had CommandAck).
- RoomState is roster/config metadata: room/name, host participant, revision, phase, tickRate, flag, configuration JSON, participant names/connected/ready flags, seat ownership/names. Observed 38 packets / 17,777 bytes each case. Configuration includes the INITIAL planet-count integer and seed/rules so each client creates the same map; it does not include changing planet garrisons, coordinates, or ship objects. Therefore saying 'no planet counts are sent' without qualification is wrong: initial map planetCount and per-command fleet amount ARE sent, not per-planet state snapshots.
- `multiplayer.nim:89-128,174-182,205-250`: command decode/queue applies launches and then `world.advance()` locally. `stateHash` includes fingerprint of world plus maximum duration. Hashes report tick 0 and every 32 applied ticks, plus final hash.
- `roomclients.nim:219-232`: EACH applied tick sends AppliedTick, and when queue drains requests Catchup even if no known gap. `CaughtUp` at current edge sends ANOTHER AppliedTick. This yields approximately **two AppliedTick + one Catchup + one CaughtUp per recipient per tick** in this immediate-consumption harness: notable avoidable sync/control chatter, not an entity snapshot. Low case: 101,592 uplink Catchup bytes + 107,568 downlink CaughtUp bytes; many: 101,116 + 107,064. Request/response count is near tick count per client. Do not attribute it solely to the injected pause.
- `relays.nim:349-359,896-911`: catch-up returns immutable historical TickPackets, at most 16 ticks per request; live pushes withheld beyond guest.applied+16. Overlap can duplicate already-pushed packets (client validates immutability/deduplicates). No catch-up state snapshot.
- `multiplayer.nim:185-192,250` / `bots.nim:222-239`: each locally owned bot executes once per applied tick INCLUDING catch-up. A policy can produce multiple submissions per decision; 16 bots * 32 decisions/sec can fan out commands independently of ship entity count. This benchmark deliberately idles bots and fixes 16 commands/sec to isolate count.
- Bounds: MaxCommandBytes=4096; MaxCommandsPerTick=1024; MaxClientCommands=4096 pending; MaxWireBytes=256KiB; relay also bounds pending bytes to half MaxWireBytes, using its accounting. Input cap=256KiB/sec; transport unacknowledged cap=512KiB; buffered client ticks=128; catch-up batch=16. Relay stores command/history/receipt accounting, not simulation entities.

## Artifacts / reproduction
Evidence: `/Users/me/.hermes/cache/scratch/galcon-wire-20261106-124028/`: low/many packets.jsonl (observed wire categories/lengths), low/many ticks.jsonl (tick/ships/hash/time/gap), client logs, relay.log, run.json, summary.json. `run.json` confirms relay stopped. Own binary paths: scratch/galcon-wire-client and scratch/galcon-wire-relay. Only new `tests/bench_many_ships_network*` files were written; no production edit/build-WASM/live restart.

Commands from `/Users/me/p/coworld-galcon`:
```
nim c -d:release --nimcache:/Users/me/.hermes/cache/scratch/galcon-wire-client-cache --out:/Users/me/.hermes/cache/scratch/galcon-wire-client tests/bench_many_ships_network.nim
```
From `/Users/me/p/polyworld`:
```
nim c -d:release --threads:on --nimcache:/Users/me/.hermes/cache/scratch/galcon-wire-relay-cache --out:/Users/me/.hermes/cache/scratch/galcon-wire-relay tools/gameserver.nim
```
Then from Galcon:
```
python3 tests/bench_many_ships_network_run.py
python3 tests/bench_many_ships_network_analyze.py <printed-output-directory>
```
Initial probe failed due Nim loop-captured callback index; fixed in benchmark only by constructing callbacks in a parameterized proc. Failed-run artifact remains separately under scratch/galcon-wire-20261106-123853; successful results above do not use it.
