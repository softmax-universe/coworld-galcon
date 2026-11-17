import common, hullcontacts, profiles, spaces

const
  FlowReach = 24
  FlowSamplesPerCell = 12
  FlowSpacing = ShipRadius * 3 div 2
  RouteAllowance = 48
  RouteGain = 12
  HullPasses = 32
  DeadlockTicks = TickRate * 3
  EscapeMinimumTicks = TickRate
  ProgressStep = 8

proc followsRoute(world: World): bool {.inline.} =
  ## Selects route recovery without changing any historical movement rules.
  not world.setup.legacyMovement and not world.setup.legacyFlocking and
    not world.setup.legacyContacts and not world.setup.legacyRouteSteering

proc escapesDeadlocks(world: World): bool {.inline.} =
  ## Keeps the escape state machine out of historical movement and replays.
  world.setup != nil and world.followsRoute() and
    not world.setup.legacyCrossings and not world.setup.legacyDeadlocks

proc escaping(world: World, id: int): bool {.inline.} =
  ## Selects temporarily non-solid ships without changing their ownership.
  world.bodies[id].escapeTicks > 0 and world.escapesDeadlocks()

proc freeBody*(world: World): int =
  ## Finds a free slot in the original bounded flocking pool.
  let cursor = world.bodyCursor
  for i in 0 ..< MaxBodies:
    let slot = world.bodyCursor mod MaxBodies
    inc world.bodyCursor
    if not world.bodies[slot].active:
      return slot
  world.bodyCursor = cursor
  -1

proc prepareSpawns(world: World) =
  ## Indexes current body positions once between movement phases.
  if world.spawnGridReady:
    return
  var count = 0
  world.spawnRadii = [FixedZero, FixedZero]
  for i in 0 ..< MaxBodies:
    let body = addr world.bodies[i]
    if not body.active:
      continue
    world.activeBodies[count] = i.uint16
    inc count
    world.spatialX[i] = int32(body.x)
    world.spatialY[i] = int32(body.y)
    world.spawnRadii[body.kind] = max(
      world.spawnRadii[body.kind], body.radius
    )
  world.buildGrid(count, 16)
  world.spawnGridReady = true

proc spawnClear*(world: World, x, y: Fixed): bool =
  ## Rejects ship positions outside the map or overlapping any active body.
  let radius = fixed(ShipRadius)
  if x < radius or y < radius or
    x > fixed(Width) - radius or y > fixed(Height) - radius:
      return false
  world.prepareSpawns()
  const
    Columns = (Width + 15) div 16
    Rows = (Height + 15) div 16
  for group in BodyKind:
    # Launches happen after contact projection, so their initial poses must
    # already leave room for the outlines before the next simulation tick.
    let
      clearance =
        if group == ShipBody and world.setup != nil and world.followsRoute():
          FixedOne * 5 / 4
        else:
          FixedZero
      reach = int32(radius + clearance).int64 + int32(world.spawnRadii[group])
      left = cell(int32(x).int64 - reach, 16, Columns)
      right = cell(int32(x).int64 + reach, 16, Columns)
      top = cell(int32(y).int64 - reach, 16, Rows)
      bottom = cell(int32(y).int64 + reach, 16, Rows)
    for row in top .. bottom:
      for column in left .. right:
        let index = row * Columns + column
        var cursor =
          if group == PlanetBody: world.gridPlanetHeads[index]
          else: world.gridHeads[index]
        while cursor != 0:
          let id = cursor.int - 1
          cursor = world.gridNext[id]
          if world.escaping(id):
            continue
          let
            body = addr world.bodies[id]
            dx = body.x - x
            dy = body.y - y
            distance = int32(radius + body.radius + clearance).int64
          if lengthSquared(dx, dy) < distance * distance:
            return false
  true

proc sweptClear(dx, dy, oldX, oldY, radius: Fixed): bool =
  ## Requires separation throughout the return to ordinary collision handling.
  if min(dx, oldX) > radius or max(dx, oldX) < -radius or
    min(dy, oldY) > radius or max(dy, oldY) < -radius:
      return true
  let squared = int32(radius).int64 * int32(radius)
  if lengthSquared(dx, dy) <= squared or
    lengthSquared(oldX, oldY) <= squared:
      return false
  let
    deltaX = dx - oldX
    deltaY = dy - oldY
  if abs(deltaX) > fixed(64) or abs(deltaY) > fixed(64):
    return false
  let
    travel = deltaX * deltaX + deltaY * deltaY
  if travel > FixedZero:
    let moment = -(oldX * deltaX + oldY * deltaY) / travel
    if moment > FixedZero and moment < FixedOne:
      return lengthSquared(oldX + deltaX * moment,
        oldY + deltaY * moment) > squared
  true

proc canRejoin(world: World, id: int, maximumTravel: Fixed): bool =
  ## Returns to solid flight only when the previous and current poses are free.
  const
    Columns = (Width + 15) div 16
    Rows = (Height + 15) div 16
  let body = addr world.bodies[id]
  for group in BodyKind:
    let
      reach = body.radius + world.spawnRadii[group] + FixedOne * 2 +
        (if group == ShipBody: maximumTravel else: FixedZero)
      left = cell(int32(min(body.x, body.previousX) - reach), 16, Columns)
      right = cell(int32(max(body.x, body.previousX) + reach), 16, Columns)
      top = cell(int32(min(body.y, body.previousY) - reach), 16, Rows)
      bottom = cell(int32(max(body.y, body.previousY) + reach), 16, Rows)
    for row in top .. bottom:
      for column in left .. right:
        let index = row * Columns + column
        var cursor = if group == ShipBody: world.gridHeads[index]
          else: world.gridPlanetHeads[index]
        while cursor != 0:
          let other = cursor.int - 1
          cursor = world.gridNext[other]
          if other == id or other == body.target or world.escaping(other):
            continue
          let neighbor = addr world.bodies[other]
          if group == ShipBody and world.setup.enemyShipsPassThrough and
            world.ships[id].owner != world.ships[other].owner:
              continue
          let
            dx = neighbor.x - body.x
            dy = neighbor.y - body.y
            oldX = (if group == ShipBody: neighbor.previousX else: neighbor.x) -
              body.previousX
            oldY = (if group == ShipBody: neighbor.previousY else: neighbor.y) -
              body.previousY
            radius = body.radius + neighbor.radius +
              (if group == ShipBody: FixedOne * 5 / 4 else: FixedOne * 2)
          if not sweptClear(dx, dy, oldX, oldY, radius):
            return false
  true

proc resetProgress(body: var Body) =
  ## Starts a fresh progress window after launch, recovery, or real advancement.
  body.progressReady = true
  body.progressDistance = hypot(body.targetX - body.x, body.targetY - body.y)
  body.stalledTicks = 0

proc updateDeadlocks*(world: World) =
  ## Lets a ship escape after three seconds without a new destination gain.
  if not world.escapesDeadlocks():
    return
  var
    checkReentry = false
    maximumTravel = FixedZero
  for body in world.bodies:
    if not body.active or body.kind != ShipBody or body.hit:
      continue
    checkReentry = checkReentry or body.escapeTicks >= EscapeMinimumTicks
    maximumTravel = max(maximumTravel,
      max(abs(body.x - body.previousX), abs(body.y - body.previousY)))
  if checkReentry:
    world.spawnGridReady = false
    world.prepareSpawns()
  for id in 0 ..< MaxBodies:
    let body = addr world.bodies[id]
    if not body.active or body.kind != ShipBody or body.hit or
      body.speed <= FixedZero:
        continue
    if not body.progressReady:
      body[].resetProgress()
      continue
    if body.escapeTicks > 0:
      body.escapeTicks = min(TickRate * 60, body.escapeTicks + 1)
      if body.escapeTicks > EscapeMinimumTicks and
        world.canRejoin(id, maximumTravel):
          body.escapeTicks = 0
          body[].resetProgress()
      continue
    let distance = hypot(body.targetX - body.x, body.targetY - body.y)
    if distance <= body.progressDistance - fixed(ProgressStep):
      body[].resetProgress()
    else:
      inc body.stalledTicks
      if body.stalledTicks >= DeadlockTicks:
        body.escapeTicks = 1
  # Arrivals and pending launches follow movement and must rebuild this index.
  world.spawnGridReady = false

proc indexSpawn*(world: World, slot: int) =
  ## Makes a newly spawned ship block later launches in the same tick.
  const Columns = (Width + 15) div 16
  let
    body = addr world.bodies[slot]
    column = cell(int32(body.x), 16, Columns)
    row = cell(int32(body.y), 16, (Height + 15) div 16)
    index = row * Columns + column
  world.gridNext[slot] = world.gridHeads[index]
  world.gridHeads[index] = (slot + 1).uint16
  world.spawnRadii[ShipBody] = max(world.spawnRadii[ShipBody], body.radius)
  if not world.setup.legacyMovement and not world.setup.legacyFlocking and
    not world.setup.legacyContacts:
      world.neighborPressure[slot] = FixedZero
      body.heading = arctan2(body.targetY - body.y, body.targetX - body.x)
      if world.followsRoute():
        world.previousHullHeading[slot] = body.heading
        world.previousHullPressure[slot] = FixedZero

proc flockHeading(world: World, id: int): Fixed =
  ## Snapshot-only bounded local steering. Destination dominates alignment;
  ## soft separation never turns an oncoming friendly into a solid wall.
  let body = addr world.bodies[id]
  let desired = arctan2(body.targetY - body.y, body.targetX - body.x)
  var dx = cos(desired)
  var dy = sin(desired)
  var ax, ay, sx, sy: Fixed
  var aligned, examined: int
  const Columns = (Width + 15) div 16
  const Rows = (Height + 15) div 16
  let left = cell(int32(body.x).int64 - 24 * FixedScale, 16, Columns)
  let right = cell(int32(body.x).int64 + 24 * FixedScale, 16, Columns)
  let top = cell(int32(body.y).int64 - 24 * FixedScale, 16, Rows)
  let bottom = cell(int32(body.y).int64 + 24 * FixedScale, 16, Rows)
  block neighbors:
    for row in top .. bottom:
      for column in left .. right:
        var cursor = world.gridHeads[row * Columns + column]
        while cursor != 0:
          let other = cursor.int - 1
          cursor = world.gridNext[other]
          inc examined
          if examined > 32: break neighbors
          if other == id or world.ships[other].owner != world.ships[id].owner:
            continue
          let ox = Fixed(world.spatialX[other]) - body.x
          let oy = Fixed(world.spatialY[other]) - body.y
          let distance = hypot(ox, oy)
          if distance > FixedZero and distance < fixed(24):
            # Only actually moving, similarly directed neighbors align.
            let vx = world.neighborVX[other]
            let vy = world.neighborVY[other]
            if vx * dx + vy * dy > FixedZero:
              ax += vx
              ay += vy
              inc aligned
            if distance < fixed(ShipRadius * 2):
              let strength = (fixed(ShipRadius * 2) - distance) / fixed(ShipRadius * 2)
              sx -= ox / distance * strength
              sy -= oy / distance * strength
  if aligned > 0:
    dx += ax / aligned.int32 / 3
    dy += ay / aligned.int32 / 3
  let separation = hypot(sx, sy)
  if separation > FixedZero:
    dx += sx / max(FixedOne, separation) / 3
    dy += sy / max(FixedOne, separation) / 3
  # Slide around non-target planets rather than repeatedly driving into them.
  # Planet count is independently capped at 128.
  for p in world.planets:
    if p.body == body.target: continue
    let ox = p.x - body.x
    let oy = p.y - body.y
    let reach = fixed((p.radius + ShipRadius + 10).int32)
    if abs(ox) >= reach or abs(oy) >= reach: continue
    let distance = hypot(ox, oy)
    if distance > FixedZero and distance < reach and ox * dx + oy * dy > FixedZero:
      let side = if (id and 1) == 0: -1'i32 else: 1'i32
      let strength = (reach - distance) / fixed(10)
      dx += (oy / distance * side - ox / distance) * strength
      dy += (-ox / distance * side - oy / distance) * strength
  arctan2(dy, dx)

proc flowHeading(world: World, id: int): Fixed =
  ## Preserves the historical v16/v17 flow behavior for recorded matches.
  let
    body = addr world.bodies[id]
    desired = arctan2(body.targetY - body.y, body.targetX - body.x)
    goalX = cos(desired)
    goalY = sin(desired)
    reach = if world.setup.legacyContacts: FlowReach else: 36
    spacing = if world.setup.legacyContacts: FlowSpacing else: 14
    crowding = if world.setup.legacyContacts: ShipRadius * 2 else: 14
    left = cell(int32(body.x).int64 - reach * FixedScale, 16,
      (Width + 15) div 16)
    right = cell(int32(body.x).int64 + reach * FixedScale, 16,
      (Width + 15) div 16)
    top = cell(int32(body.y).int64 - reach * FixedScale, 16,
      (Height + 15) div 16)
    bottom = cell(int32(body.y).int64 + reach * FixedScale, 16,
      (Height + 15) div 16)
  var
    ax, ay, alignment, sx, sy, passing, pressure: Fixed
    dx = goalX
    dy = goalY
  for row in top .. bottom:
    for column in left .. right:
      var
        cursor = world.gridHeads[row * ((Width + 15) div 16) + column]
        examined = 0
      while cursor != 0 and examined < FlowSamplesPerCell:
        let other = cursor.int - 1
        cursor = world.gridNext[other]
        inc examined
        if other == id or world.ships[other].owner != world.ships[id].owner:
          continue
        var
          ox = Fixed(world.spatialX[other]) - body.x
          oy = Fixed(world.spatialY[other]) - body.y
        if lengthSquared(ox, oy) >=
          reach.int64 * reach * FixedScale * FixedScale:
            continue
        var distance = hypot(ox, oy)
        let
          speed = world.bodies[other].speed
          weight = (fixed(reach.int32) - distance) / fixed(reach.int32)
        if speed > FixedZero:
          let
            vx = world.neighborVX[other] / speed
            vy = world.neighborVY[other] / speed
            agreement = clamp(vx * goalX + vy * goalY, -FixedOne, FixedOne)
          # Project onto the neighbor's axis. Opposite streams align without
          # cancelling or reversing, and perpendicular influence fades smoothly.
          ax += vx * agreement * weight
          ay += vy * agreement * weight
          alignment += abs(agreement) * weight
          let
            forward = ox * goalX + oy * goalY
            lateral = abs(oy * goalX - ox * goalY)
          if forward > FixedZero and lateral < fixed(spacing.int32) and
            agreement < FixedOne / 2 and
            ox * (goalX * body.speed - world.neighborVX[other]) +
              oy * (goalY * body.speed - world.neighborVY[other]) > FixedZero:
              # Both streams keep right in their own direction of travel.
              passing = max(passing, weight *
                (FixedOne - lateral / fixed(spacing.int32)))
        if distance < fixed(crowding.int32):
          pressure += (fixed(crowding.int32) - distance) /
            fixed(crowding.int32)
        if distance < fixed(spacing.int32):
          if distance == FixedZero:
            # Antisymmetric tie breaks let coincident ships fan out safely.
            var seed = (min(id, other) + 1).uint32 * 0x9e3779b9'u32 xor
              (max(id, other) + 1).uint32 * 0x85ebca6b'u32
            seed = (seed xor (seed shr 16)) * 0x7feb352d'u32
            seed = seed xor (seed shr 15)
            ox = Fixed(int32(seed and 0xffff'u32) - 32768)
            oy = Fixed(int32(seed shr 16) - 32768)
            if id > other:
              ox = -ox
              oy = -oy
            distance = hypot(ox, oy)
            if distance == FixedZero:
              ox = if id < other: FixedOne else: -FixedOne
              distance = FixedOne
          let strength = (fixed(spacing.int32) - distance) / fixed(spacing.int32)
          sx -= ox / distance * strength
          sy -= oy / distance * strength
  world.neighborPressure[id] = min(FixedOne, pressure / 3)
  if alignment > FixedZero:
    dx += ax / max(FixedOne, alignment) * 2 / 3
    dy += ay / max(FixedOne, alignment) * 2 / 3
  let separation = max(FixedOne, hypot(sx, sy))
  if world.setup.legacyContacts:
    dx += sx / separation / 4 - goalY * passing / 3
    dy += sy / separation / 4 + goalX * passing / 3
  else:
    dx += sx / separation / 4 - goalY * passing
    dy += sy / separation / 4 + goalX * passing
  # Neighboring ships take the nearer side of an obstacle together instead of
  # splitting by pool ID. A centered approach consistently passes to the right.
  for planet in world.planets:
    if planet.body == body.target:
      continue
    let
      ox = planet.x - body.x
      oy = planet.y - body.y
      reach = fixed((planet.radius + ShipRadius + 14).int32)
    if abs(ox) >= reach or abs(oy) >= reach:
      continue
    let distance = hypot(ox, oy)
    if distance > FixedZero and distance < reach and
      ox * goalX + oy * goalY > FixedZero:
        let
          side = if goalX * oy - goalY * ox > FixedZero: -1'i32 else: 1'i32
          strength = (reach - distance) / fixed(14)
        dx += (-oy / distance * side - ox / distance) * strength
        dy += (ox / distance * side - oy / distance) * strength
  let
    previousX = world.neighborVX[id]
    previousY = world.neighborVY[id]
    previousSpeed = hypot(previousX, previousY)
    nextSpeed = hypot(dx, dy)
  if previousSpeed > FixedZero and nextSpeed > FixedZero and
    previousX * goalX + previousY * goalY > FixedZero:
      # Smooth changes in the sampled neighborhood without adding mutable state.
      dx = dx / nextSpeed + previousX / previousSpeed * 2
      dy = dy / nextSpeed + previousY / previousSpeed * 2
  arctan2(dy, dx)

proc routeHeading(world: World, id: int): Fixed =
  ## Adapts LvD's bounded lateral traffic bias around each ship's own route.
  const Reach = 64
  if world.escaping(id):
    let body = addr world.bodies[id]
    world.routePriority[id] = FixedOne
    world.neighborPressure[id] = FixedZero
    return arctan2(body.targetY - body.y, body.targetX - body.x)
  let
    body = addr world.bodies[id]
    forwardX = world.neighborVX[id]
    forwardY = world.neighborVY[id]
    left = cell(int32(body.x).int64 - Reach * FixedScale, 16,
      (Width + 15) div 16)
    right = cell(int32(body.x).int64 + Reach * FixedScale, 16,
      (Width + 15) div 16)
    top = cell(int32(body.y).int64 - Reach * FixedScale, 16,
      (Height + 15) div 16)
    bottom = cell(int32(body.y).int64 + Reach * FixedScale, 16,
      (Height + 15) div 16)
  var
    avoidance, alignment, pressure: Fixed
    aligned = 0'i32
  for row in top .. bottom:
    for column in left .. right:
      var
        cursor = world.gridHeads[row * ((Width + 15) div 16) + column]
        examined = 0
      while cursor != 0 and examined < FlowSamplesPerCell:
        let other = cursor.int - 1
        cursor = world.gridNext[other]
        inc examined
        if other == id or world.ships[other].owner != world.ships[id].owner or
          world.escaping(other):
            continue
        let
          ox = Fixed(world.spatialX[other]) - body.x
          oy = Fixed(world.spatialY[other]) - body.y
          squared = lengthSquared(ox, oy)
        if squared == 0 or squared >= Reach.int64 * Reach *
          FixedScale * FixedScale:
            continue
        let
          distance = hypot(ox, oy)
          scaled = distance / Reach
          peerX = world.neighborVX[other]
          peerY = world.neighborVY[other]
          agreement = forwardX * peerX + forwardY * peerY
          ahead = ox * forwardX + oy * forwardY
          across = oy * forwardX - ox * forwardY
        if distance < fixed(14):
          pressure += (fixed(14) - distance) / 14
        if world.bodies[other].speed > FixedZero and
          agreement > FixedOne / 2:
            alignment += peerY * forwardX - peerX * forwardY
            inc aligned
        if ahead <= FixedZero:
          continue
        if world.bodies[other].speed > FixedZero and
          agreement < -FixedOne / 4:
            # Counterflow keeps one consistent side without turning backward.
            avoidance -= (FixedOne - scaled) * 3 / 5
        elif abs(across) < fixed(Reach) * 44 / 100 and
          scaled < FixedOne * 65 / 100:
            # Crossing traffic moves away from the occupied side, not into it.
            let side = if across > FixedZero: -1'i32 else: 1'i32
            avoidance += (FixedOne * 65 / 100 - scaled) * side * 3 / 10
  world.neighborPressure[id] = min(FixedOne, pressure / 3)
  world.routePriority[id] = FixedOne
  if aligned > 0:
    alignment = alignment / aligned * 3 / 20
  let lateral = clamp(avoidance + alignment,
    -FixedOne * 45 / 100, FixedOne * 45 / 100)
  var
    dx = forwardX - forwardY * lateral
    dy = forwardY + forwardX * lateral
  let
    routeX = body.targetX - body.routeX
    routeY = body.targetY - body.routeY
    routeLength = hypot(routeX, routeY)
  if routeLength > FixedZero:
    let
      alongX = routeX / routeLength
      alongY = routeY / routeLength
      offset = alongX * (body.y - body.routeY) -
        alongY * (body.x - body.routeX)
      drift = max(FixedZero, abs(offset) - fixed(RouteAllowance))
      urgency = min(FixedOne * 7, drift / fixed(RouteGain))
      recovery = min(FixedOne, drift / 32) *
        (if offset < FixedZero: -1'i32 else: 1'i32)
      remaining = alongX * (body.targetX - body.x) +
        alongY * (body.targetY - body.y)
    # Let nearby ships yield, but make displaced ships harder to push farther.
    world.routePriority[id] += urgency
    dx += forwardX * urgency / 2
    dy += forwardY * urgency / 2
    if remaining > fixed(48):
      dx += alongY * recovery
      dy -= alongX * recovery
  for planet in world.planets:
    if planet.body == body.target:
      continue
    let
      ox = planet.x - body.x
      oy = planet.y - body.y
      reach = fixed((planet.radius + ShipRadius + 14).int32)
    if abs(ox) >= reach or abs(oy) >= reach:
      continue
    let distance = hypot(ox, oy)
    if distance > FixedZero and distance < reach and
      ox * forwardX + oy * forwardY > FixedZero:
        let
          side = if forwardX * oy - forwardY * ox > FixedZero: -1'i32 else: 1'i32
          strength = (reach - distance) / 14
        dx += (-oy / distance * side - ox / distance) * strength
        dy += (ox / distance * side - oy / distance) * strength
  arctan2(dy, dx)

proc collide(world: World, first, second: int) {.inline.} =
  ## Applies the original weighted fixed-point response to one candidate pair.
  let
    a = addr world.bodies[first]
    b = addr world.bodies[second]
    clearance =
      if world.setup != nil and not world.setup.legacyMovement and
        not world.setup.legacyFlocking and not world.setup.legacyContacts and
        a.kind != b.kind and (a.speed > FixedZero or b.speed > FixedZero) and
        a.target != second and b.target != first:
          FixedOne * 2
      else:
        FixedZero
    radius = a.radius + b.radius + clearance
  if world.setup.enemyShipsPassThrough and
    a.kind == ShipBody and b.kind == ShipBody and
    world.ships[first].owner != world.ships[second].owner:
      return
  if a.kind == ShipBody and b.kind == ShipBody and
    (world.escaping(first) or world.escaping(second)):
      return
  if not world.setup.legacyMovement and a.kind == ShipBody and
    b.kind == ShipBody and a.speed > FixedZero and b.speed > FixedZero and
    world.ships[first].owner == world.ships[second].owner:
      return # Soft steering handles friends; hard correction undoes progress.
  var
    dx = b.x - a.x
    dy = b.y - a.y
  if abs(dx) > radius or abs(dy) > radius:
    return
  var distance = hypot(dx, dy)
  if distance >= radius:
    return
  if a.target == second:
    a.hit = true
    return
  if b.target == first:
    b.hit = true
    return
  if world.escaping(first) or world.escaping(second):
    return
  if distance == FixedZero:
    distance = FixedOne
    dx = FixedOne
  if not world.setup.legacyMovement and a.kind != b.kind and
    (if a.kind == ShipBody: a.speed else: b.speed) > FixedZero:
    # Planets are immovable in gameplay. Round outward to avoid residual Q16
    # overlap; never let ship pressure move the obstacle or undo another ship.
    let separation = radius + Fixed(2)
    let offsetX = Fixed(int32(int32(dx).int64 * int32(separation) div int32(distance)))
    let offsetY = Fixed(int32(int32(dy).int64 * int32(separation) div int32(distance)))
    if a.kind == ShipBody:
      a.x = b.x - offsetX
      a.y = b.y - offsetY
    else:
      b.x = a.x + offsetX
      b.y = a.y + offsetY
    return
  let
    weight = int64(a.weight) + b.weight
    centerX = (int64(int32(a.x)) * a.weight +
      int64(int32(b.x)) * b.weight) div weight
    centerY = (int64(int32(a.y)) * a.weight +
      int64(int32(b.y)) * b.weight) div weight
    offsetX = int64(int32(radius)) * int32(dx) div int32(distance)
    offsetY = int64(int32(radius)) * int32(dy) div int32(distance)
  a.x = Fixed(int32(centerX - offsetX * b.weight div weight))
  a.y = Fixed(int32(centerY - offsetY * b.weight div weight))
  b.x = Fixed(int32(centerX + offsetX * a.weight div weight))
  b.y = Fixed(int32(centerY + offsetY * a.weight div weight))

proc separateHulls(world: World, count: int) =
  ## Separates friendly hulls while reserving room around immovable planets.
  const
    Columns = (Width + 15) div 16
    Rows = (Height + 15) div 16
    Reach = 14 * FixedScale
  let
    routeFlow = world.followsRoute()
    triangleFlow = routeFlow and not world.setup.legacyCrossings
  var planetReach = fixed(ShipRadius + 2)
  var dirty, changed, awake: array[MaxBodies, bool]
  var hullSamples: array[MaxBodies, HullSamples]
  var nearPlanets: array[MaxBodies, bool]
  var planetGuard, oldPlanetGuard: array[MaxBodies, Fixed]
  var ownerHeads: array[MaxPlayers + 1, array[MaxGridCells, uint16]]
  for planet in world.planets:
    planetReach = max(planetReach,
      world.bodies[planet.body].radius + fixed(ShipRadius + 2))
  for i in 0 ..< count:
    let id = world.activeBodies[i].int
    let body = addr world.bodies[id]
    if body.kind != ShipBody or body.speed <= FixedZero or world.escaping(id):
      continue
    dirty[id] = true
    if triangleFlow:
      # Gradually reserve the old circular space before reaching a planet.
      # Triangle-only projections can otherwise wedge ships against its edge.
      for planet in world.planets:
        let reach = fixed((planet.radius + 44).int32)
        if lengthSquared(body.x - planet.x, body.y - planet.y) <
          int32(reach).int64 * int32(reach):
            planetGuard[id] = max(planetGuard[id], min(FixedOne,
              (reach - hypot(body.x - planet.x, body.y - planet.y)) / 20))
        if lengthSquared(body.previousX - planet.x,
          body.previousY - planet.y) < int32(reach).int64 * int32(reach):
            oldPlanetGuard[id] = max(oldPlanetGuard[id], min(FixedOne,
              (reach - hypot(body.previousX - planet.x,
                body.previousY - planet.y)) / 20))
      nearPlanets[id] = max(planetGuard[id], oldPlanetGuard[id]) > FixedZero
      let turn = arctan2(sin(body.heading - world.previousHullHeading[id]),
        cos(body.heading - world.previousHullHeading[id]))
      for sample in 1 .. 4:
        hullSamples[id][sample] = world.makeHullSample(id, sample, turn)
    let
      forward = FixedOne - world.neighborPressure[id] / 10
      width = FixedOne - world.neighborPressure[id] / 4
      center = (forward * forward * 3 - width * width) / (forward * 2)
      margin =
        if triangleFlow: FixedOne * 9 / 8
        elif routeFlow: FixedOne
        else: FixedOne * 5 / 4
    # This circle encloses all three compressed vertices. The extra radius
    # includes the half-pixel outline and room for bounded solver residuals.
    world.hullDX[id] = cos(body.heading)
    world.hullDY[id] = sin(body.heading)
    world.hullX[id] = world.hullDX[id] * center
    world.hullY[id] = world.hullDY[id] * center
    world.hullRadius[id] = (forward * forward * 9 + width * width) /
      (forward * 2) + margin
    let
      oldForward = FixedOne - world.previousHullPressure[id] / 10
      oldWidth = FixedOne - world.previousHullPressure[id] / 4
      oldCenter = (oldForward * oldForward * 3 - oldWidth * oldWidth) /
        (oldForward * 2)
    world.previousHullX[id] = cos(world.previousHullHeading[id]) * oldCenter
    world.previousHullY[id] = sin(world.previousHullHeading[id]) * oldCenter
    world.previousHullRadius[id] =
      (oldForward * oldForward * 9 + oldWidth * oldWidth) /
        (oldForward * 2) + margin
  let iterations =
    if world.escapesDeadlocks(): 48
    elif routeFlow: HullPasses
    else: 48
  for iteration in 0 ..< iterations:
    changed = default(typeof(changed))
    var sweepX, sweepY: array[MaxPlayers + 1, int64]
    for owner in 0 .. MaxPlayers:
      sweepX[owner] = Reach.int64
      sweepY[owner] = Reach.int64
    for i in 0 ..< count:
      let id = world.activeBodies[i].int
      world.spatialX[id] = int32(world.bodies[id].x + world.hullX[id])
      world.spatialY[id] = int32(world.bodies[id].y + world.hullY[id])
      if routeFlow and world.bodies[id].kind == ShipBody and
        not world.escaping(id):
          # Bounds cover solid motion, including contact corrections.
          let owner = world.ships[id].owner
          sweepX[owner] = max(sweepX[owner], Reach.int64 +
            abs(world.spatialX[id].int64 -
              int32(world.bodies[id].previousX + world.previousHullX[id]).int64))
          sweepY[owner] = max(sweepY[owner], Reach.int64 +
            abs(world.spatialY[id].int64 -
              int32(world.bodies[id].previousY + world.previousHullY[id]).int64))
    # Planets stay fixed, and owner lists replace all ship links below.
    if iteration == 0:
      world.buildGrid(count, 16)
    # Enemy ships never need contact queries against one another's fleets.
    ownerHeads = default(typeof(ownerHeads))
    for i in 0 ..< count:
      let id = world.activeBodies[i].int
      if world.bodies[id].kind != ShipBody or world.escaping(id):
        continue
      let
        owner = world.ships[id].owner
        column = cell(world.spatialX[id], 16, Columns)
        row = cell(world.spatialY[id], 16, Rows)
        index = row * Columns + column
      world.gridNext[id] = ownerHeads[owner][index]
      ownerHeads[owner][index] = (id + 1).uint16
    # Wake lower-ID neighbors so active contacts retain the stable pair order.
    awake = dirty
    # Every moving ship is already awake for the first projection.
    if iteration > 0:
      for i in 0 ..< count:
        let id = world.activeBodies[i].int
        if not dirty[id]:
          continue
        let
          startX =
            if routeFlow:
              int32(world.bodies[id].previousX + world.previousHullX[id]).int64
            else: world.spatialX[id].int64
          startY =
            if routeFlow:
              int32(world.bodies[id].previousY + world.previousHullY[id]).int64
            else: world.spatialY[id].int64
          left = cell(min(world.spatialX[id].int64, startX) -
            sweepX[world.ships[id].owner], 16, Columns)
          right = cell(max(world.spatialX[id].int64, startX) +
            sweepX[world.ships[id].owner], 16, Columns)
          top = cell(min(world.spatialY[id].int64, startY) -
            sweepY[world.ships[id].owner], 16, Rows)
          bottom = cell(max(world.spatialY[id].int64, startY) +
            sweepY[world.ships[id].owner], 16, Rows)
        for row in top .. bottom:
          for column in left .. right:
            var cursor = ownerHeads[world.ships[id].owner][row * Columns + column]
            while cursor != 0:
              let other = cursor.int - 1
              cursor = world.gridNext[other]
              if other < id and world.ships[other].owner == world.ships[id].owner:
                awake[other] = true
    dirty = awake
    var maximumOverlap = FixedZero
    for i in 0 ..< count:
      let id = world.activeBodies[i].int
      let body = addr world.bodies[id]
      if (not dirty[id] and not changed[id]) or body.kind != ShipBody or
        body.speed <= FixedZero or body.hit or world.escaping(id):
        continue
      let
        startX =
          if routeFlow:
            int32(body.previousX + world.previousHullX[id]).int64
          else: world.spatialX[id].int64
        startY =
          if routeFlow:
            int32(body.previousY + world.previousHullY[id]).int64
          else: world.spatialY[id].int64
        left = cell(min(world.spatialX[id].int64, startX) -
          sweepX[world.ships[id].owner], 16, Columns)
        right = cell(max(world.spatialX[id].int64, startX) +
          sweepX[world.ships[id].owner], 16, Columns)
        top = cell(min(world.spatialY[id].int64, startY) -
          sweepY[world.ships[id].owner], 16, Rows)
        bottom = cell(max(world.spatialY[id].int64, startY) +
          sweepY[world.ships[id].owner], 16, Rows)
      for row in top .. bottom:
        for column in left .. right:
          var cursor = ownerHeads[world.ships[id].owner][row * Columns + column]
          while cursor != 0:
            let other = cursor.int - 1
            cursor = world.gridNext[other]
            if other <= id or
              world.ships[other].owner != world.ships[id].owner:
              continue
            let neighbor = addr world.bodies[other]
            if neighbor.speed <= FixedZero or neighbor.hit:
              continue
            var
              dx = neighbor.x + world.hullX[other] - body.x - world.hullX[id]
              dy = neighbor.y + world.hullY[other] - body.y - world.hullY[id]
            let
              radius = world.hullRadius[id] + world.hullRadius[other]
              oldX = neighbor.previousX + world.previousHullX[other] -
                body.previousX - world.previousHullX[id]
              oldY = neighbor.previousY + world.previousHullY[other] -
                body.previousY - world.previousHullY[id]
              sweepRadius = max(world.hullRadius[id],
                world.previousHullRadius[id]) +
                max(world.hullRadius[other], world.previousHullRadius[other])
            if (min(dx, oldX) > sweepRadius or max(dx, oldX) < -sweepRadius) or
              (min(dy, oldY) > sweepRadius or max(dy, oldY) < -sweepRadius):
                continue
            if triangleFlow:
              # Reject the corners of the swept bounding box before testing
              # four sets of triangle axes. The extra slack covers pose bends.
              let
                closestX = max(FixedZero, max(min(dx, oldX), -max(dx, oldX)))
                closestY = max(FixedZero, max(min(dy, oldY), -max(dy, oldY)))
                bound = sweepRadius + FixedOne / 8
              if lengthSquared(closestX, closestY) >
                int32(bound).int64 * int32(bound):
                  continue
            var
              distance = FixedZero
              overlap = FixedZero
            if not triangleFlow or nearPlanets[id] or nearPlanets[other]:
              let
                guard =
                  if triangleFlow: max(planetGuard[id], planetGuard[other])
                  else: FixedOne
                oldGuard =
                  if triangleFlow:
                    max(oldPlanetGuard[id], oldPlanetGuard[other])
                  else: FixedOne
                contactRadius = radius * guard
                contactSweepRadius = sweepRadius * max(guard, oldGuard)
              if lengthSquared(dx, dy) <
                int32(contactRadius).int64 * int32(contactRadius):
                  distance = hypot(dx, dy)
                  overlap = contactRadius - distance
              let
                deltaX = dx - oldX
                deltaY = dy - oldY
                travel = deltaX * deltaX + deltaY * deltaY
              if travel > FixedZero:
                let moment = -(oldX * deltaX + oldY * deltaY) / travel
                if moment > FixedOne / 8 and moment < FixedOne:
                  let
                    sampleX = oldX + deltaX * moment
                    sampleY = oldY + deltaY * moment
                    # Two rounded interpolation products can add one quantum.
                    bound = contactSweepRadius + Fixed(2)
                  if lengthSquared(sampleX, sampleY) <
                    int32(bound).int64 * int32(bound):
                      let
                        sampleDistance = hypot(sampleX, sampleY)
                        oldDistance = hypot(oldX, oldY)
                        required = min(contactSweepRadius, oldDistance) *
                          (FixedOne - moment) + contactSweepRadius * moment
                        sweepOverlap = (required - sampleDistance) / moment
                      if sampleDistance > FixedZero and sweepOverlap > overlap:
                        dx = sampleX
                        dy = sampleY
                        distance = sampleDistance
                        overlap = sweepOverlap
            if triangleFlow:
              for sample in 1 .. 4:
                let
                  blend = FixedOne * sample.int32 / 4
                  pairX = neighbor.previousX - body.previousX +
                    ((neighbor.x - neighbor.previousX) -
                      (body.x - body.previousX)) * blend
                  pairY = neighbor.previousY - body.previousY +
                    ((neighbor.y - neighbor.previousY) -
                      (body.y - body.previousY)) * blend
                  contact = hullPenetration(hullSamples[id][sample],
                    hullSamples[other][sample], pairX, pairY)
                  amount = contact.amount / blend
                if amount > overlap:
                  overlap = amount
                  dx = contact.nx
                  dy = contact.ny
                  distance = FixedOne
            if overlap <= FixedZero:
              continue
            if distance == FixedZero:
              dx = FixedOne
              dy = if ((id xor other) and 1) == 0: FixedOne else: -FixedOne
              distance = hypot(dx, dy)
            let
              nx = dx / distance
              ny = dy / distance
              closing = (world.hullDX[id] - world.hullDX[other]) * nx +
                (world.hullDY[id] - world.hullDY[other]) * ny
              # Repeated sideways pushes add energy, so finish radially.
              slip =
                if closing <= FixedOne / 2: FixedZero
                elif routeFlow:
                  if iteration < 4 and
                    world.neighborVX[id] * world.neighborVX[other] +
                      world.neighborVY[id] * world.neighborVY[other] <
                      -FixedOne / 4:
                        -FixedOne / 2
                  else:
                    FixedZero
                else: FixedOne
              push = overlap / 2 + Fixed(2)
              pushX = (nx + ny * slip) * push
              pushY = (ny - nx * slip) * push
              share =
                if routeFlow:
                  world.routePriority[other] * 2 /
                    (world.routePriority[id] + world.routePriority[other])
                else:
                  FixedOne
            maximumOverlap = max(maximumOverlap, overlap)
            body.x -= pushX * share
            body.y -= pushY * share
            neighbor.x += pushX * (FixedOne * 2 - share)
            neighbor.y += pushY * (FixedOne * 2 - share)
            changed[id] = true
            changed[other] = true
    # Finish the complete ship pass before enforcing immovable obstacles.
    for i in 0 ..< count:
      let id = world.activeBodies[i].int
      let body = addr world.bodies[id]
      if (not dirty[id] and not changed[id]) or body.kind != ShipBody or
        body.speed <= FixedZero or body.hit or world.escaping(id):
        continue
      if world.planets.len > 0:
        let
          left = cell(int32(body.x).int64 - int32(planetReach), 16, Columns)
          right = cell(int32(body.x).int64 + int32(planetReach), 16, Columns)
          top = cell(int32(body.y).int64 - int32(planetReach), 16, Rows)
          bottom = cell(int32(body.y).int64 + int32(planetReach), 16, Rows)
        for row in top .. bottom:
          for column in left .. right:
            var cursor = world.gridPlanetHeads[row * Columns + column]
            while cursor != 0:
              let
                other = cursor.int - 1
                beforeX = body.x
                beforeY = body.y
              cursor = world.gridNext[other]
              world.collide(id, other)
              if body.target != other:
                let
                  planet = addr world.bodies[other]
                  oldX = body.previousX - planet.x
                  oldY = body.previousY - planet.y
                  deltaX = body.x - body.previousX
                  deltaY = body.y - body.previousY
                  travel = deltaX * deltaX + deltaY * deltaY
                if travel > FixedZero:
                  let moment = -(oldX * deltaX + oldY * deltaY) / travel
                  if moment > FixedOne / 8 and moment < FixedOne:
                    let
                      sampleX = oldX + deltaX * moment
                      sampleY = oldY + deltaY * moment
                      distance = hypot(sampleX, sampleY)
                      radius = planet.radius + body.radius + FixedOne
                    if distance > FixedZero and distance < radius:
                      let push = (radius - distance) / moment + Fixed(2)
                      body.x += sampleX / distance * push
                      body.y += sampleY / distance * push
              if body.x != beforeX or body.y != beforeY:
                maximumOverlap = max(maximumOverlap,
                  hypot(body.x - beforeX, body.y - beforeY))
                changed[id] = true
    if maximumOverlap < FixedOne / 8:
      break
    dirty = changed

proc moveBodies*(world: World, kind = AllPairs) {.measure.} =
  ## Moves ships and resolves candidates from a deterministic tick snapshot.
  let routeFlow = world.setup != nil and world.followsRoute()
  if world.escapesDeadlocks():
    for body in world.bodies.mitems:
      if body.active and body.kind == ShipBody and not body.progressReady:
        body.resetProgress()
  world.spawnGridReady = false
  var
    activeCount = 0
    maximumRadii: array[BodyKind, int32]
    maximumIds: array[BodyKind, int] = [-1, -1]
  if world.setup != nil and not world.setup.legacyMovement:
    world.prepareSpawns()
    for i in 0 ..< MaxBodies:
      let b = addr world.bodies[i]
      world.previousHullHeading[i] = b.heading
      world.previousHullPressure[i] = world.neighborPressure[i]
      world.neighborVX[i] = clamp(b.x - b.previousX, -b.speed, b.speed)
      world.neighborVY[i] = clamp(b.y - b.previousY, -b.speed, b.speed)
      if routeFlow and b.active and b.kind == ShipBody:
        if not b.routeReady:
          b.routeX = b.x
          b.routeY = b.y
          b.routeReady = true
        let distance = hypot(b.targetX - b.x, b.targetY - b.y)
        world.neighborVX[i] = FixedZero
        world.neighborVY[i] = FixedZero
        if distance > FixedZero and b.speed > FixedZero:
          world.neighborVX[i] = (b.targetX - b.x) / distance
          world.neighborVY[i] = (b.targetY - b.y) / distance
      world.neighborPressure[i] = FixedZero
    for i in 0 ..< MaxBodies:
      if world.bodies[i].active and world.bodies[i].kind == ShipBody:
        world.neighborHeading[i] =
          if world.setup.legacyFlocking: world.flockHeading(i)
          elif routeFlow: world.routeHeading(i)
          else: world.flowHeading(i)
    world.spawnGridReady = false
  profileBlock "movement":
    for i in 0 ..< MaxBodies:
      if not world.bodies[i].active:
        continue
      world.activeBodies[activeCount] = i.uint16
      inc activeCount
      let body = addr world.bodies[i]
      if body.kind == ShipBody:
        body.previousX = body.x
        body.previousY = body.y
        let travelHeading =
          if world.setup == nil or world.setup.legacyMovement: arctan2(body.targetY - body.y, body.targetX - body.x)
          else: world.neighborHeading[i]
        if routeFlow:
          let turn = arctan2(sin(travelHeading - body.heading),
            cos(travelHeading - body.heading))
          body.heading += clamp(turn / 6, -FixedOne / 20, FixedOne / 20)
        else:
          body.heading = travelHeading
        body.x += cos(travelHeading) * body.speed
        body.y += sin(travelHeading) * body.speed
      if kind != AllPairs:
        world.spatialX[i] = int32(body.x)
        world.spatialY[i] = int32(body.y)
        maximumRadii[body.kind] = max(
          maximumRadii[body.kind], int32(body.radius)
        )
        maximumIds[body.kind] = i
  let size =
    case kind
    of Grid16: 16
    of Grid32: 32
    else: 64
  profileBlock "spatial index":
    case kind
    of SortAxis:
      world.sortAxis(activeCount)
    of Grid16, Grid32, Grid64:
      world.buildGrid(activeCount, size)
    of AllPairs:
      discard
  profileBlock "collisions":
    case kind
    of AllPairs:
      for i in 0 ..< activeCount:
        for j in i + 1 ..< activeCount:
          world.collide(world.activeBodies[i].int, world.activeBodies[j].int)
    of SortAxis:
      for i in 0 ..< activeCount:
        let id = world.activeBodies[i].int
        for group in BodyKind:
          if id >= maximumIds[group]:
            continue
          let
            radius = int32(world.bodies[id].radius).int64 + maximumRadii[group]
            left = world.spatialX[id].int64 - radius
            right = world.spatialX[id].int64 + radius
            start =
              if group == PlanetBody: 0
              else: world.sortedCounts[PlanetBody]
            finish = start + world.sortedCounts[group]
          var index = world.firstInRange(
            start, world.sortedCounts[group], left
          )
          while index < finish and world.sorted[index].x.int64 <= right:
            let other = world.sorted[index].id.int
            if other > id:
              world.collide(id, other)
            inc index
    of Grid16, Grid32, Grid64:
      let
        columns = (Width + size - 1) div size
        rows = (Height + size - 1) div size
      for i in 0 ..< activeCount:
        let id = world.activeBodies[i].int
        for group in BodyKind:
          if id >= maximumIds[group]:
            continue
          let
            radius = int32(world.bodies[id].radius).int64 + maximumRadii[group]
            left = cell(world.spatialX[id].int64 - radius, size, columns)
            right = cell(world.spatialX[id].int64 + radius, size, columns)
            top = cell(world.spatialY[id].int64 - radius, size, rows)
            bottom = cell(world.spatialY[id].int64 + radius, size, rows)
          for y in top .. bottom:
            for x in left .. right:
              let cellIndex = y * columns + x
              var cursor =
                if group == PlanetBody: world.gridPlanetHeads[cellIndex]
                else: world.gridHeads[cellIndex]
              while cursor != 0:
                let other = cursor.int - 1
                if other > id:
                  world.collide(id, other)
                cursor = world.gridNext[other]
  if world.setup != nil and not world.setup.legacyMovement and
    not world.setup.legacyFlocking and not world.setup.legacyContacts:
      world.separateHulls(activeCount)
  world.updateDeadlocks()
