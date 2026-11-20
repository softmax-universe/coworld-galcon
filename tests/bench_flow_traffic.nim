import
  std/[monotimes, strformat, times],
  galcon/common,
  test_flow_traffic, test_ship_contacts

proc benchmark(world: World, label: string, ticks: int) =
  ## Measures current steering through crowded fleet crossings.
  let
    started = getMonoTime()
    metrics = world.measureTraffic(ticks)
    duration = (getMonoTime() - started).inNanoseconds.float64 / 1e6
  echo label, " ships=", world.activeShips,
    " ticks=", ticks, " ", metrics.describe(),
    &" durationMs={duration:.2f}"

for kind in ContactTraffic:
  benchmark(contactWorld(kind), $kind, 360)
