import
  std/[os, tempfiles],
  bassy,
  galcon/[common, worlds, bots, chats, sessions, options, replays]

const CounterPolicy = """
counter = counter + 1
if counter = 1 then
  sent = sendChat(-2, "Fresh match")
end if
"""

proc rejectRematch(session: Session, seed: int32) =
  ## Requires invalid rematch requests to leave the source session untouched.
  var rejected = false
  try:
    discard session.rematch(seed)
  except GalconError:
    rejected = true
  doAssert rejected

proc play(session: Session) =
  ## Completes the short fixture through the ordinary live session loop.
  while not session.done:
    session.step()

proc verify(recording: Recording) =
  ## Requires every recorded chat and order to reproduce its original tick hash.
  let world = newWorld(recording.setup)
  var cursor = 0
  while world.tick < recording.hashes.len.int32:
    recording.replayTick(world, cursor)
  doAssert cursor == recording.actions.len
  doAssert world.fingerprint() == recording.hashes[^1]

proc testLocalRematch*() =
  ## Covers preserved local configuration, fresh bots, and independent replays.
  let root = createTempDir("galcon-local-rematch-", "")
  defer: removeDir(root)

  echo "Local rematch preserves the original setup and starts fresh bot runtimes"
  let
    path = root / "first.replay"
    options = parseOptions(@[
      "--players", "4", "--neutrals-per-player", "5", "--difficulty", "hard",
      "--balanced-map", "true", "--enemy-ships-pass-through", "false",
      "--neutrals-dont-produce", "false", "--ticks", "16", "--record", path
    ])
  options.setup.collisions = Grid32
  options.setup.placement = ClusteredPlacement
  let
    originalSetup = options.setup.clone()
    live = newSession(options,
      @[CounterPolicy, "", CounterPolicy, ""],
      @["Private first", "Captain 空🙂", "Private second", "Vacant"], 2, true)
  doAssert not live.canRematch()
  live.rejectRematch(42)
  doAssert live.chat.sendChat(2, -2, "First game only") > 0
  live.play()
  doAssert live.canRematch()
  doAssert live.brains[1].runtime.getGlobal("counter") == 16
  doAssert live.brains[3].runtime.getGlobal("counter") == 16
  doAssert live.recording.actions.len == 3
  let
    oldBytes = readFile(path)
    oldHash = live.liveWorld.fingerprint()
    oldRecording = live.recording.encodeRecording()
    expected = originalSetup.clone()
  expected.seed = 42
  live.seek(4)
  doAssert live.inHistory
  let next = live.rematch(42)
  doAssert next != live and next.liveWorld != live.liveWorld
  doAssert next.world == next.liveWorld and next.world.tick == 0
  doAssert next.world.setup[] == expected[]
  doAssert next.world.fingerprint() == newWorld(expected).fingerprint()
  doAssert next.human == live.human and next.names == live.names
  doAssert next.maximumTicks == 16 and next.keepHistory == live.keepHistory
  doAssert next.recordPath.len == 0
  doAssert next.brains[2] == nil and next.brains[4] == nil
  doAssert next.chat != live.chat and next.world.chatCount == 0
  doAssert next.recording != live.recording and next.recording.actions.len == 0
  doAssert next.recording.hashes.len == 0
  doAssert next.checkpoints.len == 1 and next.checkpoints[0].world.tick == 0
  for owner in [1, 3]:
    doAssert next.brains[owner] != live.brains[owner]
    doAssert next.brains[owner].runtime != live.brains[owner].runtime
    doAssert next.brains[owner].decisions == 0
    doAssert next.chat.inboxes[owner].count == 0
  next.step()
  for owner in [1, 3]:
    doAssert not next.brains[owner].failed, next.brains[owner].error
    doAssert next.brains[owner].runtime.getGlobal("counter") == 1
    doAssert live.brains[owner].runtime.getGlobal("counter") == 16
  next.play()
  doAssert next.recording.actions.len == 2
  doAssert live.liveWorld.fingerprint() == oldHash
  doAssert live.recording.encodeRecording() == oldRecording
  doAssert readFile(path) == oldBytes
  doAssert live.world.tick == 4
  live.recording.verify()
  next.recording.verify()

  echo "Repeated rematches retain rules without borrowing a menu or replay setup"
  let third = next.rematch(43)
  expected.seed = 43
  doAssert third.world.setup[] == expected[]
  doAssert third.human == 2 and third.names == live.names
  doAssert third.maximumTicks == 16
  third.world.setup.counts[0] = 0
  doAssert next.world.setup.counts == originalSetup.counts
  doAssert live.world.setup.counts == originalSetup.counts
  live.rejectRematch(originalSetup.seed)
  live.rejectRematch(-1)
  doAssert not Session(nil).canRematch()
  Session(nil).rejectRematch(42)
  live.networked = true
  doAssert not live.canRematch()
  live.rejectRematch(42)
  live.networked = false
  let playback = newSession(parseOptions(@["--replay", path]))
  playback.play()
  doAssert playback.done and not playback.canRematch()
  playback.rejectRematch(42)

  echo "CLI rematches reuse private policy contents even after their files vanish"
  let privatePath = root / "Private policy.bas"
  writeFile(privatePath, CounterPolicy)
  let cli = newSession(parseOptions(@[
    "--players", "3", "--player", "2", "--name", "Commander",
    "--bot", privatePath & ":2", "--ticks", "3"
  ]))
  removeFile(privatePath)
  cli.play()
  let cliNext = cli.rematch(71)
  doAssert cliNext.names == cli.names and cliNext.human == 2
  doAssert cliNext.names[1] == "Private policy"
  doAssert cliNext.names[2] == "Commander"
  doAssert cliNext.names[3] == "Private policy"
  cliNext.play()
  for owner in [1, 3]:
    doAssert not cliNext.brains[owner].failed, cliNext.brains[owner].error
    doAssert cliNext.brains[owner].runtime.getGlobal("counter") == 3
  doAssert cliNext.recording.actions.len == 2

  echo "Headless default bots keep their controllers and history setting"
  let headless = newSession(parseOptions(@["--headless", "--ticks", "1"]))
  headless.play()
  let headlessNext = headless.rematch(72)
  doAssert not headlessNext.keepHistory and headlessNext.human == 0
  doAssert headlessNext.names == headless.names
  headlessNext.play()
  for owner in 1 .. headlessNext.world.setup.players:
    doAssert headlessNext.brains[owner] != nil
    doAssert not headlessNext.brains[owner].failed
    doAssert headlessNext.brains[owner].decisions == 1
  doAssert headlessNext.recording.hashes.len == 0

testLocalRematch()
echo "Galcon local rematch configuration, private bots, and replay isolation passed."
