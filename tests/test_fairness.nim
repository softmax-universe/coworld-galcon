import
  std/[os, strutils],
  polyworld/tapes,
  galcon/[common, worlds, replays, options, sessions]

proc testFairness*() =
  ## Checks equal resources, seeded random starts, and replay verification.
  echo "Sixteen-player clusters have one home and five nearby neutrals each"
  let crowded = parseOptions(@[
    "--headless", "--players", "16", "--neutrals-per-player", "5",
    "--ticks", "128", "--record", Root / "build" / "clusters.replay"
  ])
  let crowdedWorld = newWorld(crowded.setup)
  doAssert crowdedWorld.planets.len == 96
  doAssert crowded.setup.placement == ClusteredPlacement
  doAssert crowded.setup.counts[0] == 80
  for owner in 1 .. MaxPlayers:
    var
      homes = 0
      nearby = 0
      home: Planet
    for planet in crowdedWorld.planets:
      if planet.owner == owner:
        inc homes
        home = planet
    doAssert homes == 1
    for planet in crowdedWorld.planets:
      if planet.owner == 0 and
        hypot(planet.x - home.x, planet.y - home.y) < fixed(45):
          inc nearby
      doAssert planet.radius <= 11
    doAssert nearby == 5
  let crowdedSession = newSession(crowded)
  while not crowdedSession.done:
    crowdedSession.step()
  let crowdedReplay = newSession(parseOptions(@[
    "--headless", "--replay", crowded.game.recordPath
  ]))
  crowdedReplay.seek(crowdedSession.world.tick)
  doAssert crowdedReplay.world.fingerprint() ==
    crowdedSession.world.fingerprint()
  removeFile(crowded.game.recordPath)
  echo "Sixty-nine planets scatter sixteen homes with compact radii"
  let scattered = parseOptions(@[
    "--headless", "--players", "16", "--planets", "69"
  ])
  doAssert scattered.setup.placement == RandomPlacement
  doAssert scattered.setup.counts[0] == 53
  let scatteredWorld = newWorld(scattered.setup)
  doAssert scatteredWorld.planets.len == 69
  for owner in 1 .. MaxPlayers:
    doAssert scattered.setup.counts[owner] == 1
  for planet in scatteredWorld.planets:
    doAssert planet.radius <= 11
  echo "Random maps leave fleet passages between every pair of planet edges"
  for count in [26, 52, 53, 69, 96, MaxPlanets]:
    for seed in 0 ..< 32:
      let setup = configuredSetup(seed.int32, Easy, MaxPlayers, count)
      let world = newWorld(setup)
      doAssert world.fingerprint() == newWorld(setup).fingerprint()
      for i, planet in world.planets:
        doAssert planet.x >= fixed((8 + planet.radius).int32)
        doAssert planet.x <= fixed((Width - 8 - planet.radius).int32)
        doAssert planet.y >= fixed((40 + planet.radius).int32)
        doAssert planet.y <= fixed((Height - 40 - planet.radius).int32)
        doAssert world.bodies[planet.body].x == planet.x
        doAssert world.bodies[planet.body].y == planet.y
        for j in 0 ..< i:
          let
            other = world.planets[j]
            dx = (planet.x.toInt - other.x.toInt).int64
            dy = (planet.y.toInt - other.y.toInt).int64
            distance = (planet.radius + other.radius + PlanetGap).int64
          doAssert dx * dx + dy * dy >= distance * distance
  echo "Competitive presets give every faction equal planet counts"
  for difficulty in Difficulty:
    for players in [2, 5, MaxPlayers]:
      for count in [players, min(MaxPlanets, players + 3), MaxPlanets]:
        let setup = configuredSetup(8, difficulty, players, count)
        var total = setup.counts[0]
        for owner in 1 .. players:
          doAssert setup.counts[owner] == setup.counts[1]
          total += setup.counts[owner]
        doAssert total == count
  echo "Every color can start in every quadrant and planet slot"
  var
    quadrants: array[MaxPlayers + 1, array[4, bool]]
    slots: array[MaxPlayers + 1, array[26, bool]]
  for seed in 0 ..< 256:
    let world = newWorld(configuredSetup(seed.int32, Easy, 5, 26))
    for i, planet in world.planets:
      if planet.owner == 0:
        continue
      doAssert planet.production == 100
      doAssert planet.shipCount == 100
      doAssert planet.realShips == stock(100)
      doAssert planet.morale == 100
      let quadrant = int(planet.x >= fixed(Width div 2)) +
        2 * int(planet.y >= fixed(Height div 2))
      quadrants[planet.owner][quadrant] = true
      slots[planet.owner][i] = true
  for owner in 1 .. 5:
    for seen in quadrants[owner]:
      doAssert seen
    for seen in slots[owner]:
      doAssert seen
  let
    first = newWorld(configuredSetup(42, Easy, 5, 26))
    repeated = newWorld(configuredSetup(42, Easy, 5, 26))
    different = newWorld(configuredSetup(43, Easy, 5, 26))
  doAssert first.fingerprint() == repeated.fingerprint()
  doAssert first.fingerprint() != different.fingerprint()
  echo "Ratings results contain only victory and defeat"
  first.winner = 3
  doAssert first.scores() == @[0, 0, 1, 0, 0]
  for planet in first.planets:
    planet.ships = stock(1_000_000)
    planet.owner = 1
  doAssert first.scores() == @[0, 0, 1, 0, 0]
  first.winner = 0
  doAssert first.scores() == @[0, 0, 0, 0, 0]
  echo "Current files retain explicit placement and reject other versions"
  let setup = configuredSetup(8, Easy, 5, 26)
  setup.placement = ClassicPlacement
  setup.enemyShipsPassThrough = false
  setup.neutralsDontProduce = false
  let world = newWorld(setup)
  let recording = Recording(setup: setup)
  for i in 0 ..< 64:
    world.advance()
    recording.recordTick(world)
  let
    path = Root / "build" / "version6.replay"
    currentPath = Root / "build" / "classic-current.replay"
  saveReplayFile(path, "galcon", 6, "unsupported")
  var rejected = false
  try:
    discard loadRecording(path)
  except GalconError as error:
    rejected = error.msg.contains("version")
  doAssert rejected
  recording.save(currentPath)
  let loaded = loadRecording(currentPath)
  doAssert loaded.setup.placement == ClassicPlacement
  doAssert loaded.hashes == recording.hashes
  let playback = newWorld(loaded.setup)
  var cursor = 0
  for i in 0 ..< loaded.hashes.len:
    loaded.replayTick(playback, cursor)
  doAssert playback.fingerprint() == world.fingerprint()
  doAssert readFile(currentPath).replayFileHeader().gameVersion == ReplayVersion
  removeFile(path)
  removeFile(currentPath)
