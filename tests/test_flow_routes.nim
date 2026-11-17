import
  std/[math, strformat],
  galcon/[common, physics, worlds],
  flowfixtures, test_ship_contacts

type
  RouteMetrics* = object
    ticks*, arrived*, samples*, backwards*, suddenTurns*, turnReversals*: int
    maximumDeviation*, averageDeviation*: float64
    maximumTurn*, averageTurn*, averageAcceleration*: float64
    maximumStep*: float64
    longestStall*, longestStill*, stalledSamples*: int
    longestCrossing*, crossingShips*, peakCrossing*: int
    arrivals640*, arrivals800*, crossing640*, crossing800*: int
    averageCrossing*: float64

proc measureRoutes*(world: World, maximumTicks = 1600,
    checkHulls = false): RouteMetrics =
  ## Measures actual flight away from source and destination planet maneuvers.
  var
    previousTurns: array[MaxBodies, float64]
    stalls, still, crossingTicks: array[MaxBodies, int]
    enteredCrossing: array[MaxBodies, bool]
    before: array[MaxBodies, Body]
  while world.activeShips > 0 or world.flowPending() > 0:
    if world.tick >= maximumTicks or world.winner >= 0:
      break
    before = world.bodies
    world.advance()
    if checkHulls:
      for blend in [0.0, 0.5, 1.0]:
        world.assertClearHulls(world.tick.int, blend)
    var crossing = 0
    for i, body in world.bodies:
      if not body.active or body.kind != ShipBody or not before[i].active:
        previousTurns[i] = 0
        stalls[i] = 0
        still[i] = 0
        crossingTicks[i] = 0
        enteredCrossing[i] = false
        continue
      result.maximumStep = max(result.maximumStep,
        hypot(body.x - body.previousX, body.y - body.previousY).toFloat64)
      let
        ship = world.ships[i]
        target = world.planets[ship.target]
      var source: Planet
      for order in world.orders:
        if order.target == ship.target.int32 and
          order.player == ship.owner.int32:
            source = world.planets[order.source]
            break
      doAssert source != nil, "Every measured ship needs its accepted route"
      let
        x = body.x.toFloat64
        y = body.y.toFloat64
        sourceX = source.x.toFloat64
        sourceY = source.y.toFloat64
        targetX = target.x.toFloat64
        targetY = target.y.toFloat64
        sourceDistance = hypot(x - sourceX, y - sourceY)
        targetDistance = hypot(x - targetX, y - targetY)
      if sourceDistance < 60 or targetDistance < 45:
        previousTurns[i] = 0
        stalls[i] = 0
        still[i] = 0
        continue
      let
        routeX = targetX - sourceX
        routeY = targetY - sourceY
        deviation = abs(routeX * (y - sourceY) -
          routeY * (x - sourceX)) / hypot(routeX, routeY)
        change = (body.heading - before[i].heading).toFloat64
        turn = math.arctan2(math.sin(change), math.cos(change))
        degrees = abs(turn) * 180 / PI
        vx = (body.x - body.previousX).toFloat64
        vy = (body.y - body.previousY).toFloat64
        oldVX = (before[i].x - before[i].previousX).toFloat64
        oldVY = (before[i].y - before[i].previousY).toFloat64
        progress = (vx * (targetX - x) + vy * (targetY - y)) /
          targetDistance
      if progress < 0.1:
        inc stalls[i]
        inc result.stalledSamples
        result.longestStall = max(result.longestStall, stalls[i])
      else:
        stalls[i] = 0
      if hypot(vx, vy) < 0.25:
        inc still[i]
        result.longestStill = max(result.longestStill, still[i])
      else:
        still[i] = 0
      if abs(x - 320) < 96 and abs(y - 240) < 96:
        inc crossing
        inc crossingTicks[i]
        if not enteredCrossing[i]:
          enteredCrossing[i] = true
          inc result.crossingShips
        result.longestCrossing = max(result.longestCrossing, crossingTicks[i])
        result.averageCrossing += 1
      result.maximumDeviation = max(result.maximumDeviation, deviation)
      result.averageDeviation += deviation
      result.maximumTurn = max(result.maximumTurn, degrees)
      result.averageTurn += degrees
      result.averageAcceleration += hypot(vx - oldVX, vy - oldVY)
      if vx * (targetX - x) + vy * (targetY - y) < 0:
        inc result.backwards
      if degrees > 15:
        inc result.suddenTurns
      if abs(turn) > PI / 360 and abs(previousTurns[i]) > PI / 360 and
        turn * previousTurns[i] < 0:
          inc result.turnReversals
      previousTurns[i] = turn
      inc result.samples
    result.peakCrossing = max(result.peakCrossing, crossing)
    if world.tick == 640:
      result.arrivals640 = world.flowArrived()
      result.crossing640 = crossing
    elif world.tick == 800:
      result.arrivals800 = world.flowArrived()
      result.crossing800 = crossing
  result.ticks = world.tick.int
  result.arrived = world.flowArrived()
  if world.tick < 640:
    result.arrivals640 = result.arrived
  if world.tick < 800:
    result.arrivals800 = result.arrived
  if result.samples > 0:
    result.averageDeviation /= result.samples.float64
    result.averageTurn /= result.samples.float64
    result.averageAcceleration /= result.samples.float64
  if result.crossingShips > 0:
    result.averageCrossing /= result.crossingShips.float64

proc describe*(metrics: RouteMetrics): string =
  ## Reports drift, visual heading changes, and physical displacement noise.
  &"ticks={metrics.ticks} arrived={metrics.arrived} " &
    &"deviationMax={metrics.maximumDeviation:.2f} " &
    &"deviationAvg={metrics.averageDeviation:.2f} " &
    &"turnMax={metrics.maximumTurn:.2f} turnAvg={metrics.averageTurn:.3f} " &
    &"accelerationAvg={metrics.averageAcceleration:.4f} " &
    &"stepMax={metrics.maximumStep:.2f} " &
    &"backwards={metrics.backwards} suddenTurns={metrics.suddenTurns} " &
    &"turnReversals={metrics.turnReversals} " &
    &"stallMax={metrics.longestStall} stillMax={metrics.longestStill} " &
    &"stallSamples={metrics.stalledSamples} " &
    &"crossingMax={metrics.longestCrossing} " &
    &"crossingAvg={metrics.averageCrossing:.1f} " &
    &"crossingPeak={metrics.peakCrossing} " &
    &"arrived640={metrics.arrivals640} arrived800={metrics.arrivals800} " &
    &"crossing640={metrics.crossing640} crossing800={metrics.crossing800}"

proc testRouteRecovery*() =
  ## A sideways shove must preserve the route and recover without teleporting.
  echo "Displaced ships recover their route with bounded smooth turns"
  let world = World(setup: defaultSetup(), winner: -1, activeShips: 1)
  world.bodies[0] = Body(
    active: true, kind: ShipBody,
    x: fixed(100), y: fixed(240),
    previousX: fixed(99), previousY: fixed(240),
    targetX: fixed(600), targetY: fixed(240), target: -1,
    radius: fixed(ShipRadius), speed: FixedOne, weight: 1
  )
  world.ships[0].owner = 1
  for tick in 0 ..< 16:
    world.moveBodies(Grid16)
  let
    routeX = world.bodies[0].routeX
    routeY = world.bodies[0].routeY
  world.bodies[0].y += fixed(128)
  world.bodies[0].previousY += fixed(128)
  let copied = world.clone()
  doAssert copied.bodies[0].routeReady
  doAssert copied.bodies[0].routeX == routeX
  doAssert copied.bodies[0].routeY == routeY
  for tick in 0 ..< 320:
    let before = world.bodies[0]
    world.moveBodies(Grid16)
    copied.moveBodies(Grid16)
    let
      body = world.bodies[0]
      distance = hypot(body.x - before.x, body.y - before.y).toFloat64
      change = (body.heading - before.heading).toFloat64
      turn = abs(math.arctan2(math.sin(change), math.cos(change))) * 180 / PI
    doAssert distance <= 1.001, "Route recovery must not teleport ships"
    doAssert body.x > before.x, "Recovery must preserve forward progress"
    doAssert turn < 4, "A displaced ship must turn without snapping"
    doAssert body.routeX == routeX and body.routeY == routeY
    doAssert world.fingerprint() == copied.fingerprint(),
      "Cloned route anchors must produce identical recovery"
  let remaining = abs(world.bodies[0].y - routeY).toFloat64
  echo &"  128px displacement recovered to {remaining:.2f}px from route"
  doAssert remaining < 48,
    "The ship must recover within the passing lane around its assigned route"

proc addRouteTestShip(world: World, id, x, y, targetX, targetY: int) =
  ## Starts a friendly ship with an established route and previous movement.
  let heading = arctan2(fixed((targetY - y).int32),
    fixed((targetX - x).int32))
  world.bodies[id] = Body(
    active: true, kind: ShipBody,
    x: fixed(x.int32), y: fixed(y.int32),
    previousX: fixed(x.int32) - cos(heading),
    previousY: fixed(y.int32) - sin(heading),
    targetX: fixed(targetX.int32), targetY: fixed(targetY.int32),
    routeX: fixed(x.int32), routeY: fixed(y.int32), routeReady: true,
    radius: fixed(ShipRadius), speed: FixedOne, heading: heading,
    weight: 1, target: -1
  )
  world.ships[id] = Ship(owner: 1, target: -1)
  inc world.activeShips

proc testFacingIndependentMovement*() =
  ## A clear route advances immediately while the visible ship turns toward it.
  echo "Ships keep moving toward their orders while their facing catches up"
  let world = World(setup: defaultSetup(), winner: -1)
  world.addRouteTestShip(0, 100, 240, 600, 240)
  world.moveBodies(Grid16)
  let forward = world.clone()
  world.bodies[0].heading = FixedPi
  for tick in 0 ..< 8:
    let before = world.bodies[0]
    world.moveBodies(Grid16)
    forward.moveBodies(Grid16)
    let
      body = world.bodies[0]
      change = (body.heading - before.heading).toFloat64
      turn = abs(math.arctan2(math.sin(change), math.cos(change))) * 180 / PI
    doAssert body.x > before.x,
      "Facing away from the goal must not delay a clear movement step"
    doAssert body.x == forward.bodies[0].x and
      body.y == forward.bodies[0].y,
        "Visual facing must not change the route's actual displacement"
    doAssert cos(body.heading) < FixedZero,
      "The fixture must exercise movement before the ship finishes turning"
    doAssert turn > 0 and turn < 4,
      "Facing must approach the route smoothly instead of snapping"

proc testParallelHullClearance*() =
  ## Nearby parallel triangles use clear lanes inside their enclosing circles.
  echo "Parallel ships use the free space between their actual hulls"
  let world = World(setup: defaultSetup(), winner: -1)
  doAssert not world.setup.legacyCrossings
  world.addRouteTestShip(0, 200, 200, 600, 200)
  world.addRouteTestShip(1, 200, 209, 600, 209)
  var isolated: array[2, World]
  for id in 0 .. 1:
    isolated[id] = world.clone()
    isolated[id].bodies[1 - id].active = false
    isolated[id].activeShips = 1
  for tick in 1 .. 16:
    world.moveBodies(Grid16)
    for id in 0 .. 1:
      isolated[id].moveBodies(Grid16)
      let
        actual = world.bodies[id]
        expected = isolated[id].bodies[id]
      doAssert actual.x == expected.x and actual.y == expected.y,
        "Overlapping enclosing circles must not displace clear ship hulls"
      doAssert actual.x == fixed((200 + tick).int32)
      doAssert actual.y == fixed((200 + id * 9).int32)
    for blend in [0.0, 0.5, 1.0]:
      world.assertClearHulls(tick, blend)

proc testPerpendicularRoutes*() =
  ## Crossing friends yield locally without adopting each other's destinations.
  echo "Perpendicular friends preserve their own routes through the crossing"
  block occupiedSide:
    let world = World(setup: defaultSetup(), winner: -1)
    world.addRouteTestShip(0, 200, 240, 600, 240)
    world.addRouteTestShip(1, 214, 252, 214, 440)
    # A neighbor's visual facing and recent shove do not redefine its order.
    world.bodies[1].heading = FixedZero
    world.bodies[1].previousX = fixed(213)
    world.bodies[1].previousY = fixed(252)
    world.moveBodies(Grid16)
    doAssert world.bodies[0].x > fixed(200) + FixedOne * 9 / 10
    doAssert world.bodies[0].y < fixed(240),
      "A crossing neighbor below the route must induce an upward sidestep"
    doAssert world.bodies[1].y > fixed(252) + FixedOne * 9 / 10,
      "The perpendicular neighbor must keep following its own southbound order"

  block completeCrossing:
    let world = World(setup: defaultSetup(), winner: -1)
    world.addRouteTestShip(0, 220, 240, 500, 240)
    world.addRouteTestShip(1, 260, 200, 260, 440)
    var maximumDrift: array[2, Fixed]
    for tick in 1 .. 160:
      world.moveBodies(Grid16)
      for blend in [0.0, 0.5, 1.0]:
        world.assertClearHulls(tick, blend)
      maximumDrift[0] = max(maximumDrift[0],
        abs(world.bodies[0].y - fixed(240)))
      maximumDrift[1] = max(maximumDrift[1],
        abs(world.bodies[1].x - fixed(260)))
      doAssert world.bodies[0].targetX == fixed(500)
      doAssert world.bodies[0].targetY == fixed(240)
      doAssert world.bodies[1].targetX == fixed(260)
      doAssert world.bodies[1].targetY == fixed(440)
    doAssert world.bodies[0].x > fixed(340)
    doAssert world.bodies[1].y > fixed(320)
    for drift in maximumDrift:
      doAssert drift > fixed(5), "The fixture must exercise actual yielding"
    doAssert abs(world.bodies[0].y - fixed(240)) < maximumDrift[0] * 3 / 4,
      "The eastbound ship must resume its own route after yielding"
    doAssert abs(world.bodies[1].x - fixed(260)) < maximumDrift[1] * 3 / 4,
      "The southbound ship must resume its own route after yielding"
    doAssert world.bodies[0].x - world.bodies[0].previousX >
      FixedOne * 9 / 10
    doAssert world.bodies[1].y - world.bodies[1].previousY >
      FixedOne * 9 / 10

proc testCrowdedLaunchClearance() =
  ## Checks new launches and interpolated hulls among many independent fleets.
  echo "Crowded launches retain their outline gap between ticks"
  let setup = configuredSetup(42, Easy, 16, MaxPlanets)
  setup.placement = ClusteredPlacement
  let world = newWorld(setup)
  for i, planet in world.planets:
    planet.owner = i mod 16 + 1
    planet.ships = stock(100_000)
    planet.realShips = planet.ships
    planet.production = 0
  for source, planet in world.planets:
    var
      farthest = FixedZero
      target = -1
    for i, other in world.planets:
      if i == source:
        continue
      let distance = hypot(other.x - planet.x, other.y - planet.y)
      if distance > farthest:
        farthest = distance
        target = i
    doAssert world.launch(planet.owner, source, target, 4096) == 4096
  for tick in 1 .. 96:
    world.advance()
    if tick mod 8 == 0:
      for blend in [0.0, 0.5, 1.0]:
        world.assertClearHulls(tick, blend)
  doAssert world.activeShips > 1000,
    "The fixture must exercise many concurrent launches and friendly contacts"

proc testFlowRoutes*() =
  ## Bounds visible wobble and route drift while requiring complete delivery.
  echo "New launches reserve clearance for opposing ship outlines"
  block:
    let world = World(setup: defaultSetup(), winner: -1)
    world.addRouteTestShip(0, 100, 240, 600, 240)
    doAssert not world.spawnClear(fixed(113), fixed(240)),
      "A new opposing nose must not touch a friendly outline before movement"
    doAssert world.spawnClear(fixed(114), fixed(240))
    world.setup.legacyRouteSteering = true
    doAssert world.spawnClear(fixed(113), fixed(240)),
      "Historical replay launches must keep their original clearance"
  testRouteRecovery()
  testFacingIndependentMovement()
  testParallelHullClearance()
  testPerpendicularRoutes()
  testCrowdedLaunchClearance()
  echo "Crowded routes remain smooth and recover after friendly crossings"
  for kind in ContactTraffic:
    let
      world = destinationFlowWorld(kind)
      metrics = world.measureRoutes(checkHulls = true)
    echo "  ", kind, " ", metrics.describe()
    doAssert metrics.samples > 20_000,
      "The fixture must measure sustained flight through the crossing"
    doAssert metrics.arrived == FlowShipCount,
      "Smoothing must not strand ships before their destinations"
    doAssert metrics.maximumTurn < 4,
      "Contact corrections must not snap the visible ship heading"
    doAssert metrics.averageTurn < 0.5,
      "Ships must keep a steady heading through dense traffic"
    doAssert metrics.maximumStep < 4,
      "Repeated collision corrections must not fling ships across the map"
    doAssert metrics.averageAcceleration < 0.1,
      "Smooth facing must also produce smooth physical movement"
    doAssert metrics.maximumDeviation < 140,
      "Avoidance must not carry ships to the opposite edge of the map"
    doAssert metrics.averageDeviation < 38,
      "Displaced ships must recover their assigned route"
    doAssert metrics.turnReversals < 1000,
      "Repeated left-right corrections must not produce visible wobble"
    if kind == CrossingContact:
      doAssert metrics.ticks <= 1100,
        "Both crossing fleets must finish without a prolonged central queue"
      doAssert metrics.longestStall < 96,
        "A crossing ship must not lose forward progress for three seconds"
      doAssert metrics.longestStill < 64,
        "A crossing ship must not remain almost motionless for two seconds"
      doAssert metrics.longestCrossing < 450,
        "Every ship must leave the intersection instead of staying in a blob"
      doAssert metrics.averageCrossing < 300,
        "The crossing must preserve sustained throughput for both fleets"
      doAssert metrics.arrivals800 >= 180,
        "Most ships must reach their assigned planets during normal flight"
      doAssert metrics.crossing800 < 64,
        "The central crowd must disperse before the last arrivals"
