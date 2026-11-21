include ../src/galcon/graphics
import std/[importutils, tempfiles]
import windy/internal
import galcon/[replaylibraries, replays]
import nativeinputs

privateAccess(Window)

proc saveTestSession(seed: int32): Session =
  ## Creates a real partial recording without bots or interactive gameplay.
  let options = parseOptions(@["--players", "2", "--ticks", "60"])
  options.headless = false
  options.setup.seed = seed
  result = newSession(options, @["", ""], @["Alice", "Bob"], 1, true)
  result.step()

proc replayMenuInput(view: View, point = vec2(-100),
    pressed = false, released = false) =
  ## Sends real transient pointer input to the production match menu.
  view.window.state.perFrame = PerFrame()
  view.window.state.buttonDown = {}
  view.window.state.mousePos = (point * view.sk.uiScale).ivec2
  view.window.state.mousePrevPos = view.window.state.mousePos
  if pressed:
    view.window.state.perFrame.buttonPressed.incl MouseLeft
    view.window.state.buttonDown.incl MouseLeft
  if released:
    view.window.state.perFrame.buttonReleased.incl MouseLeft
  view.window.syncTestInput()
  view.drawMatchMenu()

proc clickReplaySave(view: View) =
  ## Clicks Save replay at the position drawn by the native game menu.
  view.matchMenu = GameMenu
  view.sk.resetInteractions()
  view.replayMenuInput()
  let
    available = view.window.size.vec2 / view.sk.uiScale
    origin = (available - vec2(480, 424)) / 2 + vec2(32)
    point = origin + vec2(180, 254)
  view.replayMenuInput(point, pressed = true)
  view.replayMenuInput(point, released = true)

proc testReplaySaveGraphics() =
  ## Exercises native saves, retry retention, and production replay routing.
  const DataVariable = when defined(windows): "APPDATA" else: "XDG_DATA_HOME"
  let
    directory = createTempDir("galcon-graphics-replays-", "")
    hadData = existsEnv(DataVariable)
    previousData = getEnv(DataVariable)
  putEnv(DataVariable, directory)
  defer:
    if hadData:
      putEnv(DataVariable, previousData)
    else:
      delEnv(DataVariable)
    removeDir(directory)
  let window = newWindow("Galcon replay saves", ivec2(1280, 900),
    visible = false)
  defer:
    window.close()
  window.makeContextCurrent()
  loadExtensions()
  let builder = newAtlasBuilder(4096, 8)
  builder.addMenuAssets()
  let
    sk = newSilky(window, builder.atlasImage, builder.atlas)
    front = newFrontend(parseOptions(@["--mute"]))
    view = View(front: front, window: window, sk: sk,
      session: saveTestSession(51), saveReplay: true, screen: GameScreen)
    library = replayDirectory()
  sk.theme = galconTheme()
  doAssert library.startsWith(directory)
  view.finishSession()
  doAssert listReplays(library).len == 1
  let path = listReplays(library)[0].path
  doAssert loadRecording(path).hashes.len == 1
  view.finishSession()
  doAssert listReplays(library).len == 1,
    "Replacing or closing a finished view must not duplicate its replay."

  view.session = saveTestSession(52)
  view.saveReplay = false
  view.clickReplaySave()
  doAssert front.error.len == 0, front.error
  doAssert listReplays(library).len == 2,
    "The production Save replay button must work with automatic saving off."
  view.finishSession()
  doAssert listReplays(library).len == 2

  let blocked = directory / "blocked"
  writeFile(blocked, "Not a directory")
  putEnv(DataVariable, blocked)
  view.session = saveTestSession(53)
  view.saveReplay = true
  window.closeRequested = true
  view.closing = true
  view.finishSession()
  doAssert not window.closeRequested and not view.closing
  doAssert front.error.len > 0
  doAssert front.unsavedReplays.len == 1
  doAssert front.unsavedReplays[0].hashes == view.session.recording.hashes
  view.finishSession()
  doAssert front.unsavedReplays.len == 1,
    "Repeated close handling must retain only one copy of the failed save."
  front.retryPendingReplays()
  doAssert front.unsavedReplays.len == 1
  putEnv(DataVariable, directory)
  front.retryPendingReplays()
  doAssert front.unsavedReplays.len == 0 and front.error.len == 0
  doAssert listReplays(library).len == 3

  view.selection = 5
  view.menuAction()
  doAssert view.screen == FrontScreen and front.browsingReplays
  front.replayBrowser.ui.selectedPath = path
  front.replayBrowser.ui.scroll = FrameState(scrollPos: vec2(0, 120))
  view.session = newSession(parseOptions(@["--replay", path]))
  view.screen = GameScreen
  view.clickReplaySave()
  doAssert listReplays(library).len == 3,
    "The production save control must be disabled while watching a replay."
  view.returnToMenu()
  doAssert view.screen == FrontScreen and front.browsingReplays
  doAssert front.replayBrowser.ui.selectedPath == path
  doAssert front.replayBrowser.ui.scroll.scrollPos.y == 120
  doAssert listReplays(library).len == 3

  let
    corrupt = loadRecording(path)
    broken = directory / "divergent.replay"
  corrupt.hashes[0] = corrupt.hashes[0] xor 1
  corrupt.save(broken)
  view.options = parseOptions(@["--mute"])
  view.options.screenshot = directory / "unexpected-frame.png"
  view.session = newSession(parseOptions(@["--replay", broken]))
  view.screen = GameScreen
  view.matchMenu = GameMenu
  view.transport = Transport(player: initPlayer(false, 1, true))
  window.state.perFrame = PerFrame()
  window.state.buttonDown = {}
  window.syncTestInput()
  view.frame()
  doAssert view.screen == FrontScreen and front.browsingReplays
  doAssert view.session == nil
  doAssert view.matchMenu == HiddenMatchMenu
  doAssert "Replay diverged" in front.replayBrowser.message
  doAssert not fileExists(view.options.screenshot)
  doAssert listReplays(library).len == 3,
    "A divergent imported replay must return to its browser without saving."

  view.session = saveTestSession(54)
  view.session.recordPath = blocked / "requested.replay"
  view.saveReplay = true
  window.closeRequested = true
  view.closing = true
  view.finishSession()
  doAssert not window.closeRequested and not view.closing
  doAssert front.error.len > 0
  doAssert front.unsavedReplays.len == 0
  doAssert listReplays(library).len == 4,
    "An explicit export failure must not prevent the separate library save."

testReplaySaveGraphics()
echo "Galcon native replay save, failed-close recovery, and menu routing passed."
