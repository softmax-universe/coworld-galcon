## Real native frontend regression: two independent windows/clients, real relay.
## No lobby helper or world order is called by this test: all user actions go
## through Windy's event route and the production View.frame/handleInput.
include ../src/galcon/graphics
import std/[importutils, sequtils]
import windy/internal
import galcon/replays
privateAccess(Window)
privateAccess(Frontend)

proc handleButtonPress(window: Window, button: Button) = handleButtonPressTemplate()
proc handleButtonRelease(window: Window, button: Button) = handleButtonReleaseTemplate()
proc press(window: Window, button: Button) = window.handleButtonPress(button)
proc release(window: Window, button: Button) = window.handleButtonRelease(button)
proc runeEvent(window: Window, rune: Rune) = handleRuneTemplate()

const ClientCount {.intdefine.} = 2

type ClientView = object
  view: View
  framebuffer, texture: GLuint
  textboxes: Table[string, TextBoxState]

proc makeClient(title: string): ClientView =
  let window = newWindow(title, ivec2(1514, 970), visible = false, vsync = false)
  window.makeContextCurrent()
  loadExtensions()
  let builder = newAtlasBuilder(4096, 8)
  let paints = newPaints(MaxPlanets)
  doAssert builder.addImage("Background", paints.background)
  doAssert builder.addImage("Particle", paints.particle)
  builder.addRasterFont(Assets / "SAVEDBYZ.TTF", "Title", 80,
    @["g", "a", "l", "c", "o", "n", " ", "2", "0", "6"])
  for (name, size) in [("Menu",36), ("Hud",24), ("Small",20),
      ("Hover",16), ("ScoreTitle",24), ("Score",14), ("ScoreSmall",10),
      ("Players",14), ("Numbers",14), ("TinyNumbers",9)]:
    builder.addRasterFont(Assets / "zeroes_3.ttf", name, size.float32)
  builder.addRasterFont(Assets / "transport/Rubik-Regular.ttf", "Chat", 13)
  builder.addTransportAssets()
  builder.addMenuAssets()
  let opts = parseOptions(@["--mute"])
  let front = newFrontend(opts)
  front.preferences.name = "" # Fresh isolated identity, never a saved user's name.
  front.preferences.server = getEnv("GALCON_MP_SERVER")
  front.preferences.bindings = GalconControls.defaults
  result.view = View(front: front, window: window,
    sk: newSilky(window, builder.atlasImage, builder.atlas), paints: paints,
    options: opts, difficulty: Easy, screen: MenuScreen, selection: 1,
    lastTime: getMonoTime())
  result.view.installChatInput()
  result.view.sk.builder = builder
  result.view.sk.theme = galconTheme()
  glGenFramebuffers(1, result.framebuffer.addr)
  glGenTextures(1, result.texture.addr)
  glBindTexture(GL_TEXTURE_2D, result.texture)
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8.GLint, 1514, 970,
    0, GL_RGBA, GL_UNSIGNED_BYTE, nil)
  glBindFramebuffer(GL_FRAMEBUFFER, result.framebuffer)
  glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
    GL_TEXTURE_2D, result.texture, 0)
  doAssert glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE

proc main() =
  doAssert getEnv("GALCON_MP_SERVER").startsWith("ws://127.0.0.1:"),
    "Only isolated loopback QA servers are allowed"
  doAssert getEnv("GALCON_MP_ISOLATED_HOME") == getHomeDir().strip(leading=false, trailing=true, chars={'/'}),
    "Run through tests/mp_e2e_run.py to isolate preferences"
  let output = getEnv("GALCON_MP_OUTPUT")
  createDir(output)
  let names = if ClientCount == 3: @["MP host :) 空 白", "MP guest 'two': (🙂)", "MP third human"] else: @["MP host :) 空 白", "MP guest 'two': (🙂)"]
  var clients: seq[ClientView]
  for i in 0..<ClientCount: clients.add makeClient("Galcon MP QA " & $i)
  let host = clients[0].view
  let guest = clients[1].view
  var room = ""
  var checks = 0
  var pointers: array[ClientCount, IVec2]
  proc check(label: string, ok: bool) =
    doAssert ok, label
    inc checks
    echo "PASS ", checks, " ", label
  proc frames(strict = true) =
    for client in clients.mitems:
      client.view.window.makeContextCurrent()
      glBindFramebuffer(GL_FRAMEBUFFER, client.framebuffer)
      # Silky textboxes are process-global; isolate them like independent apps.
      swap(textBoxStates, client.textboxes)
      client.view.frame()
      swap(textBoxStates, client.textboxes)
      if strict: doAssert client.view.front.error.len == 0, client.view.front.error
      client.view.window.state.perFrame = PerFrame()
    pollEvents() # Pump real sockets after consuming injected per-frame events.
    for i in 0..<ClientCount: clients[i].view.window.state.mousePos = pointers[i]
    sleep(4)
  template awaitState(label: string, condition: untyped) =
    block:
      let deadline = networkTime() + 12
      while not (condition) and networkTime() < deadline: frames()
      if not (condition):
        for c in clients:
          let v = c.view
          echo "DIAG screen=",v.screen," page=",v.front.page," playing=",v.transport.player.playing," selectedPlayer=",v.controls.player," holding=",v.controls.holding," double=",v.controls.double
          if v.session != nil: echo "DIAG live=",v.session.liveWorld.tick," shown=",v.session.world.tick," canCommand=",v.session.canCommand," human=",v.session.human," stocks=",v.session.liveWorld.planets.mapIt(it.shipCount)
          if v.front.connection != nil: echo "DIAG connected=",v.front.connection.client.connected," applied=",v.front.connection.client.applied," server=",v.front.connection.client.serverTick," packets=",v.front.connection.client.packets.len," outgoing=",v.front.connection.client.outgoing.len
      doAssert condition, "TIMEOUT " & label
      echo "STATE ", label
  proc picture(i: int, label: string) =
    let client = clients[i]
    client.view.window.makeContextCurrent()
    glBindFramebuffer(GL_FRAMEBUFFER, client.framebuffer)
    let image = newImage(1514, 970)
    glReadPixels(0, 0, 1514, 970, GL_RGBA, GL_UNSIGNED_BYTE, image.data[0].addr)
    image.flipVertical()
    image.writeFile(output / ($i & "-" & label & ".png"))
  proc point(i: int, p: Vec2) =
    let old = clients[i].view.window.state.mousePos
    pointers[i] = ivec2(p.x.int32, p.y.int32)
    clients[i].view.window.state.mousePos = pointers[i]
    clients[i].view.window.state.perFrame.mouseDelta = pointers[i] - old
  proc button(i: int, key: Button, down: bool) =
    if down: clients[i].view.window.press(key)
    else: clients[i].view.window.release(key)
    frames()
  proc click(i: int, p: Vec2) =
    point(i, p)
    frames() # Hover must be rendered before press, just like a real pointer.
    button(i, MouseLeft, true)
    frames()
    button(i, MouseLeft, false)
    frames()
  proc text(i: int, value: string) =
    for rune in value.runes:
      clients[i].view.window.runeEvent(rune)
      frames()
  proc lobbyPoint(i: int, p: Vec2): Vec2 =
    let sk = clients[i].view.sk
    let origin = (clients[i].view.window.size.vec2 / sk.uiScale - vec2(1514,970))/2
    (origin + p) * sk.uiScale
  proc lobbyClick(i: int, p: Vec2) = click(i, lobbyPoint(i,p))
  proc ready(i: int): bool =
    let c = clients[i].view.front.connection.client
    for participant in c.snapshot.participants:
      if participant.id == c.participant: return participant.ready
  proc cleanup() =
    if getCurrentException() != nil:
      echo "FAILURE ", getCurrentExceptionMsg(), "\n", getCurrentException().getStackTrace()
    for i in 0..<ClientCount:
      try: picture(i,"final")
      except: discard
    # Abort only our private synthetic match so LeaveRoom is authorized.
    if host.front.connection != nil and room.len>0 and host.front.connection.client.snapshot.room == room and host.front.connection.client.snapshot.phase in {Playing,Waiting}:
      host.front.connection.client.send(RoomMessage(kind:AbortMatch,match:host.front.connection.client.match,detail:"Own isolated MP UI QA cleanup"))
      let abortDeadline=networkTime()+2
      while networkTime()<abortDeadline and host.front.connection.client.snapshot.phase in {Playing,Waiting}: frames(false)
    # Only leave the exact synthetic room. Never kick or administer participants.
    for client in clients:
      let c = client.view.front.connection
      if c != nil and room.len > 0 and c.client.snapshot.room == room:
        c.client.send(RoomMessage(kind: LeaveRoom))
    let deadline = networkTime()+3
    while networkTime() < deadline:
      var joined = false
      for client in clients:
        let c = client.view.front.connection
        if c != nil and c.client.snapshot.room == room and room.len > 0: joined = true
      if not joined: break
      frames(false)
    for client in clients:
      let c = client.view.front.connection
      if c != nil:
        echo "CLEANUP participant=", c.client.participant, " room=", c.client.snapshot.room
        doAssert c.client.snapshot.room.len == 0, "Synthetic client did not leave"
        # Windy macOS close currently hangs up on the wrong async dispatcher;
        # process exit closes these two sockets after acknowledged room leaves.
      client.view.window.close()
  defer: cleanup()
  frames()
  for i in 0..<ClientCount:
    let view = clients[i].view
    check("client " & $i & " first-run identity prompt", view.front.nameDialogOpen())
    # Menu uses board-scale UI; identity modal centers in the logical viewport.
    let logical = view.window.size.vec2 / view.sk.uiScale
    let at = (logical-vec2(620,260))*0.5'f
    click(i, (at+vec2(200,100))*view.sk.uiScale)
    text(i,names[i])
    click(i,(at+vec2(490,210))*view.sk.uiScale)
    check("client " & $i & " entered opaque name preserved", view.front.preferences.name == names[i] and not view.front.nameDialogOpen())
    # Original main menu's real multiplayer row.
    click(i, (view.offset+vec2(320,226))*view.sk.uiScale)
    awaitState("client " & $i & " menu opens and logs in", view.front.connection != nil and view.front.connection.client.welcomed)
    check("client " & $i & " relay Welcome identity", view.front.connection.client.name == names[i] and view.front.page == MultiplayerMenu)
    picture(i,"browser")
  # Private room created via rendered create controls; title remains name-derived.
  lobbyClick(0,vec2(1340,432))
  lobbyClick(0,vec2(1200,500))
  awaitState("create", host.front.connection.client.snapshot.room.len > 0)
  room = host.front.connection.client.snapshot.room
  let snapshot = host.front.connection.client.snapshot
  check("four fresh empty slots, private synthetic room", snapshot.seats.len == 4 and snapshot.seats.allIt(it.owner == 0) and not snapshot.flag)
  check("room name preserves entered identity", snapshot.name == names[0] & "'s game")
  echo "OWN_ROOM ",room
  # Guests enter invitations through actual textbox and Join button.
  for i in 1..<ClientCount:
    lobbyClick(i,vec2(1150,700))
    text(i,room)
    lobbyClick(i,vec2(1200,764))
    awaitState("guest joins same room", clients[i].view.front.connection.client.snapshot.room == room and host.front.connection.client.snapshot.participants.len == i+1)
  for i in 0..<ClientCount:
    let seat = if i == 0: 1 elif i == 1: 3 else: 0
    # Lobby page has top=142 (not browser top=224).
    lobbyClick(i,vec2(if seat mod 2 == 1: 620 else: 180, if seat div 2 == 0: 290 else: 364))
    lobbyClick(i,vec2(750,340)) # Seat picker -> Play as you.
    awaitState("claim noncontiguous seat " & $seat,
      host.front.connection.client.snapshot.seats[seat].owner == clients[i].view.front.connection.client.participant)
  check("sparse roster contains only the assigned humans, no bots", (ClientCount == 3 or host.front.connection.client.snapshot.seats[0].owner == 0) and host.front.connection.client.snapshot.seats[2].owner == 0 and host.front.connection.client.snapshot.seats[1].name == "Human" and host.front.connection.client.snapshot.seats[3].name == "Human")
  for i in 0..<ClientCount:
    lobbyClick(i,vec2(560,922))
    awaitState("explicit ready " & $i, ready(i))
    picture(i,"ready")
  check("prepared hashes agree", host.front.prepared.stateHash() == guest.front.prepared.stateHash())
  lobbyClick(0,vec2(1350,922))
  awaitState("host starts all real game views", clients.allIt(it.view.screen == GameScreen))
  check("sparse stable seats pack into active players", host.front.prepared.playerSeats == (if ClientCount == 3: @[0,1,3] else: @[1,3]) and guest.front.prepared.playerSeats == host.front.prepared.playerSeats and host.session.human == (if ClientCount == 3: 2 else: 1) and guest.session.human == (if ClientCount == 3: 3 else: 2))
  check("names preserved through match", host.session.names[host.session.human] == names[0] and host.session.names[guest.session.human] == names[1] and guest.session.names == host.session.names)
  awaitState("authoritative visible ticking", host.session.liveWorld.tick >= 8 and guest.session.world.tick >= 8)
  for i in 0..<ClientCount:
    let v = clients[i].view
    let w = v.session.liveWorld
    var source = -1
    var target = -1
    var farthest = -1.0'f
    for j,p in w.planets:
      if p.owner == v.session.human: source = j; break
    doAssert source >= 0
    let src = w.planets[source]
    for j,p in w.planets:
      if p.owner == 0:
        let distance = length(vec2((p.x-src.x).toFloat32,(p.y-src.y).toFloat32))
        if distance > farthest: target = j; farthest = distance
    doAssert target >= 0
    proc board(p: Planet): Vec2 =
      (v.presentation.boardOrigin + vec2(p.x.toFloat32+0.5'f,p.y.toFloat32+0.5'f)*v.presentation.boardScale)*v.sk.uiScale
    click(i,board(src))
    check("client " & $i & " real click selects owned planet",v.controls.selected[source])
    # A deliberate second press after the OS double-click interval is a drag,
    # not the separately supported select-all double-click gesture.
    let settle = networkTime()+0.7
    while networkTime()<settle: frames()
    point(i,board(src)); frames()
    button(i,MouseLeft,true)
    point(i,board(w.planets[target])); frames()
    check("client " & $i & " actual drag has selection and target",v.controls.holding and v.controls.hover == target)
    let beforeTick = w.tick
    let beforeHash = w.fingerprint()
    # Exercise handleInput before any pump: release may queue intent, never mutate.
    v.window.release(MouseLeft)
    v.handleInput()
    check("client " & $i & " order waits for relay authority", w.tick == beforeTick and w.fingerprint() == beforeHash)
    frames()
    awaitState("client " & $i & " relay records launch", v.session.recording.orders.anyIt(it.player == v.session.human.int32 and it.source == source.int32 and it.target == target.int32))
    var body = -1
    for j,b in w.bodies:
      if b.active and b.kind == ShipBody and w.ships[j].owner == v.session.human: body = j; break
    check("client " & $i & " ship visible on map",body >= 0 and v.session.world == w)
    let oldX = w.bodies[body].x
    let oldY = w.bodies[body].y
    let tick = w.tick
    picture(i,"launch")
    awaitState("fleet movement " & $i,w.tick >= tick+8)
    check("client " & $i & " authoritative fleet changes position",w.bodies[body].active and (w.bodies[body].x != oldX or w.bodies[body].y != oldY))
    picture(i,"moving")
    echo "FLEET client=",i," stableSeat=",v.front.prepared.playerSeats[v.session.human-1]," source=",source," target=",target," tick=",w.tick," body=",body," from=",oldX,",",oldY," to=",w.bodies[body].x,",",w.bodies[body].y
    # Real Silky slider and right-button callback, without advancing authority.
    point(i,board(w.planets[target]))
    let percentHash = w.fingerprint()
    let percentOrders = v.session.recording.orders.len
    let percentOutbox = v.front.connection.client.outgoing
    let percentTick = w.tick
    v.transport.player.playing = false
    v.transport.player.targetTick = w.tick + 100
    v.window.state.perFrame.scrollDelta = vec2(0, 0.2'f) # Windy macOS accessor *10.
    if v.window.onScroll != nil: v.window.onScroll()
    v.handleInput()
    check("client " & $i & " wheel cannot edit percentage", v.controls.percent == 50)
    v.window.state.perFrame = PerFrame()
    proc percentPointer(fraction: float32) =
      let p = (v.presentation.boardOrigin + vec2(320 + 300 * fraction, 458) *
        v.presentation.boardScale) * v.sk.uiScale
      v.window.state.mousePos = ivec2(p.x.int32, p.y.int32)
    proc percentFrame() =
      v.sk.beginUi(v.window, v.window.size)
      v.drawSendSlider()
      v.sk.endUi()
    percentPointer(0.36'f)
    percentFrame()
    v.window.press(MouseLeft)
    v.handleInput()
    percentFrame()
    v.window.state.perFrame = PerFrame()
    check("client " & $i & " slider click chooses precise 37 percent", v.controls.percent == 37)
    for (fraction, expected) in [(0.72'f, 72), (-3.0'f, 1), (3.0'f, 100)]:
      percentPointer(fraction)
      v.handleInput()
      percentFrame()
      check("client " & $i & " held slider local " & $expected,
        v.controls.percent == expected and not v.controls.holding and
        w.fingerprint() == percentHash and v.front.connection.client.outgoing == percentOutbox)
    v.window.release(MouseLeft)
    v.handleInput()
    percentFrame()
    v.window.state.perFrame = PerFrame()
    point(i,board(w.planets[target]))
    check("client " & $i & " percentage is local despite delayed/paused transport",
      w.tick == percentTick and w.fingerprint() == percentHash and
      v.session.recording.orders.len == percentOrders and
      v.front.connection.client.outgoing == percentOutbox)
    v.window.state.perFrame = PerFrame()
    v.window.press(Key3)
    v.handleInput()
    check("client " & $i & " number key is immediately local with stalled transport",
      v.controls.percent == 30 and w.fingerprint() == percentHash and
      v.front.connection.client.outgoing == percentOutbox)
    v.window.release(Key3)
    v.window.state.perFrame = PerFrame()
    v.window.press(Key7)
    v.handleInput()
    v.window.release(Key7)
    v.transport.player.playing = true
    v.transport.player.targetTick = -1
    v.window.state.perFrame = PerFrame()
    let ordersBefore = v.session.recording.orders.len
    let hashBeforeRight = w.fingerprint()
    let commandsBefore = v.front.connection.client.outgoing.len
    v.window.press(MouseRight)
    v.handleInput()
    check("client " & $i & " right down only previews, without queued command",
      w.fingerprint() == hashBeforeRight and v.session.recording.orders.len == ordersBefore and
      v.controls.selected[source] and v.controls.holding and
      v.front.connection.client.outgoing.len == commandsBefore)
    v.window.state.perFrame = PerFrame()
    frames()
    picture(i,"right-held")
    let heldTick = w.tick
    awaitState("held preview across authoritative ticks", w.tick >= heldTick + 4)
    check("client " & $i & " holding never dispatches a command",
      v.session.recording.orders.len == ordersBefore and v.controls.holding)
    point(i, vec2(-2000, -2000))
    frames()
    check("client " & $i & " fleet hold survives outside window without orders",
      v.controls.holding and v.controls.hover == -1 and
      v.session.recording.orders.len == ordersBefore)
    point(i, board(w.planets[target]))
    frames()
    check("client " & $i & " fleet reentry restores valid target",
      v.controls.holding and v.controls.hover == target)
    let releaseHash = w.fingerprint()
    proc queuedOrders(): int =
      for bytes in v.front.connection.client.outgoing:
        if decode(bytes).kind == SubmitCommand: inc result
    let queuedBeforeRelease = queuedOrders()
    v.window.release(MouseRight)
    v.handleInput()
    check("client " & $i & " release queues once without speculative mutation",
      w.fingerprint() == releaseHash and v.session.recording.orders.len == ordersBefore and
      not v.controls.holding and queuedOrders() == queuedBeforeRelease + 1)
    v.handleInput() # A consumed release cannot dispatch a duplicate intent.
    check("client " & $i & " duplicate release is idempotent",
      queuedOrders() == queuedBeforeRelease + 1)
    v.window.state.perFrame = PerFrame()
    let submitted = v.front.connection.client.outgoing
    v.window.press(Key2)
    v.handleInput()
    check("client " & $i & " later percentage edit cannot rewrite released intent",
      v.controls.percent == 20 and v.front.connection.client.outgoing == submitted and
      w.fingerprint() == releaseHash)
    v.window.release(Key2)
    v.window.state.perFrame = PerFrame()
    frames()
    awaitState("client " & $i & " relay records right-click launch", v.session.recording.orders.len > ordersBefore)
    let rightOrder = v.session.recording.orders[^1]
    check("client " & $i & " right-click records selected source and target", rightOrder.player == v.session.human.int32 and rightOrder.source == source.int32 and rightOrder.target == target.int32)
    let replayWorld = newWorld(v.session.recording.setup)
    var orderCursor, chatCursor: int
    while replayWorld.tick < rightOrder.tick:
      v.session.recording.replayTick(replayWorld, orderCursor, chatCursor)
    let expectedCount = roundedRatio(replayWorld.planets[source].ships * 70, FixedScale * 100).int32
    check("client " & $i & " authoritative accepted amount is exactly 70 percent", rightOrder.count == expectedCount and rightOrder.count > 0)
    echo "RIGHTCLICK client=",i," tick=",rightOrder.tick," percent=70 accepted=",rightOrder.count
    let afterRightTick = w.tick
    awaitState("right release settles", w.tick >= afterRightTick + 4)
    check("client " & $i & " exactly one right-release order accepted",
      v.session.recording.orders.len == ordersBefore + 1)
  awaitState("all peers recorded all human orders", clients.allIt(it.view.session.recording.orders.len >= ClientCount*2))
  for i in 0..<ClientCount:
    let v = clients[i].view
    button(i, KeyEnter, true)
    button(i, KeyEnter, false)
    check("client " & $i & " Enter opens chat", v.chatting)
    let message = "Hello from human " & $i & " :) 空 café"
    text(i, message)
    check("client " & $i & " real Unicode rune callback", v.chatInput == message)
    let percent = v.controls.percent
    let playing = v.transport.player.playing
    button(i, Key1, true); button(i, Key1, false)
    button(i, KeySpace, true); button(i, KeySpace, false)
    button(i, KeyTab, true); button(i, KeyTab, false)
    check("client " & $i & " chat suppresses gameplay keys", v.controls.percent == percent and v.transport.player.playing == playing and not v.card.shown)
    let before = v.session.liveWorld.fingerprint()
    v.window.press(KeyEnter)
    v.handleInput() # Queue before sockets pump: no speculative local echo.
    check("client " & $i & " chat waits for authoritative relay", v.session.liveWorld.fingerprint() == before and v.session.recording.chats.len == i)
    v.window.release(KeyEnter)
    v.window.state.perFrame = PerFrame() # This event was already consumed above.
    frames()
    awaitState("every peer sees human chat " & $i, clients.allIt(it.view.session.recording.chats.len == i+1))
    for client in clients:
      check("client receives exact shared chat " & $i, client.view.session.recording.chats[^1].chatText() == message and client.view.session.recording.chats[^1].player == v.session.human.int32)
    picture(i, "chat-received")
    button(i, KeyEnter, true); button(i, KeyEnter, false)
    text(i, "cancel this")
    button(i, KeyEscape, true); button(i, KeyEscape, false)
    check("client " & $i & " Escape cancels without menu or chat", not v.chatting and v.chatInput.len == 0 and v.screen == GameScreen and v.session.recording.chats.len == i+1)
  awaitState("128 server-ordered ticks", min(host.session.liveWorld.tick,guest.session.liveWorld.tick) >= 128)
  var ticks = high(int)
  for client in clients: ticks = min(ticks,client.view.session.recording.hashes.len)
  for tick in 0..<ticks:
    for client in clients:
      doAssert host.session.recording.hashes[tick] == client.view.session.recording.hashes[tick], "peer hash mismatch at " & $tick
  check("every common tick agrees", ticks >= 128)
  for i in 0..<ClientCount:
    let recording = clients[i].view.session.recording
    let path = output / ($i & ".replay")
    recording.save(path)
    let tape = loadRecording(path)
    check("client " & $i & " replay keeps each human chat exactly once", tape.chats.len == ClientCount and tape.chats == host.session.recording.chats)
    let world = newWorld(tape.setup)
    var cursor,chatCursor: int
    while world.tick < tape.hashes.len.int32: tape.replayTick(world,cursor,chatCursor)
    echo "REPLAY client=",i," names=",tape.names," expected=",@names," orders=",tape.orders," hashes=",tape.hashes.len," final=",world.fingerprint()," expectedHash=",tape.hashes[^1]
    check("client " & $i & " saved replay verifies every tick",world.fingerprint() == tape.hashes[^1] and tape.names == (if ClientCount == 3: @["",names[2],names[0],names[1]] else: @["", names[0], names[1]]) and tape.orders.anyIt(it.player == 1) and tape.orders.anyIt(it.player == 2))
  echo "RESULT PASS clients=",ClientCount," checks=",checks," peerTicks=",ticks," room=",room," native real input frontend, not browser"

try: main()
except Exception as e:
  echo "ERROR ",e.msg,"\n",e.getStackTrace()
  quit(1)
