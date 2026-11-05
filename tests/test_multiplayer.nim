import
  std/os,
  jsony,
  polyworld/[relays, rooms, roomclients],
  galcon/[common, multiplayer, worlds, sessions, options, replays, chats]

proc testMultiplayer*() =
  ## Exercises real binary relay traffic, distributed bots, reconnect, and replay.
  let relay = Relay()
  var
    clients: seq[RoomClient]
    matches: seq[NetworkMatch]
    now = 1.0

  proc exchange() =
    ## Drains bounded synthetic sockets through the actual universal protocol.
    for iteration in 0 ..< 40:
      var sent = false
      for i, client in clients:
        if not client.connected: continue
        let outgoing = move(client.outgoing)
        for bytes in outgoing:
          relay.process(i + 1, bytes, now)
          sent = true
      let outgoing = move(relay.outgoing)
      for message in outgoing:
        let client = clients[message.connection - 1]
        if client.connected and message.bytes.len > 0:
          client.accept(message.bytes)
          doAssert client.error.len == 0, client.error
          sent = true
      if not sent: return
    doAssert false, "Relay traffic failed to settle"

  proc client(name: string): RoomClient =
    ## Connects a new participant with Galcon's versioned identity.
    result = RoomClient(identity: identity(), name: name)
    clients.add result
    result.opened()
    exchange()

  echo "Galcon unified protocol: 16 players, two bot owners and spectator"
  let
    first = client("Host")
    second = client("Guest")
    config = MatchConfig(maximumTicks: 384)
  first.send(RoomMessage(kind: CreateRoom, name: "Galcon test", number: 16,
    tickRate: TickRate, flag: true, payload: config.toJson()))
  exchange()
  let room = first.snapshot.room
  second.send(RoomMessage(kind: JoinRoom, room: room))
  exchange()
  for i in 0 ..< 16:
    let controller = if i mod 2 == 0: first else: second
    controller.send(RoomMessage(kind: ClaimSeat, seat: i.uint32,
      name: if i == 0: "Human" else: "Truce Bot"))
  exchange()
  for c in [first, second]:
    var sources = newSeq[string](16)
    for i in 0 ..< 16:
      if c.snapshot.seats[i].owner == c.participant and i != 0:
        sources[i] = TruceSource
    let match = prepareMatch(c, sources)
    matches.add match
    c.send(RoomMessage(kind: Ready, revision: c.snapshot.revision,
      hash: match.stateHash()))
  exchange()
  doAssert matches[0].stateHash() == matches[1].stateHash()
  doAssert matches[0].session.human == 1
  doAssert matches[1].session.human == 0
  first.send(RoomMessage(kind: StartMatch))
  exchange()
  for match in matches:
    match.start(match.client.events[0])
    match.client.events.setLen(0)
  exchange()
  doAssert not second.submit(0, "forged"), "Guests cannot command the host's seat"
  block:
    let hash = matches[0].stateHash()
    var rejected = false
    try:
      matches[0].applyPacket(RoomMessage(kind: TickPacket, match: first.match,
        tick: 1, commands: @[Command(participant: second.participant,
          seat: 0, payload: "forged")]))
    except RoomsError:
      rejected = true
    doAssert rejected and matches[0].stateHash() == hash
  let before = matches[0].stateHash()
  discard matches[0].session.chat.sendChat(1, -2, "hello from Green")
  doAssert matches[0].stateHash() == before, "Submissions must not mutate the world"
  exchange()
  var spectatorAdded, disconnected, reconnected: bool
  for step in 0 ..< 1400:
    now += 1.0 / TickRate
    relay.advance(now)
    exchange()
    for match in matches:
      if not match.client.connected: continue
      var packet: RoomMessage
      while not match.finished and match.client.takeTick(packet):
        match.applyPacket(packet)
    exchange()
    if not spectatorAdded and first.applied >= 64:
      let watcher = client("Spectator")
      watcher.send(RoomMessage(kind: JoinRoom, room: room))
      exchange()
      let match = prepareMatch(watcher, newSeq[string](16))
      match.start(watcher.events[0])
      watcher.events.setLen(0)
      matches.add match
      spectatorAdded = true
    if not disconnected and first.applied >= 128:
      relay.disconnect(2)
      second.lost()
      disconnected = true
    if disconnected and not reconnected and step >= 160:
      second.opened()
      exchange()
      reconnected = true
    if matches.len == 3 and matches[0].finished and matches[1].finished and
      matches[2].finished:
        break
  doAssert reconnected and spectatorAdded
  for match in matches:
    doAssert match.finished, "Match did not finish: " & $match.session.liveWorld.tick
    doAssert match.session.liveWorld.tick == 384
    doAssert match.stateHash() == matches[0].stateHash()
    doAssert match.session.recording.orders.len > 0
    doAssert match.session.recording.chats.len > 0
    doAssert match.client.snapshot.phase != Desynced
    doAssert match.session.recording.hashes == matches[0].session.recording.hashes
  echo "Galcon network rewind and native replay verification"
  let
    session = matches[2].session
    finalHash = session.liveWorld.fingerprint()
    path = Root / "build/network-test.replay"
  session.seek(77)
  doAssert session.world.tick == 77
  doAssert session.liveWorld.fingerprint() == finalHash
  session.returnToLive()
  session.saveRecording(path)
  let playback = newSession(parseOptions(@["--replay", path]))
  playback.seek(384)
  doAssert playback.world.fingerprint() == finalHash
  removeFile(path)
  echo "Galcon rejects malformed and unauthorized commands"
  for bad in ["{}", "null", "{\"players\":17}", "{\"planets\":2}",
    "{\"maximumTicks\":0}"]:
    var rejected = false
    try: discard parseConfig(bad)
    except GalconError: rejected = true
    # Empty JSON intentionally selects the approved defaults.
    doAssert rejected or bad == "{}"
  echo "Galcon networking checks passed"
