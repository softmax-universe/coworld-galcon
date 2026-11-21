import
  std/[os, tempfiles],
  polyworld/cli,
  galcon/[common, options, replays, sessions]

proc rejected(arguments: seq[string]): bool =
  ## Checks invalid launch arguments without starting a game or process.
  try:
    discard parseOptions(arguments)
  except CliError, GalconError:
    result = true

echo "Galcon uses the shared value spellings and its actual simulation rate"
block:
  let defaults = parseOptions(@[])
  doAssert defaults.game.speed == 1 and defaults.game.vsync
for arguments in [
  @["--bot", "one.bas:2", "--bots", "two.bas", "--seed", "19",
    "--seconds", "2", "--record", "nested/match.replay", "--verbose", "true"],
  @["--bot=one.bas:2", "--bots=two.bas", "--seed=19", "--seconds=2",
    "--record=nested/match.replay", "--verbose=true"],
  @["--bot:one.bas:2", "--bots:two.bas", "--seed:19", "--seconds:2",
    "--record:nested/match.replay", "--verbose:true"]
]:
  let parsed = parseOptions(arguments)
  doAssert parsed.game.botGroups.botCount == 3
  doAssert parsed.game.botGroups[0].path == "one.bas"
  doAssert parsed.game.botGroups[0].count == 2
  doAssert parsed.game.botGroups[1].path == "two.bas"
  doAssert parsed.playerCount == 3
  doAssert parsed.game.seed == 19
  doAssert parsed.game.maximumTicks == 2 * TickRate
  doAssert parsed.game.seconds == 2
  doAssert parsed.game.recordPath == "nested/match.replay"
  doAssert parsed.game.verbose and parsed.start
for arguments in [@["--minutes", "1"], @["--minutes=1"], @["--minutes:1"]]:
  let parsed = parseOptions(arguments)
  doAssert parsed.game.maximumTicks == 60 * TickRate
  doAssert parsed.game.seconds == 60
doAssert parseOptions(@["--headless", "--headless-tick-rate", "24"])
  .game.headlessTickRate == 24
for arguments in [@["--replay", "saved.replay"],
  @["--replay=saved.replay"], @["--replay:saved.replay"]]:
  let parsed = parseOptions(arguments)
  doAssert parsed.game.replayPath == "saved.replay"
  doAssert parsed.start

echo "Unsupported capabilities and conflicting replay modes are rejected"
for arguments in [
  @["--replay", "--seed", "1"], @["--record="],
  @["--llm-mode", "barrier"], @["--llm-mode:async"],
  @["--replay", "saved.replay", "--record", "copy.replay"],
  @["--replay", "saved.replay", "--bot", "one.bas"],
  @["--player", "Alice"], @["--bot", "one.bas:0"],
  @["--name", "Alice\nBob"], @["--name", "\xFF"],
  @["--bot", "one.bas:9999999999999999999999999999999"],
  @["--headless", "--server", "ws://localhost:9911/ws"],
  @["--headless", "--room", "ABCD"]
]:
  doAssert rejected(arguments), $arguments

when not defined(headless):
  echo "A human slot and display name have distinct common options"
  doAssert rejected(@["--headless-tick-rate", "24"])
  doAssert rejected(@["--headless-tick-rate=0"])
  for network in [@["--server", "ws://localhost:9911/ws"], @["--room", "ABCD"]]:
    for local in [@["--bot", "one.bas:2"], @["--player"],
      @["--replay", "saved.replay"]]:
      doAssert rejected(network & local)
    let configured = parseOptions(network &
      @["--record", "match.replay", "--name", "Alice"])
    doAssert configured.game.recordPath == "match.replay"
    doAssert configured.game.playerName == "Alice"
    doAssert not configured.start
  for arguments in [
    @["--replay", "saved.replay", "--play", "false", "--speed", "3"],
    @["--replay=saved.replay", "--play=false", "--speed=3"],
    @["--replay:saved.replay", "--play:false", "--speed:3"]
  ]:
    let parsed = parseOptions(arguments)
    doAssert parsed.game.pauseOnStart and parsed.game.speed == 3
  for arguments in [
    @["--player", "2", "--name", "Alice", "--bot", "one.bas:2"],
    @["--player=2", "--name=Alice", "--bots=one.bas:2"],
    @["--player:2", "--name:Alice", "--bots:one.bas:2"]
  ]:
    let parsed = parseOptions(arguments)
    doAssert parsed.game.playerSlot == 2 and parsed.playerCount == 3
    doAssert parsed.game.playerName == "Alice" and parsed.name == "Alice"
  let named = parseOptions(@["--player", "--name", "Alice"])
  named.setup.counts = @[0, 1, 1]
  let session = newSession(named)
  doAssert session.human == 1
  doAssert session.names[1] == "Alice"
  doAssert session.recording.names[1] == "Alice"
  for arguments in [
    @["--server", "ws://localhost:9911/ws", "--room", "ABCD"],
    @["--server=ws://localhost:9911/ws", "--room=ABCD"],
    @["--server:ws://localhost:9911/ws", "--join:ABCD"]
  ]:
    let parsed = parseOptions(arguments)
    doAssert parsed.server == "ws://localhost:9911/ws"
    doAssert parsed.join == "ABCD"

echo "A record destination persists into menu sessions without starting one"
block:
  let root = createTempDir("galcon-cli-record-", "")
  defer: removeDir(root)
  let
    path = root / "new folder" / "match.replay"
    launch = parseOptions(@["--record", path])
    menu = parseOptions(@["--players", "2"])
  doAssert not launch.start
  menu.headless = false
  let session = newSession(menu, @["", ""], @["Alice", "Bob"], 1, true)
  session.applyLaunchOptions(launch.game)
  session.finish()
  doAssert fileExists(path)
  let recording = loadRecording(path)
  doAssert recording.names == @["", "Alice", "Bob"]
  doAssert recording.hashes.len == 0
  let playback = newSession(parseOptions(@["--replay", path]))
  playback.applyLaunchOptions(launch.game)
  doAssert playback.recordPath.len == 0

echo "Galcon CLI tests passed"
