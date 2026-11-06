import std/importutils
import polyworld/networks
import galcon/[frontends, multiplayer, common]
privateAccess(Frontend)
let front = Frontend(config: MatchConfig(players: 4), online: true,
  connection: Connection(stats: NetworkStats(), client: RoomClient(participant: 1,
    connected: true, welcomed: true)))
let client = front.connection.client
client.snapshot = RoomMessage(room: "authority", participant: 1, phase: Lobby,
  seats: @[Seat(owner: 1, name: "Human"), Seat(owner: 2, name: "Human"),
    Seat(owner: 2, name: "Truce Bot"), Seat()],
  participants: @[Participant(id: 1, connected: true), Participant(id: 2, connected: true)])
front.playerContext(2)
doAssert front.contextSeat == 2
client.snapshot.seats[2] = Seat(owner: 3, name: "Truce Bot")
var rejected = false
try: front.activateContext()
except RoomsError: rejected = true
doAssert rejected and client.outgoing.len == 0, "Stale bot owner must not clear replacement"
front.playerContext(1)
client.snapshot.room = "replacement"
rejected = false
try: front.activateContext()
except RoomsError: rejected = true
doAssert rejected and client.outgoing.len == 0
client.snapshot.room = "authority"
client.snapshot.participants.add Participant(id: 3, connected: true)
front.playerContext(2)
front.activateContext()
let command = decode(client.outgoing[^1])
doAssert command.kind == ReleaseSeat and command.seat == 2
client.snapshot.participant = 2
front.playerContext(2)
doAssert front.contextSeat == -1, "Guest context administration must be absent"
rejected = false
try: front.fillBots()
except RoomsError: rejected = true
doAssert rejected
rejected = false
try: front.shuffleTeam()
except RoomsError: rejected = true
doAssert rejected
client.snapshot.participant = 1
front.playerContext(1)
client.snapshot.participants.setLen(1)
rejected = false
try: front.activateContext()
except RoomsError: rejected = true
doAssert rejected
client.connected = false
front.playerContext(2)
doAssert front.contextSeat == -1
echo "Authority and stale room/seat/participant/connection revalidation passed"
