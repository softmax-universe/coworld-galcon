import
  bassy,
  polyworld/[policyhosts, policies, rngs, mailboxes],
  common, worlds, profiles, chats

when defined(coworld):
  import polyworld/coworld

const
  BaselineSource* = staticRead(Baseline)

type
  Brain* = ref object
    runtime*: Runtime
    owner*: int
    chat*: ChatHub
    rng: Rng
    neighbors: seq[seq[int]]
    failed*: bool
    error*: string
    decisions*: int

proc policyLimits*(planets = 26): Limits =
  ## Scales decision work for quadratic map scans while bounding memory.
  doAssert planets in 1 .. MaxPlanets
  let scale = max(1, (planets * planets + 26 * 26 - 1) div (26 * 26))
  result = defaultLimits()
  result.maxInstructions = 200_000 * scale.int64
  result.maxWorkUnits = 300_000 * scale.int64
  result.maxMemoryBytes = 4 * 1024 * 1024
  result.maxSourceBytes = 256 * 1024
  result.maxPrintBytes = 4096
  result.maxPrintEvents = 128

proc buildHost*(world: World, brain: Brain, owner: int): Host =
  ## Exposes visible planet data and ownership-checked orders through Polyworld.
  result = initPolicyHost(owner - 1)
  let sendChatProc: NumericHostProc = proc(args: openArray[Value]): Value =
    ## Sends bounded script text to every faction using its color name.
    brain.runtime.withString(args[1], text):
      result = brain.chat.sendChat(owner, args[0].asInt.int, text)
  let pullMailboxProc: NumericHostProc = proc(args: openArray[Value]): Value =
    ## Reads and consumes this player's oldest global message.
    let inbox = brain.chat.inboxes[owner]
    if inbox.count == 0:
      return brain.runtime.putString("")
    result = brain.runtime.putString(inbox.messages[inbox.first])
    discard inbox.pop()
  let playerNameProc: NumericHostProc = proc(args: openArray[Value]): Value =
    ## Resolves a one-based faction ID to a color without policy metadata.
    let id = args[0].asInt.int
    result = brain.runtime.putString(
      if id in 1 .. world.setup.players: playerName(id) else: ""
    )
  let mailboxNameProc: NumericHostProc = proc(args: openArray[Value]): Value =
    ## Resolves Polyworld's zero-based mailbox address to the same color.
    let id = args[0].asInt.int
    result = brain.runtime.putString(
      if id in 0 ..< world.setup.players: playerName(id + 1) else: ""
    )
  discard result.addFunction("sendChat", 2, sendChatProc, 256)
  discard result.addFunction("pullMailbox$", 0, pullMailboxProc, 256)
  discard result.addFunction("playerName$", 1, playerNameProc, 4)
  discard result.addFunction("playerColor$", 1, playerNameProc, 4)
  discard result.addFunction("mailboxName$", 1, mailboxNameProc, 4)
  template query(name: string, parameters: int, body: untyped) =
    discard result.addQuery(
      name,
      parameters,
      proc(args {.inject.}: openArray[int32]): int32 =
        ## Evaluates one bounded planet query.
        body
    )
  query("planetCount", 0):
    world.planets.len.int32
  query("playerCount", 0):
    world.setup.players.int32
  query("selfPlayer", 0):
    owner.int32
  query("worldTick", 0):
    world.tick
  query("mailboxId", 0):
    brain.chat.inboxes[owner].lastId
  query("mailboxCount", 0):
    brain.chat.inboxes[owner].count.int32
  query("mailboxSelf", 0):
    (owner - 1).int32
  query("mailboxPlayers", 0):
    world.setup.players.int32
  template field(name: string, body: untyped) =
    query(name, 1):
      let index = args[0].int
      if not world.validPlanet(index):
        return 0
      let p {.inject.} = world.planets[index]
      int32(body)
  field("owner", p.owner)
  field("ships", p.shipCount)
  field("production", p.production)
  field("morale", p.morale)
  field("realMorale", p.realMorale)
  field("realShips", p.realShips div FixedScale)
  field("x", p.x.toInt)
  field("y", p.y.toInt)
  field("ready", int(p.frame mod 16 == 0))
  field("neighborCount", p.neighbors.len)
  query("incoming", 2):
    let
      planet = args[0].int
      player = args[1].int
    if not world.validPlanet(planet) or player < 0 or
      player > world.setup.players:
        return 0
    world.planets[planet].incoming[player].int32
  query("neighbor", 2):
    let
      source = args[0].int
      rank = args[1].int
    if not world.validPlanet(source) or rank < 0:
      return -1
    if brain != nil and rank < brain.neighbors[source].len:
      return brain.neighbors[source][rank].int32
    if rank < world.planets[source].neighbors.len:
      return world.planets[source].neighbors[rank].int32
    -1
  query("fraction", 3):
    let source = args[0].int
    if not world.validPlanet(source) or args[2] <= 0 or args[2] > 10_000:
      return 0
    int32(world.planets[source].ships * clamp(args[1], 0, args[2]) div
      (args[2].int64 * FixedScale))
  query("reinforcement", 2):
    if not world.validPlanet(args[0].int) or not world.validPlanet(args[1].int):
      return 0
    int32((world.planets[args[0]].realShips -
      world.planets[args[1]].realShips) div (2 * FixedScale))
  query("stronger", 2):
    if not world.validPlanet(args[0].int) or
      not world.validPlanet(args[1].int):
        return 0
    int32(world.planets[args[0]].realShips -
      world.planets[args[1]].realShips > stock(10))
  discard result.addFunction(
    "shuffleNeighbors",
    1,
    proc(args: openArray[int32]): int32 =
      ## Shuffles policy-local neighbors without changing replayed game state.
      let index = args[0].int
      if brain == nil or not world.validPlanet(index):
        return 0
      let count = brain.neighbors[index].len
      for i in countdown(count - 1, 1):
        let j = brain.rng.between(0, i.int32).int
        swap(brain.neighbors[index][i], brain.neighbors[index][j])
      1
  )
  discard result.addFunction(
    "launch",
    3,
    proc(args: openArray[int32]): int32 =
      ## Refuses commands for another player's planets.
      world.launch(owner, args[0].int, args[1].int, args[2].int).int32
  )
  discard result.addFunction(
    "send",
    3,
    proc(args: openArray[int32]): int32 =
      ## Applies the same percentage command used by the human controls.
      world.send(owner, args[0].int, args[1].int, args[2].int).int32
  )

proc newBrain*(
    world: World, owner: int, source: string, chat: ChatHub = nil
): Brain =
  ## Compiles a genuine BASIC policy with the shared Polyworld host facade.
  if owner < 1 or owner > world.setup.players:
    raise newException(GalconError, "Policy owner is outside the player roster")
  result = Brain(
    owner: owner,
    rng: initRng(world.setup.seed, owner.uint64),
    chat: if chat == nil: newChatHub(world) else: chat
  )
  for p in world.planets:
    var neighbors: seq[int]
    for index in p.neighbors:
      neighbors.add index
    result.neighbors.add neighbors
  let
    limits = policyLimits(world.planets.len)
    host = buildHost(world, result, owner)
  try:
    let program =
      when defined(coworld):
        compilePlayer(source, host, limits, owner - 1)
      else:
        compile(source, host, limits)
    result.runtime = initRuntime(program, host, limits)
  except BasicError as error:
    when defined(coworld):
      rejectPlayer(owner - 1, error.msg)
    else:
      raise newException(GalconError, "Cannot compile BASIC policy " &
        $owner & ": " & error.msg)

proc readSource*(path: string): string =
  ## Loads raw BASIC or a Polyworld policy package with bounded reads.
  try:
    result = readPolicy(path).source
  except PolicyError, IOError, OSError:
    raise newException(
      GalconError,
      "Cannot load BASIC policy: " & getCurrentExceptionMsg()
    )

proc decide*(brain: Brain) {.measure.} =
  ## Restarts one bounded decision while retaining the policy's variables.
  if brain == nil or brain.failed:
    return
  try:
    brain.runtime.restart()
    when defined(coworld):
      discard brain.runtime.run(playerPrinter(brain.owner - 1))
    else:
      discard brain.runtime.run()
    inc brain.decisions
  except BasicError as error:
    brain.failed = true
    brain.error = error.msg
    when defined(coworld):
      playerError(brain.owner - 1, error.msg)
    else:
      echo "BASIC policy ", brain.owner, ": ", error.msg
