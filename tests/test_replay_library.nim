import
  std/[os, strutils, tempfiles, times],
  polyworld/tapes,
  galcon/[chats, common, replaylibraries, replays, worlds]

type TestRecordingData = object
  setup: Setup
  actions: seq[Action]
  hashes: seq[uint64]
  names: seq[string]

proc ownerPlanet(world: World, player: int): int =
  ## Finds the seeded home planet for one player in this fixture.
  for index, planet in world.planets:
    if planet.owner == player:
      return index
  doAssert false, "The fixture must give each player a home planet."

proc sampleRecording(): Recording =
  ## Records real chat and launches in acceptance order with exact world hashes.
  let
    setup = configuredSetup(77, Easy, 2, 6)
    world = newWorld(setup)
    source = world.ownerPlanet(1)
    target = world.ownerPlanet(2)
  result = Recording(setup: setup, names: @["Neutral", "Alice", "Bob"])
  for tick in 0 ..< 32:
    if tick in [0, 10]:
      doAssert world.addChat(1, "Repeated message")
      doAssert world.launch(1, source, target, 3) == 3
    if tick == 5:
      doAssert world.launch(1, source, target, 2) == 2
      doAssert world.addChat(2, "Reply after launch")
    world.advance()
    result.recordTick(world)

proc verify(recording: Recording) =
  ## Plays every saved action and requires each deterministic state hash.
  let world = newWorld(recording.setup)
  var cursor = 0
  while world.tick < recording.hashes.len.int32:
    recording.replayTick(world, cursor)
  doAssert cursor == recording.actions.len
  doAssert world.fingerprint() == recording.hashes[^1]

proc rejectImport(source, directory: string) =
  ## Requires a rejected import to preserve its source and existing recordings.
  let
    before = listReplays(directory).len
    bytes = readFile(source)
  var rejected = false
  try:
    discard importReplay(source, directory)
  except ReplayError:
    rejected = true
  doAssert rejected
  doAssert listReplays(directory).len == before
  doAssert readFile(source) == bytes

proc testReplayLibrary() =
  ## Covers the current format, storage, imports, validation, and disk errors.
  let
    root = createTempDir("galcon-replay-library-", "")
    directory = root / "library with spaces"
    recording = sampleRecording()
    bytes = recording.encodeRecording()
  defer: removeDir(root)
  doAssert ReplayVersion == 23
  doAssert bytes.replayFileHeader().gameVersion == ReplayVersion
  recording.validate()
  recording.validate()
  doAssert recording.encodeRecording() == bytes
  doAssert recording.actions[0].kind == ActionChat
  doAssert recording.actions[1].kind == ActionLaunch
  doAssert recording.actions[2].kind == ActionLaunch
  doAssert recording.actions[3].kind == ActionChat
  doAssert recording.actions[4].kind == ActionChat
  doAssert recording.actions[4].text == recording.actions[0].text
  decodeRecording(bytes).verify()
  doAssert replayDirectory().isAbsolute()
  doAssert replayDirectory().endsWith("Polyworld" / "Galcon" / "Replays")
  doAssert listReplays(directory).len == 0
  doAssert not dirExists(directory)

  let
    first = saveLibraryReplay(recording, directory)
    second = saveLibraryReplay(recording, directory)
  doAssert first != second
  doAssert first.parentDir == directory
  doAssert first.splitFile().name.startsWith("Galcon-")
  doAssert readFile(first) == bytes and readFile(second) == bytes
  let entry = inspectReplay(first)
  doAssert entry.playable and entry.problem.len == 0
  doAssert entry.gameVersion == ReplayVersion
  doAssert entry.fileVersion == ReplayFileVersion and entry.tapeVersion == 0
  doAssert entry.ticks == recording.hashes.len
  doAssert entry.size == bytes.len
  let loaded = loadRecording(first)
  doAssert loaded.actions == recording.actions
  doAssert loaded.hashes == recording.hashes
  doAssert loaded.names == recording.names
  loaded.verify()
  setLastModificationTime(first, fromUnix(100))
  setLastModificationTime(second, fromUnix(200))
  writeFile(directory / "notes.txt", "Leave me alone")
  writeFile(directory / "unfinished.partial", bytes)
  let ordered = listReplays(directory)
  doAssert ordered.len == 2 and ordered[0].path == second
  doAssert ordered[1].path == first

  let source = root / "An imported match.REPLAY"
  writeFile(source, bytes)
  let imported = importReplay(source, directory)
  doAssert imported != source and readFile(source) == bytes
  doAssert readFile(imported) == bytes
  doAssert importReplay(imported, directory) == imported
  doAssert importReplay(source, directory) != imported

  let old = root / "older.replay"
  writeFile(old, encodeReplayFile("galcon", ReplayVersion - 1,
    "Unknown historical payload"))
  let oldCopy = importReplay(old, directory)
  doAssert readFile(old) == readFile(oldCopy)
  let unsupported = inspectReplay(oldCopy)
  doAssert not unsupported.playable
  doAssert "Game version" in unsupported.problem
  doAssert unsupported.gameVersion == ReplayVersion - 1

  let bad = root / "bad.replay"
  for malformed in ["not a replay", ReplayMagic,
      bytes[0 ..< ReplayMagic.len + 6 + "galcon".len],
      bytes[0 ..< bytes.len - 3],
      encodeReplayFile("other", ReplayVersion, "foreign")]:
    writeFile(bad, malformed)
    doAssert not inspectReplay(bad).playable
    rejectImport(bad, directory)
  let invalid = recording.clone()
  invalid.actions[0].player = MaxPlayers + 1
  writeFile(bad, encodeReplayFile("galcon", ReplayVersion, TestRecordingData(
    setup: invalid.setup, actions: invalid.actions,
    hashes: invalid.hashes, names: invalid.names
  )))
  doAssert not inspectReplay(bad).playable
  rejectImport(bad, directory)
  var rejected = false
  try:
    discard saveLibraryReplay(invalid, directory)
  except GalconError:
    rejected = true
  doAssert rejected
  rejected = false
  try:
    discard encodeRecording(nil)
  except GalconError:
    rejected = true
  doAssert rejected

  let oversized = root / "oversized.replay"
  block:
    let file = open(oversized, fmWrite)
    defer: file.close()
    file.setFilePos(DefaultMaxReplayBytes.int64)
    file.write("x")
  doAssert not inspectReplay(oversized).playable
  rejected = false
  try:
    discard loadRecording(oversized)
  except GalconError as error:
    rejected = "size limit" in error.msg
  doAssert rejected
  rejected = false
  try:
    discard importReplay(oversized, directory)
  except ReplayError:
    rejected = true
  doAssert rejected
  let blocked = root / "blocked"
  writeFile(blocked, "Not a directory")
  rejected = false
  try:
    discard saveLibraryReplay(recording, blocked / "Replays")
  except ReplayError:
    rejected = true
  doAssert rejected
  doAssert readFile(first) == bytes

testReplayLibrary()
echo "Galcon replay library, version checks, imports, and playback passed."
