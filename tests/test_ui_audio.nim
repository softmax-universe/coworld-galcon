## Hidden production UI events and silent native audio lifecycle checks.
include ../src/galcon/graphics
import std/importutils
import windy/internal

privateAccess(Window)

proc handleButtonPress(window: Window, button: Button) =
  ## Delivers a native press without sending an operating-system event.
  handleButtonPressTemplate()

proc handleButtonRelease(window: Window, button: Button) =
  ## Delivers a native release without sending an operating-system event.
  handleButtonReleaseTemplate()

let window = newWindow("Galcon UI audio checks", ivec2(640, 480),
  visible = false)
window.makeContextCurrent()
loadExtensions()
var framebuffer, colorTexture: GLuint
glGenFramebuffers(1, framebuffer.addr)
glGenTextures(1, colorTexture.addr)
glBindTexture(GL_TEXTURE_2D, colorTexture)
glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8.GLint, 640, 480, 0,
  GL_RGBA, GL_UNSIGNED_BYTE, nil)
glBindFramebuffer(GL_FRAMEBUFFER, framebuffer)
glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
  GL_TEXTURE_2D, colorTexture, 0)
doAssert glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE

let builder = newAtlasBuilder(2048, 8)
builder.addMenuAssets()
let view = View(
  window: window,
  sk: newSilky(window, builder.atlasImage, builder.atlas),
  front: Frontend(),
  options: parseOptions(@[]),
  screen: MenuScreen
)
view.sk.theme = galconTheme()
view.front.preferences.bindings = GalconControls.defaults
view.front.preferences.applyPreferences(window, false)
view.layout()
var cues: array[UiCue, int]
view.front.onUiCue = proc(cue: UiCue) =
  ## Counts actual UI feedback without playing any audio.
  inc cues[cue]

proc point(x, y: int) =
  ## Moves the logical pointer and supplies its real per-frame movement.
  let position = ivec2(x.int32, y.int32)
  window.state.perFrame.mouseDelta = position - window.state.mousePos
  window.state.mousePrevPos = window.state.mousePos
  window.state.mousePos = position

proc buttonFrame(enabled = true): bool =
  ## Draws one production button into the hidden framebuffer.
  view.sk.beginUi(window, window.size)
  result = view.front.menuButton(view.sk, "Test button", vec2(100, 100),
    200, enabled = enabled)
  view.sk.endUi()
  window.state.perFrame = PerFrame()

proc key(button: Button) =
  ## Sends a complete key gesture through the real menu input handler.
  window.state.perFrame = PerFrame()
  if button == MouseLeft:
    window.state.doubleClickTime = 0
  window.handleButtonPress(button)
  view.handleInput()
  window.state.perFrame = PerFrame()
  window.handleButtonRelease(button)
  view.handleInput()
  window.state.perFrame = PerFrame()

point(20, 20)
discard buttonFrame()
point(140, 120)
discard buttonFrame()
doAssert cues[UiHover] == 1 and cues[UiClick] == 0,
  "Entering an enabled visible button produces one hover cue"
for i in 0 ..< 4:
  discard buttonFrame()
doAssert cues[UiHover] == 1, "Stationary hovering cannot repeat its cue"
window.state.doubleClickTime = 0
window.handleButtonPress(MouseLeft)
doAssert not buttonFrame()
doAssert cues[UiClick] == 0, "Button press alone is not activation"
window.handleButtonRelease(MouseLeft)
doAssert buttonFrame()
doAssert cues[UiClick] == 1, "Button release produces one activation cue"

point(20, 20)
discard buttonFrame(false)
point(140, 120)
discard buttonFrame(false)
window.handleButtonPress(MouseLeft)
discard buttonFrame(false)
window.handleButtonRelease(MouseLeft)
doAssert not buttonFrame(false)
doAssert cues == [1, 1], "Disabled buttons stay silent"

point(20, 20)
discard buttonFrame()
window.handleButtonPress(MouseLeft)
discard buttonFrame()
point(140, 120)
discard buttonFrame()
doAssert cues == [1, 1], "Dragging into a button does not produce hover"
point(20, 20)
window.handleButtonRelease(MouseLeft)
discard buttonFrame()
point(140, 120)
discard buttonFrame()
doAssert cues[UiHover] == 2, "A fresh pointer entry produces another cue"

cues = default(array[UiCue, int])
view.selection = 3
point(20, 20)
window.state.perFrame = PerFrame()
key(KeyDown)
doAssert view.selection == 4 and cues[UiHover] == 1,
  "Keyboard menu selection gives hover feedback"
key(KeyEnter)
doAssert view.screen == HelpScreen and cues[UiClick] == 1,
  "Keyboard menu activation gives click feedback"
key(KeyEscape)
key(KeyUp)
doAssert view.screen == MenuScreen and view.selection == 3
point(100, 120 + 3 * 46 + 20)
view.handleInput()
window.state.perFrame = PerFrame()
let menuHoverCount = cues[UiHover]
view.handleInput()
doAssert cues[UiHover] == menuHoverCount,
  "Main-menu hover feedback does not repeat while stationary"
key(MouseLeft)
doAssert view.screen == FrontScreen and view.front.page == SettingsMenu and
  cues[UiClick] == 2, "Pointer activation acknowledges the settings button"

view.screen = MenuScreen
view.front.preferences.mainVolume = 0
view.front.preferences.musicVolume = 25
view.front.preferences.fxVolume = 50
view.front.preferences.uiVolume = 60
when compiles(view.front.preferences.soundMuted):
  view.front.preferences.soundMuted = false
view.initSounds()
doAssert view.musicSource != nil and view.musicSource.playing and
  view.musicSource.looping and view.musicSource.gain == 0,
  "The menu starts its original soundtrack silently at zero master volume"
for cue in UiCue:
  doAssert view.uiSounds[cue] != nil and view.uiSources[cue] != nil
  doAssert view.uiSounds[cue].duration > 0 and
    view.uiSounds[cue].duration < 0.1,
    "Interface cues remain short"
  view.front.emitUiCue(cue)
  doAssert not view.uiSources[cue].playing,
    "Zero master volume cannot play interface feedback"

# Inspect nonzero channel gains only with every source stopped.
view.musicEnabled = false
view.syncAudio()
view.front.preferences.mainVolume = 50
view.front.preferences.musicVolume = 20
view.front.preferences.fxVolume = 40
view.syncAudio()
doAssert not view.musicSource.playing
doAssert abs(view.musicSource.gain - 0.1'f) < 0.0001'f
doAssert abs(view.launchSource.gain - 0.2'f) < 0.0001'f
doAssert abs(view.uiSources[UiHover].gain - 0.066'f) < 0.0001'f
doAssert abs(view.uiSources[UiClick].gain - 0.114'f) < 0.0001'f
view.front.preferences.musicVolume = 80
view.front.preferences.uiVolume = 0
view.syncAudio()
doAssert abs(view.musicSource.gain - 0.4'f) < 0.0001'f and
  abs(view.launchSource.gain - 0.2'f) < 0.0001'f
for cue in UiCue:
  doAssert view.uiSources[cue].gain == 0 and not view.uiSources[cue].playing
view.front.preferences.fxVolume = 0
view.syncAudio()
doAssert view.launchSource.gain == 0 and
  abs(view.musicSource.gain - 0.4'f) < 0.0001'f,
  "Music, battle effects, and interface levels are independent"

view.front.preferences.mainVolume = 0
view.musicEnabled = true
view.syncAudio()
key(KeyF3)
doAssert not view.musicEnabled and not view.musicSource.playing
key(KeyF3)
doAssert view.musicEnabled and view.musicSource.playing and
  view.musicSource.gain == 0, "F3 controls music from the main menu"
let soundtrack = view.musicSource
let audioDeadline = getMonoTime() + initDuration(seconds = 1)
while view.musicSource.playback <= 0.02'f and getMonoTime() < audioDeadline:
  sleep(10)
let playingOffset = view.musicSource.playback
doAssert playingOffset > 0.02'f,
  "The silent soundtrack advances before checking menu continuity"
view.session = newSession(parseOptions(@["--player", "1"]))
view.screen = GameScreen
view.returnToMenu()
doAssert view.screen == MenuScreen and view.musicSource == soundtrack and
  view.musicSource.playing and view.musicSource.playback >= playingOffset,
  "Returning to the menu preserves the same playing soundtrack"

let
  mutedOptions = parseOptions(@["--mute"])
  muted = View(options: mutedOptions, front: newFrontend(mutedOptions))
doAssert muted.front.preferences.mainVolume == 0
muted.front.preferences.musicVolume = 20
muted.front.preferences.fxVolume = 40
muted.initSounds()
doAssert muted.musicSource != nil and muted.launchSource != nil
doAssert muted.musicSource.playing and muted.musicSource.gain == 0
for cue in UiCue:
  doAssert muted.uiSources[cue] != nil and muted.uiSources[cue].gain == 0,
    "A muted launch creates silent sources that settings can enable"
muted.musicEnabled = false
muted.syncAudio()
muted.front.preferences.mainVolume = 50
muted.syncAudio()
doAssert not muted.musicSource.playing
doAssert muted.musicSource.gain > 0 and muted.launchSource.gain > 0,
  "The mute flag cannot permanently disable audio after a settings change"

let screenshot = View(options: parseOptions(@[
    "--screenshot", "unused.png", "--unmute"]),
  front: Frontend())
screenshot.initSounds()
doAssert screenshot.musicSource == nil and screenshot.launchSource == nil
for cue in UiCue:
  doAssert screenshot.uiSources[cue] == nil,
    "Screenshot capture still skips audio creation"

view.front.onUiCue = nil
muted.front.onUiCue = nil
for source in [view.musicSource, view.launchSource, view.blastSource,
  view.captureSource, view.uiSources[UiHover], view.uiSources[UiClick],
  muted.musicSource, muted.launchSource, muted.blastSource,
  muted.captureSource, muted.uiSources[UiHover], muted.uiSources[UiClick]]:
    source.close()
glDeleteTextures(1, colorTexture.addr)
glDeleteFramebuffers(1, framebuffer.addr)
window.close()
echo "Hidden UI feedback, silent menu music, and independent audio levels passed"
