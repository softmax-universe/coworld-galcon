import
  std/os,
  polyworld/tapes,
  galcon/[common, worlds, replays]

proc replayFinal(recording: Recording): World =
  ## Replays every order and verifies every recorded simulation fingerprint.
  result = newWorld(recording.setup)
  var cursor = 0
  for tick in 0 ..< recording.hashes.len:
    recording.replayTick(result, cursor)
  doAssert cursor == recording.orders.len

echo "Frozen version 15 fleet movement survives loading and resaving"
block:
  # Captured before version 16: seed 42, three players, nine planets, 512 ticks.
  # Every 64 ticks each owned planet sent 30 ships four planet indices ahead.
  let
    path = Root / "tests/fixtures/movement-v15.replay"
    copied = Root / "build/movement-v15-resave.replay"
    recording = loadRecording(path)
  doAssert readFile(path).replayFileHeader().gameVersion == 15
  doAssert recording.hashes.len == 512
  doAssert recording.orders.len == 30
  doAssert recording.setup.legacyFlocking
  doAssert recording.setup.legacyContacts
  doAssert recording.setup.legacyRouteSteering
  doAssert recording.setup.legacyCrossings
  doAssert recording.setup.legacyDeadlocks
  doAssert not recording.setup.legacyMovement
  let original = recording.replayFinal()
  doAssert original.fingerprint() == 8981790453949206857'u64
  doAssert original.impacts == 150
  recording.save(copied)
  doAssert readFile(copied).replayFileHeader().gameVersion == ReplayVersion
  let saved = loadRecording(copied)
  doAssert saved.setup.legacyFlocking
  doAssert saved.setup.legacyContacts
  doAssert saved.setup.legacyRouteSteering
  doAssert saved.setup.legacyCrossings
  doAssert saved.setup.legacyDeadlocks
  doAssert not saved.setup.legacyMovement
  doAssert saved.hashes == recording.hashes
  doAssert saved.replayFinal().fingerprint() == original.fingerprint()
  removeFile(copied)

echo "Frozen version 16 soft contacts survive loading and resaving"
block:
  # Captured before version 17 with the same launch schedule as version 15.
  let
    path = Root / "tests/fixtures/movement-v16.replay"
    copied = Root / "build/movement-v16-resave.replay"
    recording = loadRecording(path)
  doAssert readFile(path).replayFileHeader().gameVersion == 16
  doAssert recording.hashes.len == 512
  doAssert recording.orders.len == 30
  doAssert recording.setup.legacyContacts
  doAssert recording.setup.legacyRouteSteering
  doAssert recording.setup.legacyCrossings
  doAssert recording.setup.legacyDeadlocks
  doAssert not recording.setup.legacyFlocking
  doAssert not recording.setup.legacyMovement
  let original = recording.replayFinal()
  doAssert original.fingerprint() == 17190597569456507194'u64
  doAssert original.impacts == 165
  recording.save(copied)
  let saved = loadRecording(copied)
  doAssert readFile(copied).replayFileHeader().gameVersion == ReplayVersion
  doAssert saved.setup.legacyContacts
  doAssert saved.setup.legacyRouteSteering
  doAssert saved.setup.legacyCrossings
  doAssert saved.setup.legacyDeadlocks
  doAssert not saved.setup.legacyFlocking
  doAssert not saved.setup.legacyMovement
  doAssert saved.hashes == recording.hashes
  doAssert saved.replayFinal().fingerprint() == original.fingerprint()
  removeFile(copied)

echo "Frozen version 17 contact steering survives loading and resaving"
block:
  # Captured before version 18 with the same launch schedule as version 15.
  let
    path = Root / "tests/fixtures/movement-v17.replay"
    copied = Root / "build/movement-v17-resave.replay"
    recording = loadRecording(path)
  doAssert readFile(path).replayFileHeader().gameVersion == 17
  doAssert recording.hashes.len == 512
  doAssert recording.orders.len == 30
  doAssert recording.setup.legacyRouteSteering
  doAssert recording.setup.legacyCrossings
  doAssert recording.setup.legacyDeadlocks
  doAssert not recording.setup.legacyContacts
  doAssert not recording.setup.legacyFlocking
  doAssert not recording.setup.legacyMovement
  let original = recording.replayFinal()
  doAssert original.fingerprint() == 6077549973392311357'u64
  doAssert original.impacts == 157
  recording.save(copied)
  let saved = loadRecording(copied)
  doAssert readFile(copied).replayFileHeader().gameVersion == ReplayVersion
  doAssert saved.setup.legacyRouteSteering
  doAssert saved.setup.legacyCrossings
  doAssert saved.setup.legacyDeadlocks
  doAssert not saved.setup.legacyContacts
  doAssert not saved.setup.legacyFlocking
  doAssert not saved.setup.legacyMovement
  doAssert saved.hashes == recording.hashes
  doAssert saved.replayFinal().fingerprint() == original.fingerprint()
  removeFile(copied)

echo "Frozen version 18 crossing pressure survives loading and resaving"
block:
  # Captured before version 19 with the same launch schedule as version 15.
  let
    path = Root / "tests/fixtures/movement-v18.replay"
    copied = Root / "build/movement-v18-resave.replay"
    recording = loadRecording(path)
  doAssert readFile(path).replayFileHeader().gameVersion == 18
  doAssert recording.hashes.len == 512
  doAssert recording.orders.len == 27
  doAssert recording.setup.legacyCrossings
  doAssert recording.setup.legacyDeadlocks
  doAssert not recording.setup.legacyRouteSteering
  doAssert not recording.setup.legacyContacts
  doAssert not recording.setup.legacyFlocking
  doAssert not recording.setup.legacyMovement
  let original = recording.replayFinal()
  doAssert original.fingerprint() == 12580543939321267476'u64
  doAssert original.impacts == 134
  recording.save(copied)
  let saved = loadRecording(copied)
  doAssert readFile(copied).replayFileHeader().gameVersion == ReplayVersion
  doAssert saved.setup.legacyCrossings
  doAssert saved.setup.legacyDeadlocks
  doAssert not saved.setup.legacyRouteSteering
  doAssert not saved.setup.legacyContacts
  doAssert not saved.setup.legacyFlocking
  doAssert not saved.setup.legacyMovement
  doAssert saved.hashes == recording.hashes
  doAssert saved.replayFinal().fingerprint() == original.fingerprint()
  removeFile(copied)

echo "Frozen version 19 triangle contacts survive loading and resaving"
block:
  # Captured before version 20 with the same launch schedule as version 15.
  let
    path = Root / "tests/fixtures/movement-v19.replay"
    copied = Root / "build/movement-v19-resave.replay"
    recording = loadRecording(path)
  doAssert readFile(path).replayFileHeader().gameVersion == 19
  doAssert recording.hashes.len == 512
  doAssert recording.orders.len == 27
  doAssert not recording.setup.legacyCrossings
  doAssert recording.setup.legacyDeadlocks
  doAssert not recording.setup.legacyRouteSteering
  doAssert not recording.setup.legacyContacts
  doAssert not recording.setup.legacyFlocking
  doAssert not recording.setup.legacyMovement
  let original = recording.replayFinal()
  doAssert original.fingerprint() == 4654717465150559285'u64
  doAssert original.impacts == 133
  recording.save(copied)
  let saved = loadRecording(copied)
  doAssert readFile(copied).replayFileHeader().gameVersion == ReplayVersion
  doAssert not saved.setup.legacyCrossings
  doAssert saved.setup.legacyDeadlocks
  doAssert not saved.setup.legacyRouteSteering
  doAssert not saved.setup.legacyContacts
  doAssert not saved.setup.legacyFlocking
  doAssert not saved.setup.legacyMovement
  doAssert saved.hashes == recording.hashes
  doAssert saved.replayFinal().fingerprint() == original.fingerprint()
  removeFile(copied)

echo "Current deadlock recovery survives replay and isolated checkpoints"
block:
  let
    setup = configuredSetup(42, Easy, 3, 9)
    world = newWorld(setup)
    recording = Recording(setup: setup)
    copied = Root / "build/movement-v20.replay"
    old = world.clone()
  doAssert not setup.legacyFlocking
  doAssert not setup.legacyMovement
  doAssert not setup.legacyContacts
  doAssert not setup.legacyRouteSteering
  doAssert not setup.legacyCrossings
  doAssert not setup.legacyDeadlocks
  old.setup.legacyContacts = true
  doAssert old.fingerprint() != world.fingerprint(),
    "Peers using different contact rules must disagree before the first order"
  old.setup.legacyContacts = false
  old.setup.legacyRouteSteering = true
  doAssert old.fingerprint() != world.fingerprint(),
    "Peers using different flow rules must disagree before the first order"
  old.setup.legacyRouteSteering = false
  old.setup.legacyCrossings = true
  doAssert old.fingerprint() != world.fingerprint(),
    "Peers using different crossing rules must disagree before the first order"
  old.setup.legacyCrossings = false
  old.setup.legacyDeadlocks = true
  doAssert old.fingerprint() != world.fingerprint(),
    "Peers using different escape rules must disagree before the first order"
  var checkpoint: World
  for tick in 0 ..< 512:
    if tick mod 64 == 0:
      for source, planet in world.planets:
        if planet.owner > 0:
          discard world.launch(
            planet.owner, source, (source + 4) mod world.planets.len, 30
          )
    world.advance()
    recording.recordTick(world)
    if tick == 255:
      checkpoint = world.clone()
  doAssert recording.orders.len > 0
  doAssert world.impacts > 0
  doAssert not checkpoint.setup.legacyFlocking
  doAssert not checkpoint.setup.legacyContacts
  doAssert not checkpoint.setup.legacyRouteSteering
  doAssert not checkpoint.setup.legacyCrossings
  doAssert not checkpoint.setup.legacyDeadlocks
  var cursor = recording.orderCursor(checkpoint.tick)
  while checkpoint.tick < world.tick:
    recording.replayTick(checkpoint, cursor)
  doAssert checkpoint.fingerprint() == world.fingerprint()
  recording.save(copied)
  let saved = loadRecording(copied)
  doAssert not saved.setup.legacyFlocking
  doAssert not saved.setup.legacyMovement
  doAssert not saved.setup.legacyContacts
  doAssert not saved.setup.legacyRouteSteering
  doAssert not saved.setup.legacyCrossings
  doAssert not saved.setup.legacyDeadlocks
  doAssert saved.hashes == recording.hashes
  doAssert saved.replayFinal().fingerprint() == world.fingerprint()
  removeFile(copied)

echo "Active escape checkpoints retain their timers and progress state"
block:
  let world = newWorld(configuredSetup(42, Easy, 3, 9))
  for source, planet in world.planets:
    if planet.owner > 0:
      doAssert world.launch(planet.owner, source,
        (source + 4) mod world.planets.len, 4) == 4
      break
  world.advance()
  var ship = -1
  for i, body in world.bodies:
    if body.active and body.kind == ShipBody:
      ship = i
      break
  doAssert ship >= 0
  let body = addr world.bodies[ship]
  body.progressReady = true
  body.progressDistance = hypot(body.targetX - body.x, body.targetY - body.y)
  body.stalledTicks = TickRate * 3
  body.escapeTicks = TickRate
  let checkpoint = world.clone()
  doAssert checkpoint.bodies[ship].progressReady
  doAssert checkpoint.bodies[ship].progressDistance == body.progressDistance
  doAssert checkpoint.bodies[ship].stalledTicks == body.stalledTicks
  doAssert checkpoint.bodies[ship].escapeTicks == body.escapeTicks
  doAssert checkpoint.fingerprint() == world.fingerprint()
  checkpoint.bodies[ship].escapeTicks += 1
  doAssert checkpoint.fingerprint() != world.fingerprint(),
    "Different escape state must be visible to multiplayer hash checks"
  checkpoint.bodies[ship].escapeTicks -= 1
  for tick in 0 ..< TickRate * 2:
    world.advance()
    checkpoint.advance()
    doAssert checkpoint.fingerprint() == world.fingerprint(),
      "An active escape checkpoint must continue deterministically"
