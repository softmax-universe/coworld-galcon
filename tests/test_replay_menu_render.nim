import
  std/[importutils, os, times],
  opengl, pixie, silky, vmath, windy/internal,
  polyworld/[chrome, replaylibraries],
  galcon/[common, rasters, replaymenus, replays, textures, themes]

privateAccess(Window)

proc verifyReplayMenu(size: IVec2, screenshot: string, zoom = 0) =
  ## Exercises the shared replay controls using Galcon's real menu artwork.
  let
    previousMode = uiScaleMode
    previousPercent = uiScalePercent
  if zoom > 0:
    uiScaleMode = CustomUiScale
    uiScalePercent = zoom
  defer:
    uiScaleMode = previousMode
    uiScalePercent = previousPercent
  let window = newWindow("Galcon replay browser", size, visible = false)
  defer: window.close()
  window.makeContextCurrent()
  loadExtensions()
  let
    builder = newAtlasBuilder(4096, 8)
    paints = newPaints(2)
  builder.addMenuAssets()
  builder.addBackground(paints)
  let sk = newSilky(window, builder.atlasImage, builder.atlas)
  sk.theme = galconTheme()
  var
    browser: ReplayBrowserState
    framebuffer, texture: GLuint
  browser.folder = "User folder / Polyworld / Galcon / Replays"
  for index in 0 ..< 12:
    browser.entries.add ReplayEntry(
      path: "/test/galcon-" & $index & ".replay",
      name: "Galcon match " & $(index + 1),
      modified: fromUnix(1795200000 - int64(index * 3600)),
      gameVersion: ReplayVersion,
      ticks: TickRate * (180 + index * 30),
      playable: true
    )
  browser.entries[1].playable = false
  browser.entries[1].gameVersion = ReplayVersion - 1
  browser.entries[1].problem = "Game version " & $(ReplayVersion - 1) &
    " (requires " & $ReplayVersion & ")"
  browser.entries[2].playable = false
  browser.entries[2].problem = "The replay file is incomplete."
  glGenFramebuffers(1, framebuffer.addr)
  glGenTextures(1, texture.addr)
  glBindTexture(GL_TEXTURE_2D, texture)
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8.GLint, size.x.GLsizei,
    size.y.GLsizei, 0, GL_RGBA, GL_UNSIGNED_BYTE, nil)
  glBindFramebuffer(GL_FRAMEBUFFER, framebuffer)
  glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
    GL_TEXTURE_2D, texture, 0)
  doAssert glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE
  defer:
    glBindFramebuffer(GL_FRAMEBUFFER, 0)
    glDeleteTextures(1, texture.addr)
    glDeleteFramebuffers(1, framebuffer.addr)

  proc input(point = vec2(-100), pressed = false, released = false,
      key = ButtonUnknown) =
    ## Supplies the same transient input fields as the native event loop.
    window.state.perFrame = PerFrame()
    window.state.buttonDown = {}
    window.state.mousePos = (point * sk.uiScale).ivec2
    window.state.mousePrevPos = window.state.mousePos
    if pressed:
      window.state.perFrame.buttonPressed.incl MouseLeft
      window.state.buttonDown.incl MouseLeft
    if released:
      window.state.perFrame.buttonReleased.incl MouseLeft
    if key != ButtonUnknown:
      window.state.perFrame.buttonPressed.incl key

  proc render(point = vec2(-100), pressed = false, released = false,
      key = ButtonUnknown): ReplayBrowserResult =
    ## Draws production controls without dispatching their filesystem actions.
    input(point, pressed, released, key)
    result = sk.drawReplayBrowser(window, browser)
    sk.endUi()

  proc click(point: Vec2): ReplayBrowserResult =
    ## Completes a real button press and release through the shared renderer.
    discard render(point, pressed = true)
    render(point, released = true)

  discard render()
  let
    view = size.vec2 / sk.uiScale
    layout = replayBrowserLayout(view)
    windowsCaption = sk.getTextSize("LobbyBody", "Open in File Explorer").x
    windowsLayout = replayBrowserLayout(view, windowsCaption + 20)
    watch = layout.rows.xy + vec2(layout.rows.w - 96, 48)
  doAssert layout.back.y + layout.back.h < view.y
  doAssert layout.folderButton.x + layout.folderButton.w < layout.refresh.x
  doAssert layout.panel.y + layout.panel.h < layout.back.y
  doAssert windowsLayout.folderButton.w >= windowsCaption + 20,
    "The Windows folder caption must fit Galcon's original font."
  doAssert windowsLayout.folderButton.x + windowsLayout.folderButton.w <
    windowsLayout.refresh.x
  let played = click(watch)
  doAssert played.action == PlayReplay
  doAssert played.path == browser.entries[0].path
  doAssert click(watch + vec2(0, ReplayRowHeight)).action == StayReplayBrowser
  doAssert click(watch + vec2(0, ReplayRowHeight * 2)).action == StayReplayBrowser
  discard render(key = KeyDown)
  doAssert browser.ui.selectedPath == browser.entries[0].path
  discard render(key = KeyDown)
  doAssert browser.ui.selectedPath == browser.entries[3].path
  doAssert render(key = KeyEnter).path == browser.entries[3].path
  for index in 0 ..< 10:
    discard render(key = KeyDown)
  doAssert browser.ui.selectedPath == browser.entries[^1].path
  doAssert browser.ui.scroll.scrollPos.y > 0
  doAssert render(key = KeyEnter).path == browser.entries[^1].path
  doAssert click(layout.importButton.xy + vec2(60, 20)).action == ImportReplayFile
  doAssert click(layout.folderButton.xy + vec2(70, 20)).action == OpenReplayFolder
  doAssert click(layout.refresh.xy + vec2(70, 20)).action == RefreshReplays
  doAssert click(layout.back.xy + vec2(70, 20)).action == BackFromReplays
  doAssert render(key = KeyEscape).action == BackFromReplays

  browser.ui = ReplayBrowserUi()
  discard render()
  let image = newImage(size.x, size.y)
  glReadPixels(0, 0, size.x.GLsizei, size.y.GLsizei,
    GL_RGBA, GL_UNSIGNED_BYTE, image.data[0].addr)
  image.flipVertical()
  var titleGreen = 0
  for y in 0 ..< min(size.y.int, (70 * sk.uiScale).int):
    for x in 0 ..< size.x.int:
      if image[x, y] == MenuGreen:
        inc titleGreen
  doAssert titleGreen > 10, "The replay heading must use Galcon green."
  if screenshot.len > 0:
    createDir(screenshot.parentDir)
    image.writeFile(screenshot)
  browser.entries.setLen(0)
  browser.ui.selectedPath = "/test/deleted.replay"
  doAssert render(key = KeyEnter).action == StayReplayBrowser
  doAssert browser.ui.selectedPath.len == 0

verifyReplayMenu(ivec2(1280, 900),
  getEnv("GALCON_REPLAY_MENU_SCREENSHOT", "/tmp/galcon-replay-ui/replays.png"))
verifyReplayMenu(ivec2(800, 600), "")
verifyReplayMenu(ivec2(1280, 900), "", zoom = 300)
echo "Galcon replay browser style, input, scaling, and disabled entries passed."
