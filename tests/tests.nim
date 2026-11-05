import
  std/[os, strutils],
  pixie, bassy,
  polyworld/tapes,
  galcon/[common, physics, worlds, bots, controls, textures, replays, options,
    sessions]

proc duel(seed = 42'i32): World =
  ## Creates a small deterministic map for focused simulation checks.
  newWorld(Setup(
    seed: seed, placement: ClassicPlacement, counts: @[0, 1, 1],
    enemyShipsPassThrough: false, neutralsDontProduce: false
  ))

proc ownerPlanet(world: World, owner: int): int =
  ## Finds a test player's initial home planet.
  for i, planet in world.planets:
    if planet.owner == owner:
      return i
  raise newException(GalconError, "Missing test player")

proc activeCount(world: World): int =
  ## Counts ship bodies independently of the simulation's cached total.
  for body in world.bodies:
    if body.active and body.kind == ShipBody:
      inc result

echo "Original 32 Hz duration flags"
doAssert parseOptions(@["--seconds", "2"]).game.maximumTicks == 64
doAssert parseOptions(@["--seconds=2"]).game.maximumTicks == 64
doAssert parseOptions(@["--minutes=2"]).game.maximumTicks == 3840

echo "Configured rosters, planet totals, and Polyworld controller flags"
block:
  let
    configured = parseOptions(@[
      "--players", "4", "--planets", "40", "--player:3",
      "--bot", Baseline & ":2", "--bot", Baseline
    ])
    session = newSession(configured)
  doAssert session.human == 3
  doAssert session.world.planets.len == 40
  doAssert session.world.setup.players == 4
  doAssert session.brains[3] == nil
  for owner in [1, 2, 4]:
    doAssert session.brains[owner].owner == owner
  doAssert configured.start
  doAssert configured.game.vsync
  let inferred = parseOptions(@["--player", "--bot", Baseline & ":3"])
  doAssert inferred.playerCount == 4
  doAssert newSession(inferred).human == 1
  let alternate = parseOptions(@[
    "--players=4", "--planets:12", "--player", "4"
  ])
  doAssert alternate.setup.counts == @[8, 1, 1, 1, 1]
  doAssert newSession(alternate).human == 4
  let solo = parseOptions(@["--headless", "--bot", Baseline])
  doAssert solo.playerCount == 1
  doAssert newSession(solo).human == 0
  for arguments in [
    @["--players", "17"], @["--planets", "129"],
    @["--players", "4", "--planets", "3"],
    @["--players", "4", "--bot", Baseline & ":2"],
    @["--players", "2", "--player:3"]
  ]:
    var rejected = false
    try:
      discard parseOptions(arguments)
    except GalconError:
      rejected = true
    doAssert rejected
  for players in [1, 2, 4, MaxPlayers]:
    let world = newWorld(configuredSetup(8, Easy, players, MaxPlanets))
    doAssert world.planets.len == MaxPlanets
    for owner in 1 .. players:
      doAssert world.ownerPlanet(owner) >= 0

echo "Multiplayer victory and isolated fixed-state checkpoints"
block:
  let world = newWorld(configuredSetup(7, Easy, 4, 12))
  for planet in world.planets.mitems:
    if planet.owner in [1, 2]:
      planet.owner = 3
  for i in 0 ..< TickRate * 4:
    world.advance()
  doAssert world.winner == -1
  for planet in world.planets.mitems:
    if planet.owner == 4:
      planet.owner = 3
  for i in 0 ..< TickRate * 3:
    world.advance()
  doAssert world.winner == 3
  doAssert world.scores() == @[0, 0, 1, 0]
  let before = world.fingerprint()
  let copied = world.clone()
  copied.planets[0].ships += stock(20)
  copied.planets[0].neighbors[0] = 0
  copied.setup.counts[0] = 0
  copied.bodies[0].x = fixed(1)
  doAssert world.fingerprint() == before
  doAssert world.setup.counts[0] == 8

echo "Original difficulty and seeded maps"
for difficulty in Difficulty:
  let
    a = newWorld(defaultSetup(8, difficulty))
    b = newWorld(defaultSetup(8, difficulty))
  doAssert a.planets.len == 26
  doAssert a.fingerprint() == b.fingerprint()
  doAssert a.planets[a.ownerPlanet(1)].shipCount == 100
  doAssert a.planets[a.ownerPlanet(2)].production == 100
  for i, planet in a.planets:
    doAssert planet.neighbors.len >= 5
    for neighbor in planet.neighbors:
      doAssert i in a.planets[neighbor].neighbors
let training = newWorld(tutorialSetup(1, 2))
doAssert training.planets[training.ownerPlanet(2)].shipCount == 25

echo "Fixed production and original morale timing"
block:
  let world = duel()
  for planet in world.planets.mitems:
    planet.neighbors.setLen(0)
    planet.morale = 100
    planet.production = 100
  world.produce()
  doAssert world.planets[0].ships == stock(100) + 4096
  world.planets[0].ships = stock(10)
  world.planets[0].incoming[1] = 30
  world.planets[0].morale = 50
  world.planets[0].production = 80
  world.planets[0].frame = 0
  world.produce()
  doAssert world.planets[0].realMorale == 25
  doAssert world.planets[0].morale == 49
  doAssert world.planets[0].ships == stock(10) +
    roundedRatio(80 * 49 * FixedScale, 160_000)

echo "Fixed movement, authorized orders, arrivals, and capture"
block:
  let world = duel()
  let
    source = world.ownerPlanet(1)
    target = world.ownerPlanet(2)
  for planet in world.planets.mitems:
    planet.production = 0
  doAssert world.launch(2, source, target, 100) == 0
  doAssert world.launch(1, -1, target, 100) == 0
  doAssert world.launch(1, source, source, 100) == 0
  doAssert world.launch(1, source, target, 1) == 1
  doAssert world.planets[source].shipCount == 99
  doAssert world.planets[target].incoming[1] == 1
  var slot = -1
  for i, body in world.bodies:
    if body.active and body.kind == ShipBody:
      slot = i
  doAssert slot >= 0
  world.planets[target].ships = 0
  world.bodies[slot].x = world.planets[target].x
  world.bodies[slot].y = world.planets[target].y
  world.bodies[slot].hit = true
  world.advance()
  doAssert world.planets[target].owner == 1
  doAssert world.planets[target].shipCount == 1
  doAssert world.planets[target].incoming[1] == 0
  doAssert world.activeShips == 0
  doAssert world.captures == 1
  doAssert world.impacts == 1
  doAssert world.revision == 1
  for i in 1 ..< TickRate * 3:
    world.advance()
  doAssert world.winner == 1
  doAssert world.scores() == @[1, 0]
block:
  let world = World()
  world.bodies[0] = Body(active: true, kind: ShipBody, radius: FixedOne,
    speed: FixedOne, target: -1, weight: 1, x: fixed(10), y: fixed(10),
    targetX: fixed(100), targetY: fixed(10))
  world.moveBodies()
  doAssert world.bodies[0].x == fixed(11)
  doAssert world.bodies[0].y == fixed(10)

echo "BASIC policies cannot control another player or escape their work budget"
block:
  let
    world = duel()
    before = world.planets[0].ships
    brain = newBrain(world, 1, "sent = launch(0, 1, 100)\n" &
      "bad = fraction(0, 2147483647, 2147483647)\n" &
      "bad = ships(-1)\n")
  brain.decide()
  doAssert not brain.failed
  doAssert world.planets[0].ships == before
  doAssert world.activeShips == 0
block:
  let
    world = duel()
    brain = newBrain(world, 1, "while 1\na = 1\nwend\n")
  brain.decide()
  doAssert brain.failed
  doAssert brain.decisions == 0

echo "Multiple selections, any-anchor dragging, and double-click select all"
block:
  let world = newWorld(Setup(seed: 3, counts: @[1, 3, 1]))
  var
    input = Controls(player: 1, percent: 50, anchor: -1, hover: -1)
    owned: seq[int]
  for i, planet in world.planets:
    if planet.owner == 1:
      owned.add i
      world.planets[i].ships = stock(2)
  for index in owned[0 .. 1]:
    let p = world.planets[index]
    input.press(world, p.x.toInt.int, p.y.toInt.int)
    discard input.release(world, p.x.toInt.int, p.y.toInt.int)
  doAssert input.selected[owned[0]] and input.selected[owned[1]]
  let
    anchor = world.planets[world.ownerPlanet(2)]
    target = world.planets[^1]
  input.press(world, anchor.x.toInt.int, anchor.y.toInt.int)
  doAssert input.release(world, target.x.toInt.int, target.y.toInt.int) == 2
  doAssert world.planets[owned[0]].shipCount == 1
  doAssert world.planets[owned[1]].shipCount == 1
  let own = world.planets[owned[0]]
  input.press(world, own.x.toInt.int, own.y.toInt.int, double = true)
  discard input.release(world, own.x.toInt.int, own.y.toInt.int)
  for index in owned:
    doAssert input.selected[index]
  world.planets[owned[0]].owner = 2
  input.clean(world)
  doAssert not input.selected[owned[0]]
  input.press(world, 0, 35)
  discard input.release(world, Width - 1, Height - 35)
  doAssert input.selected[owned[1]] and input.selected[owned[2]]

echo "Rendering cannot consume simulation RNG or erase planet textures"
block:
  let
    world = newWorld(defaultSetup())
    before = world.fingerprint()
    paints = newPaints(world.planets.len)
    planet = world.planets[world.ownerPlanet(1)]
    image = paints.planetImage(planet, 1)
    board = paints.boardImage(world)
  doAssert world.fingerprint() == before
  doAssert image[image.width div 2, image.height div 2].a == 255
  doAssert image[0, 0].a == 0
  var tones: seq[uint32]
  for pixel in image.data:
    if pixel.a == 255:
      let color = cast[uint32](pixel)
      if color notin tones:
        tones.add color
  doAssert tones.len > 30
  doAssert board.width == Width * ArtScale
  doAssert board.height == Height * ArtScale
  for pixel in board.data:
    doAssert pixel.a == 255

echo "Independent BASIC matches and replay reproduce every fixed-state hash"
block:
  let options = parseOptions(@["--headless", "--seed", "77", "--ticks", "1800"])
  options.setup.collisions = AllPairs
  options.setup.placement = ClassicPlacement
  options.setup.enemyShipsPassThrough = false
  options.setup.neutralsDontProduce = false
  let
    a = newSession(options)
    b = newSession(options)
  var recording = Recording(setup: options.setup)
  while not a.done:
    a.brains[2].decide()
    a.brains[1].decide()
    a.world.advance()
    recording.recordTick(a.world)
    if a.world.winner >= 0 or a.world.tick >= a.maximumTicks:
      a.finish()
    b.step()
    doAssert a.world.fingerprint() == b.world.fingerprint()
    doAssert a.world.activeShips == a.world.activeCount()
    for p in a.world.planets:
      doAssert p.ships >= 0
      for incoming in p.incoming:
        doAssert incoming >= 0
  doAssert a.world.captures > 0
  doAssert not a.brains[1].failed and not a.brains[2].failed
  let path = Root / "build" / "test.replay"
  createDir(path.parentDir)
  recording.save(path)
  let loaded = loadRecording(path)
  doAssert readFile(path).startsWith("POLYWORLDREPLAY")
  let playback = newWorld(loaded.setup)
  var cursor = 0
  for i in 0 ..< loaded.hashes.len:
    loaded.replayTick(playback, cursor)
  doAssert playback.fingerprint() == a.world.fingerprint()
  echo "Golden deterministic state: ", a.world.fingerprint()
  doAssert a.world.fingerprint() == 1708288313738586754'u64
  writeFile(Root / "build" / "deterministic.hash", $a.world.fingerprint())
  let damaged = loaded.clone()
  damaged.hashes[0] = damaged.hashes[0] xor 1
  doAssert damaged.hashes[0] != loaded.hashes[0]
  var rejected = false
  try:
    let bad = newWorld(damaged.setup)
    var badCursor = 0
    damaged.replayTick(bad, badCursor)
  except GalconError:
    rejected = true
  doAssert rejected
  removeFile(path)

when defined(nimTypeNames):
  echo "Five-bot headless ticks allocate nothing after initialization"
  block:
    let session = newSession(parseOptions(@[
      "--headless", "--players", "5", "--planets", "26", "--seed", "8",
      "--minutes", "10"
    ]))
    for i in 0 ..< 2048:
      session.step()
    doAssert not session.done
    let before = getMemCounters()
    while not session.done:
      session.step()
    let after = getMemCounters()
    doAssert after[0] == before[0]
    doAssert after[1] == before[1]
    doAssert session.world.captures > 0
    echo "Allocation-free ticks: ", session.world.tick - 2048

echo "Launches require clear space and retain ships when the rim is full"
block:
  let
    world = duel()
    source = world.ownerPlanet(1)
    target = world.ownerPlanet(2)
  for planet in world.planets:
    planet.production = 0
  world.planets[source].ships = stock(10000)
  let
    playback = world.clone()
    sent = world.launch(1, source, target, 10000)
  doAssert sent > 1 and sent < 100
  doAssert world.planets[source].ships == stock(10000 - sent)
  doAssert world.planets[target].incoming[1] == sent
  doAssert world.activeShips == sent
  doAssert playback.launch(1, source, target, sent) == sent
  doAssert world.fingerprint() == playback.fingerprint()
  for i, body in world.bodies:
    if not body.active or body.kind != ShipBody:
      continue
    doAssert body.x >= fixed(ShipRadius)
    doAssert body.x <= fixed(Width - ShipRadius)
    doAssert body.y >= fixed(ShipRadius)
    doAssert body.y <= fixed(Height - ShipRadius)
    for j, other in world.bodies:
      if i == j or not other.active:
        continue
      let distance = int32(body.radius + other.radius).int64
      doAssert lengthSquared(body.x - other.x, body.y - other.y) >=
        distance * distance
  let blocked = world.fingerprint()
  doAssert world.launch(1, source, target, 10000) == 0
  doAssert world.launch(1, source, target, 1) == 0
  doAssert world.fingerprint() == blocked
  var resumed = false
  for tick in 0 ..< 64:
    world.advance()
    playback.advance()
    let launched = world.launch(1, source, target, 10000)
    if launched > 0:
      doAssert playback.launch(1, source, target, launched) == launched
      doAssert world.fingerprint() == playback.fingerprint()
      resumed = true
      break
  doAssert resumed, "Ships must launch again as the surrounding fleet moves."
block:
  let
    world = duel()
    source = world.ownerPlanet(1)
    target = world.ownerPlanet(2)
    body = world.planets[source].body
  world.bodies[body].radius += fixed(ShipRadius * 3)
  let blocked = world.fingerprint()
  doAssert world.launch(1, source, target, 100) == 0
  doAssert world.fingerprint() == blocked

echo "Spatial spawn queries match a full scan for ships and planets"
block:
  let world = newWorld(configuredSetup(9, Easy, 16, 69))
  for owner in 1 .. 16:
    let source = world.ownerPlanet(owner)
    world.planets[source].ships = stock(10000)
    discard world.launch(owner, source, (source + 1) mod 69, 10000)
  for y in countup(-6, Height + 6, 7):
    for x in countup(-6, Width + 6, 7):
      var clear = x >= ShipRadius and x <= Width - ShipRadius and
        y >= ShipRadius and y <= Height - ShipRadius
      for body in world.bodies:
        if not body.active:
          continue
        let distance = int32(fixed(ShipRadius) + body.radius).int64
        if lengthSquared(body.x - fixed(x.int32), body.y - fixed(y.int32)) <
          distance * distance:
            clear = false
            break
      doAssert world.spawnClear(fixed(x.int32), fixed(y.int32)) == clear

echo "Full ship pools preserve replay state after partial or blocked launches"
block:
  let world = duel()
  let source = world.ownerPlanet(1)
  world.planets[source].ships = stock(MaxBodies + 100)
  for i in 0 ..< MaxBodies - 2:
    if world.bodies[i].active:
      continue
    world.bodies[i] = Body(
      active: true,
      kind: ShipBody,
      x: fixed(Width - ShipRadius),
      y: fixed(Height - ShipRadius),
      radius: fixed(ShipRadius)
    )
    world.ships[i] = Ship(owner: 1, target: world.ownerPlanet(2))
    inc world.activeShips
  let playback = world.clone()
  doAssert world.launch(1, source, world.ownerPlanet(2), MaxBodies + 100) == 2
  doAssert playback.launch(1, source, playback.ownerPlanet(2), 2) == 2
  doAssert world.fingerprint() == playback.fingerprint()
  doAssert world.activeShips == MaxBodies - world.planets.len
  let full = world.fingerprint()
  doAssert world.freeBody() == -1
  doAssert world.launch(1, source, world.ownerPlanet(2), 50) == 0
  doAssert world.fingerprint() == full

echo "Live rewind preserves BASIC variables, RNG, and pending human commands"
block:
  let
    configured = parseOptions(@[
      "--players", "4", "--planets", "32", "--ticks", "1200", "--seed", "21"
    ])
    live = newSession(configured)
    reference = newSession(configured)
  for session in [live, reference]:
    session.brains[2] = newBrain(session.liveWorld, 2,
      "counter = counter + 1\n" & BaselineSource)
  for i in 0 ..< 700:
    live.step()
    reference.step()
  let
    home = live.world.ownerPlanet(1)
    target = live.world.ownerPlanet(2)
  doAssert live.world.launch(1, home, target, 7) == 7
  doAssert reference.world.launch(1, home, target, 7) == 7
  let
    frontier = live.world.fingerprint()
    decisions = live.brains[2].decisions
    counter = live.brains[2].runtime.getGlobal("counter")
  for tick in [0'i32, 139, 500, 7, 699]:
    live.seek(tick)
    doAssert live.world.tick == tick
    doAssert live.inHistory
    doAssert not live.canCommand
    if tick > 0:
      doAssert live.world.fingerprint() == live.recording.hashes[tick - 1]
    doAssert live.liveWorld.fingerprint() == frontier
    doAssert live.brains[2].decisions == decisions
    doAssert live.brains[2].runtime.getGlobal("counter") == counter
  live.step()
  doAssert not live.inHistory
  doAssert live.world == live.liveWorld
  doAssert live.canCommand
  doAssert live.world.orders.len == 1
  doAssert live.world.fingerprint() == frontier
  for i in 0 ..< 500:
    live.step()
    reference.step()
    doAssert live.world.fingerprint() == reference.world.fingerprint()
  doAssert live.done
  doAssert live.world.tick == 1200
  live.seek(200)
  doAssert live.done and live.world.tick == 200
  live.returnToLive()
  doAssert live.world.tick == 1200
  doAssert not live.canCommand
  let path = Root / "build" / "multiplayer.replay"
  live.seek(300)
  live.saveRecording(path)
  let playback = newSession(parseOptions(@["--replay", path]))
  doAssert playback.world.setup.players == 4
  doAssert playback.world.planets.len == 32
  playback.seek(1200)
  doAssert playback.world.fingerprint() == reference.world.fingerprint()
  playback.seek(1)
  doAssert playback.world.fingerprint() == live.recording.hashes[0]
  playback.seek(777)
  doAssert playback.world.fingerprint() == live.recording.hashes[776]
  playback.seek(1200)
  removeFile(path)

echo "Version 2 replays retain original physics in the current replay format"
block:
  type
    OriginalSetup = object
      seed: int32
      difficulty: Difficulty
      tutorial: int
      players: int
      counts: seq[int]
    OriginalRecording = object
      setup: OriginalSetup
      orders: seq[Order]
      hashes: seq[uint64]
  let setup = configuredSetup(8, Easy, 5, 26)
  setup.collisions = AllPairs
  setup.placement = ClassicPlacement
  setup.enemyShipsPassThrough = false
  setup.neutralsDontProduce = false
  let world = newWorld(setup)
  var old = OriginalRecording(setup: OriginalSetup(
    seed: 8, players: 5, counts: @[21, 1, 1, 1, 1, 1]
  ))
  for i in 0 ..< 10:
    world.advance()
    old.hashes.add world.fingerprint()
  let
    path = Root / "build" / "version2.replay"
    copied = Root / "build" / "version2-copy.replay"
  saveReplayFile(path, "galcon", 2, old)
  let recording = loadRecording(path)
  recording.save(copied)
  doAssert recording.setup.collisions == AllPairs
  doAssert readFile(copied).replayFileHeader().gameVersion == ReplayVersion
  let upgraded = loadRecording(copied)
  doAssert upgraded.setup.collisions == AllPairs
  doAssert upgraded.hashes == recording.hashes
  removeFile(path)
  removeFile(copied)

echo "Bounded history thinning and old two-player replay compatibility"
block:
  let configured = parseOptions(@["--ticks", "9000", "--planets", "2"])
  let live = newSession(configured)
  live.brains[2] = newBrain(live.world, 2, "idle = 1\n")
  for i in 0 ..< 9000:
    live.step()
  doAssert live.checkpoints.len <= MaxCheckpoints
  doAssert live.checkpointSpacing > CheckpointTicks
  doAssert live.checkpoints[0].world.tick == 0
  live.seek(8127)
  doAssert live.world.fingerprint() == live.recording.hashes[8126]
  live.seek(9000)
  doAssert live.world.tick == 9000
block:
  type
    OldSetup = object
      seed: int32
      difficulty: Difficulty
      tutorial: int
      counts: array[3, int]
    OldRecording = object
      setup: OldSetup
      orders: seq[Order]
      hashes: seq[uint64]
  let setup = defaultSetup()
  setup.collisions = AllPairs
  setup.enemyShipsPassThrough = false
  setup.neutralsDontProduce = false
  let world = newWorld(setup)
  var old = OldRecording(setup: OldSetup(seed: 8, counts: [24, 1, 1]))
  for i in 0 ..< 10:
    world.advance()
    old.hashes.add world.fingerprint()
  let path = Root / "build" / "legacy.replay"
  saveReplayFile(path, "galcon", 1, old)
  let recording = loadRecording(path)
  let playback = newWorld(recording.setup)
  var cursor = 0
  for i in 0 ..< 10:
    recording.replayTick(playback, cursor)
  doAssert playback.fingerprint() == world.fingerprint()
  removeFile(path)

when not defined(headless):
  import test_transports, test_summaries, test_rasters
  testTransports()
  testSummaries()
  testRasters()

import test_spaces, test_chats, test_effects, test_fairness, test_rules, test_bots
testSpaces()
testChats()
testEffects()
testFairness()
testRules()
testBots()

import test_multiplayer
testMultiplayer()

echo "All Galcon checks passed"
