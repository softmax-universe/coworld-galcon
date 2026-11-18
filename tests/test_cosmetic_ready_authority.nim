import polyworld/[rooms, relays]

proc send(relay: Relay, connection: int, message: RoomMessage) =
  ## Sends actual wire data through the shared relay.
  relay.receive(connection, decode(message.encode()), 1)

proc lobby(game = "galcon", protocol = 3'u32): Relay =
  ## Creates the same occupied room for arbitrary game identities.
  result = Relay()
  for connection in 1 .. 2:
    result.send(connection, RoomMessage(kind: Hello,
      name: "Human " & $connection,
      identity: GameIdentity(game: game, gameplay: 1, protocol: protocol)))
  result.send(1, RoomMessage(kind: CreateRoom, name: "Startup", number: 2,
    tickRate: 32, payload: "{\"arbitrary\": [1, 2, 3]}"))
  result.send(2, RoomMessage(kind: JoinRoom, room: result.rooms[0].id))
  for connection in 1 .. 2:
    result.send(connection, RoomMessage(kind: ClaimSeat,
      seat: uint32(connection - 1), seatKind: HumanSeat, name: "Human"))

proc startMessage(relay: Relay): RoomMessage =
  ## Computes the common initial responsibility/configuration hash.
  let snapshot = relay.state(relay.rooms[0])
  RoomMessage(kind: StartMatch, revision: snapshot.revision,
    hash: snapshot.setupHash())

proc rejected(relay: Relay, connection: int, message: RoomMessage) =
  ## Requires invalid authority or setup to leave the room unchanged.
  var failed = false
  try:
    relay.send(connection, message)
  except RoomsError:
    failed = true
  doAssert failed

for game in ["galcon", "unrelated-game", "light_vs_dark"]:
  let relay = lobby(game, 97)
  let room = relay.rooms[0]
  relay.rejected(2, relay.startMessage())
  doAssert not relay.guests[0].ready and not relay.guests[1].ready
  let stale = relay.startMessage()
  relay.send(1, RoomMessage(kind: ClaimSeat, seat: 0, name: "Display label"))
  relay.rejected(1, stale)
  var altered = relay.startMessage()
  altered.hash = altered.hash xor 1
  relay.rejected(1, altered)
  relay.send(1, relay.startMessage())
  doAssert room.phase == Playing
  for connection in 1 .. 2:
    relay.send(connection, RoomMessage(kind: ReportHash, match: room.match,
      tick: 0, hash: 42))
  doAssert room.phase == Playing
  echo game, ": identity-independent start with cosmetic readiness passed"

block:
  let relay = lobby()
  let room = relay.rooms[0]
  relay.send(1, relay.startMessage())
  relay.send(1, RoomMessage(kind: ReportHash, match: room.match,
    tick: 0, hash: 42))
  relay.send(2, RoomMessage(kind: ReportHash, match: room.match,
    tick: 0, hash: 43))
  doAssert room.phase == Desynced
  echo "Different client simulations stop at their initial checkpoint"

block:
  let relay = lobby()
  let request = relay.startMessage()
  relay.disconnect(2)
  relay.send(1, request)
  doAssert relay.rooms[0].phase == Playing,
    "Disconnected controllers cannot turn cosmetic status into a start gate"

block:
  let relay = lobby()
  for connection in 1 .. 2:
    relay.send(connection, RoomMessage(kind: ReleaseSeat,
      seat: uint32(connection - 1)))
  relay.send(1, relay.startMessage())
  doAssert relay.rooms[0].phase == Playing,
    "A game decides whether its empty roster is meaningful, not the relay"
