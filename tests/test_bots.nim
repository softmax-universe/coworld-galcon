import
  std/os,
  bassy,
  galcon/[common, worlds, bots]

type
  TargetFixture = object
    world: World
    brain: Brain

proc newTargetFixture(): TargetFixture =
  ## Prepares a ready bot beside two affordable neutral expansion targets.
  result.world = newWorld(configuredSetup(7, Easy, 3, 6))
  for i, planet in result.world.planets:
    planet.owner = if i == 0: 1 elif i == 3: 2 elif i == 4: 3 else: 0
    planet.ships = stock(if i == 0: 500 elif i in [1, 2]: 6 else: 10000)
    planet.production = if i == 1: 100 elif i == 2: 30 else: 1
    planet.morale = 100
    planet.realMorale = 100
    planet.frame = 1
    planet.x = fixed((if i == 0: 60 elif i == 1: 120
      elif i == 2: 150 else: 450 + i * 20).int32)
    planet.y = fixed((if i == 1: 200 elif i == 2: 280 else: 240).int32)
    planet.neighbors.setLen(0)
    result.world.bodies[planet.body].x = planet.x
    result.world.bodies[planet.body].y = planet.y
  result.brain = newBrain(
    result.world, 1, readFile(Root / "players" / "truce.bas")
  )
  for tick in 0 ..< result.world.planets.len:
    result.brain.decide()
    doAssert not result.brain.failed
  result.world.planets[0].frame = 0

proc firstTarget(fixture: TargetFixture): int =
  ## Runs one policy decision and returns its first successful attack target.
  fixture.brain.decide()
  doAssert not fixture.brain.failed
  doAssert fixture.world.orders.len > 0
  fixture.world.orders[0].target.int

proc testBots*() =
  ## Checks expansion choices against actual fleets and repeated captures.
  echo "Bots choose other planets when targets are covered or contested"
  block:
    let fixture = newTargetFixture()
    doAssert fixture.firstTarget() == 1
  for owner in [1, 2, 3]:
    let fixture = newTargetFixture()
    fixture.world.planets[1].incoming[owner] = 100
    doAssert fixture.firstTarget() == 2
    for order in fixture.world.orders:
      doAssert order.target != 1
  block:
    let fixture = newTargetFixture()
    fixture.world.planets[1].incoming[2] = 5
    fixture.world.planets[1].incoming[3] = 5
    doAssert fixture.firstTarget() == 2
  block:
    let fixture = newTargetFixture()
    fixture.world.planets[0].frame = 1
    fixture.world.planets[1].owner = 2
    fixture.world.tick = 1
    fixture.brain.decide()
    fixture.world.planets[1].owner = 3
    fixture.world.tick = 2
    fixture.world.planets[0].frame = 0
    doAssert fixture.firstTarget() == 2
    fixture.world.orders.setLen(0)
    for body in fixture.world.bodies.mitems:
      if body.kind == ShipBody:
        body.active = false
    for planet in fixture.world.planets:
      planet.incoming[1] = 0
    fixture.world.activeShips = 0
    fixture.world.spawnGridReady = false
    fixture.world.tick = 300
    doAssert fixture.firstTarget() == 1
  echo "Fleet queries validate planet and anonymous faction IDs"
  block:
    let
      world = newWorld(configuredSetup(8, Easy, 3, 6))
      brain = newBrain(world, 1,
        "valid = incoming(0, 2)\n" &
        "negative = incoming(-1, 2)\n" &
        "outside = incoming(planetCount(), 2)\n" &
        "faction = incoming(0, playerCount() + 1)\n" &
        "neutral = incoming(0, 0)\n")
    world.planets[0].incoming[2] = 42
    brain.decide()
    doAssert not brain.failed
    doAssert brain.runtime.getGlobal("valid") == 42
    for name in ["negative", "outside", "faction", "neutral"]:
      doAssert brain.runtime.getGlobal(name) == 0
