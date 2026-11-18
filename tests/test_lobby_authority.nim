import std/importutils
import polyworld/networks
import galcon/[frontends, multiplayer]
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
doAssert front.contextSeat == -1, "Guests cannot administer another owner's slot"
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

for participant in [1'u32, 2'u32]:
  for index in 0 .. 4:
    let lobby = Frontend(config: MatchConfig(players: 5), online: true,
      connection: Connection(stats: NetworkStats(),
        client: RoomClient(participant: participant,
          connected: true, welcomed: true)))
    let peer = lobby.connection.client
    peer.snapshot = RoomMessage(room: "permissions", participant: 1, phase: Lobby,
      seats: @[Seat(owner: 1, name: "Human"), Seat(owner: 1, name: "Classic Bot"),
        Seat(owner: 2, name: "Human"), Seat(owner: 2, name: "Truce Bot"), Seat()],
      participants: @[Participant(id: 1, connected: true),
        Participant(id: 2, connected: true)])
    let allowed = index < 4 and (participant == 1 or index in [2, 3])
    lobby.playerContext(index)
    if not allowed:
      doAssert lobby.contextSeat == -1
      doAssert peer.outgoing.len == 0
      continue
    doAssert lobby.contextSeat == index
    lobby.activateContext()
    doAssert peer.outgoing.len == 1 and lobby.contextSeat == -1
    let action = decode(peer.outgoing[0])
    if participant == 1 and index == 2:
      doAssert action.kind == KickParticipant and action.participant == 2
    else:
      doAssert action.kind == ReleaseSeat and action.seat == index.uint32,
        "Own humans leave their slot; owned and host-moderated bots are removed"
    doAssert peer.snapshot.seats[index].owner != 0,
      "Context actions await the server before changing the roster"

block:
  let local = Frontend(config: MatchConfig(players: 3), localHuman: 1)
  let bot = LocalPolicy(name: "Local Bot", bytes: "a = 1\n")
  local.policies[1] = bot
  local.playerContext(0)
  doAssert local.contextSeat == 0
  local.activateContext()
  doAssert local.localHuman == 0 and local.policies[1] == bot
  local.playerContext(1)
  doAssert local.contextSeat == 1
  local.activateContext()
  doAssert local.policies[1].bytes.len == 0
  local.playerContext(2)
  doAssert local.contextSeat == -1
  local.policies[0] = bot
  local.playerContext(0)
  let replacement = LocalPolicy(name: "Replacement Bot", bytes: "a = 2\n")
  local.policies[0] = replacement
  rejected = false
  try: local.activateContext()
  except RoomsError: rejected = true
  doAssert rejected and local.policies[0] == replacement,
    "A stale local context must preserve a replacement occupant"
echo "Authority and stale room/seat/participant/connection revalidation passed"
