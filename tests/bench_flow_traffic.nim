import
  std/[monotimes, strformat, times],
  galcon/common,
  test_flow_traffic, test_ship_contacts

proc benchmark(world: World, label: string, ticks: int, legacy: bool) =
  ## Compares identical fleet fixtures under preserved and current steering.
  world.setup.legacyFlocking = legacy
  let
    started = getMonoTime()
    metrics = world.measureTraffic(ticks)
    duration = (getMonoTime() - started).inNanoseconds.float64 / 1e6
    version =
      if legacy: "v15"
      elif world.setup.legacyContacts: "v16 soft flow"
      else: "current friendly contacts"
  echo version, " ", label, " ships=", world.activeShips,
    " ticks=", ticks, " ", metrics.describe(),
    &" durationMs={duration:.2f}"

for legacy in [true, false]:
  for kind in TrafficKind:
    benchmark(trafficWorld(kind), $kind, 240, legacy)
  benchmark(trafficWorld(OpposingTraffic, MaxBodies), "full pool", 96,
    legacy)
  benchmark(planetTraffic(), "planet crossing", 360, legacy)

for kind in ContactTraffic:
  benchmark(contactWorld(kind), $kind, 360, false)
