import polyworld/[rooms, relays]

proc testLobbyRelay*() =
  ## Exercises shared slot permissions without game-name startup exceptions.
  let relay = Relay()
  let game = GameIdentity(game: "galcon", gameplay: 13, protocol: 3)
  proc send(connection: int, message: RoomMessage) =
    ## Passes commands through the wire codec and actual relay.
    relay.receive(connection, decode(message.encode()), 0)
    relay.outgoing.setLen(0)
  proc rejected(connection: int, message: RoomMessage) =
    ## Requires authorization failures without changing slot ownership.
    var failed = false
    try:
      send(connection, message)
    except RoomsError:
      failed = true
    doAssert failed
  for i in 1 .. 3:
    send(i, RoomMessage(kind: Hello, identity: game, name: "Player " & $i))
  let host = relay.guests[0]
  let guest = relay.guests[1]
  let newcomer = relay.guests[2]
  send(1, RoomMessage(kind: CreateRoom, name: "Lobby", number: 3,
    tickRate: 32, payload: "{\"opaque\":{\"teams\":[7,4]}}"))
  let room = relay.rooms[0]
  send(1, RoomMessage(kind: ClaimSeat, seat: 0, name: "Host",
    seatKind: HumanSeat))
  send(2, RoomMessage(kind: JoinRoom, room: room.id))
  send(2, RoomMessage(kind: ClaimSeat, seat: 1, name: "Guest",
    seatKind: HumanSeat))
  send(2, RoomMessage(kind: ClaimSeat, seat: 2, name: "Human",
    seatKind: BotSeat))
  doAssert room.seats[2].kind == BotSeat,
    "Bot identity cannot be inferred from its display name"
  rejected(2, RoomMessage(kind: ReleaseSeat, seat: 0))
  rejected(2, RoomMessage(kind: ClaimSeat, seat: 0, name: "Taken"))
  rejected(2, RoomMessage(kind: KickParticipant, participant: host.id))
  send(1, RoomMessage(kind: ReleaseSeat, seat: 1))
  doAssert guest.room == room.id and room.seats[1].owner == 0,
    "Host may remove a human seat without removing the participant"
  send(1, RoomMessage(kind: ClaimSeat, seat: 1, participant: guest.id,
    seatKind: HumanSeat, name: "Assigned by host"))
  send(1, RoomMessage(kind: ReadyStatus, flag: true))
  doAssert host.ready and not guest.ready
  let snapshot = relay.state(room)
  send(1, RoomMessage(kind: StartMatch, revision: room.revision,
    hash: snapshot.setupHash()))
  doAssert room.phase == Playing
  send(1, RoomMessage(kind: ReleaseSeat, seat: 2))
  doAssert room.seats[2].owner == 0 and guest.room == room.id,
    "Live bot removal does not kick the owner"
  send(1, RoomMessage(kind: ClaimSeat, seat: 1, participant: host.id,
    seatKind: BotSeat, name: "Replacement policy"))
  doAssert room.seats[1].owner == host.id and room.seats[1].kind == BotSeat
  rejected(2, RoomMessage(kind: ReleaseSeat, seat: 1))
  send(2, RoomMessage(kind: ClaimSeat, seat: 2, seatKind: BotSeat,
    name: "Guest replacement"))
  doAssert room.seats[2].owner == guest.id
  send(1, RoomMessage(kind: KickParticipant, participant: guest.id))
  doAssert guest.room.len == 0 and room.seats[2].owner == 0
  doAssert newcomer.room.len == 0
  echo "Generic host and guest slot permissions work before and during play"

testLobbyRelay()
