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
let builder = newAtlasBuilder(64, 8)
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
  window.handleButtonPress(button)
  view.handleInput()
  window.handleButtonRelease(button)
  window.state.perFrame = PerFrame()
  view.handleInput()
planet(source)
key(MouseLeft)
doAssert view.controls.selected[source]
planet(target)
let before = world.planets[source].ships
key(MouseRight)
doAssert world.planets[source].ships < before, "Right-click target must send selected ships"
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
proc blocked(label: string, beforeInput, afterInput: proc()) =
  planet(target)
  beforeInput()
  let hash = world.fingerprint()
  let selected = view.controls.selected
  let percent = view.controls.percent
  key(MouseRight)
  wheel(1)
  doAssert world.fingerprint() == hash, label & " blocks sends"
  doAssert view.controls.selected == selected, label & " preserves selection"
  doAssert view.controls.percent == percent, label & " blocks wheel"
  afterInput()
blocked("Chat", proc() = view.chatting = true, proc() = view.chatting = false)
blocked("Statistics", proc() = view.card.shown = true, proc() = view.card.shown = false)
blocked("Pause", proc() = view.transport.player.playing = false, proc() = view.transport.player.playing = true)
blocked("Seeking", proc() = view.transport.player.targetTick = 5, proc() = view.transport.player.targetTick = -1)
blocked("History", proc() = view.session.world = world.clone(), proc() = view.session.world = world)
blocked("Replay", proc() = view.session.playback = true, proc() = view.session.playback = false)
blocked("Spectator", proc() = view.session.human = 0, proc() = view.session.human = 1)
blocked("Finished", proc() = view.session.done = true, proc() = view.session.done = false)
blocked("Menu", proc() = view.screen = FrontScreen, proc() = view.screen = GameScreen)
blocked("Sidebar", proc() = point(-100, 200), proc() = discard)
blocked("HUD", proc() = point(320, 460), proc() = discard)
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
window.close()
echo "Production Windy right-click, wheel, and UI/authority isolation passed"
