include ../src/galcon/graphics
import std/importutils
import jsony
import windy/internal
import galcon/[bots, replays]
import nativeinputs

const ExpandSource = staticRead(Root / "players/expand.bas")

privateAccess(Window)

proc pointerFrame(view: View, point: Vec2,
    pressed = false, released = false) =
  ## Delivers one native pointer frame to the complete production view.
  let window = view.window
  window.state.perFrame = PerFrame()
  window.state.mousePrevPos = window.state.mousePos
  window.state.mousePos = (point * view.sk.uiScale).ivec2
  if pressed:
    window.state.buttonDown.incl MouseLeft
    window.state.perFrame.buttonPressed.incl MouseLeft
  if released:
    window.state.buttonDown.excl MouseLeft
    window.state.perFrame.buttonReleased.incl MouseLeft
  window.syncTestInput()
  view.frame()

proc rematchWidget(view: View, point: Vec2,
    pressed = false, released = false): int =
  ## Draws only the real rematch widget to inspect hidden and disabled states.
  let window = view.window
  window.state.perFrame = PerFrame()
  window.state.mousePrevPos = window.state.mousePos
  window.state.mousePos = (point * view.sk.uiScale).ivec2
  if pressed:
    window.state.buttonDown.incl MouseLeft
    window.state.perFrame.buttonPressed.incl MouseLeft
  if released:
    window.state.buttonDown.excl MouseLeft
    window.state.perFrame.buttonReleased.incl MouseLeft
  window.syncTestInput()
  view.sk.beginUi(window, window.size)
  doAssert not view.drawRematchButton(),
    "A hidden or disabled rematch must not activate"
  result = view.sk.drawer.layers[NormalLayer].len
  view.sk.endUi()

proc completeBattle(view: View) =
  ## Completes the actual simulation and opens its persistent result card.
  while not view.session.done:
    view.session.step()
  view.syncResults(100)
  view.layout()
  doAssert view.screen == EndScreen and view.card.terminal

proc gameVertices(view: View): int =
  ## Counts the full board and results card before the shared button pass.
  view.sk.beginUi(view.window, view.window.size)
  view.drawGame()
  result = view.sk.drawer.layers[NormalLayer].len
  view.sk.endUi()

proc testRematchGraphics() =
  ## Checks shared-button restarts through full hidden native frames.
  let
    window = newWindow("Galcon rematch controls", ivec2(1514, 970),
      visible = false)
    options = parseOptions(@[
      "--players", "4", "--planets", "36", "--seed", "8",
      "--balanced-map", "true", "--player", "1", "--mute", "--ticks", "384"
    ])
  defer:
    window.close()
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
  let
    builder = newAtlasBuilder(4096, 8)
    paints = newPaints(MaxPlanets)
  builder.addBackground(paints)
  doAssert builder.addImage("Particle", paints.particle)
  for name in ["Numbers", "Players", "Score"]:
    builder.addRasterFont(Assets / "zeroes_3.ttf", name, 14)
  for name in ["Hud", "ScoreTitle"]:
    builder.addRasterFont(Assets / "zeroes_3.ttf", name, 24)
  builder.addRasterFont(Assets / "zeroes_3.ttf", "Hover", 16)
  builder.addRasterFont(Assets / "zeroes_3.ttf", "TinyNumbers", 9)
  builder.addRasterFont(Assets / "zeroes_3.ttf", "ScoreSmall", 10)
  builder.addRasterFont(Assets / "transport/Rubik-Regular.ttf", "Chat", 13)
  builder.addMenuAssets()
  builder.addTransportAssets()
  let view = View(
    window: window, options: options, paints: paints,
    front: newFrontend(options),
    sk: newSilky(window, builder.atlasImage, builder.atlas)
  )
  view.front.replayPreferences.saveReplay = false
  view.front.preferences.bindings = GalconControls.defaults
  view.front.preferences.applyPreferences(window, false)
  view.sk.builder = builder
  view.sk.theme = galconTheme()
  view.start(provided = newSession(
    options,
    @["", TruceSource, ExpandSource, BaselineSource],
    @["Alice", "Truce Bot", "Expand Bot", "Classic Bot"],
    1,
    true
  ))
  view.layout()
  doAssert not view.saveReplay
  for round in 1 .. 2:
    view.completeBattle()
    view.pointerFrame(vec2(-100))
    if round == 1:
      glFinish()
      let image = newImage(1514, 970)
      glReadPixels(0, 0, 1514, 970, GL_RGBA, GL_UNSIGNED_BYTE,
        image.data[0].addr)
      image.flipVertical()
      image.writeFile(Root / "build/rematch-buttons.png")
    let
      previous = view.session
      recording = previous.recording.encodeRecording()
      oldHash = previous.world.fingerprint()
      nextSetup = previous.world.setup.clone()
      button = view.resultButton(rematch = true)
      center = button.xy + button.wh / 2
    view.pointerFrame(center)
    view.pointerFrame(center)
    view.pointerFrame(center, pressed = true)
    doAssert view.session == previous and view.screen == EndScreen,
      "Pressing rematch must wait for the shared button's release"
    view.pointerFrame(center, released = true)
    doAssert view.front.error.len == 0, view.front.error
    doAssert view.session != previous and view.screen == GameScreen
    doAssert view.session.world.tick == 0 and not view.session.done
    doAssert view.session.world.setup.seed != previous.world.setup.seed
    nextSetup.seed = view.session.world.setup.seed
    doAssert view.session.world.setup[] == nextSetup[]
    doAssert view.session.names == previous.names
    doAssert view.session.human == previous.human
    doAssert view.session.maximumTicks == previous.maximumTicks
    doAssert view.session.recording.hashes.len == 0
    doAssert previous.recording.encodeRecording() == recording
    doAssert previous.world.fingerprint() == oldHash
    doAssert not view.card.shown and not view.saveReplay
    doAssert view.session.recordPath.len == 0
    for owner in 2 .. 4:
      doAssert view.session.brains[owner] != previous.brains[owner]
      doAssert view.session.brains[owner].decisions == 0
  echo "Two native rematches retain roster and rules with fresh sessions and maps"

  view.completeBattle()
  view.session.playback = true
  doAssert view.rematchWidget(vec2(-100)) == 0
  view.session.playback = false
  view.tutorial = 1
  doAssert view.rematchWidget(vec2(-100)) == 0
  view.tutorial = 0
  view.session.networked = true
  view.front.connection = Connection(client: RoomClient(
    connected: true, welcomed: true, participant: 2,
    snapshot: RoomMessage(participant: 1, room: "guest-rematch", phase: Ended)
  ))
  let
    oldSession = view.session
    guestButton = view.resultButton(rematch = true)
    center = guestButton.xy + guestButton.wh / 2
  view.sk.resetInteractions()
  doAssert view.rematchWidget(vec2(-100)) > 0
  doAssert view.rematchWidget(center) > 0
  doAssert view.rematchWidget(center, pressed = true) > 0
  doAssert view.rematchWidget(center, released = true) > 0
  doAssert view.session == oldSession
  doAssert not view.front.rematchPending()
  doAssert view.front.connection.client.outgoing.len == 0
  echo "Replay and tutorial rematches stay hidden; network guests stay disabled"

  let client = view.front.connection.client
  client.participant = 1
  client.snapshot.payload = MatchConfig(players: 4, planets: 36, seed: 8,
    maximumTicks: 384).toJson()
  let vertices = view.gameVertices()
  view.front.requestRematch()
  doAssert view.front.rematchPending()
  doAssert view.gameVertices() == vertices,
    "Starting a rematch must keep the completed results card visible"
  for button in [KeyEnter, KeyEscape, KeySpace, KeyTab]:
    window.state.perFrame = PerFrame()
    window.state.perFrame.buttonPressed.incl button
    window.syncTestInput()
    view.handleInput()
    doAssert view.screen == EndScreen and view.session == oldSession
    doAssert view.card.shown and not view.returnPending
    doAssert view.front.rematchPending()
    doAssert client.outgoing.len == 1,
      "Pending rematches must ignore shortcuts without sending more requests"
  doAssert view.rematchWidget(center) > 0
  doAssert view.rematchWidget(center, pressed = true) > 0
  doAssert view.rematchWidget(center, released = true) > 0
  view.sk.beginUi(window, window.size)
  doAssert not view.drawResultButton()
  view.sk.endUi()
  doAssert client.outgoing.len == 1
  echo "Pending rematches retain results and ignore keyboard and button input"

  let raceFront = newFrontend(options)
  raceFront.replayPreferences.saveReplay = false
  raceFront.connection = Connection(client: RoomClient(
    began: true, participant: 1,
    snapshot: RoomMessage(participant: 1, room: "fresh-rematch", phase: Lobby)
  ))
  let raceView = View(front: raceFront, session: oldSession, screen: GameScreen)
  for i in 0 ..< 2:
    raceView.syncMatchScreen()
    doAssert raceView.screen == GameScreen and raceView.session == oldSession,
      "BeginMatch must retain the game while the prior lobby snapshot is stale"
  echo "A rematch stays visible between BeginMatch and the next room snapshot"

testRematchGraphics()
