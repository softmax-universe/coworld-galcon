import
  std/os,
  galcon/[common, physics, worlds, options, sessions, bots]

proc testRules*() =
  ## Checks switchable fleet contacts, neutral garrisons, and replay rules.
  echo "Large maps allow existing full distance-table policy startup"
  let startup = newBrain(newWorld(configuredSetup(42, Easy, 16, 69)), 1,
    "dim distances(16383)\n" &
    "a = 0\nwhile a < planetCount()\n" &
    "b = 0\nwhile b < planetCount()\n" &
    "dx = x(a) - x(b)\ndy = y(a) - y(b)\n" &
    "distance = dx * dx + dy * dy\nlo = 0\nhi = 1024\n" &
    "while lo < hi\nmid = (lo + hi) \\ 2\n" &
    "if mid * mid < distance then\nlo = mid + 1\n" &
    "else\nhi = mid\nend if\nwend\n" &
    "distances(a * 128 + b) = lo\nb = b + 1\nwend\n" &
    "a = a + 1\nwend\n")
  startup.decide()
  doAssert not startup.failed
  doAssert startup.decisions == 1
  echo "Rules B is the default for every setup entry point"
  for setup in [
    Setup(), defaultSetup(), configuredSetup(8, Easy, 5, 26),
    tutorialSetup(8, 1)
  ]:
    doAssert setup.enemyShipsPassThrough
    doAssert setup.neutralsDontProduce
  echo "Enemy fleets pass through while friendly contacts still separate"
  for kind in CollisionKind:
    for enabled in [false, true]:
      for friendly in [false, true]:
        let setup = defaultSetup()
        setup.enemyShipsPassThrough = enabled
        let world = World(setup: setup, winner: -1)
        world.bodies[3] = Body(
          active: true, kind: ShipBody, x: fixed(100), y: fixed(100),
          radius: fixed(6), weight: 1, target: -1
        )
        world.bodies[11] = Body(
          active: true, kind: ShipBody, x: fixed(105), y: fixed(100),
          radius: fixed(6), weight: 1, target: -1
        )
        world.ships[3].owner = 1
        world.ships[11].owner = if friendly: 1 else: 2
        world.moveBodies(kind)
        if enabled and not friendly:
          doAssert world.bodies[3].x == fixed(100)
          doAssert world.bodies[11].x == fixed(105)
        else:
          doAssert world.bodies[11].x - world.bodies[3].x == fixed(12)
      let setup = defaultSetup()
      setup.enemyShipsPassThrough = enabled
      let world = World(setup: setup, winner: -1)
      world.bodies[3] = Body(
        active: true, kind: ShipBody, x: fixed(100), y: fixed(100),
        radius: fixed(6), weight: 1, target: 11
      )
      world.bodies[11] = Body(
        active: true, kind: PlanetBody, x: fixed(105), y: fixed(100),
        radius: fixed(22), weight: 100_000, target: -1
      )
      world.moveBodies(kind)
      doAssert world.bodies[3].hit
  echo "Frozen neutrals use the full 0 through 100 initial garrison range"
  var seen: array[101, bool]
  for seed in 0 ..< 128:
    let setup = configuredSetup(seed.int32, Easy, 5, 26)
    let world = newWorld(setup)
    for planet in world.planets:
      if planet.owner == 0:
        doAssert planet.shipCount in 0 .. 100
        seen[planet.shipCount] = true
      else:
        doAssert planet.shipCount == 100
    var stocks: seq[int64]
    for planet in world.planets:
      stocks.add planet.ships
    for tick in 0 ..< 128:
      world.produce()
    for i, planet in world.planets:
      if planet.owner == 0:
        doAssert planet.ships == stocks[i]
      else:
        doAssert planet.ships > stocks[i]
  for value in seen:
    doAssert value
  echo "Captured neutrals resume production and disabled flags retain 2006 rules"
  let setup = configuredSetup(8, Easy, 2, 26)
  setup.neutralsDontProduce = true
  let world = newWorld(setup)
  var
    neutral = -1
    source = -1
  for i, planet in world.planets:
    if planet.owner == 0:
      neutral = i
    elif planet.owner == 1:
      source = i
  world.planets[neutral].ships = 0
  doAssert world.launch(1, source, neutral, 1) == 1
  world.advance() # Tick-batched emission precedes the forced arrival below.
  for i, body in world.bodies:
    if body.active and body.kind == ShipBody:
      world.bodies[i].x = world.planets[neutral].x
      world.bodies[i].y = world.planets[neutral].y
      world.bodies[i].hit = true
  world.advance()
  doAssert world.planets[neutral].owner == 1
  let before = world.planets[neutral].ships
  world.produce()
  doAssert world.planets[neutral].ships > before
  let originalSetup = defaultSetup()
  originalSetup.enemyShipsPassThrough = false
  originalSetup.neutralsDontProduce = false
  let original = newWorld(originalSetup)
  var originalStocks: seq[int64]
  for planet in original.planets:
    originalStocks.add planet.ships
    if planet.owner == 0:
      doAssert planet.shipCount in 10 .. 29
      planet.neighbors.setLen(0)
      planet.morale = 100
  original.produce()
  for i, planet in original.planets:
    if planet.owner == 0:
      doAssert planet.ships > originalStocks[i]
  echo "Local flags and each rule combination survive deterministic replay"
  let defaults = parseOptions(@["--headless"])
  doAssert defaults.setup.enemyShipsPassThrough
  doAssert defaults.setup.neutralsDontProduce
  for passThrough in [false, true]:
    for frozen in [false, true]:
      for stage in 1 .. 3:
        let tutorial = parseOptions(@[
          "--tutorial", $stage,
          "--enemy-ships-pass-through", $passThrough,
          "--neutrals-dont-produce", $frozen
        ])
        doAssert tutorial.setup.enemyShipsPassThrough == passThrough
        doAssert tutorial.setup.neutralsDontProduce == frozen
        let restarted = tutorial.matchSetup(Hard, stage)
        doAssert restarted.enemyShipsPassThrough == passThrough
        doAssert restarted.neutralsDontProduce == frozen
      let path = Root / "build" / "rules.replay"
      let options = parseOptions(@[
        "--headless", "--players", "5", "--ticks", "256",
        "--enemy-ships-pass-through", $passThrough,
        "--neutrals-dont-produce", $frozen, "--record", path
      ])
      let session = newSession(options)
      while not session.done:
        session.step()
      let playback = newSession(parseOptions(@["--headless", "--replay", path]))
      doAssert playback.world.setup.enemyShipsPassThrough == passThrough
      doAssert playback.world.setup.neutralsDontProduce == frozen
      playback.seek(session.world.tick)
      doAssert playback.world.fingerprint() == session.world.fingerprint()
      removeFile(path)
