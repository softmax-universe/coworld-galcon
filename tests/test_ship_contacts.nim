import
  std/[math, strformat],
  galcon/[common, physics, worlds]

type
  ContactTraffic* = enum
    HeadOnContact, CrossingContact, PlanetContact
  HullPoint = tuple[x, y: float64]
  ShipHull = array[3, HullPoint]

proc contactWorld*(kind: ContactTraffic, count = 256): World =
  ## Starts two same-owner streams with clear space between every ship.
  doAssert count in [32, 128, 256]
  result = World(setup: defaultSetup(), winner: -1)
  let columns = if count == 32: 8 else: 16
  for i in 0 ..< count:
    let
      second = i >= count div 2
      local = i mod (count div 2)
      along = local mod columns * 12
      across = local div columns * 12
    var x, y, targetX, targetY: int
    if kind == CrossingContact:
      if second:
        x = 320 + across
        y = 30 + along
        targetX = x
        targetY = 1200
      else:
        x = 70 + along
        y = 220 + across
        targetX = 1200
        targetY = y
    else:
      x = if second: 560 - along else: 80 + along
      y = 170 + across
      targetX = if second: -600 else: 1240
      targetY = y
    let heading = arctan2(fixed((targetY - y).int32),
      fixed((targetX - x).int32))
    result.bodies[i] = Body(
      active: true, kind: ShipBody,
      x: fixed(x.int32), y: fixed(y.int32),
      previousX: fixed(x.int32) - cos(heading),
      previousY: fixed(y.int32) - sin(heading),
      targetX: fixed(targetX.int32), targetY: fixed(targetY.int32),
      radius: fixed(ShipRadius), speed: FixedOne, heading: heading,
      weight: 1, target: -1
    )
    result.ships[i] = Ship(owner: 1, target: i mod 7)
  result.activeShips = count
  if kind == PlanetContact:
    result.planets.add Planet(
      x: fixed(320), y: fixed(220), radius: 24, body: MaxBodies - 1
    )
    result.bodies[MaxBodies - 1] = Body(
      active: true, kind: PlanetBody, x: fixed(320), y: fixed(220),
      radius: fixed(24), weight: 100_000, target: -1
    )

proc shipHull(world: World, id: int, blend: float64): ShipHull =
  ## Independently reconstructs the visible compressed triangle in world units.
  let
    body = world.bodies[id]
    previousHeading = world.previousHullHeading[id].toFloat64
    turn = body.heading.toFloat64 - previousHeading
    heading = previousHeading +
      math.arctan2(math.sin(turn), math.cos(turn)) * blend
    previousPressure = world.previousHullPressure[id].toFloat64
    pressure = clamp(previousPressure +
      (world.neighborPressure[id].toFloat64 - previousPressure) * blend,
      0.0, 1.0)
    forward = 1.0 - pressure * 0.1
    width = 3.0 - pressure * 0.75
    dx = math.cos(heading)
    dy = math.sin(heading)
    x = body.previousX.toFloat64 +
      (body.x - body.previousX).toFloat64 * blend
    y = body.previousY.toFloat64 +
      (body.y - body.previousY).toFloat64 * blend
  result[0] = (x + dx * 6 * forward, y + dy * 6 * forward)
  result[1] = (x - dx * 3 * forward - dy * width,
    y - dy * 3 * forward + dx * width)
  result[2] = (x - dx * 3 * forward + dy * width,
    y - dy * 3 * forward - dx * width)

proc visibleGap(first, second: ShipHull): float64 =
  ## Measures separation using triangle edges independently of solver circles.
  result = -float64.high
  for hull in [first, second]:
    for edge in 0 ..< 3:
      let
        start = hull[edge]
        finish = hull[(edge + 1) mod 3]
        nx = finish.y - start.y
        ny = start.x - finish.x
        length = sqrt(nx * nx + ny * ny)
      var
        firstMin = float64.high
        secondMin = float64.high
        firstMax = -float64.high
        secondMax = -float64.high
      for vertex in first:
        let value = vertex.x * nx + vertex.y * ny
        firstMin = min(firstMin, value)
        firstMax = max(firstMax, value)
      for vertex in second:
        let value = vertex.x * nx + vertex.y * ny
        secondMin = min(secondMin, value)
        secondMax = max(secondMax, value)
      result = max(result,
        max(secondMin - firstMax, firstMin - secondMax) / length)

proc planetGap(hull: ShipHull, planet: Planet): float64 =
  ## Measures the closest triangle edge to an obstacle's circular boundary.
  result = float64.high
  let
    x = planet.x.toFloat64
    y = planet.y.toFloat64
  for edge in 0 ..< 3:
    let
      start = hull[edge]
      finish = hull[(edge + 1) mod 3]
      dx = finish.x - start.x
      dy = finish.y - start.y
      blend = clamp(((x - start.x) * dx + (y - start.y) * dy) /
        (dx * dx + dy * dy), 0.0, 1.0)
      ox = start.x + dx * blend - x
      oy = start.y + dy * blend - y
    result = min(result, sqrt(ox * ox + oy * oy) - planet.radius.float64)

proc assertClearHulls*(world: World, tick: int, blend = 1.0) =
  ## Checks solid triangles, independently of the collision approximation.
  var
    hulls: array[MaxBodies, ShipHull]
    active: array[MaxBodies, int]
    count = 0
  for i, body in world.bodies:
    if not body.active or body.kind != ShipBody:
      continue
    if body.escapeTicks > 0:
      # Escaping ships deliberately phase through otherwise solid traffic.
      continue
    if blend == 0 and body.x == body.previousX and body.y == body.previousY:
      # Fresh launches did not exist in the preceding simulation snapshot.
      continue
    active[count] = i
    inc count
    hulls[i] = world.shipHull(i, blend)
  for index in 0 ..< count:
    let
      i = active[index]
      first = world.bodies[i]
      firstX = first.previousX.toFloat64 +
        (first.x - first.previousX).toFloat64 * blend
      firstY = first.previousY.toFloat64 +
        (first.y - first.previousY).toFloat64 * blend
    for other in index + 1 ..< count:
      let
        j = active[other]
        second = world.bodies[j]
        secondX = second.previousX.toFloat64 +
          (second.x - second.previousX).toFloat64 * blend
        secondY = second.previousY.toFloat64 +
          (second.y - second.previousY).toFloat64 * blend
      if world.ships[i].owner != world.ships[j].owner or
        abs(firstX - secondX) > 14 or abs(firstY - secondY) > 14:
          continue
      let gap = visibleGap(hulls[i], hulls[j])
      doAssert gap >= 1.1,
        &"Hull gap {gap:.4f}, ships {i}/{j}, tick {tick}, blend {blend}"
    for planet in world.planets:
      if planet.body == first.target:
        continue
      if abs(firstX - planet.x.toFloat64) > (planet.radius + 7).float64 or
        abs(firstY - planet.y.toFloat64) > (planet.radius + 7).float64:
          continue
      doAssert planetGap(hulls[i], planet) >= 0.1,
        &"Visible hull {i} intersects the planet at tick {tick}"

proc testShipContacts*() =
  ## Verifies non-overlapping crossings and sustained destination progress.
  echo "Ship hulls retain a gap throughout opposing and crossing streams"
  for count in [32, 128, 256]:
    for kind in ContactTraffic:
      let
        world = contactWorld(kind, count)
        before = world.clone()
      var maximumPressure: Fixed
      world.assertClearHulls(0)
      # Include the last rows clearing the intersection and recovering their
      # routes after yielding, while checking hull gaps throughout the delay.
      for tick in 1 .. 900:
        world.moveBodies(Grid16)
        for blend in [0.0, 0.5, 1.0]:
          world.assertClearHulls(tick, blend)
        for i in 0 ..< count:
          maximumPressure = max(maximumPressure, world.neighborPressure[i])
        if kind == PlanetContact:
          doAssert world.bodies[MaxBodies - 1].x == fixed(320)
          doAssert world.bodies[MaxBodies - 1].y == fixed(220)
      var
        minimum = float64.high
        average = 0.0
      for i in 0 ..< count:
        let
          initial = before.bodies[i]
          final = world.bodies[i]
          progress = (hypot(initial.targetX - initial.x,
            initial.targetY - initial.y) -
            hypot(final.targetX - final.x,
              final.targetY - final.y)).toFloat64
        minimum = min(minimum, progress)
        average += progress
      average /= count.float64
      echo &"  {kind} ships={count} min={minimum:.2f} avg={average:.2f}"
      doAssert maximumPressure > FixedZero,
        "The fixture must exercise actual close contact"
      doAssert minimum > 400, "Every ship must escape the crossing"
      doAssert average > 700, "Contact must not turn streams into a traffic jam"

  echo "Moving enemy ships retain the explicit pass-through rule"
  block:
    let world = World(setup: defaultSetup(), winner: -1, activeShips: 2)
    for i in 0 ..< 2:
      let
        x = fixed(if i == 0: 300 else: 340)
        direction = if i == 0: FixedOne else: -FixedOne
        heading = arctan2(FixedZero, direction)
      world.bodies[i] = Body(
        active: true, kind: ShipBody, x: x, y: fixed(220),
        previousX: x - direction, previousY: fixed(220),
        targetX: fixed(if i == 0: 1200 else: -600), targetY: fixed(220),
        radius: fixed(ShipRadius), speed: FixedOne, heading: heading,
        weight: 1, target: -1
      )
      world.ships[i].owner = i + 1
    let
      firstOnly = world.clone()
      secondOnly = world.clone()
    firstOnly.bodies[1].active = false
    secondOnly.bodies[0].active = false
    var closest = fixed(100)
    for tick in 1 .. 60:
      world.moveBodies(Grid16)
      firstOnly.moveBodies(Grid16)
      secondOnly.moveBodies(Grid16)
      doAssert world.bodies[0].x == firstOnly.bodies[0].x
      doAssert world.bodies[0].y == firstOnly.bodies[0].y
      doAssert world.bodies[1].x == secondOnly.bodies[1].x
      doAssert world.bodies[1].y == secondOnly.bodies[1].y
      closest = min(closest, hypot(world.bodies[0].x - world.bodies[1].x,
        world.bodies[0].y - world.bodies[1].y))
    doAssert closest < FixedOne,
      "Enemy fleets must actually pass through the same position"
    doAssert world.bodies[0].x > world.bodies[1].x

  echo "Contact resolution preserves clone and collision-backend determinism"
  for traffic in [HeadOnContact, CrossingContact]:
    let original = contactWorld(traffic, 128)
    for tick in 0 ..< 80:
      original.moveBodies(Grid16)
    let expected = original.clone()
    var fingerprints: array[48, uint64]
    for tick in 0 ..< fingerprints.len:
      expected.moveBodies(Grid16)
      fingerprints[tick] = expected.fingerprint()
    for backend in CollisionKind:
      let actual = original.clone()
      for tick in 0 ..< fingerprints.len:
        actual.moveBodies(backend)
        doAssert actual.fingerprint() == fingerprints[tick],
          &"Contact state diverged for {backend} at tick {tick}"
