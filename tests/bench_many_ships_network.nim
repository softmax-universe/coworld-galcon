import std/[os, monotimes, json, strutils]
import jsony, windy
import polyworld/[rooms, roomclients]
import galcon/[common, multiplayer, worlds, sessions, replays]

proc clock(): float64 = getMonoTime().ticks.float64 / 1e9
let output = getEnv("GALCON_WIRE_OUTPUT")
let mode = paramStr(1)
let log = open(output / (mode & "-packets.jsonl"), fmWrite)
let ticksLog = open(output / (mode & "-ticks.jsonl"), fmWrite)
var clients: array[2, RoomClient]
var sockets: array[2, WebSocketHandle]
var matches: array[2, NetworkMatch]
var request, claimed: array[2, bool]
var revisions: array[2, uint32]
var started = false
var startTime = 0.0
var stalled = false
var resumeAt = 0.0
var previous: array[2, float64]
var maxShips = 0
var hashChecks = 0
var lastCommand = -1'i32
proc record(direction: string, i: int, bytes: string) =
  let m = decode(bytes)
  var j = %*{"time": clock(), "direction": direction, "client": i,
    "kind": $m.kind, "bytes": bytes.len, "tick": m.tick,
    "commands": m.commands.len, "applied": clients[i].applied}
  if m.kind in {ReportHash, FinishMatch, Ready, BeginMatch}: j["hash"] = %($m.hash)
  log.writeLine($j)
proc connectClient(index: int) =
  clients[index] = RoomClient(identity: identity(), name: "wire-" & $index)
  sockets[index] = openWebSocket(getEnv("GALCON_WIRE_SERVER"))
  sockets[index].onOpen = proc() = clients[index].opened()
  sockets[index].onMessage = proc(bytes: string, kind: WebSocketMessageKind) =
    doAssert kind == BinaryMessage
    record("down", index, bytes)
    clients[index].accept(bytes)
  sockets[index].onError = proc(message: string) =
    raise newException(IOError, message)
connectClient(0)
connectClient(1)
let deadline = clock() + 65
while clock() < deadline:
  pollEvents()
  for i in 0..1:
    let c = clients[i]
    doAssert c.error.len == 0, c.error
    if c.welcomed and not request[i]:
      if i == 0:
        c.send(RoomMessage(kind: CreateRoom, name: "isolated wire audit", number: 16,
          tickRate: TickRate, flag: true,
          payload: MatchConfig(players: 16, planets: 69, maximumTicks: 768).toJson()))
        request[i] = true
      elif clients[0].snapshot.room.len > 0:
        c.send(RoomMessage(kind: JoinRoom, room: clients[0].snapshot.room))
        request[i] = true
    if c.snapshot.room.len > 0:
      if not claimed[i]:
        for seat in 0..<16:
          if seat mod 2 == i:
            c.send(RoomMessage(kind: ClaimSeat, seat: seat.uint32,
              name: if seat < 2: "Human" else: "Idle"))
        claimed[i] = true
      var full = c.snapshot.seats.len == 16
      for seat in c.snapshot.seats: full = full and seat.owner != 0
      if full and c.snapshot.phase == Lobby and revisions[i] != c.snapshot.revision:
        var sources = newSeq[string](16)
        for seat in 2..<16:
          if seat mod 2 == i: sources[seat] = "end\n"
        matches[i] = prepareMatch(c, sources)
        revisions[i] = c.snapshot.revision
        c.send(RoomMessage(kind: Ready, revision: revisions[i], hash: matches[i].stateHash()))
      var ready = full
      for p in c.snapshot.participants: ready = ready and p.ready
      if i == 0 and ready and not started and matches[0] != nil:
        c.send(RoomMessage(kind: StartMatch))
        started = true
    for event in c.events:
      matches[i].start(event)
      if startTime == 0: startTime = clock()
    c.events.setLen(0)
    if matches[i] != nil and matches[i].started:
      if i == 1 and c.applied >= 192 and not stalled:
        stalled = true
        resumeAt = clock() + 0.9
      if i != 1 or clock() >= resumeAt:
        var packet: RoomMessage
        while not matches[i].finished and c.takeTick(packet):
          let t = clock()
          matches[i].applyPacket(packet)
          let w = matches[i].session.liveWorld
          maxShips = max(maxShips, w.activeShips)
          ticksLog.writeLine($(%*{"time": t, "client": i, "tick": packet.tick,
            "gapMs": (if previous[i] == 0: 0.0 else: (t-previous[i])*1000),
            "activeShips": w.activeShips, "pendingLaunches": w.pendingLaunchCount,
            "hash": $matches[i].stateHash(), "recovery": packet.tick in 193'u32..224'u32}))
          previous[i] = t
    if c.receiptPending and c.outgoing.len == 0:
      c.send(RoomMessage(kind: Received))
    let outgoing = move(c.outgoing)
    for bytes in outgoing:
      record("up", i, bytes)
      sockets[i].send(bytes, BinaryMessage)
  if matches[0] != nil and matches[1] != nil and matches[0].started and matches[1].started:
    if clients[0].applied == clients[1].applied:
      doAssert matches[0].stateHash() == matches[1].stateHash()
      inc hashChecks
      let tick = matches[0].session.liveWorld.tick
      if tick mod 32 == 0 and tick != lastCommand and tick < 768:
        lastCommand = tick
        let w = matches[0].session.liveWorld
        for player in 1..16:
          var source = -1
          for p, planet in w.planets:
            if planet.owner == player and (source < 0 or planet.shipCount > w.planets[source].shipCount): source = p
          if source >= 0:
            var target = -1
            var distance = -1'i64
            for p, planet in w.planets:
              if planet.owner != player:
                let dx = (planet.x - w.planets[source].x).int64
                let dy = (planet.y - w.planets[source].y).int64
                let d = dx*dx + dy*dy
                if d > distance: distance = d; target = p
            if target >= 0:
              discard matches[(player-1) mod 2].queueOrder(player, source, target,
                (if mode == "low": 1 else: 1000000), false)
    if matches[0].finished and matches[1].finished and clients[0].snapshot.phase == Ended:
      doAssert matches[0].stateHash() == matches[1].stateHash()
      doAssert matches[0].session.recording.hashes == matches[1].session.recording.hashes
      echo $(%*{"mode": mode, "elapsed": clock()-startTime, "maxActiveShips": maxShips,
        "tick": clients[0].applied, "finalHash": $matches[0].stateHash(),
        "hashChecks": hashChecks, "phase": $clients[0].snapshot.phase})
      for s in sockets: s.close()
      log.close(); ticksLog.close()
      quit(0)
  sleep(1)
raise newException(IOError, "wire benchmark timed out")
