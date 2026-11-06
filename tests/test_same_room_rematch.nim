## Real production View lifecycle, sockets, human inputs and saved replays.
## Reuse the ordinary fixture's identity/lobby/input routes, not fabricated ticks.
import std/[macros, strutils, os]
macro rematchLifecycle(): untyped =
  let fixture = staticRead("mp_e2e_native.nim")
  let setupEnd = fixture.find("  for i in 0..<ClientCount:\n    lobbyClick(i,vec2(560,922))")
  let actionsStart = fixture.find("  for i in 0..<ClientCount:\n    let v = clients[i].view\n    let w = v.session.liveWorld")
  let actionsEnd = fixture.find("  for i in 0..<ClientCount:\n    let v = clients[i].view\n    button(i, KeyEnter, true)", actionsStart)
  doAssert setupEnd > 0 and actionsStart > setupEnd and actionsEnd > actionsStart
  var source = fixture[0..<setupEnd].replace("  lobbyClick(0,vec2(1340,432))", "  host.front.config.maximumTicks = TickRate * 60\n  lobbyClick(0,vec2(1340,432))")
  source.add """
  # A private policy exists only on its controlling client, never in room payload.
  const privateSource = "private_rematch_counter = private_rematch_counter + 1\n"
  let settled = networkTime()+0.5
  while networkTime()<settled: frames()
  host.front.networkPolicies[0] = LocalPolicy(name: "Private rematch bot", bytes: privateSource)
  host.front.connection.client.send(RoomMessage(kind: ClaimSeat, seat: 0, name: "Private rematch bot"))
  awaitState("private bot joins sparse four-slot roster", guest.front.connection.client.snapshot.seats[0].owner == host.front.connection.client.participant)
  # The normal UI's minimum is one minute. Complete both games naturally at that
  # configured tick limit; never mutate a world, fabricate completion or Abort.
  let originalRoom = host.front.connection.client.snapshot
  var previousMatch: uint32
  var oldPreparations: seq[NetworkMatch]
  for round in 1..2:
    awaitState("fresh automatic preparation round " & $round,
      clients.allIt(it.view.front.prepared != nil and not it.view.front.prepared.started))
    for i in 0..<ClientCount:
      check("no cosmetic Ready round " & $round & " client " & $i, not ready(i))
      check("fresh untouched world", clients[i].view.front.prepared.session.liveWorld.tick == 0)
      if round == 2:
        check("replaced completed preparation", clients[i].view.front.prepared != oldPreparations[i])
    check("private policy retained locally", host.front.networkPolicies[0].bytes == privateSource and guest.front.networkPolicies[0].bytes.len == 0)
    check("preparations agree", host.front.prepared.stateHash() == guest.front.prepared.stateHash())
    lobbyClick(0,vec2(1350,922))
    awaitState("host starts round " & $round, clients.allIt(it.view.screen == GameScreen))
    check("new match identity", host.front.connection.client.match != 0 and host.front.connection.client.match != previousMatch and host.front.connection.client.match == guest.front.connection.client.match)
    previousMatch = host.front.connection.client.match
    check("sparse seats including private bot packed", host.front.prepared.playerSeats == @[0,1,3] and guest.front.prepared.playerSeats == @[0,1,3] and host.session.human == 2 and guest.session.human == 3)
    check("private bot executable only on owner", host.session.brains[1] != nil and guest.session.brains[1] == nil)
    awaitState("visible ticks round " & $round, clients.allIt(it.view.session.world.tick >= 8))
"""
  # All existing real selection/drag/wheel/right-click authority and motion checks.
  for line in fixture[actionsStart..<actionsEnd].splitLines():
    if line.len > 0: source.add "  " & line & "\n"
  source.add """
    block:
      let deadline = networkTime()+75
      while not clients.allIt(it.view.front.prepared.finished and it.view.screen == EndScreen and it.view.front.connection.client.snapshot.phase == Ended) and networkTime()<deadline:
        frames()
      check("both actual games complete naturally round " & $round, clients.allIt(it.view.front.prepared.finished and it.view.session.done and it.view.screen == EndScreen and it.view.front.connection.client.snapshot.phase == Ended))
    let ticks = host.session.recording.hashes.len
    check("same final tick", ticks == host.session.maximumTicks and guest.session.recording.hashes.len == ticks)
    check("all peer tick hashes agree", host.session.recording.hashes == guest.session.recording.hashes)
    for i in 0..<ClientCount:
      let recording = clients[i].view.session.recording
      let path = output / ("round-" & $round & "-client-" & $i & ".replay")
      recording.save(path)
      let tape = loadRecording(path)
      check("each human command retained", tape.orders.anyIt(it.player == 2) and tape.orders.anyIt(it.player == 3))
      check("replay names and hashes retained", tape.names == @["", "Private rematch bot", names[0], names[1]] and tape.hashes == host.session.recording.hashes)
      let world = newWorld(tape.setup)
      var cursor, chatCursor: int
      while world.tick < tape.hashes.len.int32: tape.replayTick(world,cursor,chatCursor)
      check("serialized replay verifies every tick", world.fingerprint() == tape.hashes[^1])
      echo "REMATCH_REPLAY round=",round," client=",i," match=",previousMatch," ticks=",ticks," orders=",tape.orders.len," hash=",world.fingerprint()
    oldPreparations = clients.mapIt(it.view.front.prepared)
    for i in 0..<(if round == 1: 1 else: ClientCount):
      button(i,KeyEscape,true); button(i,KeyEscape,false)
      check("finished player returns to same lobby view", clients[i].view.screen == FrontScreen and clients[i].view.front.page == LobbyMenu)
    if round == 1:
      check("guest still viewing completed battle", guest.screen == EndScreen)
      lobbyClick(0,vec2(1350,922)) # Actual host Return to lobby, not Leave/Recreate.
      awaitState("same room reopened", clients.allIt(it.view.front.connection.client.snapshot.phase == Lobby))
      check("host reopening brings every player back to room", clients.allIt(it.view.screen == FrontScreen and it.view.front.page == LobbyMenu))
      for client in clients:
        let snapshot = client.view.front.connection.client.snapshot
        check("room identity owner participants seats settings preserved", snapshot.room == originalRoom.room and snapshot.participant == originalRoom.participant and snapshot.participants.mapIt(it.id) == originalRoom.participants.mapIt(it.id) and snapshot.seats == originalRoom.seats and snapshot.payload == originalRoom.payload and snapshot.name == originalRoom.name and snapshot.tickRate == originalRoom.tickRate and snapshot.flag == originalRoom.flag)
        check("new revision", snapshot.revision > originalRoom.revision)
  echo "RESULT PASS same-room rematch clients=2 rounds=2 checks=",checks," native production frontend, not browser"

try: main()
except Exception as e:
  echo "ERROR ",e.msg,"\n",e.getStackTrace()
  quit(1)
"""
  source = source.replace("include ../src/galcon/graphics", "include \"" & currentSourcePath().parentDir.parentDir / "src/galcon/graphics.nim" & "\"")
  result = parseStmt(source)
rematchLifecycle()
