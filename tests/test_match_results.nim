## Native production input and real binary Relay, no browser/live server.
include ../src/galcon/graphics
import std/[importutils, sequtils]
import windy/internal
import polyworld/relays
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
  let builder = newAtlasBuilder(64,8)
  let front = newFrontend(parseOptions(@["--mute"]))
  front.preferences.name = "Result human " & $i
  front.preferences.bindings = GalconControls.defaults
  front.preferences.applyPreferences(window,false)
  front.config = MatchConfig(players:4, maximumTicks:48)
  front.connection = Connection(client: RoomClient(identity:identity(), name:front.preferences.name))
  views.add View(front:front, window:window, sk:newSilky(window,builder.atlasImage,builder.atlas), screen:FrontScreen)
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
  v.window.state.perFrame = PerFrame()
  v.window.handleButtonPress(button)
  v.handleInput()
  v.window.handleButtonRelease(button)
  v.window.state.perFrame = PerFrame()

exchange()
let host=views[0]
let guest=views[1]
host.front.createRoom()
exchange()
let originalRoom=host.front.connection.client.snapshot.room
guest.front.connection.client.send(RoomMessage(kind:JoinRoom,room:originalRoom))
exchange()
host.front.connection.client.claimHuman(1)
guest.front.connection.client.claimHuman(3)
exchange()
for round in 1..2:
  for v in views:
    doAssert v.front.prepared != nil and not v.front.prepared.started
    doAssert v.front.prepared.session.liveWorld.tick == 0
  host.front.connection.client.send(RoomMessage(kind:StartMatch))
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
    doAssert v.session.recording.orders.anyIt(it.player==1)
    doAssert v.session.recording.orders.anyIt(it.player==2)
    v.card.update(true,now+86400)
    doAssert v.card.shown,"Results must persist forever"
    press(v,KeyTab)
    doAssert v.card.shown,"Tab cannot hide results"
  press(guest,KeyEscape)
  doAssert guest.screen==EndScreen,"Guest must remain on results, not a fake lobby"
  doAssert guest.front.connection.client.outgoing.allIt(decode(it).kind != ReturnLobby),"Only owner can reopen"
  doAssert guest.returnPending,"Guest gets explicit waiting-for-host state"
  if round==1:
    press(host,KeyEscape)
  else:
    let button = host.resultButton()
    let p = (host.presentation.boardOrigin + (button.xy + button.wh / 2) * host.presentation.boardScale) * host.sk.uiScale
    host.window.state.mousePos=ivec2(p.x.int32,p.y.int32)
    press(host,MouseLeft)
  doAssert host.screen==EndScreen,"Await authoritative Lobby, never show intermediate fake lobby"
  doAssert host.front.connection.client.outgoing.anyIt(decode(it).kind==ReturnLobby),"Escape must reopen directly"
  exchange()
  for v in views:
    v.syncMatchScreen()
    doAssert v.screen==FrontScreen and v.front.page==LobbyMenu
    doAssert v.front.connection.client.snapshot.room==originalRoom
    doAssert v.front.prepared != nil and not v.front.prepared.started
  echo "RESULT round=",round," clients=2 ticks=48 delayed-peer hashes agree same room"

echo "Persistent result input and same-room two-client rematch passed (native, not browser)"
