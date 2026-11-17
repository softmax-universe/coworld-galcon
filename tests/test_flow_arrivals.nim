import
  std/strformat,
  galcon/[common, worlds],
  flowfixtures

proc testFlowArrivals*() =
  ## Requires complete delivery to actual planets after friendly avoidance.
  echo "Friendly fleets deliver every ordered ship after crossing"
  for kind in ContactTraffic:
    for count in [32, 128, FlowShipCount]:
      let world = destinationFlowWorld(kind, count = count)
      var
        expected: seq[int64]
        maximumPressure: Fixed
      for planet in world.planets:
        expected.add planet.ships
      for order in world.orders:
        expected[order.target] += stock(order.count.int)
      doAssert world.flowPending() == count
      doAssert world.flowArrived() == 0
      while world.flowArrived() < count and world.tick < 1600:
        world.advance()
        doAssert world.winner == -1
        for i, body in world.bodies:
          if body.active and body.kind == ShipBody:
            maximumPressure = max(maximumPressure, world.neighborPressure[i])
      echo &"  {kind} ships={count} arrived={world.flowArrived()} " &
        &"ticks={world.tick}"
      doAssert world.flowArrived() == count,
        "All ships must reach their destination, not merely leave the crossing"
      doAssert maximumPressure > FixedZero,
        "The launched fleets must exercise friendly contact avoidance"
      doAssert world.activeShips == 0
      doAssert world.flowPending() == 0
      doAssert world.pendingLaunchCount == 0
      for i, planet in world.planets:
        doAssert planet.ships == expected[i],
          "Every route must deliver exactly its accepted order"
        for incoming in planet.incoming:
          doAssert incoming == 0

  echo "Enemy pass-through fleets still reach their hostile destinations"
  let world = destinationFlowWorld(HeadOnContact, enemies = true)
  var expected: seq[int64]
  for planet in world.planets:
    expected.add planet.ships
  for order in world.orders:
    expected[order.target] -= stock(order.count.int)
  while world.flowArrived() < FlowShipCount and world.tick < 1600:
    world.advance()
    doAssert world.winner == -1
  echo &"  enemy ships={FlowShipCount} arrived={world.flowArrived()} " &
    &"ticks={world.tick}"
  doAssert world.flowArrived() == FlowShipCount
  doAssert world.activeShips == 0
  doAssert world.pendingLaunchCount == 0
  doAssert world.impacts == FlowShipCount
  doAssert world.captures == 0
  for i, planet in world.planets:
    doAssert planet.ships == expected[i]
    for incoming in planet.incoming:
      doAssert incoming == 0
