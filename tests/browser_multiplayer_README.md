# Real browser multiplayer regression

`browser_multiplayer.cjs` launches two fresh Chromium contexts, enters names,
uses the original Home → Multiplayer canvas menus, creates an explicitly private
room, joins by its authoritative room identifier, claims sparse Human seats 1/3,
readies both clients and starts as host. It asserts displayed ticks advance beyond
20, drags an owned planet to a distant neutral planet from BOTH clients, checks
ordinary percent-send commands and their authoritative TickPacket delivery to both
peers, then compares a shared post-command hash checkpoint. No gameplay state or
network commands are injected.

Dependencies are scratch-only Playwright (Chromium installed). Set
`GALCON_QA_DEPS` to a directory with `node_modules/playwright`; its default is
`/Users/me/.hermes/cache/scratch/lvd-browser-qa`.

Run a separately owned relay on **loopback port 19931**. Do not restart the user's
relay or reuse an existing user's room. Stop the isolated relay after the test;
closing browsers alone retains reconnectable rooms on a long-running relay.

```sh
PATH=/opt/homebrew/bin:$PATH EM_PYTHON=/opt/homebrew/bin/python3 \
  nim c -d:release -d:emscripten -d:galconBrowserProbe src/galcon.nim
python3 -m http.server 19932 --bind 127.0.0.1 --directory build/web
GALCON_QA_REQUIRE_PROBE=1 \
GALCON_QA_URL='http://127.0.0.1:19932/galcon.html?qa=1&server=ws%3A%2F%2F127.0.0.1%3A19931%2Fws' \
  node tests/browser_multiplayer.cjs
```

The optional compile-time `galconBrowserProbe` exports no actions. With `?qa=1`,
it calls a test-supplied read-only `Module.polyworldGalconProbe(snapshot)` callback
containing authoritative tick, human player and active ship positions. The test
then also asserts that each human's own ships actually move >5 world units.
Production builds omit this define entirely. Rebuild without it before publishing.
Normal production acceptance still checks real drags, authoritative command delivery,
visible tick progress and post-command hash agreement, and retains fleet screenshots.

`GALCON_QA_URL` may point to the LAN standalone page while retaining the isolated
loopback relay query. `GALCON_QA_OUT` chooses the evidence directory. The harness
disables HTTP cache and background throttling and holds mouse gestures across frames.
Coordinates are for the fixed default seed/map and 1514×970 viewport; changed map
layout requires updating them. Exit status 1 is RED; `report.json` records exact
WebSocket messages, console output, frame ticks and optional movement snapshots.

## Deployed freeze captured

The old deployed WASM drained exactly ticks 1…16 and then remained at tick 16
although frames and WebSocket keepalives continued. There was only the initial
Catchup, and no consumed-edge history probe. Its generated roomclients C still
required `applied < serverTick` before requesting history at an empty buffer.
The shared source already contained the loading-gap recovery fix, but this game
bundle predated it. Rebuilding against current shared sources fixed the browser
regression without a relay change or a duplicated game-level workaround.

New commands are acknowledged by inclusion in TickPacket; a separate CommandAck is
sent only for retransmission. Requiring a new-command CommandAck is an invalid test.
