import common, profiles, spaces

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
    let
      reach = int32(radius).int64 + int32(world.spawnRadii[group])
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
          let
            body = addr world.bodies[cursor.int - 1]
            dx = body.x - x
            dy = body.y - y
            distance = int32(radius + body.radius).int64
          if lengthSquared(dx, dy) < distance * distance:
            return false
          cursor = world.gridNext[cursor.int - 1]
  true

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

proc collide(world: World, first, second: int) {.inline.} =
  ## Applies the original weighted fixed-point response to one candidate pair.
  let
    a = addr world.bodies[first]
    b = addr world.bodies[second]
    radius = a.radius + b.radius
  if world.setup.enemyShipsPassThrough and
    a.kind == ShipBody and b.kind == ShipBody and
    world.ships[first].owner != world.ships[second].owner:
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

proc moveBodies*(world: World, kind = AllPairs) {.measure.} =
  ## Moves ships and resolves candidates from a deterministic tick snapshot.
  world.spawnGridReady = false
  var
    activeCount = 0
    maximumRadii: array[BodyKind, int32]
    maximumIds: array[BodyKind, int] = [-1, -1]
  if world.setup != nil and not world.setup.legacyMovement:
    world.prepareSpawns()
    for i in 0 ..< MaxBodies:
      let b = addr world.bodies[i]
      world.neighborVX[i] = clamp(b.x - b.previousX, -b.speed, b.speed)
      world.neighborVY[i] = clamp(b.y - b.previousY, -b.speed, b.speed)
    for i in 0 ..< MaxBodies:
      if world.bodies[i].active and world.bodies[i].kind == ShipBody:
        world.neighborHeading[i] = world.flockHeading(i)
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
        body.heading =
          if world.setup == nil or world.setup.legacyMovement: arctan2(body.targetY - body.y, body.targetX - body.x)
          else: world.neighborHeading[i]
        body.x += cos(body.heading) * body.speed
        body.y += sin(body.heading) * body.speed
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
