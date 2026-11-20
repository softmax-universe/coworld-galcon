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
  doAssert cursor == recording.actions.len

echo "Current deadlock recovery survives replay and isolated checkpoints"
block:
  let
    setup = configuredSetup(42, Easy, 3, 9)
    world = newWorld(setup)
    recording = Recording(setup: setup)
    copied = Root / "build/movement-current.replay"
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
  var cursor = recording.actionCursor(checkpoint.tick)
  while checkpoint.tick < world.tick:
    recording.replayTick(checkpoint, cursor)
  doAssert checkpoint.fingerprint() == world.fingerprint()
  recording.save(copied)
  let saved = loadRecording(copied)
  doAssert readFile(copied).replayFileHeader().gameVersion == ReplayVersion
  doAssert saved.actions == recording.actions
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
