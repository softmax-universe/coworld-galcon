# Testing

CI runs the bounded unit entry point once on Linux, macOS, and Windows:

```sh
nim check -d:headless -d:release -d:fixedChecks -d:nimTypeNames tests/unit_tests.nim
nim r -d:headless -d:release -d:fixedChecks -d:nimTypeNames tests/unit_tests.nim
```

Use the pinned dependencies in `galcon.lock`. The unit suite covers command and
configuration validation, room authority, short deterministic movement, bot
decisions, ordered chat, replay versions, storage, seeking, and save recovery.
It does not open windows, render screenshots, initialize audio, or run network
servers. Each CI job has a five-minute limit, including setup and compilation.

Long simulation regressions and graphical tests remain available locally:

```sh
nim r -d:release -d:fixedChecks -d:nimTypeNames tests/tests.nim
nim r -d:release tests/test_lobby_graphics.nim
nim r -d:release tests/test_replay_menu_render.nim
nim r -d:release tests/test_replay_save_graphics.nim
```

The full and graphical suites require a native display and audio libraries.
They are not part of CI. Run them locally when changing rendering, native input,
or simulation behavior that needs the longer scenarios.
