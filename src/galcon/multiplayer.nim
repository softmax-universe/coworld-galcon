import
  std/[os, unicode],
  jsony,
  polyworld/[rooms, roomclients, policies],
  common, worlds, options, sessions, bots, chats, replays

export rooms, roomclients

const
  NetworkProtocol* = 3'u32
  TruceSource* = staticRead(Root / "players/truce.bas")

type
  MatchConfig* = ref object
    seed*: int32 = 8
    players*: int = 16
    planets*: int = 69
    maximumTicks*: int32 = TickRate * 600
    difficulty*: Difficulty = Easy
    balancedMap*: bool = true
    enemyShipsPassThrough*, neutralsDontProduce*: bool = true
  Submission = object
    kind: uint32
    source, target, value: int
    text: string
  NetworkMatch* = ref object
    client*: RoomClient
    session*: Session
    revision*: uint32
    started*, finished*: bool
    submit*: SubmitOrder
    decisionTick: int32 = -1
    playerSeats*: seq[int]
    seatPlayers*: seq[int]
    sources: seq[string]
    brainSources: seq[string]

proc identity*(): GameIdentity =
  ## Identifies compatible Galcon clients through the shared room envelope.
  GameIdentity(game: "galcon", gameplay: ReplayVersion.uint32,
    protocol: NetworkProtocol)

proc validate*(config: MatchConfig) =
  ## Bounds room configuration before allocating a map or bot runtime.
  if config == nil or config.players notin 2 .. MaxPlayers or
    config.planets notin config.players .. MaxPlanets or
    config.maximumTicks notin 1 .. MaxTicks or config.seed < 0:
      raise newException(GalconError, "Invalid Galcon match settings")

proc parseConfig*(payload: string): MatchConfig =
  ## Parses only the game payload inside the shared room protocol.
  try:
    result = payload.fromJson(MatchConfig)
  except jsony.JsonError as error:
    raise newException(GalconError, "Invalid Galcon settings: " & error.msg)
  result.validate()

proc matchOptions*(config: MatchConfig): Options =
  ## Constructs a deterministic match with explicit Rules B switches.
  config.validate()
  result = Options(playerCount: config.players, planetCount: config.planets,
    enemyShipsPassThrough: config.enemyShipsPassThrough,
    neutralsDontProduce: config.neutralsDontProduce,
    balancedMap: config.balancedMap)
  result.game.seed = config.seed
  result.game.maximumTicks = config.maximumTicks
  result.game.speed = 1
  result.setup = result.matchSetup(config.difficulty)

proc humanSeat*(snapshot: RoomMessage, participant: uint32): int =
  ## Selects the first assigned human slot, with zero reserved for spectators.
  for i, seat in snapshot.seats:
    if participant != 0 and seat.owner == participant and seat.kind == HumanSeat:
      return i + 1

proc claimHuman*(client: RoomClient, index: int) =
  ## Moves the local human; the host may also take an occupied slot.
  if index notin 0 ..< client.snapshot.seats.len or
    (client.snapshot.seats[index].owner notin [0'u32, client.participant] and
      client.snapshot.participant != client.participant):
      reject("That slot belongs to another participant")
  for i, seat in client.snapshot.seats:
    if i != index and seat.owner == client.participant and seat.kind == HumanSeat:
      client.send(RoomMessage(kind: ReleaseSeat, seat: i.uint32))
  client.send(RoomMessage(kind: ClaimSeat, seat: index.uint32,
    seatKind: HumanSeat, name: "Human"))

proc stateHash*(match: NetworkMatch): uint64 =
  ## Includes match duration and settings as well as fixed-point world state.
  result = match.session.liveWorld.fingerprint()
  result = result xor match.session.maximumTicks.uint64

proc decodeSubmission(bytes: string): Submission =
  ## Rejects malformed commands before applying a whole authoritative tick.
  var reader = PacketReader(data: bytes)
  result.kind = reader.get32()
  case result.kind
  of 0:
    result.text = reader.getString(MaxChatBytes - 16)
    if result.text.len == 0 or validateUtf8(result.text) >= 0:
      reject("Invalid Galcon chat text")
  of 1, 2:
    result.source = reader.get32().int
    result.target = reader.get32().int
    result.value = reader.get32().int
    if result.source >= MaxPlanets or result.target >= MaxPlanets or
      result.value > int32.high.int or
      (result.kind == 2 and result.value > 100):
        reject("Invalid Galcon fleet order")
  else:
    reject("Unknown Galcon command")
  if reader.cursor != bytes.len:
    reject("Trailing Galcon command bytes")

proc canSubmit(match: NetworkMatch): bool =
  ## Only the connected live simulation may originate new player decisions.
  match != nil and match.started and not match.finished and
    match.client.connected and match.client.welcomed and
    not match.client.catchingUp and match.client.snapshot.phase == Playing and
    not match.client.snapshot.flag

proc queueOrder*(
    match: NetworkMatch, player, source, target, value: int, percent: bool
): int =
  ## Queues intent without changing ships before the relay orders the command.
  let world = match.session.liveWorld
  if not match.canSubmit or player notin 1 .. world.setup.players or
    not world.validPlanet(source) or not world.validPlanet(target) or
    source == target or world.planets[source].owner != player or value <= 0:
      return
  var bytes: string
  bytes.put32(if percent: 2 else: 1)
  bytes.put32(source.uint32)
  bytes.put32(target.uint32)
  bytes.put32(clamp(value, 0, if percent: 100 else: int32.high.int).uint32)
  if match.client.submit(match.playerSeats[player - 1].uint32, bytes):
    result =
      if percent: world.planets[source].shipCount * min(value, 100) div 100
      else: min(value, world.planets[source].shipCount)

proc prepareMatch*(client: RoomClient, sources: seq[string]): NetworkMatch =
  ## Compiles only locally owned policies; the server never receives bot code.
  let
    snapshot = client.setupSnapshot()
    config = parseConfig(snapshot.payload)
  if client.identity != identity() or snapshot.tickRate != TickRate.uint32 or
    snapshot.seats.len != config.players:
      reject("Galcon identity, tick rate, or roster differs from the room")
  var
    owned, names: seq[string]
    playerSeats: seq[int]
    seatPlayers = newSeq[int](config.players)
    human = 0
  for i, seat in snapshot.seats:
    if seat.owner == 0: continue
    playerSeats.add i
    seatPlayers[i] = playerSeats.len
    names.add seat.name
    owned.add ""
    if seat.kind == HumanSeat:
      if seat.owner == client.participant and human == 0:
        human = playerSeats.len
      for participant in snapshot.participants:
        if participant.id == seat.owner:
          names[^1] = participant.name
    elif seat.owner == client.participant:
      if i >= sources.len or sources[i].len == 0:
        reject("Choose a local policy for every bot you own")
      owned[^1] = loadPolicy(sources[i]).source
  if playerSeats.len == 0: reject("Assign at least one player before starting")
  let options = config.matchOptions()
  options.playerCount = playerSeats.len
  options.setup = options.matchSetup(config.difficulty)
  let session = newSession(options, owned, names, human, true)
  session.networked = true
  result = NetworkMatch(client: client, session: session,
    revision: snapshot.revision, playerSeats: playerSeats,
    seatPlayers: seatPlayers, sources: sources,
    brainSources: newSeq[string](playerSeats.len))
  for index, seatIndex in playerSeats:
    if snapshot.seats[seatIndex].owner == client.participant and
        snapshot.seats[seatIndex].kind == BotSeat:
      result.brainSources[index] = sources[seatIndex]
  let current {.cursor.} = result
  result.submit = proc(player, source, target, value: int, percent: bool): int =
    ## Routes human and BASIC intent through exactly the same protocol.
    current.queueOrder(player, source, target, value, percent)
  for brain in session.brains:
    if brain != nil:
      brain.submit = result.submit
  session.chat.submit = proc(sender, target: int, text: string): int32 =
    ## Keeps anonymous global chat deterministic on every participant.
    if not current.canSubmit or sender notin 1 .. current.playerSeats.len or
      target != -2 or
      text.len == 0 or text.len > MaxChatBytes - 16 or validateUtf8(text) >= 0:
        return 0
    var bytes: string
    bytes.put32(0)
    bytes.putString(text)
    if current.client.submit(current.playerSeats[sender - 1].uint32, bytes):
      return 1

proc refreshControllers*(match: NetworkMatch, sources: seq[string]) =
  ## Changes local control without rebuilding the immutable initial world.
  match.sources = sources
  let
    client = match.client
    roster = if client.began: client.appliedSeats
      else: client.setupSnapshot().seats
    session = match.session
  session.human = 0
  for index, seatIndex in match.playerSeats:
    let player = index + 1
    if seatIndex >= roster.len or roster[seatIndex].owner != client.participant:
      session.brains[player] = nil
      match.brainSources[index] = ""
      continue
    let seat = roster[seatIndex]
    if seat.kind == HumanSeat:
      if session.human == 0:
        session.human = player
      session.brains[player] = nil
      match.brainSources[index] = ""
    else:
      let source = if seatIndex < sources.len: sources[seatIndex] else: ""
      if source.len == 0:
        session.brains[player] = nil
        match.brainSources[index] = ""
      else:
        if session.brains[player] == nil or match.brainSources[index] != source:
          let policy = loadPolicy(source).source
          session.brains[player] = newBrain(session.liveWorld, player, policy,
            session.chat)
          session.brains[player].submit = match.submit
          match.brainSources[index] = source

proc decide(match: NetworkMatch) =
  ## Runs only the locally owned bots for the applied roster revision.
  let session = match.session
  if not match.canSubmit or match.decisionTick == session.liveWorld.tick:
    return
  match.refreshControllers(match.sources)
  match.decisionTick = session.liveWorld.tick
  for owner in countdown(session.liveWorld.setup.players, 1):
    session.brains[owner].decide()

proc resumeCommands*(match: NetworkMatch) =
  ## Resumes at the caught-up edge even when no further tick has arrived.
  var rejected: RoomMessage
  while match.client.takeRejected(rejected):
    discard
  match.decide()

proc start*(match: NetworkMatch, event: RoomMessage) =
  ## Checks shared setup identity before reporting independent simulation state.
  if match.started or event.kind != BeginMatch or
    event.match != match.client.match or event.revision != match.revision or
    event.hash != setupHash(match.client.setupSnapshot()):
      reject("Galcon setup changed or initial state disagrees")
  match.started = true
  match.client.send(RoomMessage(kind: ReportHash, match: match.client.match,
    tick: 0, hash: match.stateHash()))
  match.decide()

proc applyPacket*(match: NetworkMatch, packet: RoomMessage) =
  ## Advances only server-ordered ticks and records an ordinary Galcon replay.
  let
    session = match.session
    world = session.liveWorld
    client = match.client
  if not match.started or match.finished or packet.kind != TickPacket or
    packet.match != client.match or packet.tick != uint32(world.tick + 1):
      reject("Unexpected Galcon simulation tick")
  for command in packet.commands:
    if command.participant == 0 or
      command.seat >= match.seatPlayers.len.uint32 or
      match.seatPlayers[command.seat] == 0:
        reject("Command slot has no initialized Galcon player")
    discard decodeSubmission(command.payload)
  for command in packet.commands:
    let
      action = decodeSubmission(command.payload)
      player = match.seatPlayers[command.seat]
    case action.kind
    of 0:
      discard session.chat.deliverChat(player, -2, action.text)
    of 1:
      discard world.launch(player, action.source, action.target, action.value)
    of 2:
      discard world.send(player, action.source, action.target, action.value)
    else: discard
  world.advance(if session.inHistory: nil else: session.observer)
  session.recording.recordTick(world)
  let shown = session.world
  session.world = world
  session.captureCheckpoint()
  session.world = shown
  if session.tickObserver != nil:
    session.tickObserver(world)
  client.appliedTick(packet.tick)
  match.finished = world.winner >= 0 or world.tick >= session.maximumTicks
  if packet.tick mod TickRate.uint32 == 0:
    client.send(RoomMessage(kind: ReportHash, match: client.match,
      tick: packet.tick, hash: match.stateHash()))
  if match.finished:
    session.finish()
    client.send(RoomMessage(kind: FinishMatch, match: client.match,
      tick: packet.tick, hash: match.stateHash()))
  else:
    match.decide()

proc abort*(match: NetworkMatch, detail: string) =
  ## Stops local advancement and reports disagreement through the shared relay.
  match.client.error = detail
  match.client.snapshot.phase = Desynced
  match.client.send(RoomMessage(kind: AbortMatch, match: match.client.match,
    detail: detail))
