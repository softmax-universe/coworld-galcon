import
  std/[importutils, sequtils, strutils],
  jsony, polyworld/relays,
  galcon/[common, frontends, multiplayer, options, replays, worlds]

privateAccess(Frontend)

const PrivatePolicy = "counter = counter + 1\n"

let relay = Relay()
var
  now = 1.0
  peers: seq[Frontend]
  sent: seq[MessageKind]

proc exchange(allowErrors = false) =
  ## Moves genuine protocol messages and advances the production lobby state.
  for iteration in 0 ..< 40:
    var traffic = false
    for i, front in peers:
      let outgoing = move(front.connection.client.outgoing)
      for bytes in outgoing:
        sent.add decode(bytes).kind
        relay.process(i + 1, bytes, now)
        traffic = true
    let outgoing = move(relay.outgoing)
    for message in outgoing:
      if message.bytes.len > 0:
        let front = peers[message.connection - 1]
        front.connection.client.accept(message.bytes)
        # A socket poll can deliver BeginMatch before its following MatchStatus.
        front.syncLobby()
        traffic = true
    for front in peers:
      doAssert front.connection.client.error.len == 0,
        front.connection.client.error
      front.syncLobby()
      if not allowErrors:
        doAssert front.error.len == 0, front.error
    if not traffic:
      return
  doAssert false, "Rematch traffic did not settle"

for name in ["Rematch host", "Rematch guest"]:
  let front = newFrontend(parseOptions(@["--mute"]))
  front.preferences.name = name
  front.config = MatchConfig(players: 4, planets: 31, seed: 77,
    maximumTicks: 8, difficulty: Hard, balancedMap: false,
    enemyShipsPassThrough: false, neutralsDontProduce: false)
  front.connection = Connection(client: RoomClient(
    identity: identity(), name: name
  ))
  peers.add front
  front.connection.client.opened()
exchange()
let
  host = peers[0]
  guest = peers[1]
  hostClient = host.connection.client
  guestClient = guest.connection.client
host.createRoom()
exchange()
guestClient.send(RoomMessage(kind: JoinRoom, room: hostClient.snapshot.room))
exchange()
guestClient.claimHuman(3)
exchange()
hostClient.claimHuman(1)
exchange()
host.networkPolicies[0] = LocalPolicy(
  name: "Private rematch bot", bytes: PrivatePolicy
)
hostClient.send(RoomMessage(kind: ClaimSeat, seat: 0, seatKind: BotSeat,
  name: "Private rematch bot"))
exchange()
hostClient.send(RoomMessage(kind: StartMatch,
  revision: hostClient.snapshot.revision, hash: hostClient.snapshot.setupHash()))
exchange()

echo "One-click network rematches retain sparse seats, policies and settings"
for round in 1 .. 3:
  doAssert host.prepared.started and guest.prepared.started
  doAssert host.prepared.playerSeats == @[0, 1, 3]
  doAssert guest.prepared.playerSeats == @[0, 1, 3]
  doAssert host.prepared.session.human == 2
  doAssert guest.prepared.session.human == 3
  doAssert host.prepared.session.brains[1] != nil
  doAssert guest.prepared.session.brains[1] == nil
  doAssert host.networkPolicies[0].bytes == PrivatePolicy
  doAssert guest.networkPolicies[0].bytes.len == 0
  for tick in 0 ..< 32:
    now += 1.0 / TickRate
    relay.advance(now)
    exchange()
    for front in peers:
      var packet: RoomMessage
      while not front.prepared.finished and front.connection.client.takeTick(packet):
        front.prepared.applyPacket(packet)
    exchange()
    if peers.allIt(it.prepared.finished):
      break
  doAssert peers.allIt(it.prepared.finished)
  relay.advance(now)
  exchange()
  doAssert hostClient.snapshot.phase == Ended
  doAssert host.prepared.session.recording.hashes ==
    guest.prepared.session.recording.hashes
  let tape = host.prepared.session.recording
  let replay = newWorld(tape.setup)
  var cursor = 0
  while replay.tick < tape.hashes.len.int32:
    tape.replayTick(replay, cursor)
  doAssert replay.fingerprint() == host.prepared.session.liveWorld.fingerprint()
  if round == 3:
    break
  let
    before = hostClient.snapshot
    beforeMatch = hostClient.match
    publicRoom = relay.rooms[0].public
    oldHost = host.prepared
    oldGuest = guest.prepared
    returns = sent.count(ReturnLobby)
    configs = sent.count(ConfigureRoom)
    starts = sent.count(StartMatch)
  doAssert host.canRematch() and not guest.canRematch()
  var rejected = false
  try:
    guest.requestRematch()
  except RoomsError:
    rejected = true
  doAssert rejected
  host.requestRematch()
  host.requestRematch()
  doAssert host.rematchPending() and host.synchronizing()
  doAssert hostClient.snapshot == before,
    "Requesting a rematch must wait for authoritative changes"
  exchange()
  doAssert not host.rematchPending()
  doAssert host.prepared != oldHost and guest.prepared != oldGuest
  doAssert host.prepared.session.liveWorld.tick == 0
  doAssert guest.prepared.session.liveWorld.tick == 0
  doAssert host.prepared.session.recording.hashes.len == 0
  doAssert host.prepared.stateHash() == guest.prepared.stateHash()
  let after = hostClient.snapshot
  doAssert after.room == before.room and after.participant == before.participant
  doAssert after.name == before.name and after.flag == before.flag
  doAssert after.tickRate == before.tickRate and after.seats == before.seats
  doAssert hostClient.match != beforeMatch
  doAssert relay.rooms[0].public == publicRoom
  doAssert after.participants.mapIt((it.id, it.name)) ==
    before.participants.mapIt((it.id, it.name))
  let config = parseConfig(after.payload)
  let oldConfig = parseConfig(before.payload)
  doAssert config.seed >= 0 and config.seed != oldConfig.seed
  config.seed = oldConfig.seed
  doAssert config.toJson() == oldConfig.toJson(), "Only the seed may change"
  doAssert sent.count(ReturnLobby) == returns + 1
  doAssert sent.count(ConfigureRoom) == configs + 1
  doAssert sent.count(StartMatch) == starts + 1

echo "Spectator hosts can restart ended and desynchronized matches"
hostClient.send(RoomMessage(kind: ReleaseSeat, seat: 0))
hostClient.send(RoomMessage(kind: ReleaseSeat, seat: 1))
exchange()
host.requestRematch()
exchange()
doAssert not host.rematchPending()
doAssert host.prepared.started and host.prepared.session.human == 0
doAssert guest.prepared.started and guest.prepared.session.human == 1
doAssert host.prepared.playerSeats == @[3]
doAssert host.prepared.stateHash() == guest.prepared.stateHash()
let spectatorMatch = hostClient.match
hostClient.send(RoomMessage(kind: AbortMatch, match: spectatorMatch,
  detail: "Rematch test desynchronization"))
exchange(allowErrors = true)
doAssert hostClient.snapshot.phase == Desynced and host.canRematch()
guest.error = ""
host.requestRematch()
exchange()
doAssert not host.rematchPending()
doAssert hostClient.match != spectatorMatch
doAssert host.prepared.started and host.prepared.session.human == 0
doAssert host.prepared.stateHash() == guest.prepared.stateHash()

proc endedFrontend(): Frontend =
  ## Builds a bounded ended room for interruption and stale-setup cases.
  result = newFrontend(parseOptions(@["--mute"]))
  result.config = MatchConfig(players: 2)
  result.online = true
  result.revision = 9
  result.autoSeatRoom = "rematch-errors"
  result.connection = Connection(client: RoomClient(
    identity: identity(), participant: 1, connected: true, welcomed: true,
    snapshot: RoomMessage(kind: RoomState, room: "rematch-errors", name: "Room",
      participant: 1, phase: Ended, match: 7, revision: 9, tickRate: TickRate,
      payload: result.config.toJson(), seats: @[
        Seat(owner: 1, name: "Host", kind: HumanSeat),
        Seat(owner: 2, name: "Guest", kind: HumanSeat)
      ], participants: @[
        Participant(id: 1, name: "Host", connected: true),
        Participant(id: 2, name: "Guest", connected: true)
      ])
  ))

echo "Interrupted and changed rooms never launch a different rematch"
for fault in 0 .. 4:
  let front = endedFrontend()
  let client = front.connection.client
  front.requestRematch()
  client.outgoing.setLen(0)
  case fault
  of 0:
    client.lost()
  of 1:
    client.snapshot.seats[1].name = "Replacement"
  of 2:
    client.snapshot.participant = 2
  of 3:
    client.snapshot.payload = MatchConfig(players: 2, seed: 999).toJson()
  else:
    client.error = "Rejected rematch command"
  front.syncLobby()
  doAssert not front.rematchPending()
  doAssert front.error.len > 0
  doAssert client.outgoing.allIt(decode(it).kind notin
    {ConfigureRoom, StartMatch})

let changed = endedFrontend()
changed.requestRematch()
changed.connection.client.outgoing.setLen(0)
changed.connection.client.snapshot.phase = Lobby
inc changed.connection.client.snapshot.revision
changed.syncLobby()
doAssert changed.rematchPending()
doAssert changed.connection.client.outgoing.countIt(
  decode(it).kind == ConfigureRoom) == 1
changed.connection.client.outgoing.setLen(0)
changed.connection.client.snapshot.seats[1].owner = 1
changed.syncLobby()
doAssert not changed.rematchPending()
doAssert changed.error.contains("players or battle settings changed")
doAssert changed.connection.client.outgoing.allIt(decode(it).kind != StartMatch)

let missingPolicy = endedFrontend()
let missingClient = missingPolicy.connection.client
missingClient.snapshot.seats[0] = Seat(owner: 1, kind: BotSeat,
  name: "Private missing policy")
missingPolicy.requestRematch()
missingClient.outgoing.setLen(0)
missingClient.snapshot.phase = Lobby
inc missingClient.snapshot.revision
missingPolicy.syncLobby()
doAssert missingPolicy.rematchPending()
missingClient.outgoing.setLen(0)
missingClient.snapshot.payload = missingPolicy.rematchPayload
inc missingClient.snapshot.revision
missingPolicy.syncLobby()
doAssert not missingPolicy.rematchPending()
doAssert missingPolicy.error.contains("local policy")
doAssert missingClient.outgoing.allIt(decode(it).kind != StartMatch)
echo "Network rematch protocol checks passed"
