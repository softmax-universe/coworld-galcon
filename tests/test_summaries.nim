import
  std/[os, times],
  galcon/[common, worlds, sessions, options, summaries, transports]

proc testSummaries*() =
  ## Verifies stock histories, replay scrubbing, and real-time ending holds.
  echo "Ship histories include planet stocks and fleets without changing play"
  let
    path = Root / "build" / "score-history.replay"
    configured = parseOptions(@[
      "--headless", "--players", "5", "--seed", "8", "--ticks", "3200",
      "--record", path
    ])
    referenceOptions = configured.clone()
    session = newSession(configured)
    summary = newSummary(session.maximumTicks)
  referenceOptions.game.recordPath = ""
  let reference = newSession(referenceOptions)
  summary.observe(session.world)
  session.tickObserver = proc(world: World) =
    ## Samples only the viewer's independently owned history.
    summary.observe(world)
  let initial = summary.samples[0].ships[1]
  var source = -1
  for i, planet in session.world.planets:
    if planet.owner == 1:
      source = i
  let target = (source + 1) mod session.world.planets.len
  doAssert session.world.launch(1, source, target, 7) == 7
  doAssert reference.world.launch(1, source, target, 7) == 7
  session.step()
  reference.step()
  doAssert summary.samples[1].ships[1] >= initial
  while not session.done:
    session.step()
    reference.step()
    doAssert session.world.fingerprint() == reference.world.fingerprint()
  doAssert summary.lastTick == session.world.tick
  var maximum = 0'i64
  for sample in summary.samples[0 .. summary.lastTick]:
    for owner in 1 .. session.world.setup.players:
      maximum = max(maximum, sample.ships[owner])
    doAssert sample.maximum == maximum
  for owner in 1 .. session.world.setup.players:
    if session.world.winner >= 0 and owner != session.world.winner:
      doAssert summary.eliminated[owner] >= 0
      doAssert summary.samples[summary.eliminated[owner]].ships[owner] == 0
  let
    finalTick = session.world.tick
    last = summary.samples[finalTick]
  session.saveRecording(path)
  let
    replay = newSession(parseOptions(@["--replay", path]))
    history = newSummary(replay.maximumTicks)
  history.observe(replay.world)
  replay.tickObserver = proc(world: World) =
    ## Reconstructs the same samples from the existing replay format.
    history.observe(world)
  replay.seek(finalTick)
  doAssert history.samples == summary.samples[0 .. finalTick]
  replay.seek(37)
  doAssert history.samples[37] == summary.samples[37]
  replay.seek(finalTick)
  doAssert history.samples[finalTick] == last
  removeFile(path)

  echo "Eliminated factions stop at zero on the shared historical scale"
  block:
    let
      world = newWorld(Setup(seed: 42, counts: @[0, 1, 1]))
      history = newSummary(10)
    for planet in world.planets:
      planet.ships = stock(if planet.owner == 1: 10 else: 80)
    history.observe(world)
    doAssert history.samples[0].maximum == 80
    for planet in world.planets:
      if planet.owner == 2:
        planet.owner = 1
    world.tick = 1
    history.observe(world)
    doAssert history.eliminated[2] == 1
    doAssert history.samples[1].ships[2] == 0
    doAssert history.samples[1].maximum == 90

  echo "Results stay visible indefinitely and cannot be dismissed by Tab"
  for speed in [1'i32, 16]:
    let ending = newSession(parseOptions(@["--headless", "--ticks", "1"]))
    var
      bar = Transport(player: initPlayer(true, 1, speed = speed,
        repeating = true))
      card: Card
    discard bar.advancePlayback(ending, 1, epochTime(), holdAtEnd = true)
    doAssert ending.world.tick == 1
    doAssert bar.player.restoreTick == -1
    card.update(true, 100)
    for now in [100.0, 105.0, 109.999]:
      card.update(true, now)
      doAssert card.shown and card.holding(now)
      discard bar.advancePlayback(ending, 1, epochTime(),
        holdAtEnd = card.holding(now))
      doAssert ending.world.tick == 1
      doAssert bar.player.restoreTick == -1
    for now in [110.0, 125.0, 86400.0]:
      card.update(true, now)
      doAssert card.shown and card.holding(now), "Results must not expire"
      card.toggle()
      doAssert card.shown, "Tab cannot dismiss final results"
      discard bar.advancePlayback(ending, 0, epochTime(), holdAtEnd = card.holding(now))
      doAssert bar.player.restoreTick == -1
    card.update(false, 86401)
    doAssert not card.shown and not card.terminal
    card.toggle()
    doAssert card.shown
    card.toggle()
    doAssert not card.shown

  block:
    let timed = newSession(parseOptions(@["--headless", "--ticks", "1"]))
    timed.step()
    doAssert timed.resultTitle() == "Time limit reached"
    timed.world.winner = 1
    timed.names[1] = "Winner :)"
    doAssert timed.resultTitle() == "Winner :) wins"
    timed.world.winner = 0
    doAssert timed.resultTitle() == "Draw"
    timed.world.winner = -1
    timed.world.tick = 0
    doAssert timed.resultTitle(interrupted = true) == "Match interrupted"

when isMainModule:
  testSummaries()
