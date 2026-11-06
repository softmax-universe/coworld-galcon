import std/[importutils, times, os]
import windy/internal
import opengl, windy, silky, pixie, vmath, jsony
import galcon/[frontends, themes, multiplayer, common]
privateAccess(Frontend)
privateAccess(Window)

proc handleButtonPress(window: Window, button: Button) =
  ## Uses the same native event route as the real Windy window.
  handleButtonPressTemplate()
proc handleButtonRelease(window: Window, button: Button) =
  ## Completes a real handleButtonRelease rather than calling the action directly.
  handleButtonReleaseTemplate()

let window = newWindow("Galcon lobby regression", ivec2(1514, 970), visible = false)
window.makeContextCurrent()
loadExtensions()
let builder = newAtlasBuilder(4096, 8)
builder.addMenuAssets()
let background = newImage(8, 8)
background.fill(rgbx(0, 0, 0, 255))
doAssert builder.addImage("Background", background)
let sk = newSilky(window, builder.atlasImage, builder.atlas)
sk.theme = galconTheme()
var framebuffer, colorTexture: GLuint
glGenFramebuffers(1, framebuffer.addr)
glGenTextures(1, colorTexture.addr)
glBindTexture(GL_TEXTURE_2D, colorTexture)
glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8.GLint, window.size.x, window.size.y,
  0, GL_RGBA, GL_UNSIGNED_BYTE, nil)
glBindFramebuffer(GL_FRAMEBUFFER, framebuffer)
glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
  GL_TEXTURE_2D, colorTexture, 0)
doAssert glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE
let front = Frontend(config: MatchConfig(players: 4),
  rosterScroll: FrameState(), roomsScroll: FrameState(),
  connection: Connection(client: RoomClient(participant: 1, connected: true, welcomed: true)), page: HomeMenu)
front.connection.client.snapshot = RoomMessage(kind: RoomState, room: "test",
  name: "Native input test", participant: 1, revision: 1, phase: Lobby,
  tickRate: TickRate.uint32, payload: front.config.toJson(),
  participants: @[Participant(id: 1, connected: true), Participant(id: 2, connected: true)],
  seats: @[Seat(owner: 1, name: "Human"), Seat(owner: 1, name: "Truce Bot"),
    Seat(owner: 2, name: "Human"), Seat(owner: 2, name: "Truce Bot")])
front.preferences.name = "Native host"
front.syncLobby()
proc expectReadyPip(ready: bool, label: string, disabled = false) =
  ## Reads the actual Ready button, not the roster or a presentation helper.
  window.state.perFrame = PerFrame()
  window.state.mousePos = ivec2(750, 880)
  let sent = front.connection.client.outgoing.len
  front.draw(sk, window)
  doAssert front.connection.client.outgoing.len == sent,
    "Drawing readiness must never submit Ready or alter retained intent"
  let image = newImage(1514, 970)
  glReadPixels(0, 0, 1514, 970, GL_RGBA, GL_UNSIGNED_BYTE, image.data[0].addr)
  image.flipVertical()
  let wanted = if disabled: sk.theme.disabledTextColor
    elif ready: rgbx(110, 230, 125, 255) else: rgbx(244, 108, 104, 255)
  var matching = 0
  for y in 909 ..< 935:
    for x in 494 ..< 520:
      if image[x, y] == wanted: inc matching
  image.writeFile(Root / "build" / ("ready-pip-" & label & ".png"))
  echo "Ready pip ", label, " scale=", sk.uiScale, " matches=", matching
  doAssert matching > 20, label & ": Ready button must draw the authoritative red/green status pip"

front.connection.client.snapshot.participants[1].ready = true
expectReadyPip(false, "unready")
# Local preparation or a sent request is not authoritative readiness.
front.prepared = NetworkMatch()
expectReadyPip(false, "prepared-not-ready")
front.prepared = nil
front.connection.client.snapshot.participants[0].ready = true
expectReadyPip(true, "ready")
# Retained readiness survives a roster revision while preparation is refreshed.
inc front.connection.client.snapshot.revision
front.syncLobby()
expectReadyPip(true, "retained")
# A settings invalidation clears authoritative readiness even if preparation exists.
front.connection.client.snapshot.participants[0].ready = false
inc front.connection.client.snapshot.revision
front.syncLobby()
expectReadyPip(false, "config-reset")
front.pendingConfig = "pending"
expectReadyPip(false, "disabled-sync", disabled = true)
front.pendingConfig = ""
front.connection.client.outgoing.setLen(0)
window.state.mousePos = ivec2(120, 360)
window.handleButtonPress(MouseRight)
front.draw(sk, window)
doAssert front.contextSeat == 2, "Actual right-click must open the target player's menu"
window.state.perFrame = PerFrame()
window.handleButtonRelease(MouseRight)
front.draw(sk, window)
window.state.perFrame = PerFrame()
# The popup is anchored at (136, 344); its action is at (148, 388).
window.state.mousePos = ivec2(220, 412)
window.handleButtonPress(MouseLeft)
front.draw(sk, window)
window.state.perFrame = PerFrame()
window.handleButtonRelease(MouseLeft)
front.draw(sk, window)
doAssert front.contextSeat == -1, front.error
doAssert front.connection.client.outgoing.len == 1
let kick = decode(front.connection.client.outgoing[0])
doAssert kick.kind == KickParticipant and kick.participant == 2
proc click(point: IVec2) =
  ## Clicks a real rendered lobby control across press and release frames.
  window.state.perFrame = PerFrame()
  window.state.mousePos = point
  window.handleButtonPress(MouseLeft)
  front.draw(sk, window)
  window.state.perFrame = PerFrame()
  window.handleButtonRelease(MouseLeft)
  front.draw(sk, window)
click(ivec2(140, 690))
doAssert front.synchronizing()
doAssert decode(front.connection.client.outgoing[^1]).kind == ResizeRoom
let sent = front.connection.client.outgoing.len
click(ivec2(180, 740))
doAssert front.connection.client.outgoing.len == sent,
  "Pending roster must block assignments until authoritative confirmation"
front.connection.client.outgoing.setLen(0)
front.connection.client.snapshot.participant = 1
front.pendingConfig = ""
front.config.players = 4
front.playerContext(3)
front.contextAt = vec2(136, 344)
front.connection.client.snapshot.seats[3].owner = 9
click(ivec2(220, 412))
doAssert front.connection.client.outgoing.len == 0, "Rendered stale context must not remove replacement bot"
front.contextSeat = -1
front.connection.client.snapshot.seats[3].owner = 2
front.playerContext(3)
front.contextAt = vec2(136, 344)
window.state.perFrame = PerFrame()
window.state.mousePos = ivec2(220, 412)
window.handleButtonRelease(MouseLeft)
front.draw(sk, window)
doAssert front.connection.client.outgoing.len == 0, "Release without fresh popup press must not act"
click(ivec2(140, 690))
doAssert front.contextSeat == -1 and front.connection.client.outgoing.len == 0,
  "Outside click dismisses and blocks background through release"
front.connection.client.snapshot.participant = 2
front.connection.client.snapshot.seats[3] = Seat()
front.connection.client.snapshot.seats[2] = Seat()
front.pendingConfig = ""
front.config.players = 4
click(ivec2(180, 740))
doAssert front.connection.client.outgoing.len == 0, "Guest fill controls must be absent"
front.connection.client.snapshot.participant = 1
front.pendingConfig = ""
front.preferences.name = "saved 🙂"
front.page = SingleMenu
front.online = false
front.editingPlayer = false
click(ivec2(1370, 36))
doAssert front.editingPlayer, "Top-right identity button must open real modal"
let saved = getConfig(AppName, "settings.json")
front.playerDraft = "mason :) 空 白"
click(ivec2(900, 580))
doAssert not front.editingPlayer, front.error
doAssert readPreferences(AppName).name == "mason :) 空 白"
setConfig(AppName, "settings.json", saved)
front.preferences.name = ""
front.page = SingleMenu
let beforeModal = front.config.players
click(ivec2(140, 690))
doAssert front.config.players == beforeModal and front.needsPlayerName(),
  "First-run name prompt must block background roster controls"
window.close()
echo "Native real Windy right-click -> rendered context menu -> left-click kick passed"
