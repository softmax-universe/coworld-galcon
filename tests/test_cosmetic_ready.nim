import std/[importutils, os]
when defined(cosmeticReadySocket):
  import std/strutils
  import windy
import jsony
import polyworld/[relays, networks]
import galcon/[frontends, multiplayer, worlds, sessions, replays, options]
privateAccess(Frontend)

let relay = Relay()
var fronts: seq[Frontend]
var now = 1.0
proc exchange() =
  when defined(cosmeticReadySocket):
    for iteration in 0 ..< 40:
      pollEvents()
      for front in fronts:
        front.connection.pump()
        front.syncLobby()
      sleep(2)
  else:
    for iteration in 0 ..< 40:
      var traffic = false
      for i, front in fronts:
        let outgoing = move(front.connection.client.outgoing)
        for bytes in outgoing:
          relay.process(i + 1, bytes, now)
          traffic = true
      let outgoing = move(relay.outgoing)
      for output in outgoing:
        if output.bytes.len > 0:
          fronts[output.connection - 1].connection.client.accept(output.bytes)
          traffic = true
      for front in fronts: front.syncLobby()
      if not traffic: return
    doAssert false, "Lobby did not settle"

for i in 0 ..< 2:
  let front = Frontend(config: MatchConfig(players: 2, maximumTicks: 192),
    connection: Connection(stats: NetworkStats(),
      client: RoomClient(identity: identity(), name: "Human " & $i)))
  fronts.add front
  when defined(cosmeticReadySocket):
    doAssert getEnv("GALCON_MP_SERVER").startsWith("ws://127.0.0.1:")
    front.connection = connect(getEnv("GALCON_MP_SERVER"), "Human " & $i, identity())
  else:
    front.connection.client.opened()
exchange()
let host = fronts[0]
let guest = fronts[1]
host.createRoom()
exchange()
host.resizeRoster(2)
exchange()
template room: untyped = host.connection.client.snapshot
host.connection.client.claimHuman(0)
guest.connection.client.send(RoomMessage(kind: JoinRoom, room: room.room))
exchange()
guest.connection.client.claimHuman(1)
exchange()
let prepared = host.prepared
let revision = room.revision
for flag in [true, false, true, false]:
  host.connection.client.send(RoomMessage(kind: ReadyStatus, flag: flag))
  exchange()
  doAssert host.connection.client.snapshot.participants[0].ready == flag
  doAssert room.revision == revision and host.prepared == prepared,
    "Cosmetic toggles must not rebuild preparation or change revision"
guest.connection.client.send(RoomMessage(kind: StartMatch))
exchange()
doAssert room.phase == Lobby and guest.error.len > 0
# Missing locally owned bot sources are visible and cannot start.
host.resizeRoster(3)
exchange()
guest.connection.client.send(RoomMessage(kind: ClaimSeat, seat: 2, name: "Missing bot"))
exchange()
doAssert guest.prepared == nil and guest.error.len > 0
host.connection.client.send(RoomMessage(kind: StartMatch))
exchange()
doAssert room.phase == Lobby
# Removing it invalidates the pending start; settings also require fresh hashes.
guest.connection.client.send(RoomMessage(kind: ReleaseSeat, seat: 2))
exchange()
doAssert room.phase == Lobby
host.config.seed += 1
host.connection.client.send(RoomMessage(kind: ConfigureRoom, name: room.name,
  number: 3, tickRate: room.tickRate, flag: false, payload: host.config.toJson()))
exchange()
doAssert host.prepared.revision == room.revision
# Fresh deterministic state agrees after non-roster settings changes.
doAssert host.prepared.stateHash() == guest.prepared.stateHash()
# Force a new revision immediately before Start to race automatic preparation.
host.resizeRoster(4)
# Start races the guest's first automatic preparation on purpose.
host.connection.client.send(RoomMessage(kind: StartMatch))
exchange()
doAssert room.phase == Playing, "Host Start must prepare and launch without social Ready"
for front in fronts:
  doAssert front.prepared != nil and front.prepared.started
  for participant in front.connection.client.snapshot.participants:
    doAssert not participant.ready, "Preparation must not change social readiness"
doAssert host.prepared.stateHash() == guest.prepared.stateHash()
echo "Cosmetic readiness: unready two-human host startup passed"

for front in fronts:
  let match = front.prepared
  var source = -1
  var target = -1
  for i, planet in match.session.liveWorld.planets:
    if planet.owner == match.session.human: source = i
    if planet.owner == 0: target = i
  doAssert source >= 0 and target >= 0

  doAssert match.queueOrder(match.session.human, source, target, 50, true) > 0
exchange()
for step in 0 ..< 300:
  when not defined(cosmeticReadySocket):
    now += 1.0 / 32
    relay.advance(now)
  exchange()
  for front in fronts:
    var packet: RoomMessage
    while not front.prepared.finished and front.connection.client.takeTick(packet):
      front.prepared.applyPacket(packet)
  if host.prepared.finished and guest.prepared.finished: break
exchange()
when not defined(cosmeticReadySocket):
  relay.advance(now + 1.0 / 32)
exchange()
for i, front in fronts:
  let match = front.prepared
  doAssert match.finished and match.session.liveWorld.tick == 192
  doAssert match.session.recording.orders.len == 2
  doAssert match.session.recording.hashes == host.prepared.session.recording.hashes
  let path = "build/cosmetic-ready-" & $i & ".replay"
  match.session.saveRecording(path)
  let playback = newSession(parseOptions(@["--replay", path]))
  playback.seek(192)
  doAssert playback.world.fingerprint() == match.session.liveWorld.fingerprint()
  removeFile(path)
  front.connection.client.send(RoomMessage(kind: LeaveRoom))
exchange()
for front in fronts:
  doAssert front.connection.client.snapshot.room.len == 0,
    "cleanup: " & front.error & " phase=" & $front.connection.client.snapshot.phase
echo "Both human commands, 192 peer/replay hashes, and acknowledged cleanup passed"
