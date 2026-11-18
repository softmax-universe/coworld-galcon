import std/[importutils, os]
import jsony
import polyworld/networks
import galcon/[frontends, multiplayer, options, common, bots, worlds]

privateAccess(Frontend)

let front = newFrontend(parseOptions(@["--players", "16"]))
front.connection = Connection(stats: NetworkStats(),
  client: RoomClient(participant: 1, welcomed: true, connected: true))
doAssert front.config.players == 16
front.createRoom()
let request = decode(front.connection.client.outgoing[^1])
doAssert request.kind == CreateRoom and request.number == 4
doAssert parseConfig(request.payload).players == 4
front.connection.client.snapshot = RoomMessage(kind: RoomState, room: "test",
  name: "Test", participant: 1, revision: 1, phase: Lobby,
  tickRate: TickRate.uint32, payload: MatchConfig(players: 4).toJson(),
  participants: @[Participant(id: 1, connected: true)],
  seats: @[Seat(owner: 1, name: "Human", kind: HumanSeat),
    Seat(owner: 1, name: "Truce Bot", kind: BotSeat),
    Seat(owner: 2, name: "Human", kind: HumanSeat),
    Seat(owner: 2, name: "Truce Bot", kind: BotSeat)])
front.syncLobby()
front.resizeRoster(5)
doAssert front.synchronizing()
let resize = decode(front.connection.client.outgoing[^1])
doAssert resize.kind == ResizeRoom and resize.number == 5
front.connection.client.snapshot.payload = resize.payload
front.connection.client.snapshot.seats.add Seat()
inc front.connection.client.snapshot.revision
front.syncLobby()
doAssert not front.synchronizing()
front.removePlayer(3)
let remove = decode(front.connection.client.outgoing[^1])
doAssert remove.kind == ReleaseSeat and remove.seat == 3
front.playerContext(2)
doAssert front.contextSeat == 2
front.kickPlayer(2)
doAssert decode(front.connection.client.outgoing[^1]).kind == KickParticipant
var rejected = false
try: front.kickPlayer(0)
except RoomsError: rejected = true
doAssert rejected
front.connection.client.snapshot.room = ""
front.syncLobby()
doAssert front.config.players == 16, "Online roster must not replace local preference"
proc testLobbyLifecycle*() =
  ## A disconnected frontend must release modal and pending state on room exit.
  let front = newFrontend(parseOptions(@["--players", "16"]))
  front.connection = Connection(stats: NetworkStats(),
    client: RoomClient(participant: 1, welcomed: true, connected: true))
  front.connection.client.snapshot = RoomMessage(kind: RoomState, room: "lifecycle",
    name: "Lifecycle", participant: 1, revision: 1,
    tickRate: TickRate.uint32, payload: MatchConfig(players: 4).toJson(),
    seats: newSeq[Seat](4))
  front.connection.client.snapshot.seats[0] =
    Seat(owner: 1, name: "Human", kind: HumanSeat)
  front.syncLobby()
  front.playerContext(1)
  front.contextSeat = -1
  front.resizeRoster(5)
  front.connection.client.snapshot.room = ""
  front.syncLobby()
  doAssert not front.synchronizing(), "Room exit must clear pending roster writes"
  doAssert front.contextSeat == -1
  doAssert front.config.players == 16

testLobbyLifecycle()

for bot in LobbyBot:
  let
    source = readFile(Root / "players" /
      ["classic.bas", "truce.bas", "expand.bas", "chatty.bas"][bot.ord])
    existing = LocalPolicy(name: "Custom Bot", bytes: "count = count + 1\n")
    local = Frontend(config: MatchConfig(players: 4), localHuman: 1)
  local.policies[1] = existing
  local.fillBots(bot)
  doAssert local.localHuman == 1 and local.policies[0].bytes.len == 0
  doAssert local.policies[1] == existing, "Fill preserves existing local bots"
  for i in 2 .. 3:
    doAssert local.policies[i].name == LobbyBotNames[bot] & " Bot"
    doAssert local.policies[i].bytes == source,
      "Each Fill choice installs its bundled policy source"
  let filled = local.policies
  local.fillBots(ClassicBot)
  doAssert local.policies == filled, "Filling a full local roster changes nothing"

  let online = Frontend(config: MatchConfig(players: 6), online: true,
    connection: Connection(stats: NetworkStats(),
      client: RoomClient(participant: 1, welcomed: true, connected: true)))
  online.connection.client.snapshot = RoomMessage(kind: RoomState,
    room: "bot-catalog", participant: 1, phase: Lobby,
    seats: @[Seat(owner: 1, name: "Human", kind: HumanSeat),
      Seat(owner: 1, name: existing.name, kind: BotSeat),
      Seat(owner: 2, name: "Human", kind: HumanSeat),
      Seat(owner: 2, name: "Guest Bot", kind: BotSeat), Seat(), Seat()])
  online.networkPolicies[1] = existing
  let occupied = online.networkPolicies
  online.fillBots(bot)
  doAssert online.connection.client.outgoing.len == 2,
    "Network Fill claims only the two empty slots"
  for i in 0 .. 3:
    doAssert online.networkPolicies[i] == occupied[i],
      "Fill leaves host and guest occupied slots untouched"
  for i, bytes in online.connection.client.outgoing:
    let claim = decode(bytes)
    doAssert claim.kind == ClaimSeat and claim.seat == (i + 4).uint32
    doAssert claim.name == LobbyBotNames[bot] & " Bot"
    doAssert claim.seatKind == BotSeat
    doAssert online.networkPolicies[i + 4].bytes == source
    doAssert online.networkPolicies[i + 4].name == claim.name

for bot in [ExpandBot, ChattyBot]:
  let world = newWorld(Setup(seed: 3, counts: @[1, 1, 1]))
  var source, target: int
  for i, planet in world.planets:
    if planet.owner == 1: source = i
    elif planet.owner == 0: target = i
    planet.frame = 0
    planet.morale = 100
    planet.realMorale = 100
  world.planets[source].ships = stock(100)
  world.planets[source].realShips = stock(100)
  world.planets[source].neighbors = @[target]
  world.planets[target].ships = stock(5)
  let brain = newBrain(world, 1, LobbyBotPolicies[bot].bytes)
  brain.decide()
  doAssert not brain.failed, brain.error
  doAssert world.orders.len == 1,
    LobbyBotNames[bot] & " must launch ships from a ready owned planet"
  let order = world.orders[0]
  doAssert order.player == 1 and order.source == source.int32 and
    order.target == target.int32 and order.count > 0

echo "All bundled bots fill only empty slots; Expand and Chatty issue real orders"
echo "Lobby defaults, resizing, bot removal, context target and local preference passed"
