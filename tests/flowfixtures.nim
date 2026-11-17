import
  galcon/[common, worlds],
  test_ship_contacts

export ContactTraffic

const
  FlowFleetSize* = 128
  FlowShipCount* = FlowFleetSize * 2

proc addFlowPlanet(world: World, name: string, x, y, owner: int,
    ships = 512, radius = 16) =
  ## Adds a standard-size planet with production disabled for exact accounting.
  let
    slot = MaxBodies - 1 - world.planets.len
    planet = Planet(
      name: name, x: fixed(x.int32), y: fixed(y.int32),
      radius: radius, body: slot, owner: owner,
      ships: stock(ships), realShips: stock(ships),
      morale: 100, realMorale: 100,
      textureSeed: (424242 + world.planets.len).int32,
      textureKind: if owner == 0: 1 else: 0
    )
  world.planets.add planet
  world.bodies[slot] = Body(
    active: true, kind: PlanetBody, x: planet.x, y: planet.y,
    radius: fixed(radius.int32), weight: 100_000, target: -1
  )

proc destinationFlowWorld*(kind: ContactTraffic, enemies = false,
    count = FlowShipCount): World =
  ## Sends real planet orders through the same launch and arrival path as play.
  doAssert count > 0 and count mod 2 == 0
  let fleet = count div 2
  result = World(setup: defaultSetup(), winner: -1)
  result.setup.counts = if enemies: @[1, 1, 1] else: @[1, 2, 0]
  result.addFlowPlanet("West", 48, 240, 1, fleet + 512)
  result.addFlowPlanet("East", 592, 240, if enemies: 2 else: 1,
    fleet + 512)
  if kind == CrossingContact:
    result.addFlowPlanet("North", 320, 48, if enemies: 2 else: 1,
      fleet + 512)
    result.addFlowPlanet("South", 320, 432, if enemies: 2 else: 1)
  result.addFlowPlanet("Beacon", 72, 64, 0, 30)
  if kind == PlanetContact:
    result.addFlowPlanet("Crossroads", 320, 240, 0, 30, 22)
  doAssert result.launch(1, 0, 1, fleet) == fleet
  let
    secondSource = if kind == CrossingContact: 2 else: 1
    secondTarget = if kind == CrossingContact: 3 else: 0
    secondOwner = result.planets[secondSource].owner
  doAssert result.launch(
    secondOwner, secondSource, secondTarget, fleet
  ) == fleet

proc flowPending*(world: World): int =
  ## Counts accepted ships still waiting for room at their source planets.
  for i in 0 ..< world.pendingLaunchCount:
    result += world.pendingLaunches[i].count.int

proc flowArrived*(world: World): int =
  ## Counts completed deliveries from the demo's two conserved launch orders.
  for order in world.orders:
    result += order.count.int
  result -= world.activeShips + world.flowPending()
