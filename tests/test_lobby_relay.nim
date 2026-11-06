import polyworld/[rooms, relays]

proc testLobbyRelay*() =
  ## Exercises authoritative lobby readiness through real binary messages.
  let relay = Relay()
  let game = GameIdentity(game: "galcon", gameplay: 13, protocol: 1)
  proc send(connection: int, message: RoomMessage) =
    ## Passes commands through the wire codec and actual relay.
    relay.receive(connection, decode(message.encode()), 0)
    relay.outgoing.setLen(0)
  proc rejected(connection: int, message: RoomMessage) =
    ## Requires authorization failures without mutating lobby membership.
    var failed = false
    try: send(connection, message)
    except RoomsError: failed = true
    doAssert failed
  for i in 1 .. 3:
    send(i, RoomMessage(kind: Hello, identity: game, name: "Player " & $i))
  let host = relay.guests[0]
  let guest = relay.guests[1]
  let newcomer = relay.guests[2]
  send(1, RoomMessage(kind: CreateRoom, name: "Lobby", number: 2,
    tickRate: 32, payload: "settings"))
  let room = relay.rooms[0]
  send(1, RoomMessage(kind: ClaimSeat, seat: 0, name: "Human"))
  send(1, RoomMessage(kind: ClaimSeat, seat: 1, name: "Truce Bot"))
  send(1, RoomMessage(kind: Ready, revision: room.revision, hash: 10))
  send(2, RoomMessage(kind: JoinRoom, room: room.id))
  doAssert host.ready, "Joining must preserve existing readiness"
  doAssert not guest.ready, "A new participant must explicitly ready"
  send(1, RoomMessage(kind: ReleaseSeat, seat: 1))
  doAssert host.ready, "Removing a bot must preserve ready intent"
  send(2, RoomMessage(kind: ClaimSeat, seat: 1, name: "Human"))
  doAssert host.ready, "New player assignments preserve existing readiness"
  doAssert not guest.ready
  rejected(2, RoomMessage(kind: KickParticipant, participant: host.id))
  rejected(1, RoomMessage(kind: KickParticipant, participant: host.id))
  doAssert guest.room == room.id
  send(2, RoomMessage(kind: LeaveRoom))
  send(1, RoomMessage(kind: ClaimSeat, seat: 1, name: "Truce Bot"))
  doAssert host.ready, "Leaving must preserve existing readiness"
  rejected(1, RoomMessage(kind: StartMatch))
  doAssert room.phase == Lobby, "Old revision hashes cannot start a match"
  send(2, RoomMessage(kind: JoinRoom, room: room.id))
  send(1, RoomMessage(kind: ReleaseSeat, seat: 1))
  send(2, RoomMessage(kind: ClaimSeat, seat: 1, name: "Truce Bot"))
  send(1, RoomMessage(kind: ReleaseSeat, seat: 1))
  doAssert guest.room == room.id, "Bot removal never kicks its owner"
  doAssert room.seats[0].owner == host.id
  send(2, RoomMessage(kind: ClaimSeat, seat: 1, name: "Human"))
  send(1, RoomMessage(kind: KickParticipant, participant: guest.id))
  doAssert guest.room.len == 0 and room.seats[1].owner == 0
  doAssert room.participants == @[host.id]
  send(1, RoomMessage(kind: ClaimSeat, seat: 1, name: "Truce Bot"))
  send(1, RoomMessage(kind: ResizeRoom, name: "Lobby", number: 3,
    tickRate: 32, payload: "settings"))
  doAssert host.ready, "Roster-only resizing preserves readiness"
  send(1, RoomMessage(kind: ClaimSeat, seat: 2, name: "Truce Bot"))
  rejected(2, RoomMessage(kind: ReleaseSeat, seat: 2))
  send(1, RoomMessage(kind: ResizeRoom, name: "Lobby", number: 2,
    tickRate: 32, payload: "settings"))
  doAssert room.seats.len == 2 and host.ready
  send(1, RoomMessage(kind: ResizeRoom, name: "Lobby", number: 2,
    tickRate: 32, payload: "changed map seed"))
  doAssert not host.ready, "A resize message cannot disguise real settings changes"
  send(1, RoomMessage(kind: Ready, revision: room.revision, hash: 20))
  send(1, RoomMessage(kind: StartMatch))
  doAssert room.phase == Playing
  doAssert newcomer.room.len == 0
  echo "Lobby membership preserves intent and requires fresh preparation"

testLobbyRelay()
