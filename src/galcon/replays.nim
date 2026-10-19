import
  std/unicode,
  flatty, polyworld/tapes,
  common, worlds, profiles, chats

const
  ReplayVersion* = 12'u16
  MaxTicks* = TickRate * 60 * 30
  MaxOrders* = 1_000_000

type
  LegacySetup = object
    seed: int32
    difficulty: Difficulty
    tutorial: int
    counts: array[3, int]
  LegacyRecording = object
    setup: LegacySetup
    orders: seq[Order]
    hashes: seq[uint64]
  SetupData = object
    ## Version 2 wire fields remain values to preserve existing replay bytes.
    seed: int32
    difficulty: Difficulty
    tutorial: int
    players: int
    counts: seq[int]
  RecordingData = object
    ## Serialized fields are assembled only at the file boundary.
    setup: SetupData
    orders: seq[Order]
    hashes: seq[uint64]
  SpatialRecordingData = object
    setup: SetupData
    collisions: CollisionKind
    orders: seq[Order]
    hashes: seq[uint64]
  ChatRecordingData = object
    setup: SetupData
    collisions: CollisionKind
    orders: seq[Order]
    hashes: seq[uint64]
    chats: seq[ChatMessage]
  NamedRecordingData = object
    setup: SetupData
    collisions: CollisionKind
    orders: seq[Order]
    hashes: seq[uint64]
    chats: seq[ChatMessage]
    names: seq[string]
  RulesRecordingData = object
    setup: SetupData
    collisions: CollisionKind
    placement: Placement
    enemyShipsPassThrough: bool
    neutralsDontProduce: bool
    orders: seq[Order]
    hashes: seq[uint64]
    chats: seq[ChatMessage]
    names: seq[string]
  Recording* = ref object
    setup*: Setup
    orders*: seq[Order]
    hashes*: seq[uint64]
    chats*: seq[ChatMessage]
    names*: seq[string]
      ## Viewer metadata never enters simulation state or the BASIC host.

proc recordTick*(recording: Recording, world: World) {.measure.} =
  ## Appends bounded orders and the resulting state hash for one tick.
  if recording.hashes.len >= MaxTicks:
    raise newException(GalconError, "Replay exceeds the 30-minute limit")
  for order in world.orders:
    if recording.orders.len >= MaxOrders:
      raise newException(GalconError, "Replay has too many orders")
    recording.orders.add order
  world.orders.setLen(0)
  for i in 0 ..< world.chatOrderCount:
    if recording.chats.len >= MaxReplayChats:
      raise newException(GalconError, "Replay has too many chat messages")
    recording.chats.add world.chatOrders[i]
  world.chatOrderCount = 0
  recording.hashes.add world.fingerprint()

proc save*(recording: Recording, path: string) =
  ## Writes a replay using Polyworld's versioned portable file format.
  try:
    let data = RulesRecordingData(
      setup: SetupData(
        seed: recording.setup.seed,
        difficulty: recording.setup.difficulty,
        tutorial: recording.setup.tutorial,
        players: recording.setup.players,
        counts: recording.setup.counts
      ),
      collisions: recording.setup.collisions,
      placement: recording.setup.placement,
      enemyShipsPassThrough: recording.setup.enemyShipsPassThrough,
      neutralsDontProduce: recording.setup.neutralsDontProduce,
      orders: recording.orders,
      hashes: recording.hashes,
      chats: recording.chats,
      names: recording.names
    )
    saveReplayFile(path, "galcon", ReplayVersion, data)
  except IOError, OSError, ReplayError:
    raise newException(
      GalconError,
      "Cannot save replay: " & getCurrentExceptionMsg()
    )

proc loadRecording*(path: string): Recording =
  ## Validates a Polyworld Galcon replay before starting playback.
  var legacyHashes = false
  try:
    result = Recording()
    let
      bytes = readFile(path)
      header = bytes.replayFileHeader()
    legacyHashes = header.gameVersion < 6
    if header.gameVersion == 1:
      let legacy = decodeReplayFile("galcon", 1, bytes, LegacyRecording)
      result.setup = Setup(
        seed: legacy.setup.seed,
        difficulty: legacy.setup.difficulty,
        tutorial: legacy.setup.tutorial,
        players: 2,
        collisions: AllPairs,
        counts: @(legacy.setup.counts)
      )
      result.orders = legacy.orders
      result.hashes = legacy.hashes
    elif header.gameVersion == 2:
      let data = decodeReplayFile("galcon", 2, bytes, RecordingData)
      result.setup = Setup(
        seed: data.setup.seed,
        difficulty: data.setup.difficulty,
        tutorial: data.setup.tutorial,
        players: data.setup.players,
        collisions: AllPairs,
        counts: data.setup.counts
      )
      result.orders = data.orders
      result.hashes = data.hashes
    elif header.gameVersion == 3:
      let data = decodeReplayFile(
        "galcon", 3, bytes, SpatialRecordingData
      )
      result.setup = Setup(
        seed: data.setup.seed,
        difficulty: data.setup.difficulty,
        tutorial: data.setup.tutorial,
        players: data.setup.players,
        collisions: data.collisions,
        counts: data.setup.counts
      )
      result.orders = data.orders
      result.hashes = data.hashes
    elif header.gameVersion == 4:
      let data = decodeReplayFile(
        "galcon", 4, bytes, ChatRecordingData
      )
      result.setup = Setup(
        seed: data.setup.seed,
        difficulty: data.setup.difficulty,
        tutorial: data.setup.tutorial,
        players: data.setup.players,
        collisions: data.collisions,
        counts: data.setup.counts
      )
      result.orders = data.orders
      result.hashes = data.hashes
      result.chats = data.chats
    elif header.gameVersion in [5'u16, 6'u16]:
      let data = decodeReplayFile(
        "galcon",
        header.gameVersion,
        bytes,
        NamedRecordingData
      )
      result.setup = Setup(
        seed: data.setup.seed,
        difficulty: data.setup.difficulty,
        tutorial: data.setup.tutorial,
        players: data.setup.players,
        collisions: data.collisions,
        counts: data.setup.counts
      )
      result.orders = data.orders
      result.hashes = data.hashes
      result.chats = data.chats
      result.names = data.names
    else:
      let data = decodeReplayFile(
        "galcon", ReplayVersion, bytes, RulesRecordingData
      )
      result.setup = Setup(
        seed: data.setup.seed,
        difficulty: data.setup.difficulty,
        tutorial: data.setup.tutorial,
        players: data.setup.players,
        collisions: data.collisions,
        placement: data.placement,
        enemyShipsPassThrough: data.enemyShipsPassThrough,
        neutralsDontProduce: data.neutralsDontProduce,
        counts: data.setup.counts
      )
      result.orders = data.orders
      result.hashes = data.hashes
      result.chats = data.chats
      result.names = data.names
    if header.gameVersion < 7:
      result.setup.placement = ClassicPlacement
      result.setup.enemyShipsPassThrough = false
      result.setup.neutralsDontProduce = false
  except IOError, OSError, ReplayError, ValueError, FlattyError, IndexDefect:
    raise newException(
      GalconError,
      "Cannot load replay: " & getCurrentExceptionMsg()
    )
  if result.hashes.len > MaxTicks or result.orders.len > MaxOrders or
    result.chats.len > MaxReplayChats:
    raise newException(GalconError, "Replay limits exceeded")
  let world = newWorld(result.setup)
  if result.names.len notin [0, result.setup.players + 1]:
    raise newException(GalconError, "Replay names must match its player roster")
  for name in result.names:
    if name.len > 128 or validateUtf8(name) >= 0:
      raise newException(GalconError, "Invalid replay player name")
    for character in name:
      if character < ' ' or character == '\x7f':
        raise newException(GalconError, "Invalid replay player name")
  var previous = -1'i32
  for order in result.orders:
    if order.tick < 0 or order.tick < previous or
      order.tick >= result.hashes.len.int32 or
      order.count <= 0 or order.count > MaxBodies or
      order.player < 1 or order.player > result.setup.players.int32 or
      not world.validPlanet(order.source.int) or
      not world.validPlanet(order.target.int) or order.source == order.target:
        raise newException(GalconError, "Invalid replay order")
    previous = order.tick
  previous = -1
  var senders: array[MaxPlayers + 1, bool]
  for message in result.chats:
    if message.tick < 0 or message.tick < previous or
      message.tick >= result.hashes.len.int32 or
      message.player < 1 or message.player > result.setup.players.int32 or
      message.length < 1 or message.length > MaxChatBytes - 16:
        raise newException(GalconError, "Invalid replay chat message")
    if message.tick != previous:
      senders = default(typeof(senders))
    if validateUtf8(message.text.toOpenArray(0, message.length - 1)) >= 0 or
      message.text[0] == ' ' or message.text[message.length - 1] == ' ':
        raise newException(GalconError, "Invalid replay chat text")
    for i in 0 ..< message.length:
      if message.text[i] < ' ' or message.text[i] == '\x7f':
        raise newException(GalconError, "Invalid replay chat text")
    if senders[message.player]:
      raise newException(GalconError, "Duplicate replay chat sender")
    senders[message.player] = true
    previous = message.tick
  if legacyHashes:
    # Legacy fingerprints included particles, so migrate only gameplay hashes.
    var
      orders = 0
      messages = 0
    for tick in 0 ..< result.hashes.len:
      while orders < result.orders.len and
        result.orders[orders].tick == tick.int32:
          let order = result.orders[orders]
          if world.launch(order.player.int, order.source.int,
            order.target.int, order.count.int) != order.count.int:
              raise newException(GalconError, "Invalid legacy replay launch")
          inc orders
      while messages < result.chats.len and
        result.chats[messages].tick == tick.int32:
          let message = result.chats[messages]
          discard world.addChat(message.player.int,
            message.text.toOpenArray(0, message.length - 1))
          inc messages
      world.advance()
      world.orders.setLen(0)
      world.chatOrderCount = 0
      result.hashes[tick] = world.fingerprint()

proc clone*(recording: Recording): Recording =
  ## Makes an explicit isolated tape copy for edits or validation experiments.
  result = Recording(
    setup: recording.setup.clone(),
    orders: newSeq[Order](recording.orders.len),
    hashes: newSeq[uint64](recording.hashes.len),
    chats: newSeq[ChatMessage](recording.chats.len),
    names: newSeq[string](recording.names.len)
  )
  for i, order in recording.orders:
    result.orders[i] = order
  for i, hash in recording.hashes:
    result.hashes[i] = hash
  for i, message in recording.chats:
    result.chats[i] = message
  for i, name in recording.names:
    result.names[i] = name

proc replayTick*(
    recording: Recording, world: World, cursor, chatCursor: var int,
    observer: ArrivalObserver = nil
) =
  ## Applies recorded orders and checks the next deterministic simulation hash.
  if world.tick >= recording.hashes.len.int32:
    return
  let tick = world.tick
  while chatCursor < recording.chats.len and
    recording.chats[chatCursor].tick == tick:
      let message = recording.chats[chatCursor]
      if not world.addChat(message.player.int,
        message.text.toOpenArray(0, message.length - 1)):
          raise newException(
            GalconError, "Invalid replay chat at tick " & $tick
          )
      inc chatCursor
  while cursor < recording.orders.len and recording.orders[cursor].tick == tick:
    let order = recording.orders[cursor]
    let sent = world.launch(
      order.player.int,
      order.source.int,
      order.target.int,
      order.count.int
    )
    if sent != order.count.int:
      raise newException(GalconError, "Invalid replay launch at tick " & $tick)
    inc cursor
  world.advance(observer)
  world.orders.setLen(0)
  world.chatOrderCount = 0
  if world.fingerprint() != recording.hashes[tick]:
    raise newException(GalconError, "Replay diverged at tick " & $tick)

proc orderCursor*(recording: Recording, tick: int32): int =
  ## Finds the first launch at or after a restored checkpoint tick.
  var
    low = 0
    high = recording.orders.len
  while low < high:
    let middle = (low + high) div 2
    if recording.orders[middle].tick < tick:
      low = middle + 1
    else:
      high = middle
  low

proc chatCursor*(recording: Recording, tick: int32): int =
  ## Finds the first global message at or after a restored checkpoint tick.
  var
    low = 0
    high = recording.chats.len
  while low < high:
    let middle = (low + high) div 2
    if recording.chats[middle].tick < tick:
      low = middle + 1
    else:
      high = middle
  low

proc replayTick*(recording: Recording, world: World, cursor: var int) =
  ## Plays one tick with a derived chat cursor for simple replay consumers.
  var messages = recording.chatCursor(world.tick)
  recording.replayTick(world, cursor, messages)
