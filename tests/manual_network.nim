import
  std/os,
  jsony, windy, vmath,
  polyworld/[connections, rooms, roomclients],
  galcon/[common, multiplayer, sessions, replays]

proc main() =
  ## Runs two independent bot owners over a real local Polyworld WebSocket relay.
  let window = newWindow("Galcon network verification", ivec2(400, 180))
  let links = [
    connect("ws://127.0.0.1:19916/ws", "Galcon QA host", identity()),
    connect("ws://127.0.0.1:19916/ws", "Galcon QA guest", identity())
  ]
  defer:
    for link in links: link.close()
    window.close()
  var
    matches: array[2, NetworkMatch]
    requested, claimed: array[2, bool]
    revisions: array[2, uint32]
    startRequested, interrupted: bool
  let deadline = networkTime() + 40
  while networkTime() < deadline:
    pollEvents()
    for link in links:
      link.pump()
      doAssert link.client.error.len == 0, link.client.error
    for i, link in links:
      let client = link.client
      if not client.welcomed: continue
      if not requested[i]:
        if i == 0:
          client.send(RoomMessage(kind: CreateRoom, name: "Galcon socket test",
            number: 16, tickRate: TickRate, flag: false,
            payload: MatchConfig(maximumTicks: 192).toJson()))
          requested[i] = true
        elif links[0].client.snapshot.room.len > 0:
          client.send(RoomMessage(kind: JoinRoom,
            room: links[0].client.snapshot.room))
          requested[i] = true
      if client.snapshot.room.len > 0:
        if not claimed[i]:
          for seat in 0 ..< 16:
            if seat mod 2 == i:
              client.send(RoomMessage(kind: ClaimSeat, seat: seat.uint32,
                name: "Truce Bot"))
          claimed[i] = true
        var full = true
        for seat in client.snapshot.seats:
          full = full and seat.owner != 0
        if full and client.snapshot.phase == Lobby and
          revisions[i] != client.snapshot.revision:
            var sources = newSeq[string](16)
            for seat in 0 ..< 16:
              if seat mod 2 == i: sources[seat] = TruceSource
            matches[i] = prepareMatch(client, sources)
            revisions[i] = client.snapshot.revision
            client.send(RoomMessage(kind: Ready, revision: revisions[i],
              hash: matches[i].stateHash()))
        var ready = full
        for participant in client.snapshot.participants:
          ready = ready and participant.ready
        if i == 0 and ready and not startRequested and matches[0] != nil:
          client.send(RoomMessage(kind: StartMatch))
          startRequested = true
      for event in client.events:
        matches[i].start(event)
      client.events.setLen(0)
      if matches[i] != nil and matches[i].started:
        var packet: RoomMessage
        for tick in 0 ..< 8:
          if matches[i].finished or not link.takeTick(packet, TickRate): break
          matches[i].applyPacket(packet)
      if i == 1 and matches[i] != nil and matches[i].started and
        client.applied >= 64 and not interrupted:
          link.reconnectAfter(0.3)
          interrupted = true
          echo "Reconnecting guest at tick ", client.applied
    if matches[0] != nil and matches[1] != nil and matches[0].finished and
      matches[1].finished and links[0].client.snapshot.phase == Ended:
        doAssert interrupted
        doAssert matches[0].stateHash() == matches[1].stateHash()
        doAssert matches[0].session.recording.hashes == matches[1].session.recording.hashes
        for i, match in matches:
          match.session.saveRecording(Root / "build" / ("socket-" & $i & ".replay"))
        echo "Real WebSocket test passed: 16 players, 192 matching ticks, reconnect, replays"
        return
    sleep(2)
  raise newException(GalconError, "WebSocket verification timed out")

main()
