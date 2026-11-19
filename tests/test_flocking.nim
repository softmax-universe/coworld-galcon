import std/[os, strutils]
import polyworld/tapes
import galcon/[common, worlds, physics, replays]

proc traffic(): World =
  result = newWorld(configuredSetup(42, Easy, 2, 2))
  # Opposite-moving friendly columns meet head on; the other owner keeps play live.
  for p in result.planets:
    p.production = 0
  for i in 0 ..< 24:
    let slot = i + 10
    let east = i < 12
    let target = if east: 0 else: 1
    result.bodies[slot] = Body(active: true, kind: ShipBody,
      x: fixed((if east: 280 + (i mod 4) * 12 else: 360 - (i mod 4) * 12).int32),
      y: fixed((220 + (i mod 3) * 12).int32),
      targetX: fixed(if east: 580 else: 60), targetY: fixed(232),
      radius: fixed(ShipRadius), weight: 1, speed: FixedOne, target: -1)
    let body = addr result.bodies[slot]
    body.heading = arctan2(body.targetY - body.y, body.targetX - body.x)
    body.previousX = body.x - cos(body.heading)
    body.previousY = body.y - sin(body.heading)
    result.ships[slot] = Ship(owner: 1, target: target)
  result.activeShips = 24

proc testFlocking*() =
  echo "Friendly opposing columns make net progress after collision resolution"
  let w = traffic()
  let before = w.clone()
  for tick in 0 ..< 160: w.moveBodies(Grid16)
  var progressed = 0
  for i in 10 ..< 34:
    let dx = w.bodies[i].x - before.bodies[i].x
    if (i < 22 and dx > fixed(80)) or (i >= 22 and dx < fixed(-80)):
      inc progressed
  echo "progressed=", progressed, "/24"
  doAssert progressed == 24

  echo "Alignment follows moving friends, ignores enemy and stationary headings"
  block:
    proc aligned(owner: int, moving: bool): Fixed =
      let v = World(setup: defaultSetup(), winner: -1)
      v.bodies[10] = Body(active: true, kind: ShipBody, x: fixed(100), y: fixed(100),
        previousX: fixed(99), previousY: fixed(100), targetX: fixed(500), targetY: fixed(100),
        radius: fixed(6), speed: FixedOne, weight: 1, target: -1)
      v.ships[10].owner = 1
      v.bodies[11] = Body(active: true, kind: ShipBody, x: fixed(100), y: fixed(120),
        previousX: fixed(100) - (if moving: FixedOne else: FixedZero),
        previousY: fixed(120) - (if moving: FixedOne else: FixedZero),
        targetX: fixed(500), targetY: fixed(400), radius: fixed(6),
        heading: arctan2(FixedOne, FixedOne),
        speed: if moving: FixedOne else: FixedZero,
        weight: 1, target: -1)
      v.ships[11].owner = owner
      v.moveBodies(Grid16)
      v.bodies[10].y - fixed(100)
    doAssert aligned(1, true) > FixedZero
    doAssert aligned(2, true) == FixedZero
    doAssert aligned(1, false) == FixedZero

  echo "Accepted launch batches wait for one tick-wide fair full-ring drain"
  block:
    let q = newWorld(configuredSetup(42, Easy, 2, 3))
    let s = if q.planets[0].owner == 1: 0 elif q.planets[1].owner == 1: 1 else: 2
    let a = (s + 1) mod 3
    let b = (s + 2) mod 3
    doAssert q.launch(1, s, a, 20) == 20
    doAssert q.launch(1, s, b, 20) == 20
    doAssert q.activeShips == 0, "Acceptance must not repeatedly drain the entire queue"
    q.advance()
    echo "ring emitted=", q.activeShips
    doAssert q.activeShips > 1
    doAssert q.planets[a].incoming[1] > 0 and q.planets[b].incoming[1] > 0

  echo "Version 14 is rejected while its physics replay in the current format"
  block:
    let path = Root / "tests/fixtures/movement-v14.replay"
    doAssert readFile(path).replayFileHeader().gameVersion == 14
    var rejected = false
    try:
      discard loadRecording(path)
    except GalconError as error:
      rejected = error.msg.contains("version")
    doAssert rejected, "Old replay versions must be rejected explicitly"
    let setup = configuredSetup(42, Easy, 2, 2)
    setup.legacyMovement = true
    setup.legacyFlocking = true
    setup.legacyContacts = true
    setup.legacyRouteSteering = true
    setup.legacyCrossings = true
    setup.legacyDeadlocks = true
    let
      tape = Recording(setup: setup)
      old = newWorld(setup)
    for tick in 0 ..< 512:
      if tick mod 64 == 0:
        discard old.send(1, 0, 1, 20)
      old.advance()
      tape.recordTick(old)
    doAssert tape.actions.len == 8
    for i, count in [20, 17, 14, 11, 9, 8, 7, 5]:
      doAssert tape.actions[i].kind == ActionLaunch
      doAssert tape.actions[i].tick == (i * 64).int32
      doAssert tape.actions[i].count == count.int32
    doAssert old.fingerprint() == 2096991766765028424'u64
    let copy = Root / "build/movement-legacy-resave.replay"
    tape.save(copy)
    let saved = loadRecording(copy)
    doAssert saved.setup.legacyMovement
    doAssert saved.actions == tape.actions and saved.hashes == tape.hashes
    let again = newWorld(saved.setup)
    var cursor = 0
    for tick in 0 ..< saved.hashes.len: saved.replayTick(again, cursor)
    doAssert again.fingerprint() == old.fingerprint()
    removeFile(copy)

when isMainModule:
  testFlocking()
