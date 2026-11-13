## Production Windy input and GL render path; no browser or OS event injection.
include ../src/galcon/graphics
import std/importutils
import windy/internal
privateAccess(Window)
proc handleButtonPress(window: Window, button: Button) = handleButtonPressTemplate()
proc handleButtonRelease(window: Window, button: Button) = handleButtonReleaseTemplate()
let window = newWindow("Galcon diagnostics", ivec2(1514, 970), visible = false)
window.makeContextCurrent()
loadExtensions()
var framebuffer, colorTexture: GLuint
glGenFramebuffers(1, framebuffer.addr)
glGenTextures(1, colorTexture.addr)
glBindTexture(GL_TEXTURE_2D, colorTexture)
glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8.GLint, 1514, 970, 0,
  GL_RGBA, GL_UNSIGNED_BYTE, nil)
glBindFramebuffer(GL_FRAMEBUFFER, framebuffer)
glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
  GL_TEXTURE_2D, colorTexture, 0)
doAssert glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE
let builder = newAtlasBuilder(2048, 8)
let tile = newImage(1, 1)
tile.fill(rgbx(255, 255, 255, 255))
for name in ["Background", "Particle", "Planet"]:
  doAssert builder.addImage(name, tile)
builder.addMenuAssets()
for name in ["maximized", "close", "resize", "scrubber.handle"]:
  doAssert name in builder.atlas.entries, "Shared debug widget asset: " & name
doAssert "Mono" in builder.atlas.fonts, "Shared debug FPS font"
for name in ["Numbers", "TinyNumbers", "Hover", "Hud", "Players", "Chat", "Score", "ScoreSmall", "ScoreTitle"]:
  builder.addRasterFont(Assets / "zeroes_3.ttf", name, 14)
let view = View(window: window, sk: newSilky(window, builder.atlasImage, builder.atlas),
  options: parseOptions(@["--mute"]),
  session: newSession(parseOptions(@["--player", "1", "--mute"])), screen: GameScreen)
view.front = newFrontend(parseOptions(@["--mute"]))
view.front.preferences.name = "Diagnostics regression"
view.front.preferences.bindings = GalconControls.defaults
view.front.preferences.applyPreferences(window, false)
view.transport = Transport(player: initPlayer(true, view.session.maximumTicks, true))
view.controls = Controls(player: 1, percent: 50, anchor: -1, hover: -1)
for i in 0 ..< view.session.world.planets.len: view.planetSprites[i] = "Planet"
view.boardRevision = view.session.world.revision
view.effects = Effects(seed: view.session.world.setup.seed)
view.summary = newSummary(view.session.maximumTicks)
view.summary.observe(view.session.world)
view.stat = 3
view.layout()
proc key(button: Button) =
  window.state.perFrame = PerFrame()
  window.handleButtonPress(button)
  view.handleInput()
  window.state.perFrame = PerFrame()
  window.handleButtonRelease(button)
  view.handleInput()
  window.state.perFrame = PerFrame()
debugMenuOpen = false
view.controls.holding = true
view.controls.ordering = true
key(KeyF1)
doAssert debugMenuOpen, "F1 opens the shared debug window"
doAssert not view.controls.holding and not view.controls.ordering
let before = view.session.world.tick
view.lastTime = getMonoTime() - initDuration(milliseconds = 100)
view.frame()
doAssert view.session.world.tick > before, "Diagnostics must not pause simulation"
doAssert DebugWindowTitle in subWindowStates, "Actual shared renderer created its window"
key(KeyEscape)
doAssert not debugMenuOpen and view.matchMenu == HiddenMatchMenu,
  "Escape closes diagnostics before opening the game menu"
key(KeyF1)
key(KeyF1)
doAssert not debugMenuOpen, "F1 toggles closed"
view.chatting = true
key(KeyF1)
doAssert not debugMenuOpen, "Chat captures debug shortcuts"
view.chatting = false
view.matchMenu = GameSettings
key(KeyF1)
doAssert not debugMenuOpen, "Settings capture precedes debug shortcuts"
view.matchMenu = HiddenMatchMenu
key(KeyF1)
let selected = view.controls.selected
let percent = view.controls.percent
key(KeySpace)
key(KeyTab)
key(MouseRight)
key(KeyEnter)
doAssert view.transport.player.playing and not view.card.shown and not view.chatting
doAssert view.controls.selected == selected and view.controls.percent == percent
key(KeyEscape)
# Full frame regression: closing F1 used to re-enable the HUD slider during
# the very same event frame, after handleInput had consumed the shortcut.
proc sliderPoint(fraction: float32) =
  let p = (view.presentation.boardOrigin + vec2(320 + 300 * fraction, 458) *
    view.presentation.boardScale) * view.sk.uiScale
  window.state.mousePos = ivec2(p.x.int32, p.y.int32)
proc eventFrame() =
  view.lastTime = getMonoTime()
  view.frame()
  window.state.perFrame = PerFrame()
view.controls.percent = 50
sliderPoint(0.8)
eventFrame() # Establish the real slider's previous-frame hover.
window.handleButtonPress(KeyF1)
view.handleInput()
window.state.perFrame = PerFrame()
doAssert debugMenuOpen
window.handleButtonRelease(KeyF1)
view.handleInput()
window.state.perFrame = PerFrame()
window.state.doubleClickTime = 0
window.handleButtonPress(MouseLeft)
window.handleButtonPress(KeyF1)
eventFrame()
doAssert not debugMenuOpen
var activeSliderVertices = 0
for vertex in view.sk.drawer.layers[NormalLayer]:
  if vertex.color == rgbx(100, 185, 240, 255): inc activeSliderVertices
doAssert activeSliderVertices == 0,
  "Closing F1 must not re-enable gameplay widgets later in the same frame"
doAssert view.controls.percent == 50,
  "Closing F1 consumes its whole frame, including the render-time percent slider"
window.handleButtonRelease(MouseLeft)
window.handleButtonRelease(KeyF1)
eventFrame()
# Actual two-socket fixture against the existing relay; no server mutation/restart.
let server = getEnv("GALCON_MP_SERVER", "ws://localhost:9911/ws")
let a = connect(server, "F1 diagnostics A", identity())
let b = connect(server, "F1 diagnostics B", identity())
try:
  let deadline = epochTime() + 8
  while epochTime() < deadline and
      (not a.client.welcomed or not b.client.welcomed or a.stats.count == 0):
    pollEvents()
    a.pump()
    b.pump()
    sleep(10)
  doAssert a.client.welcomed and b.client.welcomed, "Both real sockets welcomed"
  doAssert a.stats.sentPackets > 0 and a.stats.receivedPackets > 0
  doAssert b.stats.sentPackets > 0 and b.stats.receivedPackets > 0
  doAssert a.stats.current.sentPackets > 0 and a.stats.current.receivedPackets > 0
  view.session.networked = true
  view.front.connection = a
  doAssert view.debugStats() == a.stats, "Renderer receives original live stats reference"
  view.debugStats().lagMs = 25
  doAssert a.stats.lagMs == 25, "Simulator controls are not editing a clone"
  view.debugStats().lagMs = 0
  debugMenuOpen = true
  view.drawDiagnostics()
  debugMenuOpen = false
  echo "Real relay counters: A sent=", a.stats.sentPackets,
    " received=", a.stats.receivedPackets,
    "; B sent=", b.stats.sentPackets, " received=", b.stats.receivedPackets
finally:
  a.close()
  b.close()
echo "Galcon shared F1 input/render regression passed"
window.close()
