import std/importutils
import polyworld/[relays, networks]
import galcon/[frontends, multiplayer]
privateAccess(Frontend)

let relay = Relay()
var fronts: seq[Frontend]
proc exchange() =
  ## Delivers the actual binary protocol, then runs each frontend snapshot path.
  for iteration in 0 ..< 30:
    var traffic = false
    for i, front in fronts:
      let outgoing = move(front.connection.client.outgoing)
      for bytes in outgoing:
        relay.process(i + 1, bytes, 0)
        traffic = true
    let outgoing = move(relay.outgoing)
    for output in outgoing:
      if output.bytes.len > 0:
        fronts[output.connection - 1].connection.client.accept(output.bytes)
        traffic = true
    for front in fronts:
      doAssert front.connection.client.error.len == 0,
        front.connection.client.error
      front.syncLobby()
    if not traffic: return
  doAssert false, "Lobby did not settle"

for i in 0 ..< 2:
  let front = Frontend(config: MatchConfig(players: 2),
    connection: Connection(stats: NetworkStats(),
      client: RoomClient(identity: identity(), name: "Human " & $i)))
  fronts.add front
  front.connection.client.opened()
exchange()
let host = fronts[0]
let guest = fronts[1]
host.createRoom()
exchange()
host.resizeRoster(2)
exchange()
let room = relay.rooms[0]
host.connection.client.claimHuman(0)
guest.connection.client.send(RoomMessage(kind: JoinRoom, room: room.id))
exchange()
guest.connection.client.claimHuman(1)
exchange()
for front in fronts:
  let client = front.connection.client
  front.prepared = prepareMatch(client, newSeq[string](2))
  client.send(RoomMessage(kind: Ready, revision: client.snapshot.revision,
    hash: front.prepared.stateHash()))
exchange()
let initial = host.prepared.stateHash()
guest.connection.client.send(RoomMessage(kind: LeaveRoom))
exchange()
doAssert relay.guests[0].ready
doAssert host.prepared != nil and host.prepared.revision == room.revision,
  "Sparse roster must refresh retained readiness immediately"
guest.connection.client.send(RoomMessage(kind: JoinRoom, room: room.id))
exchange()
guest.connection.client.claimHuman(1)
exchange()
doAssert host.prepared != nil and host.prepared.revision == room.revision
doAssert not relay.guests[1].ready, "Rejoining human must explicitly ready"
host.resizeRoster(3)
exchange()
doAssert host.prepared != nil and host.prepared.revision == room.revision
guest.connection.client.send(RoomMessage(kind: ClaimSeat, seat: 2,
  name: "Truce Bot"))
exchange()
doAssert host.prepared != nil
doAssert host.prepared.stateHash() != initial,
  "Changed player count must rebuild the initial state, not reuse old hashes"
guest.connection.client.send(RoomMessage(kind: ReleaseSeat, seat: 2))
exchange()
host.resizeRoster(2)
exchange()
doAssert host.prepared != nil
let client = guest.connection.client
guest.prepared = prepareMatch(client, newSeq[string](2))
client.send(RoomMessage(kind: Ready, revision: client.snapshot.revision,
  hash: guest.prepared.stateHash()))
exchange()
host.connection.client.send(RoomMessage(kind: StartMatch))
exchange()
doAssert room.phase == Playing
doAssert host.prepared.started and guest.prepared.started
doAssert host.prepared.stateHash() == guest.prepared.stateHash()
doAssert host.prepared.stateHash() == initial
echo "Actual relay and frontends preserve ready intent, rebuild revisions and launch with consensus"
