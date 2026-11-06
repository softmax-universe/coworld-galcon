## Native deterministic CPU benchmark. No renderer, sockets, or production edits.
import std/[os, strutils, monotimes, json]
import galcon/[common, worlds, sessions, bots, replays, chats, profiles]

let outDir = if paramCount() > 0: paramStr(1) else: "tmp/many-ships-sim"
let sampleTicks = if paramCount() > 1: parseInt(paramStr(2)) else: 512
let warmTicks = if paramCount() > 2: parseInt(paramStr(3)) else: 512
createDir(outDir)

proc fixture(high: bool): World =
  var counts = @[0]
  for i in 1 .. 16: counts.add 8
  result = newWorld(Setup(seed: 20261106, players: 16, counts: counts,
    placement: RandomPlacement, collisions: Grid16,
    enemyShipsPassThrough: true, neutralsDontProduce: true))
  for p in result.planets:
    p.ships = stock(if high: 1_000_000 else: 8)
    if not high: p.production = 0
    p.realShips = p.ships
  for i, p in result.planets:
    if not high and i != 0: continue
    var target = -1
    var longest = -1'i64
    for j, other in result.planets:
      if other.owner == p.owner: continue
      let distance = lengthSquared(p.x - other.x, p.y - other.y)
      if distance > longest:
        longest = distance
        target = j
    doAssert result.launch(p.owner, i, target, if high: 100_000 else: 8) > 0

proc nowNs(): int64 = getMonoTime().ticks
proc nsSince(start: int64): int64 = nowNs() - start

when defined(simProbe):
  let w = fixture(true)
  for i in 0 ..< warmTicks:
    w.advance()
    if i mod 100 == 0:
      echo "warm tick=", w.tick, " active=", w.activeShips,
        " pending=", w.pendingLaunchCount
  quit()

proc runCase(high: bool) =
  let label = if high: "high" else: "low"
  var w = fixture(high)
  for i in 0 ..< warmTicks:
    w.advance()
  echo label, " warm=", w.tick, " active=", w.activeShips,
    " pending=", w.pendingLaunchCount
  w.orders.setLen(0)
  let initial = w.clone()
  let chat = newChatHub(w)
  let s = Session(world: w, liveWorld: w, chat: chat,
    maximumTicks: (warmTicks + sampleTicks + 1).int32,
    keepHistory: true, checkpointSpacing: CheckpointTicks,
    recording: Recording(setup: w.setup,
      hashes: newSeq[uint64](warmTicks)))
  s.captureCheckpoint()
  # Default bot policies execute against the same genuine queue-filled world.
  # Their orders are recorded and reapplied to the paired world-only run.
  for owner in 1 .. w.setup.players:
    s.brains[owner] = newBrain(w, owner, BaselineSource, chat)
  var rows: seq[JsonNode]
  var warmRows: seq[JsonNode]
  var sink: uint64
  for mode in ["session", "world", "replay", "hash"]:
    var world = initial.clone()
    var cursor = s.recording.orderCursor(world.tick)
    var chatCursor = 0
    if mode == "session": world = w
    var checkpointSession = Session(world: world, liveWorld: world,
      keepHistory: true, checkpointSpacing: CheckpointTicks)
    if mode != "session": checkpointSession.captureCheckpoint()
    for n in 0 ..< sampleTicks:
      when ProfileTracePath.len > 0:
        if n mod 64 == 0: startTrace(category = label & ":" & mode)
      let beforeTick = world.tick
      let beforeActive = world.activeShips
      let beforePending = world.pendingLaunchCount
      if high: doAssert beforeActive >= 3500
      else: doAssert beforeActive <= 8
      let memBefore = getOccupiedMem()
      let checkpointsBefore = if mode == "session": s.checkpoints.len
        else: checkpointSession.checkpoints.len
      var orderNs, recordNs, checkpointNs: int64
      var elapsed: int64
      profileBlock "bench.tick":
        let start = nowNs()
        case mode
        of "session":
          s.step()
        of "world":
          let orderStart = nowNs()
          while cursor < s.recording.orders.len and
            s.recording.orders[cursor].tick == world.tick:
            let order = s.recording.orders[cursor]
            doAssert world.launch(order.player.int, order.source.int,
              order.target.int, order.count.int) == order.count.int
            inc cursor
          orderNs = nsSince(orderStart)
          let advanceStart = nowNs()
          world.advance()
          elapsed = nsSince(advanceStart)
          doAssert world.fingerprint() == s.recording.hashes[world.tick - 1]
          let recordStart = nowNs()
          # Match recordTick's order clearing and hash cost without a new tape.
          world.orders.setLen(0)
          sink = sink xor world.fingerprint()
          recordNs = nsSince(recordStart)
          let checkpointStart = nowNs()
          profileBlock "bench.checkpoint": checkpointSession.captureCheckpoint()
          checkpointNs = nsSince(checkpointStart)
        of "replay":
          profileBlock "bench.replayTick":
            s.recording.replayTick(world, cursor, chatCursor)
          let checkpointStart = nowNs()
          profileBlock "bench.checkpoint": checkpointSession.captureCheckpoint()
          checkpointNs = nsSince(checkpointStart)
        of "hash":
          profileBlock "bench.hashBatch":
            for repeat in 0 ..< 32: sink = sink xor world.fingerprint()
        else: discard
        if mode != "world": elapsed = nsSince(start)
      let checkpointsAfter = if mode == "session": s.checkpoints.len
        else: checkpointSession.checkpoints.len
      let memAfter = getOccupiedMem()
      rows.add %*{"case": label, "mode": mode, "sample": n,
        "tick_before": beforeTick, "tick_after": world.tick,
        "active_before": beforeActive, "active_after": world.activeShips,
        "pending_before": beforePending, "pending_after": world.pendingLaunchCount,
        "impacts": world.impacts, "captures": world.captures,
        "tick_ns": elapsed, "order_ns": orderNs, "record_ns": recordNs,
        "checkpoint_ns": checkpointNs,
        "checkpoint_added": checkpointsAfter > checkpointsBefore,
        "heap_before": memBefore, "heap_after": memAfter,
        "heap_delta": memAfter - memBefore}
      when ProfileTracePath.len > 0:
        if n mod 64 == 63 or n == sampleTicks - 1:
          endTrace()
          dumpMeasures(outDir / (label & "-" & mode & "-" & $(n div 64) & ".json"))
      if mode != "hash": doAssert world.tick == beforeTick + 1
    if mode == "session":
      for owner in 1 .. w.setup.players:
        doAssert not s.brains[owner].failed
      writeFile(outDir / (label & "-state.json"), $(%*{
        "initial_hash": $initial.fingerprint(), "final_hash": $w.fingerprint(),
        "initial_tick": initial.tick, "final_tick": w.tick,
        "initial_active": initial.activeShips, "final_active": w.activeShips,
        "orders": s.recording.orders.len, "hashes": s.recording.hashes.len,
        "checkpoints": s.checkpoints.len, "world_bytes": sizeof(w[]),
        "bot_decisions": s.brains[1].decisions, "sink": $sink}))
  writeFile(outDir / (label & "-samples.json"), $(%rows))

runCase(false)
runCase(true)
