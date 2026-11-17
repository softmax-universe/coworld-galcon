import
  polyworld/[relays, networks],
  galcon/[frontends, multiplayer]

type SeatLobby = ref object
  relay: Relay
  fronts: seq[Frontend]
  claims: seq[int]

proc transport(lobby: SeatLobby): bool =
  ## Delivers actual binary messages without running frontend state updates.
  for i, front in lobby.fronts:
    let outgoing = move(front.connection.client.outgoing)
    for bytes in outgoing:
      if decode(bytes).kind == ClaimSeat:
        inc lobby.claims[i]
      lobby.relay.process(i + 1, bytes, 1.0)
      result = true
  let outgoing = move(lobby.relay.outgoing)
  for output in outgoing:
    if output.bytes.len > 0:
      lobby.fronts[output.connection - 1].connection.client.accept(output.bytes)
      result = true

proc exchange(lobby: SeatLobby, expectedError = "") =
  ## Settles automatic claims and preparation, including contested-seat errors.
  for iteration in 0 ..< 40:
    let traffic = lobby.transport()
    for front in lobby.fronts:
      front.syncLobby()
      doAssert front.connection.client.error.len == 0
      doAssert front.error.len == 0 or front.error == expectedError, front.error
      if front.error == expectedError:
        front.error = ""
    if not traffic:
      return
  doAssert false, "Automatic seat assignment must settle without request loops"

proc newSeatLobby(count: int): SeatLobby =
  ## Connects independent frontend clients to the same in-memory relay.
  result = SeatLobby(relay: Relay(), claims: newSeq[int](count))
  for i in 0 ..< count:
    let front = Frontend(config: MatchConfig(players: 4, maximumTicks: 192),
      connection: Connection(stats: NetworkStats(),
        client: RoomClient(identity: identity(), name: "Joining human " & $i)))
    result.fronts.add front
    front.connection.client.opened()
  result.exchange()

proc room(lobby: SeatLobby): RelayRoom =
  ## Finds the host's authoritative room rather than a copied client roster.
  lobby.relay.room(lobby.fronts[0].connection.client.snapshot.room)

proc join(lobby: SeatLobby, index: int) =
  ## Requests membership without manually assigning any seat.
  lobby.fronts[index].connection.client.send(
    RoomMessage(kind: JoinRoom, room: lobby.room().id))

proc assertHuman(lobby: SeatLobby, index, seat: int) =
  ## Requires exactly one authoritative human seat for the participant.
  let client = lobby.fronts[index].connection.client
  doAssert lobby.room().seats[seat].owner == client.participant
  doAssert lobby.room().seats[seat].name == "Human"
  doAssert client.snapshot.humanSeat(client.participant) == seat + 1

proc queuedClaims(front: Frontend): int =
  ## Counts pending claim operations independently of the implementation state.
  for bytes in front.connection.client.outgoing:
    if decode(bytes).kind == ClaimSeat:
      inc result

proc testJoiningSeats() =
  ## Hosts and guests claim once, and setup controls wait for acknowledgement.
  let
    lobby = newSeatLobby(2)
    host = lobby.fronts[0]
  host.createRoom()
  discard lobby.transport()
  host.syncLobby()
  doAssert host.synchronizing()
  doAssert host.queuedClaims() == 1
  for iteration in 0 ..< 20:
    host.syncLobby()
  doAssert host.queuedClaims() == 1,
    "Repeated snapshots must not resend an unacknowledged human claim"
  template rejectsPending(action: untyped) =
    ## Setup edits must not replace a human while its claim is in flight.
    block:
      var rejected = false
      try:
        action
      except RoomsError:
        rejected = true
      doAssert rejected
  rejectsPending(host.resizeRoster(6))
  rejectsPending(host.fillBots())
  rejectsPending(host.removePlayer(0))
  lobby.exchange()
  lobby.assertHuman(0, 0)
  doAssert not host.synchronizing()
  doAssert lobby.claims[0] == 1
  lobby.join(1)
  lobby.exchange()
  lobby.assertHuman(1, 1)
  doAssert lobby.claims[1] == 1
  for front in lobby.fronts:
    doAssert front.prepared != nil,
      "An automatically seated player must prepare the actual match"

proc testContestedSeats() =
  ## Simultaneous joins retry contested slots without moving an existing human.
  let lobby = newSeatLobby(3)
  lobby.fronts[0].createRoom()
  lobby.exchange()
  lobby.join(1)
  lobby.join(2)
  discard lobby.transport()
  for front in lobby.fronts:
    front.syncLobby()
  for index in 1 .. 2:
    doAssert lobby.fronts[index].queuedClaims() == 1
  lobby.exchange()
  for index in 0 .. 2:
    lobby.assertHuman(index, index)
  doAssert lobby.claims[1] == 1 and lobby.claims[2] == 2,
    "The losing joiner must retry the next free slot exactly once"
  let guest = lobby.fronts[1]
  guest.connection.client.claimHuman(3)
  lobby.exchange()
  lobby.assertHuman(1, 3)
  doAssert lobby.room().seats[1].owner == 0
  guest.removePlayer(3)
  lobby.exchange()
  let claims = lobby.claims[1]
  lobby.fronts[0].resizeRoster(5)
  lobby.exchange()
  doAssert guest.connection.client.snapshot.humanSeat(
    guest.connection.client.participant) == 0
  doAssert lobby.claims[1] == claims,
    "Clearing a human slot intentionally must not trigger another auto-claim"

proc testFullRoomAndRejoin() =
  ## A full room preserves every controller until a fresh membership can fit.
  let
    lobby = newSeatLobby(2)
    host = lobby.fronts[0]
    guest = lobby.fronts[1]
  host.createRoom()
  lobby.exchange()
  host.fillBots(TruceBot)
  lobby.exchange()
  lobby.join(1)
  lobby.exchange()
  doAssert lobby.claims[1] == 0
  lobby.assertHuman(0, 0)
  for seat in 1 .. 3:
    doAssert lobby.room().seats[seat].owner == host.connection.client.participant
    doAssert lobby.room().seats[seat].name == "Truce Bot"
  host.removePlayer(2)
  lobby.exchange()
  doAssert lobby.claims[1] == 0 and lobby.room().seats[2].owner == 0,
    "A spectator must stay unassigned when a slot later opens"
  guest.connection.client.send(RoomMessage(kind: LeaveRoom))
  lobby.exchange()
  lobby.join(1)
  lobby.exchange()
  lobby.assertHuman(1, 2)
  doAssert lobby.claims[1] == 1,
    "Leaving and joining again must begin a fresh assignment attempt"
  let
    previousRoom = lobby.room().id
    previousClaims = lobby.claims[0]
  host.connection.client.send(RoomMessage(kind: LeaveRoom))
  lobby.exchange()
  host.createRoom()
  lobby.exchange()
  doAssert lobby.room().id != previousRoom
  lobby.assertHuman(0, 0)
  doAssert lobby.claims[0] == previousClaims + 1,
    "A host entering a different room must receive a new human slot"

proc testReconnectSeats() =
  ## Reconnects preserve acknowledged seats and recover unsent pending claims.
  let
    lobby = newSeatLobby(2)
    host = lobby.fronts[0]
    guest = lobby.fronts[1]
    client = guest.connection.client
  host.createRoom()
  lobby.exchange()
  lobby.join(1)
  discard lobby.transport()
  guest.syncLobby()
  doAssert guest.queuedClaims() == 1 and guest.synchronizing()
  lobby.relay.disconnect(2)
  client.lost()
  guest.syncLobby()
  lobby.exchange()
  client.opened()
  lobby.exchange()
  lobby.assertHuman(1, 1)
  doAssert lobby.claims[1] == 1,
    "A claim lost before transport must be sent once after reconnect"
  let claims = lobby.claims[1]
  lobby.relay.disconnect(2)
  client.lost()
  guest.syncLobby()
  lobby.exchange()
  client.opened()
  lobby.exchange()
  lobby.assertHuman(1, 1)
  doAssert lobby.claims[1] == claims,
    "Reconnect must keep an existing human seat without claiming another"

proc testRosterShrinkRace() =
  ## A removed pending slot leaves its joiner spectating without an error.
  let
    lobby = newSeatLobby(2)
    host = lobby.fronts[0]
    guest = lobby.fronts[1]
  host.createRoom()
  lobby.exchange()
  host.fillBots(TruceBot)
  lobby.exchange()
  host.removePlayer(2)
  host.removePlayer(3)
  lobby.exchange()
  lobby.join(1)
  discard lobby.transport()
  guest.syncLobby()
  doAssert guest.queuedClaims() == 1 and guest.synchronizing()
  host.resizeRoster(2)
  lobby.exchange()
  doAssert lobby.room().seats.len == 2
  lobby.assertHuman(0, 0)
  doAssert lobby.room().seats[1].owner == host.connection.client.participant
  doAssert lobby.room().seats[1].name == "Truce Bot"
  doAssert guest.connection.client.snapshot.humanSeat(
    guest.connection.client.participant) == 0
  doAssert lobby.claims[1] == 1 and not guest.synchronizing(),
    "A roster shrink must settle the pending claim without repeated requests"

proc testPlayingSpectator() =
  ## Joining an active match remains spectating even after the room reopens.
  let
    lobby = newSeatLobby(2)
    host = lobby.fronts[0]
    client = host.connection.client
  host.createRoom()
  lobby.exchange()
  client.send(RoomMessage(kind: StartMatch))
  lobby.exchange()
  doAssert lobby.room().phase == Playing
  lobby.join(1)
  lobby.exchange()
  doAssert lobby.claims[1] == 0
  doAssert lobby.fronts[1].prepared.session.human == 0
  client.send(RoomMessage(kind: AbortMatch, match: client.match,
    detail: "Return to lobby for spectator check"))
  lobby.exchange("Joining human 0: Return to lobby for spectator check")
  client.send(RoomMessage(kind: ReturnLobby))
  lobby.exchange()
  doAssert lobby.room().phase == Lobby
  doAssert lobby.claims[1] == 0,
    "Watching a running match must not claim a slot for the next match"

proc testAutoSeats*() =
  ## Exercises automatic joining through real frontend and relay transitions.
  echo "Room entry automatically assigns one available human slot"
  testJoiningSeats()
  testContestedSeats()
  testFullRoomAndRejoin()
  testReconnectSeats()
  testRosterShrinkRace()
  testPlayingSpectator()
  echo "Automatic seats, contested joins, spectators and reconnects passed"
