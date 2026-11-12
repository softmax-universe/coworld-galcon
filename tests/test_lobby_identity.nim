import std/importutils
import windy
import jsony
import polyworld/[menus, networks]
import galcon/[frontends, options, multiplayer, common, sessions]
privateAccess(Frontend)

let original = getConfig(AppName, "settings.json")
block:
  defer: setConfig(AppName, "settings.json", original)
  for stored in ["", "{}", "{\"name\":\"\"}", "{\"name\":\"Player\"}",
      "{\"name\":\"  pLaYeR  \"}"]:
    setConfig(AppName, "settings.json", stored)
    for args in [@["--menu", "multiplayer"],
        @["--menu", "multiplayer", "--server", "ws://127.0.0.1:1/ws"],
        @["--join", "ABC123"]]:
      let fresh = newFrontend(parseOptions(args))
      doAssert fresh.needsPlayerName(), "Missing/legacy Player must require confirmation: " & stored
      fresh.pump()
      doAssert fresh.connection == nil, "No socket or Hello before identity confirmation"
      var blocked = false
      try: fresh.connect()
      except GalconError: blocked = true
      doAssert blocked and fresh.connection == nil, "Direct startup connect must also be gated"
  let fresh = newFrontend(parseOptions(@[]))
  fresh.savePlayerName("  treeform :) 空 白 \"q\": (host)  ")
  let restored = newFrontend(parseOptions(@[]))
  doAssert restored.preferences.name == "  treeform :) 空 白 \"q\": (host)  "
  doAssert not restored.needsPlayerName()
let front = newFrontend(parseOptions(@["--name", "mason :)"]))
doAssert front.roomName == "mason :)'s game"
doAssert front.localHuman == 0
for policy in front.policies: doAssert policy.bytes.len == 0
front.preferences.name = ""
doAssert front.needsPlayerName()
front.savePlayerName("空 白 🙂 \"quote\": (host)")
doAssert front.preferences.name == "空 白 🙂 \"quote\": (host)"
doAssert not front.needsPlayerName()
doAssert readPreferences(AppName).name == front.preferences.name
front.roomName = "custom: 🙂 game"
front.savePlayerName("mason :)")
doAssert front.roomName == "custom: 🙂 game"
front.policies[3] = LocalPolicy(name: "Truce Bot", bytes: TruceSource)
let session = front.localMatch()
doAssert session.world.setup.players == 1
doAssert session.brains[1] != nil
doAssert session.displayName(1) == "Truce Bot", "Display names must not include faction color words"
for literal in ["treeform", "mason :)", "  空 白 🙂 \"q\": (host)  ", "Red (literal)"]:
  session.names[1] = literal
  doAssert session.displayName(1) == literal, "Display names must be opaque"

front.connection = Connection(stats: NetworkStats(), client: RoomClient(
  participant: 1, welcomed: true, connected: true, identity: identity()))
front.connection.client.snapshot = RoomMessage(kind: RoomState, room: "names",
  name: "original", participant: 1, revision: 1, phase: Lobby,
  tickRate: TickRate, payload: MatchConfig(players: 4).toJson(), seats: newSeq[Seat](4))
front.syncLobby()
front.renameGame("mason :)'s game 空 白")
let rename = decode(front.connection.client.outgoing[^1])
doAssert rename.kind == ConfigureRoom and rename.name == "mason :)'s game 空 白"
doAssert rename.payload == front.connection.client.snapshot.payload
front.connection.client.snapshot.participant = 2
let count = front.connection.client.outgoing.len
var rejected = false
try: front.renameGame("forged")
except RoomsError: rejected = true
doAssert rejected and front.connection.client.outgoing.len == count
setConfig(AppName, "settings.json", "")
let firstRun = newFrontend(parseOptions(@[]))
doAssert firstRun.preferences.name == "" and firstRun.needsPlayerName(),
  "Missing settings must not invent a Player identity"
setConfig(AppName, "settings.json", original)
let returning = newFrontend(parseOptions(@[]))
doAssert returning.preferences.name == readPreferences(AppName).name
setConfig(AppName, "settings.json", original)
echo "Empty defaults, first-run identity, opaque persisted edit, custom game name, sparse local, owner rename passed"
