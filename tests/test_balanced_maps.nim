import std/[algorithm, base64, os, sets]
import jsony, polyworld/tapes
import galcon/[common, worlds, replays, options, multiplayer]

proc quadrant(p: Planet): int =
  int(p.x >= fixed(Width div 2)) + 2 * int(p.y >= fixed(Height div 2))

proc testConfig() =
  let config = multiplayer.MatchConfig(players: 4, planets: 32)
  doAssert config.balancedMap, "New lobbies default to balanced maps"
  doAssert parseConfig(config.toJson()).balancedMap
  doAssert config.matchOptions().setup.balancedMap
  config.balancedMap = false
  doAssert not parseConfig(config.toJson()).balancedMap
  doAssert not config.matchOptions().setup.balancedMap
  doAssert not configuredSetup(8, Easy, 4, 32).balancedMap
  doAssert not parseConfig("{\"players\":4,\"planets\":32}").balancedMap,
    "Legacy room payloads without the flag retain the old generator"
  doAssert identity().gameplay == ReplayVersion.uint32
  doAssert parseOptions(@["--balanced-map", "true"]).setup.balancedMap
  doAssert not parseOptions(@["--balanced-map", "false"]).setup.balancedMap
  for payload in ["{\"players\":4,\"planets\":32,\"balancedMap\":null}",
      "{\"players\":4,\"planets\":32,\"balancedMap\":1}"]:
    var rejected = false
    try: discard parseConfig(payload)
    except GalconError: rejected = true
    doAssert rejected, "Map mode must be an explicit boolean, not null or a number"

proc testMaps() =
  for players in 2 .. MaxPlayers:
    for count in max(2, players) .. MaxPlanets:
      for seed in [0'i32, 17'i32]:
        let setup = configuredSetup(seed, Easy, players, count)
        setup.balancedMap = true
        let world = newWorld(setup)
        doAssert world.planets.len == count
        type Profile = tuple[radius, production, defenders: int]
        var profiles, neutrals: array[4, seq[Profile]]
        var homeCounts: array[4, int]
        var homes: array[MaxPlayers + 1, int]
        for i, p in world.planets:
          let profile = (p.radius, p.production, p.shipCount)
          profiles[p.quadrant()].add profile
          doAssert world.bodies[p.body].radius == fixed(p.radius.int32),
            "Collision radii follow the balanced planet size"
          doAssert p.x >= fixed((8 + p.radius).int32)
          doAssert p.x <= fixed((Width - 8 - p.radius).int32)
          doAssert p.y >= fixed((40 + p.radius).int32)
          doAssert p.y <= fixed((Height - 40 - p.radius).int32)
          if p.owner > 0:
            inc homes[p.owner]
            inc homeCounts[p.quadrant()]
            doAssert p.production == 100 and p.shipCount == 100
          else:
            neutrals[p.quadrant()].add profile
            doAssert p.morale == 50 and p.realMorale == 50,
              "Matching home sizes must not give neutral planets home morale"
          for j in 0 ..< i:
            let other = world.planets[j]
            let dx = (p.x.toInt - other.x.toInt).int64
            let dy = (p.y.toInt - other.y.toInt).int64
            let gap = (p.radius + other.radius + PlanetGap).int64
            doAssert dx * dx + dy * dy >= gap * gap
            if p.owner > 0 and other.owner > 0:
              doAssert dx * dx + dy * dy >= 80 * 80,
                "Homes remain separated even with sixteen players"
        for owner in 1 .. players: doAssert homes[owner] == 1
        var minimum = count
        var maximum = 0
        for q in 0 ..< 4:
          profiles[q].sort()
          neutrals[q].sort()
          minimum = min(minimum, profiles[q].len)
          maximum = max(maximum, profiles[q].len)
        doAssert maximum - minimum <= 1, "Quadrant populations differ by at most one"
        var fullGroups: seq[Profile]
        for q in 0 ..< 4:
          if profiles[q].len == minimum:
            if fullGroups.len == 0: fullGroups = profiles[q]
            else: doAssert profiles[q] == fullGroups
        for q in 0 ..< 4:
          if profiles[q].len > minimum:
            var matched = false
            for extra in 0 ..< profiles[q].len:
              var withoutExtra = profiles[q]
              withoutExtra.delete(extra)
              if withoutExtra == fullGroups: matched = true
            doAssert matched,
              "Only the unavoidable remainder may differ in size, production or defenders"
        if count mod 4 == 0:
          for q in 1 ..< 4:
            doAssert profiles[q] == profiles[0],
              "Sizes, production and defending ships match across quadrants"
        for q in 0 ..< 4:
          for r in 0 ..< q:
            doAssert abs(homeCounts[q] - homeCounts[r]) <= 1,
              "Home counts are balanced between quadrants"
            if profiles[q].len == profiles[r].len and homeCounts[q] == homeCounts[r]:
              doAssert neutrals[q] == neutrals[r],
                "Quadrants with equal home counts have identical neutral capture costs"
        doAssert world.fingerprint() == newWorld(setup.clone()).fingerprint()
  for players in [2, 4]:
    let setup = configuredSetup(8, Easy, players, 32)
    setup.balancedMap = true
    let world = newWorld(setup)
    var quadrants: seq[int]
    for p in world.planets:
      if p.owner > 0:
        quadrants.add p.quadrant()
    if players == 2: doAssert (quadrants[0] xor quadrants[1]) == 3

proc testMapVariation() =
  ## Sample a seed family without prescribing any particular planet position.
  var homeX, homeY: HashSet[int]
  var interiorHomes, variedMaps: int
  for seed in 0 ..< 24:
    let setup = configuredSetup(seed.int32, Easy, 4, 32)
    setup.balancedMap = true
    let world = newWorld(setup)
    var xs, ys: HashSet[int]
    var nearestDistances: HashSet[int64]
    for i, p in world.planets:
      let x = p.x.toInt.int
      let y = p.y.toInt.int
      xs.incl x
      ys.incl y
      if p.owner > 0:
        homeX.incl min(x, Width - x)
        homeY.incl min(y, Height - y)
        if x > 96 and x < Width - 96 and y > 112 and y < Height - 112:
          inc interiorHomes
      var nearest = int64.high
      for j, other in world.planets:
        if i == j: continue
        let dx = (x - other.x.toInt).int64
        let dy = (y - other.y.toInt).int64
        nearest = min(nearest, dx * dx + dy * dy)
      nearestDistances.incl nearest
    if xs.len > 16 and ys.len > 16 and nearestDistances.len > 8:
      inc variedMaps
  doAssert interiorHomes >= 12, "Home planets also occupy the quadrant interiors"
  doAssert homeX.len > 24 and homeY.len > 24,
    "Different seeds vary home locations in both dimensions"
  doAssert variedMaps >= 20,
    "Planet coordinates and neighbor distances should not form a rigid lattice"

proc testReplay() =
  for balanced in [false, true]:
    let config = multiplayer.MatchConfig(players: 5, planets: 69, balancedMap: balanced)
    let setup = config.matchOptions().setup
    let world = newWorld(setup)
    let peer = newWorld(parseConfig(config.toJson()).matchOptions().setup)
    let tape = Recording(setup: setup.clone())
    doAssert tape.clone().setup.balancedMap == balanced
    var source, target: int
    for i, p in world.planets:
      if p.owner == 1: source = i
      elif p.owner == 2: target = i
    for tick in 0 ..< 96:
      if tick == 0:
        doAssert world.send(1, source, target, 50) == peer.send(1, source, target, 50)
      world.advance()
      peer.advance()
      tape.recordTick(world)
      doAssert world.fingerprint() == peer.fingerprint()
    let path = Root / "build/balanced-roundtrip.replay"
    tape.save(path)
    doAssert readFile(path).replayFileHeader().gameVersion == ReplayVersion
    let loaded = loadRecording(path)
    doAssert loaded.setup.balancedMap == balanced, "Map mode survives replay serialization"
    doAssert not loaded.setup.legacyBalancedMap,
      "New recordings retain varied placement when saved and loaded"
    doAssert loaded.hashes == tape.hashes
    let playback = newWorld(loaded.setup)
    var cursor = 0
    for tick in 0 ..< loaded.hashes.len: loaded.replayTick(playback, cursor)
    doAssert playback.fingerprint() == world.fingerprint()
    removeFile(path)

proc testLegacyReplay() =
  type
    OldSetup = object
      seed: int32
      difficulty: Difficulty
      tutorial, players: int
      counts: seq[int]
    Rules = object
      setup: OldSetup
      collisions: CollisionKind
      placement: Placement
      enemyShipsPassThrough, neutralsDontProduce: bool
      orders: seq[Order]
      hashes: seq[uint64]
      chats: seq[ChatMessage]
      names: seq[string]
    Pending = object
      rules: Rules
      legacyLaunches: bool
  let setup = configuredSetup(17, Easy, 4, 32)
  setup.legacyMovement = true
  let world = newWorld(setup)
  let recording = Recording(setup: setup)
  for tick in 0 ..< 32:
    world.advance()
    recording.recordTick(world)
  let path = Root / "build/balanced-legacy13.replay"
  let copy = Root / "build/balanced-legacy14.replay"
  saveReplayFile(path, "galcon", 13, Pending(rules: Rules(
    setup: OldSetup(seed: setup.seed, difficulty: setup.difficulty,
      players: setup.players, counts: setup.counts),
    collisions: setup.collisions, placement: setup.placement,
    enemyShipsPassThrough: setup.enemyShipsPassThrough,
    neutralsDontProduce: setup.neutralsDontProduce,
    hashes: recording.hashes)))
  let loaded = loadRecording(path)
  doAssert not loaded.setup.balancedMap
  doAssert not loaded.setup.legacyLaunches
  loaded.save(copy)
  for file in [path, copy]:
    let tape = loadRecording(file)
    doAssert not tape.setup.balancedMap
    let playback = newWorld(tape.setup)
    var cursor = 0
    for tick in 0 ..< tape.hashes.len: tape.replayTick(playback, cursor)
    doAssert playback.fingerprint() == world.fingerprint()
    removeFile(file)

proc testLegacyBalancedReplay() =
  ## Captured before varied placement: v20, seed17/Easy/4 players/32 planets.
  const
    InitialHash = 4588863931359644885'u64
    FinalHash = 12458984394461214843'u64
    Fixture =
      "UE9MWVdPUkxEUkVQTEFZAgAUAAYAZ2FsY29uEQAAAAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAUAAAAA" &
      "AAAAHAAAAAAAAAABAAAAAAAAAAEAAAAAAAAAAQAAAAAAAAABAAAAAAAAAAIAAAAAAAAAAAAAAAAAAAAB" &
      "AQAAAAAAAAAAIAAAAAAAAAB66R69JhkHZvwONDDdDD/v698lpSwi/iF3flAQZxrGSp0JsW0u6MDoUPvx" &
      "JFcg7Bq6M6Gi/koKNeJlc7CxanugJAus6xa9ua68F3kqBhiASJBUNARmNqTtMukjT9cvu/tq8H9iU1Dj" &
      "9rbrxrfN+N3aB9vTU/HgFWB5qJxLNN+c/ZHudOafqLj7p+iCyi6dmz8N4W6lsIgtjs/kSbKOiyjPmZtt" &
      "5u9Ew7sNn3rWzdPe2JWfyoDHSZHyYvN0DLCq6JlEju9pYmz9/0A+hBxnIssZdZbnpKI+RFHwAxG39n/f" &
      "2oXlySG8ESCKj+8v/B0t6jbX3a0Dpy0Rknv4/tVLNOesAAAAAAAAAAAAAAAAAAAAAAABAAAAAAAA"
  let path = Root / "build/balanced-legacy20.replay"
  let copy = Root / "build/balanced-legacy-upgraded.replay"
  writeFile(path, base64.decode(Fixture))
  doAssert readFile(path).replayFileHeader().gameVersion == 20
  let loaded = loadRecording(path)
  doAssert loaded.setup.balancedMap and loaded.setup.legacyBalancedMap
  doAssert loaded.setup.clone().legacyBalancedMap
  loaded.save(copy)
  for file in [path, copy]:
    let tape = loadRecording(file)
    doAssert tape.setup.balancedMap and tape.setup.legacyBalancedMap
    let world = newWorld(tape.setup)
    doAssert world.fingerprint() == InitialHash,
      "Historical balanced maps retain their initial positions and RNG state"
    var cursor = 0
    for tick in 0 ..< tape.hashes.len: tape.replayTick(world, cursor)
    doAssert tape.hashes.len == 32 and world.fingerprint() == FinalHash,
      "Old balanced replays retain exact playback after upgrading the file"
    removeFile(file)

proc testLegacyFingerprints() =
  # Captured from HEAD 135afd6 using its common/worlds/physics/spaces sources.
  const Expected = [
    [9513823520648979471'u64, 11798626085132050013'u64, 9466632345067519230'u64],
    [15180347488718544099'u64, 16481180551950526177'u64, 18202625695735639318'u64],
    [8459055772431598712'u64, 523097342836221721'u64, 13194352398586763394'u64]]
  for s, seed in [0'i32, 17'i32, 98'i32]:
    for p, placement in [RandomPlacement, ClassicPlacement, ClusteredPlacement]:
      let setup = configuredSetup(seed, Easy, 4, 32)
      setup.balancedMap = false
      setup.legacyMovement = true
      setup.placement = placement
      doAssert newWorld(setup).fingerprint() == Expected[s][p],
        "Unchecked maps preserve historical positions, RNG state and complete hashes"

proc testBalancedMaps*() =
  testLegacyFingerprints()
  testConfig()
  testMaps()
  testMapVariation()
  testReplay()
  testLegacyReplay()
  testLegacyBalancedReplay()

when isMainModule:
  testBalancedMaps()
  echo "Balanced configuration, quadrant profiles, varied home locations, seeds and passages passed"
