import
  std/strformat,
  galcon/[common, physics, worlds],
  test_ship_contacts

type
  DeadlockTraffic* = enum
    ClusteredDestinations, FourWayDestinations, RepeatedCorridorOrders
  DeadlockMetrics* = object
    ticks*, accepted*, arrived*, active*, queued*: int
    escapes*, longestStill*: int

proc addDeadlockPlanet(world: World, x, y, radius: int, owner = 1) =
  ## Adds a fixed planet with enough stock for repeated conserved orders.
  let
    slot = MaxBodies - 1 - world.planets.len
    planet = Planet(
      name: "Port " & $world.planets.len,
      x: fixed(x.int32), y: fixed(y.int32), radius: radius,
      body: slot, owner: owner, ships: stock(4096), realShips: stock(4096),
      morale: 100, realMorale: 100
    )
  world.planets.add planet
  world.bodies[slot] = Body(
    active: true, kind: PlanetBody, x: planet.x, y: planet.y,
    radius: fixed(radius.int32), weight: 100_000, target: -1
  )

proc issueDeadlockOrders*(world: World, traffic: DeadlockTraffic,
    wave = 0) =
  ## Sends simultaneous orders to different destinations without fake bodies.
  case traffic
  of ClusteredDestinations:
    for source in 0 ..< 9:
      for offset in [4, 5]:
        doAssert world.launch(1, source, (source + offset) mod 9, 64) == 64
  of FourWayDestinations:
    for source in 0 ..< 4:
      doAssert world.launch(1, source, (source + 2) mod 4, 96) == 96
      doAssert world.launch(1, source, (source + 1) mod 4, 48) == 48
  of RepeatedCorridorOrders:
    for source in 0 ..< 4:
      let target = (source + 1 + wave) mod 4
      doAssert target != source
      doAssert world.launch(1, source, target, 64) == 64

proc deadlockWorld*(traffic: DeadlockTraffic): World =
  ## Reproduces clustered ports, intersecting routes, and repeated congestion.
  result = World(setup: defaultSetup(), winner: -1)
  result.setup.counts = @[1, 1, 0]
  case traffic
  of ClusteredDestinations:
    for row in 0 ..< 3:
      for column in 0 ..< 3:
        result.addDeadlockPlanet(260 + column * 60, 180 + row * 60,
          if row == 1 and column == 1: 22 else: 18)
  of FourWayDestinations:
    for position in [(120, 240), (320, 80), (520, 240), (320, 400)]:
      result.addDeadlockPlanet(position[0], position[1], 18)
    result.addDeadlockPlanet(320, 240, 22)
  of RepeatedCorridorOrders:
    for position in [(140, 180), (140, 300), (500, 180), (500, 300)]:
      result.addDeadlockPlanet(position[0], position[1], 18)
    for x in [260, 380]:
      for y in [160, 240, 320]:
        result.addDeadlockPlanet(x, y, 22)
  result.addDeadlockPlanet(48, 48, 12, 0)
  result.issueDeadlockOrders(traffic)

proc pendingDeadlockShips(world: World): int =
  ## Counts accepted ships still waiting for a free launch position.
  for i in 0 ..< world.pendingLaunchCount:
    result += world.pendingLaunches[i].count.int

proc measureDeadlocks*(world: World, traffic: DeadlockTraffic,
    maximumTicks = 4000, verifyHulls = false): DeadlockMetrics =
  ## Counts arrivals, long stationary runs, and entry into temporary escape.
  var
    before: array[MaxBodies, Body]
    still: array[MaxBodies, int]
  while world.tick < maximumTicks and world.winner < 0:
    if traffic == RepeatedCorridorOrders and world.tick in [80'i32, 160'i32]:
      world.issueDeadlockOrders(traffic, world.tick.int div 80)
    if world.activeShips == 0 and world.pendingDeadlockShips() == 0 and
      (traffic != RepeatedCorridorOrders or world.tick > 160):
        break
    before = world.bodies
    world.advance()
    var rejoined = false
    for i, body in world.bodies:
      if not body.active or body.kind != ShipBody or not before[i].active:
        still[i] = 0
        continue
      if hypot(body.x - before[i].x, body.y - before[i].y) < FixedOne / 4:
        inc still[i]
      else:
        still[i] = 0
      result.longestStill = max(result.longestStill, still[i])
      if body.escapeTicks > 0 and before[i].escapeTicks == 0:
        inc result.escapes
      elif body.escapeTicks == 0 and before[i].escapeTicks > 0:
        rejoined = true
    if verifyHulls and (world.tick mod 32 == 0 or rejoined):
      for blend in [0.25, 0.5, 0.75, 1.0]:
        world.assertClearHulls(world.tick.int, blend)
  result.ticks = world.tick.int
  for order in world.orders:
    result.accepted += order.count.int
  result.active = world.activeShips
  result.queued = world.pendingDeadlockShips()
  result.arrived = result.accepted - result.active - result.queued

proc describe*(metrics: DeadlockMetrics): string =
  ## Reports conserved delivery and the longest observed physical standstill.
  &"ticks={metrics.ticks} accepted={metrics.accepted} " &
    &"arrived={metrics.arrived} active={metrics.active} " &
    &"queued={metrics.queued} escapes={metrics.escapes} " &
    &"stillMax={metrics.longestStill}"

proc addDeadlockShip(world: World, id, x, y, targetX, targetY: int,
    speed = FixedOne) =
  ## Starts a friendly body for focused progress and rejoining checks.
  let heading = arctan2(fixed((targetY - y).int32),
    fixed((targetX - x).int32))
  world.bodies[id] = Body(
    active: true, kind: ShipBody,
    x: fixed(x.int32), y: fixed(y.int32),
    previousX: fixed(x.int32), previousY: fixed(y.int32),
    targetX: fixed(targetX.int32), targetY: fixed(targetY.int32),
    routeX: fixed(x.int32), routeY: fixed(y.int32), routeReady: true,
    radius: fixed(ShipRadius), speed: speed, heading: heading,
    weight: 1, target: -1
  )
  world.ships[id] = Ship(owner: 1, target: -1)
  inc world.activeShips

proc testDeadlockProgress() =
  ## Meaningful progress resets the timer; jitter and circling cannot reset it.
  echo "Deadlock escape begins after three seconds without new progress"
  block jitter:
    let world = World(setup: defaultSetup(), winner: -1)
    world.addDeadlockShip(0, 200, 240, 600, 240)
    world.updateDeadlocks()
    doAssert world.bodies[0].progressReady
    for tick in 1 .. TickRate * 3:
      world.bodies[0].x = fixed(200) +
        (if tick mod 2 == 0: FixedOne / 2 else: -FixedOne / 2)
      world.updateDeadlocks()
      if tick < TickRate * 3:
        doAssert world.bodies[0].escapeTicks == 0,
          "A brief wait must not turn a ship into an escaping ship"
      else:
        doAssert world.bodies[0].escapeTicks > 0,
          "Tiny collision jiggles must not conceal a three-second deadlock"

  block circling:
    let world = World(setup: defaultSetup(), winner: -1)
    world.addDeadlockShip(0, 220, 240, 600, 240)
    world.updateDeadlocks()
    for tick in 1 .. TickRate * 3:
      let angle = FixedTau * (tick mod 64).int32 / 64
      world.bodies[0].x = fixed(200) + cos(angle) * 20
      world.bodies[0].y = fixed(240) + sin(angle) * 20
      world.updateDeadlocks()
      if tick < TickRate * 3:
        doAssert world.bodies[0].escapeTicks == 0
    doAssert world.bodies[0].escapeTicks > 0,
      "Travelling around the same loop must not count as destination progress"

  block progressing:
    let world = World(setup: defaultSetup(), winner: -1)
    world.addDeadlockShip(0, 100, 240, 600, 240)
    world.updateDeadlocks()
    for tick in 1 .. TickRate * 6:
      world.bodies[0].x += FixedOne
      world.updateDeadlocks()
      doAssert world.bodies[0].escapeTicks == 0,
        "Normally moving ships must keep their collision boundary"

proc testDeadlockRejoining() =
  ## Escape lasts at least a second and never ends inside occupied space.
  echo "Escaping ships rejoin only after their interpolated hull is clear"
  block minimumDuration:
    let world = World(setup: defaultSetup(), winner: -1)
    world.addDeadlockShip(0, 200, 240, 600, 240)
    world.updateDeadlocks()
    world.bodies[0].escapeTicks = 1
    for tick in 1 ..< TickRate:
      world.updateDeadlocks()
      doAssert world.bodies[0].escapeTicks > 0
    world.updateDeadlocks()
    doAssert world.bodies[0].escapeTicks == 0,
      "An escaping ship should become solid again once its minimum time ends"
    doAssert world.bodies[0].stalledTicks == 0

  block occupiedShip:
    let world = World(setup: defaultSetup(), winner: -1)
    world.addDeadlockShip(0, 300, 240, 600, 240)
    world.addDeadlockShip(1, 300, 240, 600, 240, FixedZero)
    world.updateDeadlocks()
    world.bodies[0].escapeTicks = TickRate
    for tick in 0 ..< 16:
      world.updateDeadlocks()
      doAssert world.bodies[0].escapeTicks > 0,
        "A timeout must not make an escaping ship solid inside another ship"
    world.bodies[0].x = fixed(330)
    world.updateDeadlocks()
    doAssert world.bodies[0].escapeTicks > 0,
      "The preceding rendered pose must also be clear before rejoining"
    world.bodies[0].previousX = world.bodies[0].x
    world.updateDeadlocks()
    doAssert world.bodies[0].escapeTicks == 0

  block occupiedPlanet:
    let world = World(setup: defaultSetup(), winner: -1)
    world.addDeadlockPlanet(300, 240, 22)
    world.addDeadlockShip(0, 300, 240, 600, 240)
    world.updateDeadlocks()
    world.bodies[0].escapeTicks = TickRate
    world.updateDeadlocks()
    doAssert world.bodies[0].escapeTicks > 0,
      "An escaping ship must remain intangible inside a non-target planet"
    world.bodies[0].x = fixed(345)
    world.bodies[0].previousX = world.bodies[0].x
    world.updateDeadlocks()
    doAssert world.bodies[0].escapeTicks == 0

  block crossingSweeps:
    let world = World(setup: defaultSetup(), winner: -1)
    world.addDeadlockShip(0, 320, 240, 600, 240)
    world.addDeadlockShip(1, 280, 240, 600, 240, FixedZero)
    world.bodies[0].previousX = fixed(280)
    world.bodies[1].previousX = fixed(320)
    world.updateDeadlocks()
    world.bodies[0].escapeTicks = TickRate
    world.updateDeadlocks()
    doAssert world.bodies[0].escapeTicks > 0,
      "Separate endpoints must not hide a collision during interpolation"

  block simultaneousReentry:
    let world = World(setup: defaultSetup(), winner: -1)
    world.addDeadlockShip(0, 300, 240, 600, 240)
    world.addDeadlockShip(1, 300, 240, 600, 240)
    world.updateDeadlocks()
    world.bodies[0].escapeTicks = TickRate
    world.bodies[1].escapeTicks = TickRate
    world.updateDeadlocks()
    doAssert world.bodies[0].escapeTicks == 0
    doAssert world.bodies[1].escapeTicks > 0,
      "Overlapping escaping peers must not both become solid in the same tick"

proc testDeadlockPassThrough() =
  ## Temporary escape passes friends and obstacles but still delivers to target.
  echo "Escaping ships pass blocked space and still arrive at their orders"
  block friendlyBody:
    let world = World(setup: defaultSetup(), winner: -1)
    world.addDeadlockShip(0, 280, 240, 600, 240)
    world.addDeadlockShip(1, 300, 240, 600, 240, FixedZero)
    world.updateDeadlocks()
    world.bodies[0].escapeTicks = 1
    for tick in 1 .. 20:
      world.moveBodies(Grid16)
    doAssert abs(world.bodies[0].x - fixed(300)) < FixedOne / 100
    doAssert world.bodies[0].y == fixed(240)
    doAssert world.bodies[1].x == fixed(300)
    doAssert world.bodies[0].escapeTicks > 0

  block targetArrival:
    let world = World(setup: defaultSetup(), winner: -1)
    world.setup.counts = @[1, 1, 0]
    world.addDeadlockPlanet(100, 240, 18)
    world.addDeadlockPlanet(500, 240, 18)
    world.addDeadlockPlanet(300, 240, 22)
    world.addDeadlockPlanet(48, 48, 12, 0)
    doAssert world.launch(1, 0, 1, 1) == 1
    world.advance()
    var id = -1
    for i, body in world.bodies:
      if body.active and body.kind == ShipBody:
        id = i
        break
    doAssert id >= 0
    world.bodies[id].x = fixed(280)
    world.bodies[id].y = fixed(240)
    world.bodies[id].previousX = fixed(280)
    world.bodies[id].previousY = fixed(240)
    world.updateDeadlocks()
    world.bodies[id].escapeTicks = 1
    for tick in 1 .. 20:
      world.advance()
    doAssert world.activeShips == 1
    doAssert abs(world.bodies[id].x - fixed(300)) < FixedOne / 100
    doAssert world.bodies[id].y == fixed(240)
    doAssert world.planets[2].ships == stock(4096),
      "An escaping ship must not deliver to an intervening planet"
    for tick in 1 .. 240:
      if world.activeShips == 0:
        break
      world.advance()
    doAssert world.activeShips == 0
    doAssert world.planets[0].ships == stock(4095)
    doAssert world.planets[1].ships == stock(4097)
    doAssert world.planets[1].incoming[1] == 0

proc testDeadlockDeterminism() =
  ## Progress timers and escaping bodies produce identical cloned simulations.
  echo "Deadlock recovery preserves clone and collision-backend determinism"
  let original = World(setup: defaultSetup(), winner: -1)
  original.addDeadlockShip(0, 280, 240, 600, 240)
  original.addDeadlockShip(1, 300, 240, 600, 240, FixedZero)
  original.updateDeadlocks()
  original.bodies[0].escapeTicks = 1
  original.bodies[0].stalledTicks = TickRate * 3
  let expected = original.clone()
  var fingerprints: array[96, uint64]
  for tick in 0 ..< fingerprints.len:
    expected.moveBodies(Grid16)
    fingerprints[tick] = expected.fingerprint()
  for backend in CollisionKind:
    let actual = original.clone()
    for tick in 0 ..< fingerprints.len:
      actual.moveBodies(backend)
      doAssert actual.fingerprint() == fingerprints[tick],
        &"Escaping state diverged for {backend} at tick {tick}"

proc testDeadlocks*() =
  ## Requires complete delivery through simultaneous multi-destination traffic.
  testDeadlockProgress()
  testDeadlockRejoining()
  testDeadlockPassThrough()
  testDeadlockDeterminism()
  echo "Congested multi-destination fleets escape and deliver every order"
  for traffic in DeadlockTraffic:
    let world = deadlockWorld(traffic)
    var initialStock = 0'i64
    for planet in world.planets:
      initialStock += planet.ships
    initialStock += stock((world.activeShips +
      world.pendingDeadlockShips()).int32)
    let metrics = world.measureDeadlocks(traffic, verifyHulls = true)
    echo "  ", traffic, " ", metrics.describe()
    doAssert metrics.arrived == metrics.accepted,
      "Every accepted ship must reach its assigned planet despite gridlock"
    doAssert metrics.active == 0 and metrics.queued == 0
    doAssert metrics.escapes > 0,
      "This fixture must exercise recovery from actual congested movement"
    doAssert metrics.longestStill <= TickRate * 3,
      "A trapped ship must begin escaping within three seconds"
    var finalStock = 0'i64
    for id, planet in world.planets:
      var expected = stock(4096)
      for order in world.orders:
        if order.source == id.int32:
          expected -= stock(order.count)
        if order.target == id.int32:
          expected += stock(order.count)
      doAssert planet.ships == expected,
        "Every delivery must reach the planet named by its original order"
      finalStock += planet.ships
      for incoming in planet.incoming:
        doAssert incoming == 0
    doAssert finalStock == initialStock,
      "Escape must never lose, duplicate, or deliver a ship twice"
