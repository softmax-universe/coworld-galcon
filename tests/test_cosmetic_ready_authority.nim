import std/unittest
import polyworld/[rooms, relays]

proc send(r: Relay, c: int, m: RoomMessage) =
  r.receive(c, decode(m.encode()), 1)

proc lobby(game = "galcon", protocol = 2'u32): Relay =
  result = Relay()
  for c in 1..2:
    result.send(c, RoomMessage(kind: Hello, name: "Human " & $c,
      identity: GameIdentity(game: game, gameplay: 1, protocol: protocol)))
  result.send(1, RoomMessage(kind: CreateRoom, name: "Startup", number: 2,
    tickRate: 32, payload: "settings"))
  result.send(2, RoomMessage(kind: JoinRoom, room: result.rooms[0].id))
  for c in 1..2:
    result.send(c, RoomMessage(kind: ClaimSeat, seat: uint32(c-1), name: "Human"))

suite "Galcon automatic startup authority":
  test "pending start waits for both current hashes and rejects mismatch":
    let r = lobby()
    let room = r.rooms[0]
    expect RoomsError: r.send(2, RoomMessage(kind: StartMatch))
    r.send(1, RoomMessage(kind: StartMatch))
    expect RoomsError:
      r.send(1, RoomMessage(kind: Prepared, revision: room.revision-1, hash: 42))
    r.send(1, RoomMessage(kind: Prepared, revision: room.revision, hash: 42))
    check room.phase == Lobby
    r.send(2, RoomMessage(kind: Prepared, revision: room.revision, hash: 43))
    check room.phase == Desynced
  test "disconnected occupied controller blocks pending start":
    let r = lobby()
    r.disconnect(2)
    expect RoomsError: r.send(1, RoomMessage(kind: StartMatch))
    check r.rooms[0].phase == Lobby
  test "empty room cannot start":
    let r = lobby()
    for c in 1..2:
      r.send(c, RoomMessage(kind: ReleaseSeat, seat: uint32(c-1)))
    expect RoomsError: r.send(1, RoomMessage(kind: StartMatch))
  test "legacy Galcon and generic games retain explicit ready gate":
    for game in ["galcon", "unrelated-game", "light_vs_dark"]:
      let r = lobby(game, 1)
      for c in 1..2:
        r.send(c, RoomMessage(kind: Prepared, revision: r.rooms[0].revision, hash: 42))
      expect RoomsError: r.send(1, RoomMessage(kind: StartMatch))
      check r.rooms[0].phase == Lobby
