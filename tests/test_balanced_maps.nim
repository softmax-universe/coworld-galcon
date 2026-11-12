import std/[algorithm, os]
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
  doAssert identity().gameplay == 14
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
        var sizes: array[4, seq[int]]
        var production: array[4, int]
        var homes: array[MaxPlayers + 1, int]
        for i, p in world.planets:
          sizes[p.quadrant()].add p.radius
          doAssert world.bodies[p.body].radius == fixed(p.radius.int32),
            "Collision radii follow the balanced planet size"
          production[p.quadrant()] += p.production
          doAssert p.x >= fixed((8 + p.radius).int32)
          doAssert p.x <= fixed((Width - 8 - p.radius).int32)
          doAssert p.y >= fixed((40 + p.radius).int32)
          doAssert p.y <= fixed((Height - 40 - p.radius).int32)
          if p.owner > 0:
            inc homes[p.owner]
            doAssert p.x <= fixed(64) or p.x >= fixed(Width - 64) or
              p.y <= fixed(80) or p.y >= fixed(Height - 80), "Homes stay on the perimeter"
            doAssert p.production == 100 and p.shipCount == 100
          else:
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
                "Perimeter homes remain separated even with sixteen players"
        for owner in 1 .. players: doAssert homes[owner] == 1
        var minimum = count
        var maximum = 0
        for q in 0 ..< 4:
          sizes[q].sort()
          minimum = min(minimum, sizes[q].len)
          maximum = max(maximum, sizes[q].len)
        doAssert maximum - minimum <= 1, "Quadrant populations differ by at most one"
        var fullGroupSizes: seq[int]
        for q in 0 ..< 4:
          if sizes[q].len == minimum:
            if fullGroupSizes.len == 0: fullGroupSizes = sizes[q]
            else: doAssert sizes[q] == fullGroupSizes
        for q in 0 ..< 4:
          if sizes[q].len > minimum:
            var matched = false
            for extra in 0 ..< sizes[q].len:
              var withoutExtra = sizes[q]
              withoutExtra.delete(extra)
              if withoutExtra == fullGroupSizes: matched = true
            doAssert matched, "Only the unavoidable remainder may differ in size"
        if count mod 4 == 0:
          for q in 1 ..< 4:
            doAssert sizes[q] == sizes[0], "Actual planet radii match across quadrants"
            doAssert production[q] == production[0], "Actual production matches including homes"
        doAssert world.fingerprint() == newWorld(setup.clone()).fingerprint()
  for players in [2, 4]:
    let setup = configuredSetup(8, Easy, players, 32)
    setup.balancedMap = true
    let world = newWorld(setup)
    var quadrants: seq[int]
    for p in world.planets:
      if p.owner > 0:
        doAssert (p.x <= fixed(64) or p.x >= fixed(Width - 64)) and
          (p.y <= fixed(80) or p.y >= fixed(Height - 80))
        quadrants.add p.quadrant()
    if players == 2: doAssert (quadrants[0] xor quadrants[1]) == 3

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
    doAssert readFile(path).replayFileHeader().gameVersion == 14
    let loaded = loadRecording(path)
    doAssert loaded.setup.balancedMap == balanced, "Map mode survives replay serialization"
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
      setup.placement = placement
      doAssert newWorld(setup).fingerprint() == Expected[s][p],
        "Unchecked maps preserve historical positions, RNG state and complete hashes"

proc testBalancedMaps*() =
  testLegacyFingerprints()
  testConfig()
  testMaps()
  testReplay()
  testLegacyReplay()

when isMainModule:
  testBalancedMaps()
  echo "Balanced configuration, quadrant production/sizes, perimeter homes, seeds and passages passed"
