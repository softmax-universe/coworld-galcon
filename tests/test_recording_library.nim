import
  std/[os, strutils, tempfiles],
  galcon/[chats, common, options, replaylibraries, replays, sessions, worlds]

proc librarySession(seed = 42'i32): Session =
  ## Creates a short recorded match without graphics or bot decisions.
  let options = parseOptions(@["--players", "2", "--ticks", "60"])
  options.setup.seed = seed
  options.headless = false
  newSession(options, @["", ""], @["Alice", "Bob"], 1, true)

proc ownerPlanet(world: World, owner: int): int =
  ## Finds an occupied home for a real fleet order in the recording.
  for index, planet in world.planets:
    if planet.owner == owner:
      return index
  raise newException(GalconError, "Missing replay test player")

proc verify(recording: Recording): uint64 =
  ## Plays every accepted action and requires each recorded world fingerprint.
  let world = newWorld(recording.setup)
  var cursor = 0
  while world.tick < recording.hashes.len.int32:
    recording.replayTick(world, cursor)
  doAssert cursor == recording.actions.len
  world.fingerprint()

proc testRecordingLibrary() =
  ## Checks real recorded matches, complete history, and shared save recovery.
  const DataVariable = when defined(windows): "APPDATA" else: "XDG_DATA_HOME"
  let
    directory = createTempDir("galcon-recording-library-", "")
    hadData = existsEnv(DataVariable)
    previousData = getEnv(DataVariable)
  putEnv(DataVariable, directory)
  defer:
    if hadData:
      putEnv(DataVariable, previousData)
    else:
      delEnv(DataVariable)
    removeDir(directory)
  let
    library = replayDirectory()
    session = librarySession()
    first = session.liveWorld.ownerPlanet(1)
    second = session.liveWorld.ownerPlanet(2)
  doAssert library.startsWith(directory)
  while session.liveWorld.tick < 20:
    if session.liveWorld.tick == 3:
      doAssert session.chat.sendChat(1, -2, "Opening") > 0
      doAssert session.liveWorld.launch(1, first, second, 2) == 2
      doAssert session.chat.sendChat(2, -2, "Opening") > 0
    session.step()
  let
    partialPath = session.saveLibraryRecording()
    partial = loadRecording(partialPath)
  doAssert partial.hashes.len == 20
  doAssert partial.actions.len == 3
  doAssert partial.actions[0].kind == ActionChat
  doAssert partial.actions[1].kind == ActionLaunch
  doAssert partial.actions[2].kind == ActionChat
  doAssert partial.actions[0].tick == partial.actions[2].tick
  doAssert partial.verify() == session.liveWorld.fingerprint()
  while not session.done:
    if session.liveWorld.tick == 30:
      doAssert session.chat.sendChat(1, -2, "Later") > 0
    session.step()
  session.updateReplaySaving(automatic = true)
  doAssert session.replaySaveError.len == 0
  let
    completed = session.recordingData()
    liveHash = session.liveWorld.fingerprint()
    completedPath = session.saveLibraryRecording()
  doAssert completed.hashes.len == 60
  doAssert completed.actions.len == 4
  doAssert listReplays(library).len == 2
  doAssert completedPath != partialPath
  doAssert loadRecording(completedPath).verify() == liveHash
  session.finishReplaySaving(automatic = true)
  doAssert listReplays(library).len == 2,
    "Completion, manual, and exit saves must reuse the same recorded prefix."

  session.seek(0)
  doAssert session.world.tick == 0 and session.liveWorld.tick == 60
  let rewound = session.recordingData()
  doAssert rewound.actions == completed.actions
  doAssert rewound.hashes == completed.hashes
  doAssert session.saveLibraryRecording() == completedPath
  doAssert listReplays(library).len == 2
  let playback = newSession(parseOptions(@["--replay", completedPath]))
  for tick in [60'i32, 0, 3, 4, 30, 31, 60]:
    playback.seek(tick)
    session.seek(tick)
    doAssert playback.world.fingerprint() == session.world.fingerprint()
  var rejected = false
  try:
    discard playback.saveLibraryRecording()
  except GalconError:
    rejected = true
  doAssert rejected, "Watching a replay must not produce another recording."
  doAssert listReplays(library).len == 2
  removeFile(completedPath)
  let recreated = session.saveLibraryRecording()
  doAssert fileExists(recreated)
  doAssert loadRecording(recreated).verify() == liveHash
  doAssert listReplays(library).len == 2

  let disabled = librarySession(43)
  disabled.step()
  disabled.updateReplaySaving(automatic = false)
  disabled.finishReplaySaving(automatic = false)
  doAssert listReplays(library).len == 2
  discard disabled.saveLibraryRecording()
  doAssert listReplays(library).len == 3,
    "Manual saves must work with automatic saving disabled."

  let blocked = directory / "blocked"
  writeFile(blocked, "Not a directory")
  putEnv(DataVariable, blocked)
  let failed = librarySession(44)
  failed.step()
  rejected = false
  try:
    discard failed.saveLibraryRecording()
  except CatchableError:
    rejected = true
  doAssert rejected and failed.replaySaving.saveRequested
  rejected = false
  try:
    failed.finishReplaySaving(automatic = false)
  except CatchableError:
    rejected = true
  doAssert rejected and failed.replaySaving.saveRequested,
    "An unsuccessful manual save must retry on exit despite automatic opt-out."
  let retained = failed.recordingData()
  doAssert retained.verify() == failed.liveWorld.fingerprint()
  putEnv(DataVariable, directory)
  failed.finishReplaySaving(automatic = false)
  doAssert not failed.replaySaving.saveRequested
  doAssert listReplays(library).len == 4
  failed.finishReplaySaving(automatic = false)
  doAssert listReplays(library).len == 4

  let interrupted = librarySession(45)
  interrupted.step()
  interrupted.finishReplaySaving(automatic = true)
  doAssert listReplays(library).len == 5,
    "Leaving an unfinished match must save its recorded prefix."

  let automatic = librarySession(46)
  while not automatic.done:
    automatic.step()
  putEnv(DataVariable, blocked)
  automatic.updateReplaySaving(automatic = true)
  doAssert automatic.replaySaveError.len > 0
  doAssert automatic.replaySaving.saveRequested
  putEnv(DataVariable, directory)
  automatic.updateReplaySaving(automatic = true)
  doAssert listReplays(library).len == 5,
    "A failed completion write must not be attempted every frame."
  automatic.finishReplaySaving(automatic = true)
  doAssert automatic.replaySaveError.len == 0
  doAssert listReplays(library).len == 6

testRecordingLibrary()
echo "Galcon library recording, ordered chat, rewind, and save recovery passed."
