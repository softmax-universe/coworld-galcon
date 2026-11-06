import jsony
import polyworld/networks
import galcon/[frontends, multiplayer, options, common]

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
  seats: @[Seat(owner: 1, name: "Human"), Seat(owner: 1, name: "Truce Bot"),
    Seat(owner: 2, name: "Human"), Seat(owner: 2, name: "Truce Bot")])
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
echo "Lobby defaults, resizing, bot removal, context target and local preference passed"
