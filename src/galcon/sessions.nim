import
  std/[os, monotimes, times, unicode],
  polyworld/[cli, configs],
  common, worlds, bots, replays, options, profiles, chats

when defined(coworld):
  import polyworld/coworld

const
  CheckpointTicks* = TickRate * 4
  MaxCheckpoints* = 64

type
  Checkpoint* = ref object
    world*: World
  Session* = ref object
    world*, liveWorld*: World
    brains*: array[MaxPlayers + 1, Brain]
    chat*: ChatHub
    names*: array[MaxPlayers + 1, string]
      ## Human-facing roster names remain outside worlds, hubs, and bot APIs.
    recording*, replay*: Recording
    replayCursor*: int
    replayChatCursor*: int
    playback*, done*, keepHistory*, networked*: bool
    human*: int
    maximumTicks*: int32
    recordPath*: string
    checkpoints*: seq[Checkpoint]
    checkpointSpacing*: int32
    observer*: ArrivalObserver
    tickObserver*: proc(world: World)
      ## Optional viewer sampling stays outside recorded simulation state.
    historyMargin*: int32
      ## A viewer may replay a short lead-in to reconstruct transient art.

proc displayName*(session: Session, owner: int): string =
  ## Labels a human viewer's faction with its color and recorded bot name.
  result = playerName(owner)
  if owner in 1 .. MaxPlayers and session.names[owner].len > 0:
    result.add " (" & session.names[owner] & ")"

proc viewerName(name: string, slot: int): string =
  ## Cleans and bounds public labels without exposing them to bot runtimes.
  result = PlayerConfig(name: name).displayName(slot)
  if validateUtf8(result) >= 0:
    raise newException(GalconError, "Player name must be valid UTF-8")
  if result.len > 128:
    var ending = 128
    while (result[ending].ord and 0xc0) == 0x80:
      dec ending
    result.setLen(ending)

proc recordedTicks*(session: Session): int32 =
  ## Returns the available file replay or the current live frontier.
  if session.playback:
    session.replay.hashes.len.int32
  else:
    session.liveWorld.tick

proc inHistory*(session: Session): bool =
  ## Reports a historical view without changing the live world or BASIC VMs.
  session.playback or session.world != session.liveWorld

proc canCommand*(session: Session): bool =
  ## Allows human orders only on the active live frontier.
  session.human > 0 and not session.inHistory and not session.done

proc captureCheckpoint*(session: Session) =
  ## Keeps at most 64 isolated checkpoints, thinning older spacing as needed.
  if not session.keepHistory:
    return
  let world = session.world
  if session.checkpoints.len > 0 and
    (world.tick <= session.checkpoints[^1].world.tick or
    world.tick mod session.checkpointSpacing != 0):
      return
  if session.checkpoints.len >= MaxCheckpoints:
    let count = session.checkpoints.len div 2
    for i in 0 ..< count:
      session.checkpoints[i] = session.checkpoints[i * 2]
    session.checkpoints.setLen(count)
    session.checkpointSpacing *= 2
  session.checkpoints.add Checkpoint(world: world.clone())

proc newSession*(
    options: Options, policies: seq[string] = @[],
    labels: seq[string] = @[], human = -1, explicitRoster = false
): Session =
  ## Creates a human game, BASIC match, or seekable deterministic replay.
  if explicitRoster and (policies.len != options.setup.players or
    labels.len != options.setup.players or human notin 0 .. options.setup.players):
      raise newException(GalconError, "Invalid explicit player roster")
  result = Session(
    maximumTicks: options.game.maximumTicks,
    recordPath: options.game.recordPath,
    keepHistory: not options.headless or options.game.recordPath.len > 0,
    checkpoints: newSeqOfCap[Checkpoint](MaxCheckpoints),
    checkpointSpacing: CheckpointTicks
  )
  if options.game.replayPath.len > 0:
    result.playback = true
    result.keepHistory = true
    result.replay = loadRecording(options.game.replayPath)
    for owner, name in result.replay.names:
      result.names[owner] = name
    result.world = newWorld(result.replay.setup)
    result.maximumTicks = result.replay.hashes.len.int32
    result.captureCheckpoint()
    return
  result.liveWorld = newWorld(options.setup)
  result.world = result.liveWorld
  result.chat = newChatHub(result.liveWorld)
  result.recording = Recording(
    setup: options.setup,
    orders: newSeqOfCap[Order](MaxBodies),
    chats: newSeqOfCap[ChatMessage](if result.keepHistory: 64 else: 0),
    hashes: newSeqOfCap[uint64](
      if result.keepHistory: options.game.maximumTicks.int else: 0
    )
  )
  let configured = options.game.botGroups.botCount()
  if options.game.playerSlot > 0:
    result.human = options.game.playerSlot.int
  elif not options.headless and configured == 0:
    result.human = 1
  var
    sources: seq[string]
    names: seq[string]
  for group in options.game.botGroups:
    let source =
      when defined(coworld):
        loadPlayerPolicy(readPlayerSource(group.path), sources.len).source
      else:
        readSource(group.path)
    for i in 0 ..< group.count:
      sources.add source
      names.add viewerName(group.path.extractFilename().changeFileExt(""),
        names.len)
  let needed = options.setup.players - int(result.human > 0)
  if sources.len > 0 and sources.len != needed:
    raise newException(GalconError, "Expected " & $needed & " BASIC policies")
  if explicitRoster:
    result.human = human
  var slot = 0
  for owner in 1 .. options.setup.players:
    result.names[owner] = "Human"
    if owner != result.human:
      let source =
        if explicitRoster: policies[owner - 1]
        elif sources.len == 0: BaselineSource
        else: sources[slot]
      result.names[owner] =
        if explicitRoster: labels[owner - 1]
        elif names.len == 0: "Classic Bot"
        else: names[slot]
      if options.setup.counts[owner] > 0 and source.len > 0:
        result.brains[owner] = newBrain(result.liveWorld, owner, source,
          result.chat)
      inc slot
    when defined(coworld):
      if owner <= coworld.config.players.len:
        result.names[owner] = viewerName(
          coworld.config.players[owner - 1].name, owner - 1
        )
  if explicitRoster:
    for owner in 1 .. options.setup.players:
      result.names[owner] = labels[owner - 1]
  result.recording.names = newSeq[string](options.setup.players + 1)
  for owner in 1 .. options.setup.players:
    result.recording.names[owner] = result.names[owner]
  result.captureCheckpoint()

proc saveRecording*(session: Session, path: string) =
  ## Saves the complete live tape even when the viewer is looking backward.
  if session.playback:
    raise newException(GalconError, "A file replay cannot be recorded again")
  if not session.keepHistory:
    raise newException(GalconError, "This headless match was not recorded")
  session.recording.save(path)

proc finish*(session: Session) =
  ## Saves one completed or interrupted match from its authoritative live tape.
  if session.done:
    return
  session.done = true
  if session.recordPath.len > 0:
    session.saveRecording(session.recordPath)

proc restoreTo*(session: Session, target: int32) =
  ## Restores the nearest checkpoint without rerunning or rewinding live bots.
  if not session.keepHistory:
    raise newException(GalconError, "This session has no seekable history")
  let wanted = clamp(target, 0'i32, session.recordedTicks)
  if not session.playback and wanted == session.liveWorld.tick and
    session.historyMargin == 0:
    session.world = session.liveWorld
    return
  var index = 0
  let beginning = max(0'i32, wanted - session.historyMargin)
  for i, checkpoint in session.checkpoints:
    if checkpoint.world.tick > beginning:
      break
    index = i
  session.world = session.checkpoints[index].world.clone()
  let tape = if session.playback: session.replay else: session.recording
  session.replayCursor = tape.orderCursor(session.world.tick)
  session.replayChatCursor = tape.chatCursor(session.world.tick)

proc returnToLive*(session: Session) =
  ## Returns instantly to the live frontier with pending orders and VMs intact.
  if not session.playback:
    session.world = session.liveWorld

proc step*(session: Session) {.measure.} =
  ## Replays historical orders or advances exactly one authoritative live tick.
  if session.playback:
    if session.world.tick < session.maximumTicks:
      session.replay.replayTick(session.world, session.replayCursor,
        session.replayChatCursor, session.observer)
      if session.tickObserver != nil:
        session.tickObserver(session.world)
      session.captureCheckpoint()
    session.done = session.world.tick >= session.maximumTicks
    return
  if session.inHistory:
    session.recording.replayTick(session.world, session.replayCursor,
      session.replayChatCursor, session.observer)
    if session.tickObserver != nil:
      session.tickObserver(session.world)
    if session.world.tick >= session.liveWorld.tick:
      session.returnToLive()
    return
  if session.done or session.networked:
    return
  if session.liveWorld.winner >= 0 or
    session.liveWorld.tick >= session.maximumTicks:
      session.finish()
      return
  for owner in countdown(session.liveWorld.setup.players, 1):
    session.brains[owner].decide()
  session.liveWorld.advance(session.observer)
  if session.tickObserver != nil:
    session.tickObserver(session.liveWorld)
  if session.keepHistory:
    session.recording.recordTick(session.liveWorld)
    session.captureCheckpoint()
  else:
    session.liveWorld.orders.setLen(0)
    session.liveWorld.chatOrderCount = 0
  if session.liveWorld.winner >= 0 or
    session.liveWorld.tick >= session.maximumTicks:
      session.finish()

proc seek*(session: Session, target: int32) =
  ## Lands on one recorded tick for tests and noninteractive replay consumers.
  let wanted = clamp(target, 0'i32, session.recordedTicks)
  session.restoreTo(wanted)
  while session.world.tick < wanted:
    session.step()

proc runHeadless*(options: Options) =
  ## Runs the same deterministic match loop without graphics or sound.
  let
    session = newSession(options)
    paced = options.game.headlessTickRate
    started = getMonoTime()
  defer:
    finishProfileTrace()
  while not session.done:
    noteProfileTick(session.world.tick)
    session.step()
    if paced > 0:
      let
        target = session.world.tick.int64 * 1_000_000_000 div paced
        elapsed = (getMonoTime() - started).inNanoseconds
        remaining = (target - elapsed) div 1_000_000
      if remaining > 0:
        sleep(remaining.int)
  echo "seed=", session.world.setup.seed,
    " players=", session.world.setup.players,
    " planets=", session.world.planets.len,
    " ticks=", session.world.tick,
    " winner=", session.world.winner,
    " hash=", session.world.fingerprint()
  when defined(coworld):
    finishCoworld(CoworldResults(
      scores: session.world.scores(),
      ticks: session.world.tick,
      seed: session.world.setup.seed,
      outcome: if session.world.winner <= 0: "draw" else: "victory"
    ))
