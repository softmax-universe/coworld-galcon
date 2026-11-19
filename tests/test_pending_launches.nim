import std/[os, strutils]
import polyworld/tapes
import galcon/[common, worlds, replays, sessions, options]

proc fixture(): World =
  result = newWorld(configuredSetup(42, Easy, 2, 2))
  for p in result.planets:
    p.production = 0
    p.ships = stock(100)

proc testPendingLaunches*() =
  doAssert ReplayVersion == 22,
    "Unified launch and chat actions require the current replay version"
  echo "Accepted 50% launches finish without another command"
  let world = fixture()
  let source = if world.planets[0].owner == 1: 0 else: 1
  let target = 1 - source
  doAssert world.send(1, source, target, 50) == 50,
    "A crowded rim must accept the full snapshot amount, not only immediate spawns"
  doAssert world.planets[source].shipCount == 50
  let peer = world.clone()
  doAssert peer.pendingLaunchCount > 0
  for tick in 0 ..< 500:
    world.advance()
    peer.advance()
    doAssert world.fingerprint() == peer.fingerprint()
  doAssert world.planets[target].shipCount == 50
  doAssert world.orders.len == 1, "Retries must not become replay orders"
  doAssert world.orders[0].count == 50

  echo "Blocked rim reserves once, keeps production, and rejects invalid orders"
  block:
    let w = fixture()
    let s = if w.planets[0].owner == 1: 0 else: 1
    let t = 1 - s
    let body = w.planets[s].body
    let radius = w.bodies[body].radius
    w.bodies[body].radius = fixed(100)
    doAssert w.send(1, s, t, 50) == 50
    doAssert w.activeShips == 0 and w.pendingLaunchCount == 1
    let hash = w.fingerprint()
    for args in [(2, s, t, 1), (1, s, s, 1), (1, -1, t, 1),
      (1, s, t, 0), (1, s, 99, 1)]:
      doAssert w.launch(args[0], args[1], args[2], args[3]) == 0
      doAssert w.fingerprint() == hash
    let copy = w.clone()
    copy.pendingLaunches[0].count -= 1
    doAssert copy.fingerprint() != hash
    doAssert w.fingerprint() == hash
    w.planets[s].production = 100
    for tick in 0 ..< 32: w.advance()
    let growth = w.planets[s].ships - stock(50)
    doAssert growth > 0
    w.planets[s].production = 0
    w.bodies[body].radius = radius
    for tick in 0 ..< 500: w.advance()
    doAssert w.pendingLaunchCount == 0
    doAssert w.planets[s].ships == stock(50) + growth
    doAssert w.planets[t].shipCount == 50
  echo "Repeated requests cannot overcommit; a full queue rejects without changes"
  block:
    let w = fixture()
    let s = if w.planets[0].owner == 1: 0 else: 1
    let t = 1 - s
    w.bodies[w.planets[s].body].radius = fixed(100)
    doAssert w.launch(1, s, t, 75) == 75
    doAssert w.launch(1, s, t, 75) == 25
    let hash = w.fingerprint()
    doAssert w.launch(1, s, t, 75) == 0
    doAssert w.fingerprint() == hash
    doAssert w.pendingLaunches[0].count == 75
    doAssert w.pendingLaunches[1].count == 25
    w.planets[s].ships = stock(MaxPendingLaunches)
    for i in 2 ..< MaxPendingLaunches:
      doAssert w.launch(1, s, t, 1) == 1
    let full = w.fingerprint()
    doAssert w.launch(1, s, t, 1) == 0
    doAssert w.fingerprint() == full
  echo "Capture cancels former-owner escrow and never gives it to the captor"
  block:
    let w = fixture()
    let s = if w.planets[0].owner == 1: 0 else: 1
    let t = 1 - s
    w.bodies[w.planets[s].body].radius = fixed(100)
    doAssert w.send(1, s, t, 100) == 100
    w.bodies[20] = Body(active: true, kind: ShipBody, hit: true,
      x: w.planets[s].x, y: w.planets[s].y, radius: fixed(ShipRadius),
      weight: 1, target: w.planets[s].body)
    w.ships[20] = Ship(owner: 2, target: s)
    w.planets[s].incoming[2] = 1
    w.activeShips = 1
    w.advance()
    doAssert w.planets[s].owner == 2
    doAssert w.pendingLaunchCount == 0
    doAssert w.planets[s].shipCount == 1
  echo "A full body pool resumes when slots become free"
  block:
    let w = fixture()
    let s = if w.planets[0].owner == 1: 0 else: 1
    let t = 1 - s
    for i in 0 ..< MaxBodies:
      if not w.bodies[i].active:
        w.bodies[i] = Body(active: true, kind: PlanetBody,
          x: fixed(600), y: fixed(400), radius: fixed(1), weight: 1, target: -1)
    doAssert w.send(1, s, t, 50) == 50
    doAssert w.activeShips == 0
    for i in 0 ..< MaxBodies:
      if i notin [w.planets[s].body, w.planets[t].body]:
        w.bodies[i].active = false
    for tick in 0 ..< 500: w.advance()
    doAssert w.pendingLaunchCount == 0
    doAssert w.planets[t].shipCount == 50
  echo "Accepted orders replay once across save/load, seeks, and checkpoints"
  block:
    let setup = configuredSetup(42, Easy, 2, 2)
    let w = newWorld(setup)
    let s = if w.planets[0].owner == 1: 0 else: 1
    let tape = Recording(setup: setup)
    doAssert w.send(1, s, 1 - s, 50) == 50
    for tick in 0 ..< 512:
      w.advance()
      tape.recordTick(w)
    doAssert tape.actions.len == 1 and tape.actions[0].kind == ActionLaunch
    doAssert tape.actions[0].count == 50
    let path = Root / "build/pending.replay"
    tape.save(path)
    let playback = newSession(parseOptions(@["--replay", path]))
    for tick in [512'i32, 1, 128, 3, 400, 512]:
      playback.seek(tick)
      doAssert playback.world.fingerprint() == tape.hashes[tick - 1]
    removeFile(path)
  echo "Accepted amounts larger than the body pool survive replay files"
  block:
    let setup = configuredSetup(42, Easy, 2, 2)
    let w = newWorld(setup)
    let tape = Recording(setup: setup)
    let s = if w.planets[0].owner == 1: 0 else: 1
    w.planets[s].ships = stock(5000)
    let amount = w.planets[s].shipCount
    doAssert amount > MaxBodies
    doAssert w.launch(1, s, 1 - s, amount) == amount
    w.advance()
    tape.recordTick(w)
    let path = Root / "build/large-pending.replay"
    tape.save(path)
    let loaded = loadRecording(path)
    doAssert loaded.actions[0].kind == ActionLaunch
    doAssert loaded.actions[0].count == amount.int32
    let playback = newWorld(loaded.setup)
    playback.planets[s].ships = stock(5000)
    var cursor = 0
    for tick in 0 ..< loaded.hashes.len: loaded.replayTick(playback, cursor)
    doAssert playback.fingerprint() == w.fingerprint()
    removeFile(path)
  echo "Current files retain immediate-spawn settings and reject version 12"
  block:
    let setup = configuredSetup(42, Easy, 2, 2)
    setup.legacyLaunches = true
    setup.legacyMovement = true
    let w = newWorld(setup)
    let s = if w.planets[0].owner == 1: 0 else: 1
    let sent = w.send(1, s, 1 - s, 50)
    doAssert sent > 0 and sent < 50
    let tape = Recording(setup: setup)
    for tick in 0 ..< 128:
      w.advance()
      tape.recordTick(w)
    let path = Root / "build/launch-v12.replay"
    let copy = Root / "build/launch-current-legacy.replay"
    saveReplayFile(path, "galcon", 12, "unsupported")
    var rejected = false
    try:
      discard loadRecording(path)
    except GalconError as error:
      rejected = error.msg.contains("version")
    doAssert rejected
    tape.save(copy)
    let session = newSession(parseOptions(@["--replay", copy]))
    doAssert session.world.setup.legacyLaunches
    doAssert session.world.setup.legacyMovement
    session.seek(128)
    doAssert session.world.fingerprint() == w.fingerprint()
    doAssert session.world.pendingLaunchCount == 0
    removeFile(path)
    removeFile(copy)

when isMainModule:
  testPendingLaunches()
