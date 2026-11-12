import std/os
import jsony
import polyworld/[relays, roomclients]
import galcon/[multiplayer, common, worlds, sessions, options, replays]

proc testSparseLobby*() =
  let relay = Relay()
  var clients: seq[RoomClient]
  var now = 1.0
  proc exchange() =
    for attempt in 0 ..< 40:
      var traffic = false
      for i, client in clients:
        let outgoing = move(client.outgoing)
        for bytes in outgoing:
          relay.process(i + 1, bytes, now)
          traffic = true
      let outgoing = move(relay.outgoing)
      for output in outgoing:
        if output.bytes.len > 0:
          clients[output.connection - 1].accept(output.bytes)
          doAssert clients[output.connection - 1].error.len == 0,
            clients[output.connection - 1].error
          traffic = true
      if not traffic: return
    doAssert false
  let names = @["mason :)", "空 白 🙂 \"quote\": (guest)"]
  for name in names:
    let client = RoomClient(identity: identity(), name: name)
    clients.add client
    client.opened()
    exchange()
  let config = MatchConfig(players: 4, planets: 26, maximumTicks: 96)
  clients[0].send(RoomMessage(kind: CreateRoom, name: names[0] & "'s game",
    number: 4, tickRate: TickRate, payload: config.toJson()))
  exchange()
  clients[1].send(RoomMessage(kind: JoinRoom, room: clients[0].snapshot.room))
  exchange()
  clients[0].claimHuman(1)
  clients[1].claimHuman(3)
  exchange()
  var matches: seq[NetworkMatch]
  for client in clients:
    let match = prepareMatch(client, newSeq[string](4))
    matches.add match
    doAssert match.session.liveWorld.setup.players == 2, "Empty slots must not spawn ghost factions"
    doAssert match.session.brains[1] == nil and match.session.brains[2] == nil
    doAssert match.session.names[1] == names[0] and match.session.names[2] == names[1]
    doAssert match.session.displayName(1) == names[0] and match.session.displayName(2) == names[1]
    client.send(RoomMessage(kind: Ready, revision: client.snapshot.revision,
      hash: match.stateHash()))
  exchange()
  clients[0].send(RoomMessage(kind: StartMatch))
  exchange()
  for match in matches:
    doAssert match.client.began and match.client.snapshot.phase == Playing,
      "The authoritative relay must start the sparse roster"
    match.start(match.client.events[0])
    match.client.events.setLen(0)
  exchange()
  var source, target: int
  for i, planet in matches[0].session.liveWorld.planets:
    if planet.owner == 1: source = i
    if planet.owner == 2: target = i
  doAssert matches[0].queueOrder(1, source, target, 50, true) == 50
  doAssert decode(clients[0].outgoing[^1]).seat == 1, "Compact player maps back to stable lobby seat"
  exchange()
  for step in 0 ..< 110:
    now += 1.0 / TickRate
    relay.advance(now)
    exchange()
    for match in matches:
      var packet: RoomMessage
      while not match.finished and match.client.takeTick(packet): match.applyPacket(packet)
    exchange()
    doAssert matches[0].stateHash() == matches[1].stateHash()
    if matches[0].finished and matches[1].finished: break
  doAssert matches[0].finished and matches[1].finished
  doAssert matches[0].session.recording.orders.len == 1
  let path = Root / "build/sparse-lobby.replay"
  matches[0].session.saveRecording(path)
  let replay = newSession(parseOptions(@["--replay", path]))
  replay.seek(96)
  doAssert replay.world.fingerprint() == matches[0].session.liveWorld.fingerprint()
  doAssert replay.names[1] == names[0] and replay.names[2] == names[1]
  removeFile(path)
  echo "Sparse noncontiguous seats: authoritative start, stable commands, opaque names, peer hashes and serialized replay passed"

when isMainModule: testSparseLobby()
