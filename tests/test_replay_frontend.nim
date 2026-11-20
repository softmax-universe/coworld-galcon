import
  std/[importutils, os, strutils, tempfiles],
  silky, vmath,
  galcon/[frontends, multiplayer, options, replaylibraries, replaymenus,
    replays, sessions, worlds]

privateAccess(Frontend)

proc testReplayFrontend*() =
  ## Opens real recordings and retains failed exports through menu transitions.
  const DataVariable = when defined(windows): "APPDATA" else: "XDG_DATA_HOME"
  let
    directory = createTempDir("galcon-replay-frontend-", "")
    hadData = existsEnv(DataVariable)
    previousData = getEnv(DataVariable)
  putEnv(DataVariable, directory)
  defer:
    if hadData:
      putEnv(DataVariable, previousData)
    else:
      delEnv(DataVariable)
    removeDir(directory)

  let session = newSession(parseOptions(@[
    "--players", "4", "--planets", "12", "--ticks", "12", "--seed", "9"
  ]))
  var source, target = -1
  for index, planet in session.world.planets:
    if planet.owner == 1:
      source = index
    elif planet.owner == 2:
      target = index
  doAssert source >= 0 and target >= 0
  doAssert session.world.launch(1, source, target, 3) == 3
  while not session.done:
    session.step()
  let
    finalHash = session.world.fingerprint()
    path = saveLibraryReplay(session.recording)
    folder = replayDirectory()
    config = MatchConfig(players: 3, seed: 99)
    front = Frontend(config: config,
      replayBrowser: initReplayBrowser(Library))
  doAssert folder.startsWith(directory)
  front.openReplays()
  front.processReplayActions()
  doAssert front.browsingReplays
  doAssert front.replayBrowser.entries.len == 1
  doAssert front.replayBrowser.entries[0].path == path
  doAssert front.replayBrowser.entries[0].playable

  front.replayBrowser.ui.selectedPath = path
  front.replayBrowser.ui.scroll = FrameState(scrollPos: vec2(0, 32))
  front.replayAction = ReplayBrowserResult(action: PlayReplay, path: path)
  front.processReplayActions()
  doAssert front.launch != nil and front.launch.playback
  doAssert front.launch.human == 0
  doAssert front.config == config and front.config.players == 3
  doAssert front.launch.recording == nil
  for brain in front.launch.brains:
    doAssert brain == nil, "Watching a recording must not start live bots."
  front.launch.seek(session.recordedTicks())
  doAssert front.launch.world.fingerprint() == finalHash
  front.launch.seek(0)
  front.launch.seek(session.recordedTicks())
  doAssert front.launch.world.fingerprint() == finalHash
  doAssert front.browsingReplays
  front.launch = nil
  front.openReplays()
  front.processReplayActions()
  doAssert front.replayBrowser.ui.selectedPath == path
  doAssert front.replayBrowser.ui.scroll.scrollPos.y == 32
  doAssert listReplays().len == 1,
    "Watching and seeking must not create another replay file."
  echo "Galcon replay menu launches, seeks, and restores its list selection."

  let original = readFile(path)
  writeFile(path, "The listed recording changed before Watch was pressed.")
  front.replayAction = ReplayBrowserResult(action: PlayReplay, path: path)
  front.processReplayActions()
  doAssert front.launch == nil
  doAssert front.replayBrowser.message.len > 0
  doAssert front.browsingReplays
  writeFile(path, original)
  front.replayAction = ReplayBrowserResult(action: BackFromReplays)
  front.processReplayActions()
  doAssert not front.browsingReplays and front.page == HomeMenu
  doAssert front.replayBrowser.ui.selectedPath == path
  doAssert front.replayAction.action == StayReplayBrowser
  echo "Galcon rejects a stale invalid replay and returns to the home menu."

  let blocked = directory / "blocked"
  writeFile(blocked, "Not a directory")
  front.unsavedReplays = @[session.recording.clone()]
  putEnv(DataVariable, blocked)
  front.retryPendingReplays()
  doAssert front.error.len > 0 and front.unsavedReplays.len == 1
  doAssert front.unsavedReplays[0].hashes == session.recording.hashes
  doAssert readFile(path) == original
  putEnv(DataVariable, directory)
  front.retryReplayRequested = true
  front.processReplayActions()
  doAssert front.unsavedReplays.len == 0
  doAssert front.error.len == 0 and not front.retryReplayRequested
  doAssert listReplays().len == 2
  front.openReplays()
  front.processReplayActions()
  doAssert front.replayBrowser.entries.len == 2
  for entry in front.replayBrowser.entries:
    doAssert entry.playable
  echo "Galcon retries failed menu saves without losing their recordings."

testReplayFrontend()
