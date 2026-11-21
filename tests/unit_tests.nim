import
  std/strutils,
  polyworld/[cli, tapes],
  galcon/[chats, common, multiplayer, options, replays, worlds],
  test_bots, test_flocking,
  test_cosmetic_ready_authority as _,
  test_replay_library as _, test_recording_library as _

echo "Shared screenshot command-line spellings and defaults"
block:
  doAssert GameOptions().capture.frames == 30
  for arguments in [
    @["--screenshot", "nested/galcon.png", "--frames", "3",
      "--windowSize", "800x600"],
    @["--screenshot=nested/galcon.png", "--frames=3",
      "--windowSize=800x600"],
    @["--screenshot:nested/galcon.png", "--frames:3",
      "--windowSize:800x600"]
  ]:
    var
      options: GameOptions
      index = 0
    while index < arguments.len:
      doAssert options.takeCommonFlag(arguments, index, arguments[index])
      inc index
    doAssert options.capture.path == "nested/galcon.png"
    doAssert options.capture.frames == 3
    doAssert options.capture.captureRequested()
    doAssert options.windowWidth == 800 and options.windowHeight == 600

echo "Command-line settings and bounded room configuration"
block:
  let configured = parseOptions(@[
    "--players", "3", "--planets", "9", "--seed", "19",
    "--seconds", "2"
  ])
  doAssert configured.setup.players == 3
  doAssert configured.setup.counts == @[6, 1, 1, 1]
  doAssert configured.setup.seed == 19
  doAssert configured.game.maximumTicks == TickRate * 2
  doAssert parseOptions(@["--minutes=1"]).game.maximumTicks == TickRate * 60
  let config = parseConfig("{\"players\":3,\"planets\":9,\"seed\":19}")
  doAssert config.matchOptions().setup.counts == configured.setup.counts
  for payload in [
    "null", "not json", "{\"players\":1}", "{\"players\":17}",
    "{\"players\":3,\"planets\":2}", "{\"maximumTicks\":0}",
    "{\"seed\":-1}"
  ]:
    var rejected = false
    try:
      discard parseConfig(payload)
    except GalconError:
      rejected = true
    doAssert rejected

echo "Current replay identity and strict format rejection"
block:
  let game = identity()
  doAssert game.game == "galcon"
  doAssert game.gameplay == ReplayVersion.uint32
  doAssert game.protocol == NetworkProtocol
  for version in 1'u16 .. ReplayVersion + 1:
    if version == ReplayVersion:
      continue
    var rejected = false
    try:
      discard decodeRecording(encodeReplayFile("galcon", version, "unused"))
    except GalconError as error:
      rejected = "version" in error.msg
    doAssert rejected, "Other versions must be rejected before payload decoding"

echo "Human seat ownership and queued claim commands"
block:
  let client = RoomClient(identity: identity(), participant: 7,
    connected: true, welcomed: true,
    snapshot: RoomMessage(kind: RoomState, participant: 9, seats: @[
      Seat(owner: 7, kind: HumanSeat), Seat(),
      Seat(owner: 9, kind: HumanSeat)
    ]))
  doAssert client.snapshot.humanSeat(7) == 1
  doAssert client.snapshot.humanSeat(9) == 3
  doAssert client.snapshot.humanSeat(0) == 0
  doAssert client.snapshot.humanSeat(8) == 0
  client.claimHuman(1)
  doAssert client.outgoing.len == 2
  doAssert decode(client.outgoing[0]).kind == ReleaseSeat
  doAssert decode(client.outgoing[0]).seat == 0
  doAssert decode(client.outgoing[1]).kind == ClaimSeat
  doAssert decode(client.outgoing[1]).seat == 1
  var rejected = false
  try:
    client.claimHuman(2)
  except RoomsError:
    rejected = true
  doAssert rejected and client.outgoing.len == 2

echo "Authorized orders and bounded chat preserve deterministic state"
block:
  let world = newWorld(configuredSetup(19, Easy, 2, 6))
  var source, target = -1
  for index, planet in world.planets:
    if planet.owner == 1:
      source = index
    elif planet.owner == 2:
      target = index
  doAssert source >= 0 and target >= 0
  let before = world.fingerprint()
  for order in [(2, source, target, 10), (1, -1, target, 10),
      (1, source, source, 10), (1, source, target, 0)]:
    doAssert world.launch(order[0], order[1], order[2], order[3]) == 0
    doAssert world.fingerprint() == before
  let ships = world.planets[source].shipCount
  doAssert world.send(1, source, target, 25) == ships div 4
  doAssert world.planets[source].shipCount == ships - ships div 4
  doAssert world.pendingLaunchCount == 1 and world.activeShips == 0
  let chat = newChatHub(world)
  doAssert chat.sendChat(1, -1, "Team") == 0
  doAssert chat.sendChat(1, 2, "Private") == 0
  doAssert chat.sendChat(0, -2, "Invalid player") == 0
  doAssert chat.sendChat(1, -2, "\xFF") == 0
  doAssert chat.sendChat(1, -2, " ") == 0
  doAssert chat.sendChat(1, -2, repeat('a', MaxChatBytes)) == 0
  doAssert chat.sendChat(1, -2, " Go\nnow ") == 2
  doAssert chat.sendChat(1, -2, "Duplicate") == 0
  doAssert world.chats[world.chatFirst].chatText() == "Go now"
  let copy = world.clone()
  for tick in 0 ..< 32:
    world.advance()
    copy.advance()
    doAssert world.fingerprint() == copy.fingerprint()

testBots()
testFlocking()
echo "All Galcon unit tests passed"
