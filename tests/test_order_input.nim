## Native Windy events exercise the production input path (not OS delivery).
include ../src/galcon/graphics
import std/[importutils, sequtils]
import windy/internal
privateAccess(Window)
proc handleButtonPress(window: Window, button: Button) = handleButtonPressTemplate()
proc handleButtonRelease(window: Window, button: Button) = handleButtonReleaseTemplate()

proc testBrowserWheel() =
  doAssert wheelSteps(-100, 0) == 1, "Browser pixel wheel up is one notch"
  doAssert wheelSteps(100, 0) == -1
  doAssert wheelSteps(-3, 1) == 1, "Browser line wheel up is one notch"
  doAssert wheelSteps(1, 2) == -1
  doAssert abs(wheelSteps(-20, 0) - 0.2) < 0.0001

testBrowserWheel()
let window = newWindow("Galcon order input", ivec2(1514, 970), visible = false)
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
for name in ["Numbers", "TinyNumbers", "Hover", "Hud", "Players", "Chat", "Score", "ScoreSmall", "ScoreTitle"]:
  builder.addRasterFont(Assets / "zeroes_3.ttf", name, 14)
let view = View(window: window, sk: newSilky(window, builder.atlasImage, builder.atlas),
  session: newSession(parseOptions(@["--player", "1", "--mute"])), screen: GameScreen)
view.front = newFrontend(parseOptions(@["--mute"]))
view.front.preferences.bindings = GalconControls.defaults
view.front.preferences.applyPreferences(window, false)
view.transport = Transport(player: initPlayer(true, view.session.maximumTicks, true))
view.controls = Controls(player: 1, percent: 50, anchor: -1, hover: -1)
view.layout()
let world = view.session.world
let source = world.planets.findIt(it.owner == 1)
let target = world.planets.findIt(it.owner == 2)
doAssert source >= 0 and target >= 0
proc point(x,y: int) =
  let p = (view.presentation.boardOrigin + vec2(x.float32+0.5'f,y.float32+0.5'f) *
    view.presentation.boardScale) * view.sk.uiScale
  window.state.mousePos = ivec2(p.x.int32,p.y.int32)
proc planet(i: int) = point(world.planets[i].x.toInt.int, world.planets[i].y.toInt.int)
proc key(button: Button) =
  window.state.perFrame = PerFrame()
  # A normal click, not an accidentally timed native double-click.
  if button == MouseLeft: window.state.doubleClickTime = 0
  window.handleButtonPress(button)
  view.handleInput()
  window.state.perFrame = PerFrame()
  window.handleButtonRelease(button)
  view.handleInput()
  window.state.perFrame = PerFrame()
# Box -> ordinary owned click replaces; Shift-click adds without toggling.
let extra = world.planets.findIt(it.owner == 0)
world.planets[extra].owner = 1
point(0, 0)
window.handleButtonPress(MouseLeft)
view.handleInput()
window.state.perFrame = PerFrame()
point(Width - 1, 439)
view.handleInput()
window.handleButtonRelease(MouseLeft)
view.handleInput()
window.state.perFrame = PerFrame()
doAssert view.controls.selected[source] and view.controls.selected[extra]
planet(source)
key(MouseLeft)
doAssert view.controls.selected[source] and not view.controls.selected[extra],
  "Ordinary click replaces a box selection"
window.handleButtonPress(KeyLeftShift)
planet(extra)
key(MouseLeft)
key(MouseLeft)
window.handleButtonRelease(KeyLeftShift)
doAssert view.controls.selected[source] and view.controls.selected[extra],
  "Shift-click adds and never toggles off"
# A selected source retains the group during drag; release on a different
# planet sends each source, whereas an ordinary release collapses to one.
planet(source)
window.state.doubleClickTime = 0
window.handleButtonPress(MouseLeft)
view.handleInput()
window.state.perFrame = PerFrame()
doAssert view.controls.selected[source] and view.controls.selected[extra]
planet(target)
let multiSource = world.planets[source].ships
let multiExtra = world.planets[extra].ships
view.handleInput()
window.handleButtonRelease(MouseLeft)
view.handleInput()
window.state.perFrame = PerFrame()
doAssert world.planets[source].ships < multiSource and
  world.planets[extra].ships < multiExtra, "Left drag preserves multi-source send"
doAssert view.controls.selected[source] and view.controls.selected[extra]
planet(source)
key(DoubleClick)
doAssert view.controls.selected[source] and view.controls.selected[extra],
  "Double-click release preserves select-all"
planet(source)
key(MouseLeft)
doAssert view.controls.selected[source] and not view.controls.selected[extra]
world.planets[extra].owner = 0
planet(target)
let before = world.planets[source].ships
let heldHash = world.fingerprint()
window.handleButtonPress(MouseRight)
view.handleInput()
window.state.perFrame = PerFrame()
doAssert world.fingerprint() == heldHash, "Right down previews without sending"
doAssert view.controls.holding and not view.controls.box
# Execute the real game drawing pass, measuring actual Silky triangle geometry.
for i in 0 ..< world.planets.len: view.planetSprites[i] = "Planet"
view.boardRevision = world.revision
view.effects = Effects(seed: world.setup.seed)
view.stat = 3
proc gameGeometry(): seq[Vec2] =
  view.sk.beginUi(window, window.size)
  view.drawGame()
  for vertex in view.sk.drawer.layers[NormalLayer]: result.add vertex.pos
  view.sk.endUi()
let preview = gameGeometry()
view.controls.holding = false
let idle = gameGeometry()
view.controls.holding = true
doAssert preview.len == idle.len + 6, "Held target line emits two real triangles"
planet(extra)
view.handleInput()
doAssert gameGeometry() != preview, "Held line follows the hovered target"
planet(target)
view.handleInput()
window.handleButtonRelease(MouseRight)
view.handleInput()
window.state.perFrame = PerFrame()
doAssert world.planets[source].ships < before, "Right-click target must send selected ships"
let releasedHash = world.fingerprint()
view.handleInput()
doAssert world.fingerprint() == releasedHash and not view.controls.holding,
  "Idle frames cannot duplicate a released order"
window.handleButtonRelease(MouseRight)
view.handleInput()
window.state.perFrame = PerFrame()
doAssert world.fingerprint() == releasedHash, "Duplicate release sends nothing"
doAssert view.controls.selected[source], "Right-click keeps selection for repeated orders"
let second = world.planets[source].ships
key(MouseRight)
doAssert world.planets[source].ships < second, "Repeated right-click must send again"
proc wheel(delta: float32) =
  window.state.perFrame = PerFrame()
  # Windy's macOS public accessor scales the accumulated native delta by ten.
  window.state.perFrame.scrollDelta = vec2(0, delta / 10)
  if window.onScroll != nil: window.onScroll()
  view.handleInput()
  window.state.perFrame = PerFrame()
wheel(1)
doAssert view.controls.percent == 60, "Wheel up raises send amount by ten"
wheel(-2)
doAssert view.controls.percent == 40, "Wheel down honors multiple notches"
wheel(0.4)
doAssert view.controls.percent == 40, "Fractional scroll must accumulate"
wheel(0.4)
doAssert view.controls.percent == 40
wheel(0.4)
doAssert view.controls.percent == 50
wheel(20)
doAssert view.controls.percent == 100
wheel(-1)
doAssert view.controls.percent == 90, "Clamping must not retain overscroll debt"
wheel(-20)
doAssert view.controls.percent == 10
wheel(1)
doAssert view.controls.percent == 20
proc blocked(label: string, beforeInput, afterInput: proc(), localPercent = false) =
  planet(target)
  beforeInput()
  let hash = world.fingerprint()
  let selected = view.controls.selected
  let percent = view.controls.percent
  key(MouseRight)
  wheel(1)
  doAssert world.fingerprint() == hash, label & " blocks sends"
  doAssert view.controls.selected == selected, label & " preserves selection"
  doAssert view.controls.percent == (if localPercent: min(percent + 10, 100) else: percent),
    label & " percentage input ownership"
  afterInput()
blocked("Chat", proc() = view.chatting = true, proc() = view.chatting = false)
blocked("Statistics", proc() = view.card.shown = true, proc() = view.card.shown = false)
blocked("Pause", proc() = view.transport.player.playing = false, proc() = view.transport.player.playing = true, true)
blocked("Seeking", proc() = view.transport.player.targetTick = 5, proc() = view.transport.player.targetTick = -1, true)
blocked("History", proc() = view.session.world = world.clone(), proc() = view.session.world = world)
blocked("Replay", proc() = view.session.playback = true, proc() = view.session.playback = false)
blocked("Spectator", proc() = view.session.human = 0, proc() = view.session.human = 1)
blocked("Finished", proc() = view.session.done = true, proc() = view.session.done = false)
blocked("Menu", proc() = view.screen = FrontScreen, proc() = view.screen = GameScreen)
blocked("Sidebar", proc() = point(-100, 200), proc() = discard)
blocked("HUD", proc() = point(320, 460), proc() = discard)
# Losing input ownership while held cancels permanently, even if it returns
# before the physical release. Selection remains available for the next order.
proc cancelHeld(label: string, interrupt, restore: proc()) =
  planet(target)
  window.handleButtonPress(MouseRight)
  view.handleInput()
  window.state.perFrame = PerFrame()
  doAssert view.controls.holding
  let hash = world.fingerprint()
  interrupt()
  view.handleInput()
  window.state.perFrame = PerFrame()
  doAssert not view.controls.holding, label & " cancels held preview"
  restore()
  planet(target)
  window.handleButtonRelease(MouseRight)
  view.handleInput()
  window.state.perFrame = PerFrame()
  doAssert world.fingerprint() == hash, label & " cannot send after restoration"
cancelHeld("Chat", proc() = view.chatting = true, proc() = view.chatting = false)
cancelHeld("Modal", proc() = view.card.shown = true, proc() = view.card.shown = false)
cancelHeld("Pause", proc() = view.transport.player.playing = false,
  proc() = view.transport.player.playing = true)
cancelHeld("History", proc() = view.session.world = world.clone(),
  proc() = view.session.world = world)
cancelHeld("Menu", proc() = view.screen = FrontScreen, proc() = view.screen = GameScreen)
cancelHeld("Offboard", proc() = point(-10, 200), proc() = discard)
cancelHeld("HUD", proc() = point(320, 460), proc() = discard)
# Partial trackpad gestures must not survive crossing a UI ownership boundary.
planet(target)
key(Key5)
wheel(0.6)
view.chatting = true
wheel(1)
view.chatting = false
wheel(0.6)
doAssert view.controls.percent == 50, "Blocked input resets fractional wheel gesture"
# Target ownership does not affect routing; captured selections are cleaned.
let friendly = world.planets.findIt(it.owner == 0)
let neutral = world.planets.findIt(it.owner == 0 and it != world.planets[friendly])
doAssert friendly >= 0 and neutral >= 0
world.planets[friendly].owner = 1
planet(source)
key(DoubleClick)
doAssert view.controls.selected[source] and view.controls.selected[friendly]
planet(target)
let sourceBefore = world.planets[source].ships
let friendlyBefore = world.planets[friendly].ships
key(MouseRight)
doAssert world.planets[source].ships < sourceBefore and world.planets[friendly].ships < friendlyBefore
planet(friendly)
let reinforcing = world.planets[source].ships
key(MouseRight)
doAssert world.planets[source].ships < reinforcing, "Friendly target accepts reinforcement"
planet(neutral)
let neutralBefore = world.planets[source].ships
key(MouseRight)
doAssert world.planets[source].ships < neutralBefore, "Neutral target accepts attack"
world.planets[friendly].owner = 2
planet(target)
let capturedBefore = world.planets[friendly].ships
key(MouseRight)
doAssert world.planets[friendly].ships == capturedBefore and not view.controls.selected[friendly]
# Empty battlefield still clears; a right-click cannot leave a stale left drag.
point(1,200)
key(MouseRight)
doAssert not view.controls.selected.anyIt(it) and not view.controls.holding
planet(source)
window.handleButtonPress(KeyLeftShift)
key(MouseLeft)
window.handleButtonRelease(KeyLeftShift)
doAssert view.controls.selected[source], "Shift selection remains supported"
# Small empty-origin rectangles replace normally and union with Shift.
world.planets[extra].owner = 1
proc boxExtra(additive: bool) =
  let p = world.planets[extra]
  let r = p.radius + 5
  let x = p.x.toInt.int
  let y = p.y.toInt.int
  doAssert world.planetAt(x-r, y-r) < 0
  if additive: window.handleButtonPress(KeyLeftShift)
  point(x-r, y-r)
  window.state.doubleClickTime = 0
  window.handleButtonPress(MouseLeft)
  view.handleInput()
  window.state.perFrame = PerFrame()
  point(x+r, y+r)
  view.handleInput()
  window.handleButtonRelease(MouseLeft)
  view.handleInput()
  window.state.perFrame = PerFrame()
  if additive: window.handleButtonRelease(KeyLeftShift)
boxExtra(true)
doAssert view.controls.selected[source] and view.controls.selected[extra],
  "Shift rectangle unions the previous selection"
boxExtra(false)
doAssert not view.controls.selected[source] and view.controls.selected[extra],
  "Ordinary rectangle replaces the previous selection"
planet(source)
window.state.doubleClickTime = 0
window.handleButtonPress(MouseLeft)
view.handleInput()
window.state.perFrame = PerFrame()
doAssert view.controls.selected[source] and not view.controls.selected[extra],
  "Press outside selected group starts a new drag selection"
window.handleButtonRelease(MouseLeft)
view.handleInput()
window.state.perFrame = PerFrame()
planet(target)
let enemyClickHash = world.fingerprint()
key(MouseLeft)
doAssert not view.controls.selected.anyIt(it) and world.fingerprint() == enemyClickHash,
  "Ordinary enemy click clears selection and never orders"
planet(source)
key(MouseLeft)
window.handleButtonPress(KeyLeftShift)
planet(extra)
key(MouseLeft)
window.handleButtonRelease(KeyLeftShift)
planet(target)
window.handleButtonPress(MouseRight)
view.handleInput()
window.state.perFrame = PerFrame()
let multiPreview = gameGeometry()
view.controls.holding = false
let multiIdle = gameGeometry()
view.controls.holding = true
doAssert multiPreview.len == multiIdle.len + 12,
  "Right-held preview draws one target line per selected source"
point(1, 200)
view.handleInput()
let emptyReleaseHash = world.fingerprint()
window.handleButtonRelease(MouseRight)
view.handleInput()
window.state.perFrame = PerFrame()
doAssert world.fingerprint() == emptyReleaseHash,
  "Right release on empty space cancels without sending"
# A box begun on the battlefield survives every board edge and the HUD.
for edge in [(-40, 200), (Width + 40, 200), (320, -40), (320, Height + 40)]:
  view.controls.clear()
  point(1, 1)
  window.state.doubleClickTime = 0
  window.handleButtonPress(MouseLeft)
  view.handleInput()
  window.state.perFrame = PerFrame()
  doAssert view.controls.holding and view.controls.box
  point(edge[0], edge[1])
  view.handleInput()
  doAssert view.controls.holding, "Box must survive leaving any map edge"
  doAssert view.controls.x in 0 .. Width and view.controls.y in 0 .. Height,
    "Selection geometry is bounded to the map"
  window.handleButtonRelease(MouseLeft)
  view.handleInput()
  window.state.perFrame = PerFrame()
  doAssert not view.controls.holding
  for i, p in world.planets:
    doAssert view.controls.selected[i] == (p.owner == 1 and
      p.x.toInt.int in min(1, clamp(edge[0], 0, Width)) .. max(1, clamp(edge[0], 0, Width)) and
      p.y.toInt.int in min(1, clamp(edge[1], 0, Height)) .. max(1, clamp(edge[1], 0, Height)))
# Shift union also survives an outside release; sidebar/HUD starts never arm.
view.controls.clear()
view.controls.selected[source] = true
window.handleButtonPress(KeyLeftShift)
point(1, 1)
window.state.doubleClickTime = 0
window.handleButtonPress(MouseLeft)
view.handleInput()
window.state.perFrame = PerFrame()
point(Width + 40, Height + 40)
view.handleInput()
let boundedBox = gameGeometry()
view.controls.holding = false
let withoutBox = gameGeometry()
view.controls.holding = true
doAssert boundedBox.len == withoutBox.len + 24,
  "Bounded selection draws exactly four production line segments"
var rectangleAt = 0
while rectangleAt < withoutBox.len and boundedBox[rectangleAt] == withoutBox[rectangleAt]:
  inc rectangleAt
for v in boundedBox[rectangleAt ..< rectangleAt + 24]:
  doAssert v.x in -0.51'f .. Width.float32 + 0.51'f and
    v.y in -0.51'f .. Height.float32 + 0.51'f,
    "Selection vertices stay inside board plus half-stroke; board clip trims stroke"
let boundedX = view.controls.x
let boundedY = view.controls.y
doAssert boundedX == Width and boundedY == Height
window.handleButtonRelease(MouseLeft)
view.handleInput()
window.state.perFrame = PerFrame()
window.handleButtonRelease(KeyLeftShift)
doAssert view.controls.selected[source] and view.controls.selected[extra]
for origin in [(-100, 200), (320, 460)]:
  let selected = view.controls.selected
  point(origin[0], origin[1])
  window.state.doubleClickTime = 0
  window.handleButtonPress(MouseLeft)
  view.handleInput()
  window.state.perFrame = PerFrame()
  point(320, 200)
  view.handleInput()
  window.handleButtonRelease(MouseLeft)
  view.handleInput()
  window.state.perFrame = PerFrame()
  doAssert view.controls.selected == selected and not view.controls.holding,
    "Sidebar/HUD origin cannot acquire a box by entering the map"
# Escape opens an overlay instead of finishing/leaving the running match.
planet(target)
window.handleButtonPress(MouseRight)
view.handleInput()
window.state.perFrame = PerFrame()
let menuHash = world.fingerprint()
key(KeyEscape)
doAssert view.screen == GameScreen and not view.session.done,
  "Live Escape must not leave the game"
doAssert view.transport.player.playing and not view.controls.holding,
  "Opening menu cancels gestures, not simulation"
key(KeyEnter)
key(KeySpace)
key(KeyTab)
wheel(1)
doAssert not view.chatting and not view.card.shown and view.transport.player.playing
window.handleButtonRelease(MouseRight)
view.handleInput()
window.state.perFrame = PerFrame()
doAssert world.fingerprint() == menuHash
key(KeyEscape)
doAssert view.screen == GameScreen and not view.session.done
doAssert view.matchMenu == HiddenMatchMenu and not view.controls.box and
  not view.controls.ordering and view.controls.anchor == -1
# Opening a menu also invalidates an active left box permanently.
point(1, 1)
window.state.doubleClickTime = 0
window.handleButtonPress(MouseLeft)
view.handleInput()
window.state.perFrame = PerFrame()
point(Width + 40, 200)
view.handleInput()
key(KeyEscape)
doAssert view.matchMenu == GameMenu and not view.controls.holding and not view.controls.box
let modalSelection = view.controls.selected
key(KeyEscape)
window.handleButtonRelease(MouseLeft)
view.handleInput()
window.state.perFrame = PerFrame()
doAssert view.controls.selected == modalSelection and not view.controls.holding
# Exercise complete rendered frames, not isolated overlay passes: the game
# pass must not overwrite Silky's previous-frame modal hover ownership.
view.options = parseOptions(@["--mute"])
view.summary = newSummary(view.session.maximumTicks)
view.summary.observe(world)
let history = view.summary
view.session.tickObserver = proc(w: World) = history.observe(w)
view.front.preferences.name = "Input regression"
proc overlayClick(row: float32, settings = false) =
  let size = if settings: vec2(976, 700) else: vec2(480, 360)
  view.frame()
  let at = (window.size.vec2 / view.sk.uiScale - size) / 2
  let p = (at + vec2(220, row)) * view.sk.uiScale
  window.state.mousePos = ivec2(p.x.int32, p.y.int32)
  view.frame()
  window.state.doubleClickTime = 0
  window.handleButtonPress(MouseLeft)
  view.frame()
  window.state.perFrame = PerFrame()
  window.handleButtonRelease(MouseLeft)
  view.frame()
  window.state.perFrame = PerFrame()
  view.layout()
key(KeyEscape)
doAssert view.matchMenu == GameMenu
overlayClick(212)
doAssert view.matchMenu == GameSettings, "Settings reuses real frontend settings"
key(KeyEscape)
doAssert view.matchMenu == GameMenu
overlayClick(286)
doAssert view.matchMenu == ConfirmLeave and not view.session.done,
  "First Leave only asks for confirmation"
key(KeyEscape)
doAssert view.matchMenu == GameMenu and not view.session.done
# Closing event frame cannot toggle pause, enter chat, select, or order.
window.handleButtonPress(KeyEscape)
window.handleButtonPress(KeySpace)
window.handleButtonPress(KeyEnter)
window.handleButtonPress(MouseRight)
view.handleInput()
doAssert view.matchMenu == HiddenMatchMenu and view.transport.player.playing and not view.chatting
window.state.perFrame = PerFrame()
for b in [KeyEscape, KeySpace, KeyEnter, MouseRight]: window.handleButtonRelease(b)
view.handleInput()
window.state.perFrame = PerFrame()
# Run the actual frame path: opening a menu must still advance local simulation.
view.options = parseOptions(@["--mute"])
view.lastTime = getMonoTime() - initDuration(milliseconds = 100)
key(KeyEscape)
let tickBeforeMenu = world.tick
view.frame()
doAssert world.tick > tickBeforeMenu and view.matchMenu == GameMenu,
  "Actual game frame continues ticking behind the menu"
overlayClick(286)
doAssert view.matchMenu == ConfirmLeave
overlayClick(294)
doAssert view.screen == MenuScreen and view.session.done,
  "Only explicit second Leave finishes the local session"
# Slider gestures use the real frontend and physical mouse delivery across
# complete frames; live scale changes must not move the captured track.
privateAccess(Frontend)
view.front.settingsTab = 1
view.screen = GameScreen
view.matchMenu = GameSettings
view.frame()
let settingsAt = (window.size.vec2 / view.sk.uiScale - vec2(976, 700)) / 2 + vec2(48, 48)
let sliderStart = (settingsAt + vec2(300, 170)) * view.sk.uiScale
let sliderEnd = (settingsAt + vec2(570, 170)) * view.sk.uiScale
window.state.mousePos = ivec2(sliderStart.x.int32, sliderStart.y.int32)
view.frame()
window.handleButtonPress(MouseLeft)
view.frame()
window.state.perFrame = PerFrame()
window.state.mousePos = ivec2(sliderEnd.x.int32, sliderEnd.y.int32)
view.frame()
window.handleButtonRelease(MouseLeft)
view.frame()
window.state.perFrame = PerFrame()
doAssert view.front.preferences.mainVolume in 45 .. 55,
  "Main volume is a draggable slider, not an inert +/- editor"
view.front.settingsTab = 0
view.matchMenu = GameMenu
key(KeyEscape)
# Finished-screen Escape stays direct, with no active-game confirmation.
view.screen = EndScreen
key(KeyEscape)
doAssert view.screen == MenuScreen and view.matchMenu == HiddenMatchMenu
window.close()
echo "Production Windy right-click, wheel, and UI/authority isolation passed"
