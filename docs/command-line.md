# Command-line options

Galcon uses Polyworld's common names and value syntax. Valued options accept
separate, equals, and colon forms: `--replay match.replay`,
`--replay=match.replay`, and `--replay:match.replay` mean the same thing.

| Option | Behavior |
| --- | --- |
| `--replay PATH` | Load a current-version replay instead of running bots. |
| `--record PATH` | Save the live match on completion or exit; create missing parent directories. |
| `--bot PATH[:N]` | Fill N bot slots from one BASIC policy or policy package; repeat for more programs. |
| `--bots PATH[:N]` | The same option as `--bot`. |
| `--player [N]` | Control one-based slot N; a bare flag means slot 1. |
| `--name TEXT` | Set the human display name, including the recorded roster. |
| `--seed N` | Choose the deterministic map seed. |
| `--ticks N` | Limit a live match to N simulation ticks. |
| `--seconds N`, `--minutes N` | Set the same limit in simulation time, using Galcon's 32 ticks per second. |
| `--play BOOL` | Start graphical playback playing or paused. |
| `--speed N` | Set the graphical simulation/playback multiplier. |
| `--windowSize WIDTHxHEIGHT`, `--vsync BOOL` | Configure the graphical window. |
| `--mute`, `--unmute` | Override saved audio settings for this launch. |
| `--verbose` | Print session and replay diagnostics. |
| `--headless-tick-rate N` | Pace headless ticks per wall-clock second; zero runs without pacing. |
| `--server URL`, `--room CODE` | Open the graphical multiplayer client; `--join` is an alias of `--room`. |
| `--screenshot PATH`, `--frames N` | Save the selected rendered frame and exit; the default is 30 frames. |

Replay playback cannot combine with bots, a human controller, or recording.
Multiplayer connection options cannot combine with a local bot roster, human
slot, or replay file; configure the room's roster in its lobby instead.
Paths are relative to the directory where the executable was launched.
`--player` always means a controller slot; use `--name` for display names.

Bot and player options start a match directly. `--record` alone keeps the menu
open and applies to the live local or multiplayer match started there. Galcon's
`--start` explicitly starts a match with its default policies.

Galcon keeps its map and rule options, including `--players`, `--planets`,
`--difficulty`, and `--tutorial`. Its BASIC host does not expose LLM requests,
so `--llm-mode` is rejected. Headless launches cannot join graphical rooms.

```sh
build/galcon --player 2 --name Alice --bot players/classic.bas:2 \
  --seed 19 --minutes 2 --record replays/match.replay
build/galcon --replay replays/match.replay --play false --speed 3
```
