import
  std/[math, strformat],
  galcon/[common, physics, worlds],
  test_ship_contacts

type TrafficMetrics* = object
  minimumProgress*, averageProgress*: float64
  averageTurn*, maximumTurn*: float64
  backwardsSteps*: int

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
  ## Requires current crowded traffic snapshots to agree across all backends.
  echo "Current contact traffic stays deterministic after restoring a snapshot"
  for traffic in ContactTraffic:
    let original = contactWorld(traffic, 32)
    discard original.measureTraffic(80)
    let expected = original.clone()
    discard expected.measureTraffic(24)
    for kind in CollisionKind:
      let actual = original.clone()
      discard actual.measureTraffic(24, kind)
      doAssert actual.fingerprint() == expected.fingerprint(),
        "Collision backends must reproduce the same current traffic snapshot"
