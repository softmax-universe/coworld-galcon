## Real Windy callbacks plus production handleInput; no fake text dispatch.
include ../src/galcon/graphics
import std/importutils
import windy/internal
privateAccess(Window)
proc handleButtonPress(window: Window, button: Button) = handleButtonPressTemplate()
proc handleButtonRelease(window: Window, button: Button) = handleButtonReleaseTemplate()
proc runeEvent(window: Window, rune: Rune) = handleRuneTemplate()

let window = newWindow("Galcon chat input regression", ivec2(1514, 970), visible = false)
window.makeContextCurrent()
loadExtensions()
var framebuffer, texture: GLuint
glGenFramebuffers(1, framebuffer.addr)
glGenTextures(1, texture.addr)
glBindTexture(GL_TEXTURE_2D, texture)
glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8.GLint, 1514, 970, 0,
  GL_RGBA, GL_UNSIGNED_BYTE, nil)
glBindFramebuffer(GL_FRAMEBUFFER, framebuffer)
glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, texture, 0)
let builder = newAtlasBuilder(512, 8)
builder.addRasterFont(Assets / "transport/Rubik-Regular.ttf", "Chat", 13)
let view = View(window: window, sk: newSilky(window, builder.atlasImage, builder.atlas),
  session: newSession(parseOptions(@["--player", "1", "--mute"])), screen: GameScreen)
view.sk.builder = builder
view.transport = Transport(player: initPlayer(true, view.session.maximumTicks, true))
view.front = newFrontend(parseOptions(@["--mute"]))
view.front.preferences.bindings = GalconControls.defaults
view.front.preferences.applyPreferences(window, false)
view.controls = Controls(player: 1, percent: 50, anchor: -1, hover: -1)
view.layout()
view.installChatInput()
proc ui() =
  view.sk.beginUi(window, window.size)
  view.drawChat()
  view.sk.endUi()
  window.runeInputEnabled = view.chatting
proc key(button: Button) =
  window.state.perFrame = PerFrame()
  window.handleButtonPress(button)
  view.handleInput()
  window.handleButtonRelease(button)
  window.state.perFrame = PerFrame()

ui()
key(KeyEnter)
doAssert view.chatting, "Enter opens in-game typing"
ui()
window.runeEvent(Rune('h'))
window.runeEvent(Rune('i'))
doAssert view.chatInput == "hi", "Real rune callback must append after Silky UI frame"
# Function/fullscreen shortcuts must not act behind text focus.
let tracing = profileTraceActive()
key(KeyF2)
doAssert profileTraceActive() == tracing, "Typing must suppress the profile hotkey"
let fullscreen = window.fullscreen
key(KeyF11)
doAssert window.fullscreen == fullscreen, "Typing must suppress fullscreen gameplay hotkey"
key(Key1)
doAssert view.controls.percent == 50
key(KeyTab)
doAssert not view.card.shown
let playing = view.transport.player.playing
key(KeySpace)
doAssert view.transport.player.playing == playing
key(KeyEscape)
doAssert not view.chatting and view.chatInput.len == 0 and view.screen == GameScreen
key(KeyEnter)
ui()
for rune in "空🙂".runes: window.runeEvent(rune)
doAssert view.chatInput == "空🙂"
key(KeyBackspace)
doAssert view.chatInput == "空"
window.runeEvent(Rune(0xd800))
window.runeEvent(Rune(0x110000))
doAssert view.chatInput == "空", "Reject non-scalar Unicode from the text callback"
for i in 0 ..< MaxChatBytes: window.runeEvent(Rune(0x1f642))
doAssert view.chatInput.len <= MaxChatBytes - 16 and validateUtf8(view.chatInput) < 0
let bounded = view.chatInput
window.runeEvent(Rune(10))
window.runeEvent(Rune(127))
doAssert view.chatInput == bounded
key(KeyEscape)
key(KeyEnter)
ui()
for rune in "Hello human".runes: window.runeEvent(rune)
let before = view.session.world.chatCount
key(KeyEnter)
doAssert not view.chatting and view.chatInput.len == 0
doAssert view.session.world.chatCount == before + 1
ui()
window.runeEvent(Rune('x'))
doAssert view.chatInput.len == 0
window.close()
echo "Human chat actual Windy input, Escape, hotkey isolation, Unicode bounds passed"
