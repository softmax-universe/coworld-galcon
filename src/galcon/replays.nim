import
  std/unicode,
  flatty, polyworld/tapes,
  common, worlds, profiles, chats

const
  ReplayVersion* = 22'u16
  MaxTicks* = TickRate * 60 * 30
  MaxOrders* = 1_000_000

type
  RecordingData = object
    setup: Setup
    actions: seq[Action]
    hashes: seq[uint64]
    names: seq[string]
  Recording* = ref object
    setup*: Setup
    actions*: seq[Action]
    hashes*: seq[uint64]
    names*: seq[string]
      ## Viewer metadata never enters simulation state or the BASIC host.
    launches, messages: int

proc recordTick*(recording: Recording, world: World) {.measure.} =
  ## Keeps the acceptance order of launches and chat in one replay stream.
  if recording.hashes.len >= MaxTicks:
    raise newException(GalconError, "Replay exceeds the 30-minute limit")
  var order, message: int
  while order < world.orders.len or message < world.chatOrderCount:
    if message == world.chatOrderCount or
      (order < world.orders.len and
        world.orders[order].sequence < world.chatOrders[message].sequence):
        if recording.launches >= MaxOrders:
          raise newException(GalconError, "Replay has too many fleet orders")
        let accepted = world.orders[order]
        recording.actions.add Action(kind: ActionLaunch,
          tick: accepted.tick, player: accepted.player,
          source: accepted.source, target: accepted.target,
          count: accepted.count)
        inc recording.launches
        inc order
    else:
      if recording.messages >= MaxReplayChats:
        raise newException(GalconError, "Replay has too many chat messages")
      let accepted = world.chatOrders[message]
      recording.actions.add Action(kind: ActionChat,
        tick: accepted.tick, player: accepted.player, text: accepted.chatText())
      inc recording.messages
      inc message
  world.orders.setLen(0)
  world.chatOrderCount = 0
  recording.hashes.add world.fingerprint()

proc save*(recording: Recording, path: string) =
  ## Writes the current action stream behind Polyworld's portable file header.
  try:
    saveReplayFile(path, "galcon", ReplayVersion, RecordingData(
      setup: recording.setup, actions: recording.actions,
      hashes: recording.hashes, names: recording.names
    ))
  except IOError, OSError, ReplayError:
    raise newException(
      GalconError,
      "Cannot save replay: " & getCurrentExceptionMsg()
    )

proc loadRecording*(path: string): Recording =
  ## Rejects obsolete layouts and validates one ordered sequence of actions.
  try:
    let data = decodeReplayFile("galcon", ReplayVersion,
      readFile(path), RecordingData)
    result = Recording(setup: data.setup, actions: data.actions,
      hashes: data.hashes, names: data.names)
  except IOError, OSError, ReplayError, ValueError, FlattyError, IndexDefect:
    raise newException(
      GalconError,
      "Cannot load replay: " & getCurrentExceptionMsg()
    )
  if result.hashes.len > MaxTicks or
    result.actions.len > MaxOrders + MaxReplayChats:
      raise newException(GalconError, "Replay limits exceeded")
  if result.setup == nil or
    ord(result.setup.difficulty) notin ord(Easy) .. ord(Crazy) or
    ord(result.setup.collisions) notin ord(AllPairs) .. ord(Grid64) or
    ord(result.setup.placement) notin ord(RandomPlacement) .. ord(ClusteredPlacement):
      raise newException(GalconError, "Invalid replay map settings")
  let world = newWorld(result.setup)
  if result.names.len notin [0, result.setup.players + 1]:
    raise newException(GalconError, "Replay names must match its player roster")
  for name in result.names:
    if name.len > 128 or validateUtf8(name) >= 0:
      raise newException(GalconError, "Invalid replay player name")
    for character in name:
      if character < ' ' or character == '\x7f':
        raise newException(GalconError, "Invalid replay player name")
  var
    previous = -1'i32
    senders: array[MaxPlayers + 1, bool]
  for action in result.actions:
    if ord(action.kind) notin ord(ActionLaunch) .. ord(ActionChat) or
      action.tick < 0 or action.tick < previous or
      action.tick >= result.hashes.len.int32 or
      action.player < 1 or action.player > result.setup.players.int32:
        raise newException(GalconError, "Invalid replay action")
    if action.tick != previous:
      senders = default(typeof(senders))
    case action.kind
    of ActionLaunch:
      if action.count <= 0 or
        (result.setup.legacyLaunches and action.count > MaxBodies) or
        not world.validPlanet(action.source.int) or
        not world.validPlanet(action.target.int) or
        action.source == action.target or action.text.len > 0:
          raise newException(GalconError, "Invalid replay fleet order")
      inc result.launches
    of ActionChat:
      if action.source != 0 or action.target != 0 or action.count != 0 or
        action.text.len < 1 or action.text.len > MaxChatBytes - 16 or
        validateUtf8(action.text) >= 0 or action.text[0] == ' ' or
        action.text[^1] == ' ':
          raise newException(GalconError, "Invalid replay chat text")
      for character in action.text:
        if character < ' ' or character == '\x7f':
          raise newException(GalconError, "Invalid replay chat text")
      if senders[action.player]:
        raise newException(GalconError, "Duplicate replay chat sender")
      senders[action.player] = true
      inc result.messages
    previous = action.tick
  if result.launches > MaxOrders or result.messages > MaxReplayChats:
    raise newException(GalconError, "Replay limits exceeded")

proc clone*(recording: Recording): Recording =
  ## Makes an explicit isolated tape copy for edits or validation experiments.
  result = Recording(
    setup: recording.setup.clone(),
    actions: newSeq[Action](recording.actions.len),
    hashes: newSeq[uint64](recording.hashes.len),
    names: newSeq[string](recording.names.len),
    launches: recording.launches, messages: recording.messages
  )
  for i, action in recording.actions:
    result.actions[i] = action
  for i, hash in recording.hashes:
    result.hashes[i] = hash
  for i, name in recording.names:
    result.names[i] = name

proc replayTick*(
    recording: Recording, world: World, cursor: var int,
    observer: ArrivalObserver = nil
) =
  ## Applies mixed actions once in recorded order without rerunning any bots.
  if world.tick >= recording.hashes.len.int32:
    return
  let tick = world.tick
  while cursor < recording.actions.len and recording.actions[cursor].tick == tick:
    let action = recording.actions[cursor]
    case action.kind
    of ActionLaunch:
      let sent = world.launch(action.player.int, action.source.int,
        action.target.int, action.count.int)
      if sent != action.count.int:
        raise newException(GalconError, "Invalid replay launch at tick " & $tick)
    of ActionChat:
      if not world.addChat(action.player.int, action.text):
        raise newException(GalconError, "Invalid replay chat at tick " & $tick)
    inc cursor
  world.advance(observer)
  world.orders.setLen(0)
  world.chatOrderCount = 0
  if world.fingerprint() != recording.hashes[tick]:
    raise newException(GalconError, "Replay diverged at tick " & $tick)

proc actionCursor*(recording: Recording, tick: int32): int =
  ## Finds the first action at or after a restored checkpoint tick.
  var
    low = 0
    high = recording.actions.len
  while low < high:
    let middle = (low + high) div 2
    if recording.actions[middle].tick < tick:
      low = middle + 1
    else:
      high = middle
  low
