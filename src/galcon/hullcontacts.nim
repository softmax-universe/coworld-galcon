import common

type
  HullVector = tuple[x, y: Fixed]
  HullTriangle* = object
    vertices: array[3, HullVector]
    axes: array[3, HullVector]
    minimum, maximum: array[3, Fixed]
  HullSamples* = array[1 .. 4, HullTriangle]

proc makeHullSample*(world: World, id, sample: int,
    turn: Fixed): HullTriangle =
  ## Precomputes the visible triangle and its axes between simulation ticks.
  let
    blend = FixedOne * sample.int32 / 4
    heading = world.previousHullHeading[id] + turn * blend
    pressure = world.previousHullPressure[id] +
      (world.neighborPressure[id] - world.previousHullPressure[id]) * blend
    forward = FixedOne - pressure / 10
    width = fixed(3) - pressure * 3 / 4
    dx = cos(heading)
    dy = sin(heading)
  result.vertices[0] = (dx * forward * 6, dy * forward * 6)
  result.vertices[1] = (-dx * forward * 3 - dy * width,
    -dy * forward * 3 + dx * width)
  result.vertices[2] = (-dx * forward * 3 + dy * width,
    -dy * forward * 3 - dx * width)
  for edge in 0 ..< 3:
    let
      a = result.vertices[edge]
      b = result.vertices[(edge + 1) mod 3]
      nx = b.y - a.y
      ny = a.x - b.x
      length = hypot(nx, ny)
    result.axes[edge] = (nx / length, ny / length)
    result.minimum[edge] = fixed(100)
    result.maximum[edge] = -fixed(100)
    for vertex in result.vertices:
      let projected = vertex.x * result.axes[edge].x +
        vertex.y * result.axes[edge].y
      result.minimum[edge] = min(result.minimum[edge], projected)
      result.maximum[edge] = max(result.maximum[edge], projected)

proc hullPenetration*(a, b: HullTriangle, dx, dy: Fixed):
    tuple[amount, nx, ny: Fixed] =
  ## Returns the shortest padded separating translation between two triangles.
  # Reserve both half-pixel outlines plus room for solver residuals.
  const Gap = FixedOne * 3 / 2
  result.amount = fixed(100)
  for side in 0 ..< 2:
    for edge in 0 ..< 3:
      let
        axis = if side == 0: a.axes[edge] else: b.axes[edge]
        offset = dx * axis.x + dy * axis.y
      var
        minA = fixed(100)
        maxA = -fixed(100)
        minB = fixed(100)
        maxB = -fixed(100)
      if side == 0:
        minA = a.minimum[edge]
        maxA = a.maximum[edge]
        for vertex in b.vertices:
          let projected = vertex.x * axis.x + vertex.y * axis.y + offset
          minB = min(minB, projected)
          maxB = max(maxB, projected)
      else:
        minB = b.minimum[edge] + offset
        maxB = b.maximum[edge] + offset
        for vertex in a.vertices:
          let projected = vertex.x * axis.x + vertex.y * axis.y
          minA = min(minA, projected)
          maxA = max(maxA, projected)
      let
        positive = maxA - minB + Gap
        negative = maxB - minA + Gap
        amount = min(positive, negative)
      if amount <= FixedZero:
        return (FixedZero, FixedZero, FixedZero)
      if amount < result.amount:
        result.amount = amount
        let sign = if positive <= negative: 1'i32 else: -1'i32
        result.nx = axis.x * sign
        result.ny = axis.y * sign
