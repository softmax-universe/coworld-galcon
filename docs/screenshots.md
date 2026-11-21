# Screenshots

Use the same screenshot arguments as the other Polyworld games:

```sh
build/galcon --screenshot output/galcon.png --frames 30 --windowSize 1280x900
```

The graphical executable renders into a hidden window without audio or frame
pacing, saves the requested rendered frame, and exits. The default is frame
30. Parent output directories are created automatically. Capture does not
automatically save a partial match to the replay library; `--record FILE`
remains available for an explicit replay export.

Space, equals, and colon forms are accepted, such as `--frames 3`,
`--frames=3`, and `--frames:3`. `--windowSize` controls the capture window.
Headless and browser builds cannot capture a native screenshot.

Choose a screen with the existing game arguments:

```sh
build/galcon --menu replays --screenshot output/replays.png --frames 3
build/galcon --start --players 2 --planets 6 --seed 77 \
  --screenshot output/match.png --frames 30
```

Screenshot rendering is a local development check, not part of CI.
