## Native production input and real binary Relay, no browser/live server.
include ../src/galcon/graphics
import std/[importutils, sequtils]
import windy/internal
import polyworld/relays
import nativeinputs
privateAccess(Window)
proc handleButtonPress(window: Window, button: Button) = handleButtonPressTemplate()
proc handleButtonRelease(window: Window, button: Button) = handleButtonReleaseTemplate()

let relay = Relay()
var now = 1.0
var views: seq[View]
for i in 0..1:
  let window = newWindow("Galcon results", ivec2(1514,970), visible=false)
  window.makeContextCurrent()
  loadExtensions()
  let builder = newAtlasBuilder(4096,8)
  builder.addMenuAssets()
  let front = newFrontend(parseOptions(@["--mute"]))
  front.preferences.name = "Result human " & $i
  front.preferences.bindings = GalconControls.defaults
  front.preferences.applyPreferences(window,false)
  front.config = MatchConfig(players:4, maximumTicks:48)
  front.connection = Connection(client: RoomClient(identity:identity(), name:front.preferences.name))
  views.add View(front:front, window:window, sk:newSilky(window,builder.atlasImage,builder.atlas), screen:FrontScreen)
  views[^1].sk.theme = galconTheme()
  front.connection.client.opened()

proc exchange() =
  for iteration in 0..<40:
    var traffic = false
    for i,v in views:
      let outgoing = move(v.front.connection.client.outgoing)
      for bytes in outgoing:
        relay.process(i+1,bytes,now)
        traffic = true
    let outgoing = move(relay.outgoing)
    for output in outgoing:
      if output.bytes.len > 0:
        views[output.connection-1].front.connection.client.accept(output.bytes)
        traffic = true
    for v in views:
      doAssert v.front.connection.client.error.len == 0,v.front.connection.client.error
      v.front.syncLobby()
    if not traffic:return
  doAssert false,"traffic failed to settle"
proc press(v:View,button:Button) =
  ## Sends one keyboard shortcut through the production input handler.
  v.window.state.perFrame = PerFrame()
  v.window.handleButtonPress(button)
  v.handleInput()
  v.window.handleButtonRelease(button)
  v.window.state.perFrame = PerFrame()

proc resultFrame(view: View): bool =
  ## Runs the shared result widget and applies its release after drawing.
  view.window.makeContextCurrent()
  view.window.syncTestInput()
  view.sk.beginUi(view.window, view.window.size)
  result = view.drawResultButton()
  view.sk.endUi()
  if result:
    view.returnToMenu()

proc clickResult(view: View, enabled = true) =
  ## Exercises real screen-space hover, press, and release without early action.
  let button = view.resultButton()
  let center = (button.xy + button.wh / 2) * view.sk.uiScale
  view.window.state.perFrame = PerFrame()
  view.window.state.mousePrevPos = view.window.state.mousePos
  view.window.state.mousePos = ivec2(-100, -100)
  discard view.resultFrame()
  view.window.state.mousePrevPos = view.window.state.mousePos
  view.window.state.mousePos = center.ivec2
  discard view.resultFrame()
  view.window.state.mousePrevPos = view.window.state.mousePos
  discard view.resultFrame()
  view.window.state.doubleClickTime = 0
  view.window.handleButtonPress(MouseLeft)
  view.handleInput()
  doAssert not view.resultFrame(), "Result buttons must not activate on press"
  view.window.state.perFrame = PerFrame()
  view.window.handleButtonRelease(MouseLeft)
  view.handleInput()
  doAssert view.resultFrame() == enabled,
    "Only an enabled result button may activate on release"
  view.window.state.perFrame = PerFrame()
  doAssert not view.resultFrame(), "Idle result frames must not repeat activation"

exchange()
let host=views[0]
let guest=views[1]
host.front.createRoom()
exchange()
let originalRoom=host.front.connection.client.snapshot.room
guest.front.connection.client.send(RoomMessage(kind:JoinRoom,room:originalRoom))
exchange()
guest.front.connection.client.claimHuman(3)
exchange()
host.front.connection.client.claimHuman(1)
exchange()
for round in 1..2:
  for v in views:
    doAssert v.front.prepared != nil and not v.front.prepared.started
    doAssert v.front.prepared.session.liveWorld.tick == 0
  host.front.connection.client.send(RoomMessage(kind: StartMatch,
    revision: host.front.connection.client.snapshot.revision,
    hash: host.front.connection.client.snapshot.setupHash()))
  exchange()
  for v in views:
    v.session=v.front.prepared.session
    v.front.launch=nil
    v.screen=GameScreen
    v.transport=Transport(player:initPlayer(true,v.session.maximumTicks))
    v.layout()
    let w=v.session.liveWorld
    let source=w.planets.findIt(it.owner==v.session.human)
    let target=w.planets.findIt(it.owner==0)
    doAssert v.front.prepared.queueOrder(v.session.human,source,target,50,true)>0
  exchange()
  # Guest deliberately applies one packet per four host ticks. Ended must not
  # stop its final-history drain or strand it on a nonterminal displayed frame.
  for step in 0..<256:
    now+=1.0/TickRate
    relay.advance(now)
    exchange()
    for i,v in views:
      if i==1 and step mod 4 != 0:continue
      var packet:RoomMessage
      let limit=if i==0:8 else:1
      for n in 0..<limit:
        if v.front.prepared.finished or not v.front.connection.client.takeTick(packet):break
        v.front.prepared.applyPacket(packet)
      # Keep the slow guest's displayed historical frame paused throughout.
      if i==1 and v.session.world == v.session.liveWorld:
        v.session.world = v.session.liveWorld.clone()
        v.transport.player.playing = false
      v.syncResults(now)
    exchange()
    if views.allIt(it.front.prepared.finished):break
  doAssert views.allIt(it.front.prepared.finished and it.session.world.tick==48)
  doAssert host.session.recording.hashes==guest.session.recording.hashes
  for v in views:
    doAssert v.session.recording.actions.anyIt(
      it.kind == ActionLaunch and it.player == 1)
    doAssert v.session.recording.actions.anyIt(
      it.kind == ActionLaunch and it.player == 2)
    v.card.update(true,now+86400)
    doAssert v.card.shown,"Results must persist forever"
    press(v,KeyTab)
    doAssert v.card.shown,"Tab cannot hide results"
  press(guest,KeyEscape)
  doAssert guest.screen==EndScreen,"Guest must remain on results, not a fake lobby"
  doAssert guest.front.connection.client.outgoing.allIt(decode(it).kind != ReturnLobby),"Only owner can reopen"
  doAssert guest.returnPending,"Guest gets explicit waiting-for-host state"
  clickResult(guest, enabled = false)
  doAssert guest.front.connection.client.outgoing.allIt(
    decode(it).kind != ReturnLobby), "Waiting guests cannot reopen the lobby"
  if round==1:
    press(host,KeyEscape)
  else:
    clickResult(host)
  doAssert host.screen==EndScreen,"Await authoritative Lobby, never show intermediate fake lobby"
  doAssert host.front.connection.client.outgoing.countIt(
    decode(it).kind == ReturnLobby) == 1,
    "Returning must submit exactly one lobby request"
  exchange()
  for v in views:
    v.syncMatchScreen()
    doAssert v.screen==FrontScreen and v.front.page==LobbyMenu
    doAssert v.front.connection.client.snapshot.room==originalRoom
    doAssert v.front.prepared != nil and not v.front.prepared.started
  echo "RESULT round=",round," clients=2 ticks=48 delayed-peer hashes agree same room"

echo "Persistent result input and same-room two-client rematch passed (native, not browser)"

# A socket interruption retains the live game; an authoritative kick removes it.
host.front.connection.client.send(RoomMessage(kind: StartMatch,
  revision: host.front.connection.client.snapshot.revision,
  hash: host.front.connection.client.snapshot.setupHash()))
exchange()
for view in views:
  view.session = view.front.prepared.session
  view.front.launch = nil
  view.screen = GameScreen
let retained = guest.session
relay.disconnect(2)
guest.front.connection.client.lost()
guest.syncMatchScreen()
doAssert guest.session == retained and guest.screen == GameScreen,
  "Transport loss must retain the session for reconnect"
guest.front.connection.client.opened()
exchange()
host.front.connection.client.send(RoomMessage(kind: KickParticipant,
  participant: guest.front.connection.client.participant))
exchange()
guest.chatting = true
guest.chatInput = "unfinished message"
guest.syncMatchScreen()
doAssert guest.session == nil and guest.front.prepared == nil
doAssert guest.front.launch == nil
doAssert guest.screen == FrontScreen and guest.front.page == MultiplayerMenu
doAssert not guest.chatting and guest.chatInput.len == 0
echo "Live kick clears the match view while connection loss preserves it"

let local = View(
  front: newFrontend(parseOptions(@["--mute"])),
  window: host.window,
  sk: host.sk,
  session: newSession(parseOptions(@["--players", "2", "--ticks", "1"]),
    @["", ""], @["Local", "Opponent"], 1, true),
  screen: EndScreen
)
local.session.step()
local.card.update(true, 1)
local.layout()
local.sk.resetInteractions()
clickResult(local)
doAssert local.screen == MenuScreen,
  "The shared local results button must return to the main menu"
echo "Local and network results use the same release-driven button"
for view in views:
  view.window.close()
