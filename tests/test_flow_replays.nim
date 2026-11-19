import
  std/[os, strutils],
  polyworld/tapes,
  galcon/[common, worlds, replays]

proc replayFinal(recording: Recording): World =
  ## Replays every order and verifies every recorded simulation fingerprint.
  result = newWorld(recording.setup)
  var cursor = 0
  for tick in 0 ..< recording.hashes.len:
    recording.replayTick(result, cursor)
  doAssert cursor == recording.actions.len

echo "Frozen replay versions are rejected; explicit physics modes still replay"
const FrozenModes = [
  (15, 8981790453949206857'u64, 150, 30),
  (16, 17190597569456507194'u64, 165, 30),
  (17, 6077549973392311357'u64, 157, 30),
  (18, 12580543939321267476'u64, 134, 27),
  (19, 4654717465150559285'u64, 133, 27)
]
for (version, hash, impacts, actions) in FrozenModes:
  let path = Root / "tests/fixtures" / ("movement-v" & $version & ".replay")
  doAssert readFile(path).replayFileHeader().gameVersion == version.uint16
  var rejected = false
  try:
    discard loadRecording(path)
  except GalconError as error:
    rejected = error.msg.contains("version")
  doAssert rejected, "Historical replay files must not enter the current decoder"
  let setup = configuredSetup(42, Easy, 3, 9)
  setup.legacyFlocking = version <= 15
  setup.legacyContacts = version <= 16
  setup.legacyRouteSteering = version <= 17
  setup.legacyCrossings = version <= 18
  setup.legacyDeadlocks = true
  let
    world = newWorld(setup)
    recording = Recording(setup: setup)
    copied = Root / "build" / ("movement-mode-" & $version & ".replay")
  for tick in 0 ..< 512:
    if tick mod 64 == 0:
      for source, planet in world.planets:
        if planet.owner > 0:
          discard world.launch(
            planet.owner, source, (source + 4) mod world.planets.len, 30
          )
    world.advance()
    recording.recordTick(world)
  doAssert world.fingerprint() == hash
  doAssert world.impacts == impacts
  doAssert recording.actions.len == actions
  recording.save(copied)
  doAssert readFile(copied).replayFileHeader().gameVersion == ReplayVersion
  let saved = loadRecording(copied)
  doAssert saved.setup.legacyFlocking == setup.legacyFlocking
  doAssert saved.setup.legacyContacts == setup.legacyContacts
  doAssert saved.setup.legacyRouteSteering == setup.legacyRouteSteering
  doAssert saved.setup.legacyCrossings == setup.legacyCrossings
  doAssert saved.setup.legacyDeadlocks
  doAssert not saved.setup.legacyMovement
  doAssert saved.actions == recording.actions
  doAssert saved.hashes == recording.hashes
  doAssert saved.replayFinal().fingerprint() == hash
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
  doAssert recording.actions.len > 0
  doAssert world.impacts > 0
  doAssert not checkpoint.setup.legacyFlocking
  doAssert not checkpoint.setup.legacyContacts
  doAssert not checkpoint.setup.legacyRouteSteering
  doAssert not checkpoint.setup.legacyCrossings
  doAssert not checkpoint.setup.legacyDeadlocks
  var cursor = recording.actionCursor(checkpoint.tick)
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
