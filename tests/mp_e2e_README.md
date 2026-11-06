# Multiplayer frontend regression

```sh
python3 tests/mp_e2e_run.py --relay /path/to/polyworld-gameserver
python3 tests/mp_e2e_run.py --clients 3 --relay /path/to/polyworld-gameserver
```

The relay must include sparse Galcon StartMatch support. The runner builds the
native test in release mode, allocates an unused loopback port, starts its own
relay, verifies health, isolates HOME/settings under the evidence directory, runs
with a bounded timeout, and terminates only its own server. No live service is
used or restarted. Requires Nim dependencies and a native macOS OpenGL session.

Focused chat callback regression (no relay):
```sh
nim c -r -d:release --nimcache:build/chat-input-nimcache --out:build/test_chat_input tests/test_chat_input.nim
```
It uses the production chat callback installer, actual Windy rune/key dispatch,
Silky begin/end frames, and production handleInput. It checks Enter/submit,
Escape/cancel, hotkey suppression, UTF-8-safe Backspace, byte bounds and invalid
Unicode scalar rejection. The current raster font atlas substitutes missing
Unicode glyphs with `?`; protocol/replay text retains the exact UTF-8 bytes.

`mp_e2e_native.nim` includes the production graphics module to drive the actual
`View.frame`, frontend drawing, menu navigation and `handleInput` without adding
production testing hooks. Each client has its own hidden native window, GL FBO,
Frontend, Connection, prepared match, simulation, and text focus state. They are
independent clients in **one test process**, not independent OS processes.
Silky's process-global textbox table is swapped per client to emulate separate
applications. Mouse/key/rune events enter through Windy's ordinary event handler
templates; gameplay never invokes `world.send`, `launch`, frontend room/ready
helpers, or NetworkMatch submission directly. Release is dispatched through
production `handleInput` separately before pumping to assert no speculative
world mutation.

Assertions cover:
- Fresh identity dialogs, actual text entry/Continue, punctuation/Unicode names.
- Main menu Multiplayer action, real connection and Welcome.
- Private room creation with all four default seats empty.
- Invitation textbox and Join button for each guest.
- Slot picker -> Play as you; two clients take stable zero-based seats 1,3.
  The optional third client takes seat 0. Unoccupied seats stay empty; no bots.
- Explicit Ready clicks and host Start Game; real BeginMatch game transitions.
- Stable-seat-to-packed-player mapping and names preserved in gameplay.
- Every human clicks an owned planet, drags to a real neutral planet, releases;
  only the real relay can turn queued intent into recorded authoritative orders.
- Rendered world is live, ticks advance, actual active ship coordinates change.
- All peers recorded every human order; every common tick fingerprint agrees.
- Human chat uses Enter/rune callbacks/Enter; every peer receives one authoritative
  copy, Escape cancels without leaving the game, and typing blocks gameplay keys.
- Every client's serialized replay reloads and verifies every recorded tick and
  preserves the exact shared human-chat sequence once.
- Own QA match aborted for cleanup; every client receives LeaveRoom confirmation.

Evidence is under `build/mp-e2e/<timestamp>/`: `compile.log`, `client.log`,
`relay.log`, `result.json`, browser/lobby/launch/movement/final PNGs, replay files,
and isolated settings. `result.json` records client count, allocated port and
confirmation that the runner-owned relay exited.

## Limits / known harness pitfalls

This is **native UI coverage, not Chromium/WASM/browser coverage**. It does not
establish that the deployed browser bundle pumps WebSocket events correctly.
No production changes were needed for the passing two- and three-human tests.

Use release builds: unoptimized per-frame GL error checks and rendering can
stall the UI long enough for relay heartbeat timeouts. Match commands must be
matched by tick, not compared at different live frontiers. Wait past the native
double-click interval before dragging a previously clicked source, otherwise the
intentional select-all double-click path suppresses a send. Native mouse motion
must carry mouseDelta for the original menu hover selection.

The native Windy WebSocket close helper currently attempts hangup on the wrong
async dispatcher and can raise `File descriptor not registered`. The test first
requires acknowledged leaves, closes windows, then relies on test-process exit
to close its sockets; the Python runner independently terminates its QA relay.

Latest verified runs at implementation time:
- `build/mp-e2e/20261105-151215-124063`: two clients, 25 checks, 130 common ticks.
- `build/mp-e2e/20261105-151254-662325`: three clients, 34 checks, 237 common ticks.
Both returned zero, all humans sent moving fleets, all saved replays verified,
all clients left, and isolated relay termination was confirmed.
