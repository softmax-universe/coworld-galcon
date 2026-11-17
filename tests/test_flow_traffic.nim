import
  std/[math, strformat],
  galcon/[common, physics, worlds]

type
  TrafficKind* = enum
    OpposingTraffic, CrossingTraffic
  TrafficMetrics* = object
    minimumProgress*, averageProgress*: float64
    averageTurn*, maximumTurn*: float64
    backwardsSteps*: int

proc softFlowSetup(): Setup =
  ## Preserves v16 behavior for fixtures deliberately starting with overlap.
  result = defaultSetup()
  result.legacyContacts = true

proc addTrafficShip(world: World, id, x, y, targetX, targetY: int) =
  ## Adds one moving friendly ship with an established destination heading.
  let heading = arctan2(fixed((targetY - y).int32),
    fixed((targetX - x).int32))
  world.bodies[id] = Body(
    active: true, kind: ShipBody,
    x: fixed(x.int32), y: fixed(y.int32),
    previousX: fixed(x.int32) - cos(heading),
    previousY: fixed(y.int32) - sin(heading),
    targetX: fixed(targetX.int32), targetY: fixed(targetY.int32),
    radius: fixed(ShipRadius), speed: FixedOne, heading: heading,
    weight: 1, target: -1
  )
  world.ships[id] = Ship(owner: 1, target: id mod 7)
  inc world.activeShips

proc trafficWorld*(kind: TrafficKind, count = 256): World =
  ## Builds intersecting dense streams with independent destinations.
  doAssert count > 0 and count <= MaxBodies and count mod 2 == 0
  result = World(setup: softFlowSetup(), winner: -1)
  let
    columns = if count > 512: 64 else: 16
    spacing = if count > 512: 3 else: 8
  for i in 0 ..< count:
    let
      second = i >= count div 2
      local = i mod (count div 2)
      along = local mod columns * spacing
      across = local div columns * spacing
    case kind
    of OpposingTraffic:
      let
        x = if second: 540 - along else: 100 + along
        y = 180 + across
        targetX = if second: -400 else: 1040
      result.addTrafficShip(i, x, y, targetX, y)
    of CrossingTraffic:
      if second:
        result.addTrafficShip(i, 280 + across, 40 + along,
          280 + across, 1000)
      else:
        result.addTrafficShip(i, 80 + along, 180 + across,
          1040, 180 + across)

proc planetTraffic*(): World =
  ## Puts an immovable planet in the middle of two opposing fleets.
  result = trafficWorld(OpposingTraffic)
  result.planets.add Planet(x: fixed(320), y: fixed(220), radius: 24,
    body: MaxBodies - 1)
  result.bodies[MaxBodies - 1] = Body(
    active: true, kind: PlanetBody, x: fixed(320), y: fixed(220),
    radius: fixed(24), weight: 100_000, target: -1
  )

proc measureTraffic*(world: World, ticks: int,
    kind = Grid16): TrafficMetrics =
  ## Measures destination progress and heading changes through a crossing.
  let initial = world.clone()
  result.minimumProgress = float64.high
  var turns = 0
  for tick in 0 ..< ticks:
    var previousVX, previousVY: array[MaxBodies, Fixed]
    for i in 0 ..< world.activeShips:
      previousVX[i] = world.bodies[i].x - world.bodies[i].previousX
      previousVY[i] = world.bodies[i].y - world.bodies[i].previousY
    world.moveBodies(kind)
    for i in 0 ..< world.activeShips:
      let
        body = world.bodies[i]
        vx = body.x - body.previousX
        vy = body.y - body.previousY
        dx = (vx - previousVX[i]).toFloat64
        dy = (vy - previousVY[i]).toFloat64
        turn = sqrt(dx * dx + dy * dy)
        goalX = body.targetX - body.previousX
        goalY = body.targetY - body.previousY
      result.averageTurn += turn
      result.maximumTurn = max(result.maximumTurn, turn)
      inc turns
      if vx * goalX + vy * goalY < FixedZero:
        inc result.backwardsSteps
  for i in 0 ..< world.activeShips:
    let
      before = initial.bodies[i]
      after = world.bodies[i]
      startDistance = hypot(before.targetX - before.x,
        before.targetY - before.y)
      endDistance = hypot(after.targetX - after.x,
        after.targetY - after.y)
      progress = (startDistance - endDistance).toFloat64
    result.minimumProgress = min(result.minimumProgress, progress)
    result.averageProgress += progress
  result.averageProgress /= world.activeShips.float64
  result.averageTurn /= turns.float64

proc describe*(metrics: TrafficMetrics): string =
  ## Formats stable progress and jitter measurements for regression output.
  &"minimum={metrics.minimumProgress:.2f} " &
    &"average={metrics.averageProgress:.2f} " &
    &"turnAverage={metrics.averageTurn:.4f} " &
    &"turnMaximum={metrics.maximumTurn:.4f} " &
    &"backwards={metrics.backwardsSteps}"

proc testFlowTraffic*() =
  ## Exercises crowded crossings, counterflow, and deterministic snapshots.
  echo "Historical soft-flow crossings preserve their movement behavior"
  for kind in TrafficKind:
    let metrics = trafficWorld(kind).measureTraffic(240)
    echo "  ", kind, " ", metrics.describe()
    doAssert metrics.minimumProgress > 160
    doAssert metrics.averageProgress > 210
    doAssert metrics.backwardsSteps == 0
    doAssert metrics.averageTurn < 0.12
    doAssert metrics.maximumTurn < 1

  echo "The full ship pool keeps moving under sustained opposing pressure"
  block:
    let metrics = trafficWorld(OpposingTraffic, MaxBodies).measureTraffic(96)
    echo "  full pool ", metrics.describe()
    doAssert metrics.minimumProgress > 55
    doAssert metrics.averageProgress > 75
    doAssert metrics.backwardsSteps == 0
    doAssert metrics.averageTurn < 0.15

  echo "Opposing destination headings align as a flow axis"
  block:
    let world = World(setup: softFlowSetup(), winner: -1)
    world.addTrafficShip(0, 100, 100, 1000, 100)
    world.addTrafficShip(1, 100, 120, -500, -480)
    world.moveBodies(Grid16)
    doAssert world.bodies[0].x > fixed(100)
    doAssert world.bodies[0].y > fixed(100)
    doAssert world.bodies[1].x < fixed(100)
    doAssert world.bodies[1].y < fixed(120)

  echo "Irrelevant early grid cells cannot hide a nearby moving friend"
  block:
    let world = World(setup: softFlowSetup(), winner: -1)
    world.addTrafficShip(0, 100, 100, 1000, 100)
    world.addTrafficShip(1, 100, 120, 1000, 1020)
    for i in 2 ..< 66:
      world.addTrafficShip(i, 80, 80, -500, 80)
      world.ships[i].owner = 2
    world.moveBodies(Grid16)
    doAssert world.bodies[0].x > fixed(100)
    doAssert world.bodies[0].y > fixed(100)

  echo "Exactly overlapping ships separate without cancelling their orders"
  block:
    let world = World(setup: softFlowSetup(), winner: -1)
    for i in 0 ..< 64:
      world.addTrafficShip(i, 200, 200, 1000, 200)
    discard world.measureTraffic(24)
    for i in 0 ..< 64:
      doAssert world.bodies[i].x > fixed(215)
      for j in i + 1 ..< 64:
        doAssert world.bodies[i].x != world.bodies[j].x or
          world.bodies[i].y != world.bodies[j].y

  echo "Dense traffic snapshots agree across every collision backend"
  block:
    let original = trafficWorld(CrossingTraffic)
    discard original.measureTraffic(80)
    let expected = original.clone()
    for tick in 0 ..< 24:
      expected.moveBodies(Grid16)
    for kind in CollisionKind:
      let actual = original.clone()
      for tick in 0 ..< 24:
        actual.moveBodies(kind)
      doAssert actual.fingerprint() == expected.fingerprint()

  echo "Opposing fleets clear a non-target planet without moving it"
  block:
    let
      world = planetTraffic()
      metrics = world.measureTraffic(360)
    echo "  planet crossing ", metrics.describe()
    doAssert world.bodies[MaxBodies - 1].x == fixed(320)
    doAssert world.bodies[MaxBodies - 1].y == fixed(220)
    doAssert metrics.minimumProgress > 300
    doAssert metrics.averageProgress > 300
    doAssert metrics.averageTurn < 0.12
    doAssert metrics.maximumTurn < 1
    doAssert metrics.backwardsSteps == 0
    for i in 0 ..< world.activeShips:
      if i < world.activeShips div 2:
        doAssert world.bodies[i].x > fixed(350)
      else:
        doAssert world.bodies[i].x < fixed(290)
