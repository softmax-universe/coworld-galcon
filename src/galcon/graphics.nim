import
  std/[os, math, tables, strutils, monotimes, times, unicode],
  silky, pixie, vmath, chroma, bumpy, opengl, slappy,
  polyworld/profiles as gameProfiles,
  polyworld/[viewers, inputs, displays, chrome, lobbies, networks],
  common, worlds, controls, textures, options, sessions, transports, chats, effects,
  summaries, rasters, frontends, themes, multiplayer

when defined(emscripten):
  {.emit: "#include <emscripten.h>".}

const
  Green = rgbx(85, 255, 85, 255)
  White = rgbx(255, 255, 255, 255)
  Gray = rgbx(170, 170, 170, 255)
  Shadow = rgbx(0, 0, 0, 255)
  PlayerListRowHeight = 22.0'f
  TutorialTexts = [
    "you are the green player.\n" &
      "click and hold on your planet,\n" &
      "drag to a target, then release.\n\n" &
      "click planets to select a group.\n" &
      "double-click yours to select all.\n\n" &
      "number keys or slider: attack size.",
    "try to take over the red enemy.\n\n" &
      "capture good neutral planets first.\n" &
      "big planets produce more ships.\n\n" &
      "reinforce your planets so the\n" &
      "enemy cannot take over.",
    "production depends on morale.\n\n" &
      "morale rises near friendly planets\n" &
      "and when receiving reinforcements.\n\n" &
      "attacks and nearby enemies lower it.\n\n" &
    "tab shows player ship histories."
  ]
  HelpText = "click planets to select a group.\n" &
    "double-click yours to select all.\n" &
    "drag from any planet to a target.\n" &
    "drag empty space to select a box.\n" &
    "right-click a target to send ships.\n" &
    "right-click empty space to clear.\n\n" &
    "slider: choose 1-100% ships\n" &
    "1-9: 10-90%, 0: 100% ships\n" &
    "tab: player ship histories\n" &
    "space or f10: pause\n" &
    "f1: network/render diagnostics\n" &
    "f2: profile, f3: music\n" &
    "enter: global chat\n" &
    "alt-enter: fullscreen\n" &
    "escape: game menu (game continues)\n\n" &
    "have fun!"

type
  Screen = enum
    MenuScreen, HelpScreen, GameScreen, TutorialScreen, EndScreen, FrontScreen
  MatchMenu = enum
    HiddenMatchMenu, GameMenu, GameSettings, ConfirmLeave
  View = ref object
    front: Frontend
    window: Window
    sk: Silky
    options: Options
    paints: Paints
    effects: Effects
    session: Session
    summary: Summary
    card: Card
    rosterLabels, rosterValues: array[MaxPlayers + 1, string]
    rosterCounts: array[MaxPlayers + 1, int64]
    rosterWidths: array[MaxPlayers + 1, float32]
    planetOwners: array[MaxPlanets, int]
    planetSprites: array[MaxPlanets, string]
    controls: Controls
    screen: Screen
    offset: Vec2
    selection: int
    difficulty: Difficulty
    tutorial, stat, boardRevision, frames: int
    transport: Transport
    presentation: Presentation
    lastTime: MonoTime
    music, launchSound, blastSound, captureSound: Sound
    musicSource, launchSource, blastSource, captureSource: Source
    musicEnabled: bool
    seenCaptures, seenImpacts: int
    chatting: bool
    closing: bool
    chatInput: string
    returnPending, returnSent: bool
    matchMenu: MatchMenu
    diagnosticsOwnInput: bool

proc ownerColor(owner: int): ColorRGBX =
  ## Converts the original player palette at the rendering boundary.
  let c = Colors[owner]
  rgbx(c[0], c[1], c[2], 255)

proc line(view: View, a, b: Vec2, color: ColorRGBX, width = 1.0'f) =
  ## Draws a two-dimensional line through Silky's triangle batch.
  let
    delta = b - a
    magnitude = length(delta)
  if magnitude < 0.001:
    return
  let
    normal = vec2(-delta.y, delta.x) / magnitude * width / 2
    uv = view.sk.atlas.entries[WhiteTileKey]
    sample = vec2(uv.x.float32 + 8, uv.y.float32 + 8)
    colors = [color, color, color]
    uvs = [sample, sample, sample]
  view.sk.drawTriangle([a + normal, a - normal, b + normal], uvs, colors)
  view.sk.drawTriangle([a - normal, b - normal, b + normal], uvs, colors)

proc ring(view: View, center: Vec2, radius: float32, color: ColorRGBX) =
  ## Draws the original bright circular selection marker in logical pixels.
  var previous = center + vec2(radius, 0)
  for i in 1 .. 64:
    let
      angle = i.float32 * PI.float32 / 32
      next = center + vec2(math.cos(angle), math.sin(angle)) * radius
    view.line(previous, next, color, 2)
    previous = next

proc text(
    view: View, font, value: string, position: Vec2,
    color = White, centered = false, shadow = true,
    maxWidth = float32.high
) =
  ## Draws transparent glyphs with an optional one-pixel glyph shadow.
  let
    at = view.offset + position
    width = if centered: Width.float32 else: maxWidth
    alignment = if centered: CenterAlign else: LeftAlign
  if shadow:
    discard view.sk.drawRasterText(
      font, value, at + vec2(1, 1), Shadow,
      maxWidth = width, hAlign = alignment, clip = false
    )
  discard view.sk.drawRasterText(
    font, value, at, color,
    maxWidth = width, hAlign = alignment, clip = false
  )

proc centeredLines(view: View, title, body: string) =
  ## Places original-font pause and tutorial text over the game background.
  let
    lines = body.splitLines()
    top = (Height - (lines.len + 3) * 22).float32 / 2
  view.text("Hud", title, vec2(0, top), centered = true)
  for i, value in lines:
    view.text("Small", value, vec2(0, top + 50 + i.float32 * 22),
      centered = true)
  view.text("Small", "click or press enter to continue",
    vec2(0, Height - 35), Gray, centered = true)

proc playSource(source: Source) =
  ## Reuses one bounded audio source rather than allocating on each impact.
  if source != nil:
    source.stop()
    source.play()

proc initSounds(view: View) =
  ## Loads Phil Hassey's original soundtrack and three sound effects.
  if view.options.muted:
    return
  try:
    slappyInit()
    view.music = newSound(Assets / "galcon.ogg", forceMono = false)
    view.launchSound = newSound(Assets / "launch.wav")
    view.blastSound = newSound(Assets / "blast.wav")
    view.captureSound = newSound(Assets / "takeover.wav")
    view.musicSource = view.music.play()
    view.musicSource.looping = true
    view.musicSource.stop()
    view.launchSource = view.launchSound.play()
    view.blastSource = view.blastSound.play()
    view.captureSource = view.captureSound.play()
    view.launchSource.stop()
    view.blastSource.stop()
    view.captureSource.stop()
    view.musicEnabled = true
  except SlappyError as error:
    echo "Original audio unavailable: ", error.msg

proc updateBoard(view: View) {.measure.} =
  ## Updates only captured planet sprites instead of repainting the playfield.
  if view.boardRevision == view.session.world.revision:
    return
  var changed = false
  for i, planet in view.session.world.planets:
    if view.planetOwners[i] == planet.owner:
      continue
    let image = view.paints.planetSprite(
      planet, planet.owner,
      view.sk.atlas.entries[view.planetSprites[i]].width
    )
    view.sk.replaceRasterImage(view.planetSprites[i], image)
    view.planetOwners[i] = planet.owner
    changed = true
  if changed:
    view.sk.finishRasterUpdates()
  view.boardRevision = view.session.world.revision

proc start(view: View, tutorial = 0, provided: Session = nil) =
  ## Starts a seeded match or one of the original three tutorial maps.
  if view.session != nil:
    view.session.observer = nil
    view.session.tickObserver = nil
    view.session.finish()
  var options = view.options.clone()
  options.setup = options.matchSetup(view.difficulty, tutorial)
  view.session = if provided == nil: newSession(options) else: provided
  view.card = Card()
  view.matchMenu = HiddenMatchMenu
  view.returnPending = false
  view.returnSent = false
  for owner in 1 .. MaxPlayers:
    view.rosterLabels[owner] = ""
    view.rosterValues[owner] = ""
  view.summary = newSummary(view.session.maximumTicks)
  view.summary.observe(view.session.world)
  let history = view.summary
  view.session.tickObserver = proc(world: World) =
    ## Captures displayed ship histories without owning the view or session.
    history.observe(world)
  view.effects = Effects(seed: view.session.world.setup.seed)
  view.session.historyMargin = EffectHistoryTicks
  let current {.cursor.} = view
  view.session.observer = proc(arrival: Arrival) =
    ## Reconstructs only the particles that can survive a requested seek.
    let target = current.transport.player.targetTick
    if target < 0 or arrival.tick + 1 >= target - EffectHistoryTicks:
      current.effects.observe(arrival)
  view.chatting = false
  view.chatInput.setLen(0)
  view.controls = Controls(player: view.session.human, percent: 50, anchor: -1,
    hover: -1)
  view.paints = newPaints(view.session.world.planets.len)
  for i, planet in view.session.world.planets:
    view.planetSprites[i] = "Planet" & $i
    view.planetOwners[i] = planet.owner
    let
      wanted = if planet.radius <= 11: 116 else: PlanetSpriteSize
      existing = view.sk.atlas.entries.getOrDefault(view.planetSprites[i])
      size = max(wanted, existing.width)
      image = view.paints.planetSprite(planet, planet.owner, size)
    if existing.width < size:
      if not view.sk.builder.addImage(view.planetSprites[i], image):
        raise newException(GalconError, "HD planet sprites exceed the atlas")
    else:
      let entry = view.sk.atlas.entries[view.planetSprites[i]]
      view.sk.image.draw(image,
        translate(vec2(entry.x.float32, entry.y.float32)), OverwriteBlend)
  view.sk.uploadAtlas()
  view.boardRevision = -1
  view.updateBoard()
  view.screen = if tutorial > 0: TutorialScreen else: GameScreen
  view.tutorial = tutorial
  view.transport = Transport(player: initPlayer(
    not view.session.playback,
    view.session.maximumTicks,
    not options.game.pauseOnStart,
    options.game.speed
  ))
  view.lastTime = getMonoTime()
  view.seenCaptures = 0
  view.seenImpacts = 0
  if view.musicSource != nil and view.musicEnabled:
    view.musicSource.play()

const MainMenuItems =
  when defined(emscripten): ["tutorial", "single player", "multiplayer", "settings", "help"]
  else: ["tutorial", "single player", "multiplayer", "settings", "help", "quit"]

proc menuAction(view: View) =
  ## Opens the selected Galcon menu or tutorial.
  case view.selection
  of 0: view.start(1)
  of 1:
    view.front.page = SingleMenu
    view.screen = FrontScreen
  of 2:
    view.front.page = MultiplayerMenu
    view.screen = FrontScreen
  of 3:
    view.front.page = SettingsMenu
    view.screen = FrontScreen
  of 4: view.screen = HelpScreen
  of 5:
    when not defined(emscripten): view.closing = true
  else: discard

proc syncMatchScreen(view: View) =
  ## Only the relay's actual Lobby snapshot can leave network results.
  if view.session != nil and view.session.networked and view.front.connection != nil:
    let snapshot = view.front.connection.client.snapshot
    if snapshot.room.len > 0 and snapshot.phase == Lobby:
      view.front.page = LobbyMenu
      view.screen = FrontScreen
      view.returnPending = false
      view.returnSent = false
    elif view.returnPending and not view.returnSent and
      snapshot.participant == view.front.connection.client.participant and
      snapshot.phase in {Ended, Desynced}:
        view.front.connection.client.send(RoomMessage(kind: ReturnLobby))
        view.returnSent = true

proc returnToMenu(view: View) =
  ## Completed rooms reopen directly; never render an Ended room as a lobby.
  view.matchMenu = HiddenMatchMenu
  if view.session.networked and view.front.connection != nil:
    let client = view.front.connection.client
    if client.snapshot.phase in {Ended, Desynced} or view.session.done:
      view.returnPending = true
      view.syncMatchScreen()
      return
  view.session.finish()
  view.front.leave()
  view.screen = MenuScreen
  if view.musicSource != nil:
    view.musicSource.stop()

proc syncResults(view: View, now: float64) =
  ## Drain Ended history first, then show the authoritative final world even if
  ## local playback was paused on a historical clone.
  let interrupted = view.session.networked and view.front.connection != nil and
    (view.front.connection.client.snapshot.phase == Desynced or
      (view.front.connection.client.snapshot.phase == Ended and
        view.front.connection.client.applied >= view.front.connection.client.serverTick))
  if view.session.networked and (view.session.done or interrupted):
    view.session.returnToLive()
  let world = view.session.world
  view.screen = if world.winner >= 0 or world.tick >= view.session.maximumTicks or interrupted:
    EndScreen else: GameScreen
  if view.screen == EndScreen:
    view.matchMenu = HiddenMatchMenu
  view.card.update(view.screen == EndScreen, now)

proc drawMenu(view: View) =
  ## Reproduces the original title, menu arrangement, and author credit.
  view.text("Title", "galcon 2006", vec2(0, 8), Green, centered = true)
  for i, item in MainMenuItems:
    view.text("Menu", item, vec2(0, 120 + i.float32 * 46),
      if i == view.selection: White else: Gray, centered = true)
  view.text("Hud", "ludum dare #8 - phil hassey", vec2(0, 440), Gray,
    centered = true)

proc drawShips(view: View) {.measure.} =
  ## Draws the original hollow triangular ships with fixed simulation headings.
  let world = view.session.world
  measurePush("ship_geometry")
  for i, body in world.bodies:
    if not body.active or body.kind != ShipBody:
      continue
    let
      heading = math.arctan2(
        (body.y - body.previousY).toFloat32,
        (body.x - body.previousX).toFloat32
      )
      blend = if interpolateVisuals and view.transport.player.playing:
        clamp(view.transport.player.accumulator * TickRate, 0.0'f, 1.0'f)
        else: 1.0'f
      center = view.offset + vec2(
        body.previousX.toFloat32 + (body.x - body.previousX).toFloat32 * blend,
        body.previousY.toFloat32 + (body.y - body.previousY).toFloat32 * blend
      )
      color = ownerColor(world.ships[i].owner)
      a = center + vec2(math.cos(heading), math.sin(heading)) * 6
      back = center - vec2(math.cos(heading), math.sin(heading)) * 3
      side = vec2(-math.sin(heading), math.cos(heading)) * 3
      b = back + side
      c = back - side
    view.line(a, b, color)
    view.line(b, c, color)
    view.line(c, a, color)
  measurePop()
  measurePush("effect_sprites")
  let particle = view.sk.atlas.entries["Particle"]
  for effect in view.effects.particles:
    let frame = effect.frame(world.tick)
    if frame >= 33:
      continue
    let alpha =
      if frame > 25: clamp(255 - (frame - 25) * 31, 0, 255).uint8
      else: 255'u8
    let position = effect.position(world.tick)
    let size = vec2(particle.width.float32, particle.height.float32) /
      ArtScale.float32
    view.sk.drawRasterImage("Particle", view.offset + vec2(
      position.x.toFloat32 - size.x / 2,
      position.y.toFloat32 - size.y / 2
    ), size, rgbx(alpha, alpha, alpha, alpha))
  measurePop()

proc drawChat(view: View) =
  ## Fits the newest global messages inside the sidebar, outside the playfield.
  let
    world = view.session.world
    panel = view.presentation.sidebar
    width = panel.size.x - 24
    top = panel.origin.y + 52 + world.setup.players.float32 * PlayerListRowHeight
  var bottom = panel.origin.y + panel.size.y - 16
  if view.chatting:
    bottom -= 48
    discard view.sk.drawRasterText("Chat", "Global: " & view.chatInput & "|",
      vec2(panel.origin.x + 12, bottom + 8), White,
      maxWidth = width, maxHeight = 40, wordWrap = true)
  for i in countdown(world.chatCount - 1, max(0, world.chatCount - 5)):
    let
      message = world.chats[(world.chatFirst + i) mod MaxChatLines]
      value = view.session.displayName(message.player.int) & ": " & message.chatText()
      firstVertex = view.sk.drawer.layers[NormalLayer].len
      available = min(58.0'f, bottom - top)
    if available < 16:
      break
    let size = view.sk.drawRasterText("Chat", value,
      vec2(panel.origin.x + 12, top), ownerColor(message.player.int),
      maxWidth = width, maxHeight = available, wordWrap = true)
    let height = min(size.y, available)
    for vertex in firstVertex ..< view.sk.drawer.layers[NormalLayer].len:
      view.sk.drawer.layers[NormalLayer][vertex].pos.y += bottom - top - height
      view.sk.drawer.layers[NormalLayer][vertex].clipPos.y += bottom - top - height
    bottom -= height + 8

proc disc(view: View, center: Vec2, radius: float32, color: ColorRGBX) =
  ## Fills a faction marker with the existing solid-color triangle batch.
  let
    uv = view.sk.atlas.entries[WhiteTileKey]
    sample = vec2(uv.x.float32 + 8, uv.y.float32 + 8)
  var previous = center + vec2(radius, 0)
  for i in 1 .. 32:
    let
      angle = i.float32 * PI.float32 / 16
      next = center + vec2(math.cos(angle), math.sin(angle)) * radius
    view.sk.drawTriangle([center, previous, next],
      [sample, sample, sample], [color, color, color])
    previous = next

proc fitText(view: View, font, value: string, width: float32): string =
  ## Bounds public player labels without cutting a UTF-8 codepoint.
  if view.sk.rasterTextSize(font, value).x <= width:
    return value
  result = value
  while result.len > 0:
    var ending = result.len - 1
    while ending > 0 and (result[ending].ord and 0xc0) == 0x80:
      dec ending
    result.setLen(ending)
    if view.sk.rasterTextSize(font, result & "...").x <= width:
      return result & "..."

proc cardPanel(
    view: View, origin, size: Vec2,
    color = rgbx(2, 12, 25, 225)
) =
  ## Fills a softly rounded panel without a border or overlapping alpha.
  let
    center = origin + size / 2
    corners = [
      origin + vec2(size.x - 8, 8),
      origin + size - vec2(8),
      origin + vec2(8, size.y - 8),
      origin + vec2(8)
    ]
    uv = view.sk.atlas.entries[WhiteTileKey]
    sample = vec2(uv.x.float32 + 8, uv.y.float32 + 8)
    first = corners[0] + vec2(0, -8)
  var previous = first
  for k, corner in corners:
    for i in 0 .. 8:
      let
        angle = (k - 1).float32 * PI.float32 / 2 +
          i.float32 * PI.float32 / 16
        point = corner + vec2(math.cos(angle), math.sin(angle)) * 8
      view.sk.drawTriangle([center, previous, point],
        [sample, sample, sample], [color, color, color])
      previous = point
  view.sk.drawTriangle([center, previous, first],
    [sample, sample, sample], [color, color, color])

proc drawSidebar(view: View) {.measure.} =
  ## Keeps player identities, totals, and chat beside the map at every resolution.
  if view.card.shown or view.screen == TutorialScreen:
    return
  let
    world = view.session.world
    sample = view.summary.samples[world.tick]
    panel = view.presentation.sidebar
    origin = panel.origin + vec2(12)
  view.sk.pushClipRect(rect(panel.origin, panel.size))
  view.sk.drawRect(panel.origin, panel.size, rgbx(4, 7, 15, 235))
  discard view.sk.drawRasterText("Players", "players", origin, Green)
  for owner in 1 .. world.setup.players:
    if view.rosterLabels[owner].len == 0:
      view.rosterLabels[owner] = view.fitText(
        "Players", view.session.displayName(owner), panel.size.x - 100
      )
    if view.rosterValues[owner].len == 0 or
      view.rosterCounts[owner] != sample.ships[owner]:
        view.rosterCounts[owner] = sample.ships[owner]
        view.rosterValues[owner] = $sample.ships[owner]
        view.rosterWidths[owner] = view.sk.rasterTextSize(
          "Players", view.rosterValues[owner]
        ).x
    let
      point = origin + vec2(0, 28 + (owner - 1).float32 * PlayerListRowHeight)
      tint = ownerColor(owner)
    view.disc(point + vec2(5, 7), 4, tint)
    discard view.sk.drawRasterText("Players", view.rosterLabels[owner],
      point + vec2(18, 0), tint)
    discard view.sk.drawRasterText("Players", view.rosterValues[owner],
      vec2(panel.origin.x + panel.size.x - 12 - view.rosterWidths[owner], point.y), tint)
  view.drawChat()
  view.sk.popClipRect()

proc resultButton(view: View): Rect =
  ## Board-space hit target shared by drawing and native/browser input.
  let height = 142.0'f + min(38.0'f, 310.0'f / view.session.world.setup.players.float32) * view.session.world.setup.players.float32
  rect(180, (Height.float32 + height) / 2 - 54, 280, 40)

proc drawCard(view: View) {.measure.} =
  ## Draws the approved borderless native-font card on one shared ship scale.
  if not view.card.shown:
    return
  let
    world = view.session.world
    tick = world.tick
    players = world.setup.players
    rowHeight = min(38.0'f, 310.0'f / players.float32)
    height = (if view.card.terminal: 142.0'f else: 86.0'f) + rowHeight * players.float32
    origin = vec2(36, (Height.float32 - height) / 2)
    title = view.session.resultTitle(interrupted = view.card.terminal)
    color = if world.winner > 0: ownerColor(world.winner) else: White
    font = if players > 10: "ScoreSmall" else: "Score"
    sample = view.summary.samples[tick]
    maximum = max(sample.maximum, 1).float64
  view.sk.drawRect(view.offset, vec2(Width, Height), rgbx(0, 0, 0, 48))
  view.cardPanel(view.offset + origin, vec2(568, height))
  let heading = view.fitText("ScoreTitle", title, 528)
  let headingWidth = view.sk.rasterTextSize("ScoreTitle", heading).x
  view.text("ScoreTitle", heading,
    vec2((Width.float32 - headingWidth) / 2, origin.y + 20), color)
  for owner in 1 .. players:
    let
      y = origin.y + 70 + (owner - 1).float32 * rowHeight
      tint = ownerColor(owner)
      label = view.fitText(font, view.session.displayName(owner), 200)
      value = $sample.ships[owner]
      valueWidth = view.sk.rasterTextSize(font, value).x
      endTick =
        if view.summary.eliminated[owner] >= 0:
          min(tick, view.summary.eliminated[owner])
        else:
          tick
      stride = max(1, tick div 210)
      graph = vec2(282, y - rowHeight * 0.32'f)
      graphHeight = rowHeight * 0.72'f
    view.disc(view.offset + vec2(56, y), 6, tint)
    view.text(font, label, vec2(73, y - 9), tint)
    view.text(font, value, vec2(588 - valueWidth, y - 9), tint)
    var
      at = 0'i32
      previous: Vec2
      first = true
    while true:
      let point = view.offset + graph + vec2(
        at.float32 / max(tick, 1).float32 * 236,
        graphHeight * (1 -
          (view.summary.samples[at].ships[owner].float64 / maximum).float32)
      )
      if not first:
        view.line(previous, point, tint, 1.5'f)
      previous = point
      first = false
      if at == endTick:
        break
      at = min(at + stride, endTick)

  if view.card.terminal:
    let button = view.resultButton()
    view.cardPanel(view.offset + button.xy, button.wh, rgbx(24, 66, 44, 255))
    let label = if view.returnPending and view.session.networked:
      if view.front.connection.client.participant == view.front.connection.client.snapshot.participant:
        "Returning to Lobby..."
      else: "Waiting for host..."
    elif view.session.networked: "Return to Lobby"
    else: "Return to Menu"
    let width = view.sk.rasterTextSize("Score", label).x
    view.text("Score", label, vec2((Width.float32 - width) / 2, button.y + 10), White)

proc drawGame(view: View) {.measure.} =
  ## Paints 2D art, translucent effects, transparent counts, and the LD8 HUD.
  view.updateBoard()
  measurePush("background_and_planet_sprites")
  view.sk.drawRasterImage("Background", view.offset, vec2(Width, Height))
  for i, planet in view.session.world.planets:
    let
      entry = view.sk.atlas.entries[view.planetSprites[i]]
      size = vec2(entry.width.float32, entry.height.float32) /
        ArtScale.float32
      center = view.offset + vec2(planet.x.toFloat32, planet.y.toFloat32)
    view.sk.drawRasterImage(view.planetSprites[i], center - size / 2, size)
  measurePop()
  view.drawShips()
  let
    world = view.session.world
    compact = world.setup.placement == ClusteredPlacement or
      world.planets.len > CompactPlanetThreshold
  view.controls.clean(world)
  let selectionColor = ownerColor(max(view.session.human, 1))
  var
    selected = 0
    sending = 0
  for i, planet in world.planets:
    let center = view.offset + vec2(planet.x.toFloat32, planet.y.toFloat32)
    if view.controls.selected[i]:
      inc selected
      sending += roundedRatio(planet.ships * view.controls.percent,
        FixedScale * 100).int
      view.ring(center, planet.radius.float32 + 4, selectionColor)
      if view.controls.holding and not view.controls.box:
        let target =
          if view.controls.hover >= 0:
            let p = world.planets[view.controls.hover]
            view.offset + vec2(p.x.toFloat32, p.y.toFloat32)
          else:
            view.offset + vec2(view.controls.x.float32, view.controls.y.float32)
        view.line(center, target, selectionColor, 1.5'f)
    if view.stat != 3:
      let value =
        case view.stat
        of 1: planet.production
        of 2: planet.morale
        else: planet.shipCount
      let label = $value
      view.text(if compact: "TinyNumbers" else: "Numbers", label,
        vec2(planet.x.toFloat32 - label.len.float32 *
          (if compact: 2.4'f else: 3.7'f),
          planet.y.toFloat32 - (if compact: 5.0'f else: 8.0'f)), White)
  if view.controls.holding and view.controls.box and view.controls.moved:
    let
      a = view.offset + vec2(min(view.controls.startX, view.controls.x).float32,
        min(view.controls.startY, view.controls.y).float32)
      b = view.offset + vec2(max(view.controls.startX, view.controls.x).float32,
        max(view.controls.startY, view.controls.y).float32)
    view.line(a, vec2(b.x, a.y), Green)
    view.line(vec2(b.x, a.y), b, Green)
    view.line(b, vec2(a.x, b.y), Green)
    view.line(vec2(a.x, b.y), a, Green)
  if view.controls.hover >= 0 and not view.card.shown:
    let p = world.planets[view.controls.hover]
    view.text("Hover", p.name & "   Prod: " & $p.production &
      "   Morale: " & $p.morale & "   Ships: " & $p.shipCount,
      vec2(8, 6), Green,
      maxWidth = Width.float32 - 16)
  if view.session.human > 0 and not view.session.inHistory:
    let status =
      "From: " & $selected & "   Ships: " & $sending &
        " (" & $view.controls.percent & "%)"
    view.text("Hover", status, vec2(8, 450), selectionColor, maxWidth = 300)
  case view.screen
  of TutorialScreen:
    view.centeredLines("tutorial #" & $view.tutorial,
      TutorialTexts[view.tutorial - 1])
  of EndScreen:
    discard
  else:
    if not view.card.shown and not view.transport.player.playing and
      view.transport.player.targetTick < 0:
        view.text("Hud", "paused", vec2(0, 36), centered = true)
  if view.screen != TutorialScreen:
    view.drawCard()

proc drawMatchMenu(view: View) =
  ## A separate shared Silky overlay pass leaves the game framebuffer intact.
  if view.matchMenu == HiddenMatchMenu:
    return
  let size = if view.matchMenu == GameSettings: vec2(976, 700) else: vec2(480, 360)
  view.sk.uiScale = view.front.settingsScale(selectedUiScale(max(0.1'f, min(
    view.window.size.x.float32 / 1000, view.window.size.y.float32 / 800)),
    1080.0'f / 800))
  view.sk.beginUi(view.window, view.window.size)
  view.sk.textStyle = "Default"
  let available = view.window.size.vec2 / view.sk.uiScale
  view.sk.drawRect(vec2(0), available, rgbx(0, 0, 0, 110))
  let at = (available - size) / 2
  view.sk.lobbyPanel(at, size)
  let origin = at + vec2(32)
  try:
    case view.matchMenu
    of HiddenMatchMenu: discard
    of GameSettings:
      if view.front.settings(view.sk, view.window, at + vec2(48, 48)):
        view.matchMenu = GameMenu
    of ConfirmLeave:
      view.sk.lobbyLabel("Leave game?", origin, 416, "LobbyHeading")
      view.sk.lobbyLabel("Are you sure you want to leave?", origin + vec2(0, 64), 416)
      view.sk.lobbyLabel("The game is still running.", origin + vec2(0, 104), 416)
      if view.sk.lobbyButton("Cancel", origin + vec2(0, 176), 416):
        view.matchMenu = GameMenu
      elif view.sk.lobbyButton("Leave game", origin + vec2(0, 240), 416):
        view.returnToMenu()
    of GameMenu:
      view.sk.lobbyLabel("Game Menu", origin, 416, "LobbyHeading")
      view.sk.lobbyLabel("Game continues in the background", origin + vec2(0, 48), 416)
      if view.sk.lobbyButton("Resume", origin + vec2(0, 104), 416):
        view.matchMenu = HiddenMatchMenu
      elif view.sk.lobbyButton("Settings", origin + vec2(0, 168), 416):
        view.matchMenu = GameSettings
      elif view.sk.lobbyButton("Leave game", origin + vec2(0, 232), 416):
        view.matchMenu = ConfirmLeave
  except GalconError, RoomsError, MenusError, IOError, OSError:
    view.front.error = getCurrentExceptionMsg()
  if view.front.error.len > 0:
    view.sk.lobbyLabel(view.front.error, at + vec2(32, size.y - 38), size.x - 64)
  view.sk.endUi()

proc debugStats(view: View): NetworkStats =
  ## Pass the live reference: shared simulator widgets edit this connection.
  if view.session != nil and view.session.networked and
      view.front.connection != nil:
    result = view.front.connection.stats

proc drawDiagnostics(view: View) =
  ## Separate screen-space pass: never transform shared widgets into board space.
  if not debugMenuOpen:
    # Keep shared FPS history warm without committing an empty UI interactor.
    view.sk.drawDebugMenu(view.window, network = view.debugStats())
    return
  let scale = view.sk.uiScale
  view.sk.uiScale = selectedUiScale(max(0.1'f, min(
    view.window.size.x.float32 / 1000, view.window.size.y.float32 / 800)),
    1080.0'f / 800)
  view.sk.beginUi(view.window, view.window.size)
  view.sk.textStyle = "Default"
  view.sk.drawDebugMenu(view.window, network = view.debugStats())
  if debugMenuOpen and view.debugStats() != nil:
    let client = view.front.connection.client
    view.sk.drawLabel("Latest server tick " & $client.serverTick &
      " | Applied " & $client.applied &
      " | Backlog " & $max(0'i64, client.serverTick.int64 - client.applied.int64) &
      " | Displayed " & $view.session.world.tick,
      vec2(16, 4), vec2(1100, 28), White, "Default")
  view.sk.endUi()
  view.sk.uiScale = scale

proc drawSendSlider(view: View) =
  ## Convert the HUD track once, after board vertices have been transformed.
  if view.screen != GameScreen: return
  let enabled = not view.chatting and not view.card.shown and
    not debugMenuOpen and not view.diagnosticsOwnInput and
    view.matchMenu == HiddenMatchMenu and
    view.session != nil and view.session.human > 0 and
    not view.session.inHistory and not view.session.done
  let at = view.presentation.boardOrigin + vec2(320, 444) * view.presentation.boardScale
  view.front.localPercentSlider(view.sk, view.window, 100,
    view.controls.percent, rect(at, vec2(300, 28) * view.presentation.boardScale), enabled)

proc installPointerCapture(view: View) =
  when defined(emscripten):
    # Game-local pointer capture preserves canvas-origin drags outside it.
    # Shared Windy input and ordinary UI wheel scrolling remain untouched.
    {.emit: """
    EM_ASM({
      var canvas = Module.canvas;
      canvas.addEventListener('pointerdown', function(e) {
        if (e.pointerType === 'mouse') {
          try { canvas.setPointerCapture(e.pointerId); } catch (_) {}
        }
      });
      window.addEventListener('mouseup', function(e) {
        if (e.target !== canvas && (e.button === 0 || e.button === 2)) {
          canvas.dispatchEvent(new MouseEvent('mouseup', {
            button:e.button, buttons:e.buttons, clientX:e.clientX,
            clientY:e.clientY, bubbles:true
          }));
        }
      });
    });
    """.}

proc handleInput(view: View) =
  ## Normalizes native input into logical integer Galcon controls.
  # Keep modal ownership through render-time widgets on the closing frame.
  view.diagnosticsOwnInput = debugMenuOpen
  let
    window = view.window
    game = view.screen in {GameScreen, TutorialScreen, EndScreen}
    pointer =
      if game:
        (window.mousePos.vec2 / view.sk.uiScale -
          view.presentation.boardOrigin) / view.presentation.boardScale
      else:
        window.mousePos.vec2 / view.sk.uiScale - view.offset
    x = floor(pointer.x).int
    y = floor(pointer.y).int
    onBoard = x in 0 ..< Width and y in 0 ..< Height
    commandPointer = onBoard and y < 440
    commands = view.screen == GameScreen and not view.chatting and
      not view.card.shown and view.session != nil and view.session.canCommand and
      view.transport.player.playing and view.transport.player.targetTick < 0
    percentageInput = view.screen == GameScreen and not view.chatting and
      not view.card.shown and view.session != nil and view.session.human > 0 and
      not view.session.inHistory and not view.session.done and commandPointer
    clicked = (if game: window.actionPressed(SelectInput)
      else: window.buttonPressed[MouseLeft]) and (not game or onBoard)
    entered = window.buttonPressed[KeyEnter]
    shift = window.actionDown(ShiftInput)

  if game and view.matchMenu != HiddenMatchMenu:
    view.controls.cancelGesture()
    view.front.cancelLocalPercent(100)
    if window.actionPressed(MenuInput) or window.buttonPressed[KeyEscape]:
      case view.matchMenu
      of GameSettings:
        if not view.front.cancelSettingsCapture():
          view.matchMenu = GameMenu
      of ConfirmLeave: view.matchMenu = GameMenu
      else: view.matchMenu = HiddenMatchMenu
    return
  if not commands:
    view.controls.cancelGesture()
  if view.chatting:
    if not view.session.canCommand or window.buttonPressed[KeyEscape]:
      view.chatting = false
      view.chatInput.setLen(0)
    elif entered:
      discard view.session.chat.sendChat(view.session.human, -2, view.chatInput)
      view.chatting = false
      view.chatInput.setLen(0)
    elif window.buttonPressed[KeyBackspace] and view.chatInput.len > 0:
      var last = view.chatInput.len - 1
      while last > 0 and (view.chatInput[last].ord and 0xc0) == 0x80:
        dec last
      view.chatInput.setLen(last)
    return
  if window.buttonPressed[KeyF1] or window.actionPressed(DebugInput):
    view.diagnosticsOwnInput = true
    debugMenuOpen = not debugMenuOpen
    view.controls.cancelGesture()
    view.front.cancelLocalPercent(100)
    return
  if debugMenuOpen and window.buttonPressed[KeyEscape]:
    debugMenuOpen = false
    view.controls.cancelGesture()
    view.front.cancelLocalPercent(100)
    return
  if view.diagnosticsOwnInput:
    view.controls.cancelGesture()
    view.front.cancelLocalPercent(100)
    return
  if entered and (window.buttonDown[KeyLeftAlt] or
    window.buttonDown[KeyRightAlt]):
      window.fullscreen = not window.fullscreen
      return
  if window.actionPressed(TraceInput):
    gameProfiles.toggleRuntimeTrace()
  if window.buttonPressed[KeyF3] and view.musicSource != nil:
    view.musicEnabled = not view.musicEnabled
    if view.musicEnabled and view.screen in {GameScreen, TutorialScreen}:
      view.musicSource.play()
    else:
      view.musicSource.stop()
  if window.actionPressed(FullscreenInput):
    window.fullscreen = not window.fullscreen
  if debugMenuOpen:
    view.controls.cancelGesture()
    view.front.cancelLocalPercent(100)
    return
  if view.screen == FrontScreen:
    return
  if view.screen in {GameScreen, TutorialScreen} and window.actionPressed(MenuInput):
    view.matchMenu = GameMenu
    view.controls.cancelGesture()
    view.front.cancelLocalPercent(100)
    return
  if view.screen == GameScreen and entered and view.session.canCommand:
    view.chatting = true
    view.controls.holding = false
    return
  if game:
    if window.buttonPressed[KeyTab]:
      view.card.toggle()
      view.controls.holding = false
    if window.actionPressed(PauseInput):
      view.transport.player.togglePlay()
      if view.session.networked and not view.transport.player.playing and
        not view.session.inHistory:
          view.session.world = view.session.liveWorld.clone()
      view.controls.holding = false
  case view.screen
  of MenuScreen:
    when not defined(emscripten):
      if window.buttonPressed[KeyEscape]: view.closing = true
    if window.buttonPressed[KeyDown]:
      view.selection = (view.selection + 1) mod MainMenuItems.len
    if window.buttonPressed[KeyUp]:
      view.selection = (view.selection + MainMenuItems.len - 1) mod MainMenuItems.len
    let overMenu = x in 80 .. 560 and y >= 120 and y < 120 + MainMenuItems.len * 46
    if overMenu and window.mouseDelta != ivec2(0, 0):
      view.selection = clamp((y - 120) div 46, 0, MainMenuItems.high)
    if entered or (clicked and overMenu):
      view.menuAction()
  of FrontScreen:
    discard
  of HelpScreen:
    if clicked or entered or window.buttonPressed[KeyEscape]:
      view.screen = MenuScreen
  of TutorialScreen:
    if clicked or entered:
      view.screen = GameScreen
  of EndScreen:
    if clicked and overlaps(vec2(x.float32, y.float32), view.resultButton()):
      view.returnToMenu()
      return
    if entered:
      if view.tutorial in 1 .. 2 and view.session.world.winner == 1:
        view.start(view.tutorial + 1)
      else:
        view.returnToMenu()
    if window.actionPressed(MenuInput):
      view.returnToMenu()
  of GameScreen:
    if view.front.localPercentCaptured(100):
      view.controls.cancelGesture()
      return
    if percentageInput:
      # This is a local UI preference, never an authoritative command.
      let keys = [Key0, Key1, Key2, Key3, Key4, Key5, Key6, Key7, Key8, Key9]
      for i, key in keys:
        if window.buttonPressed[key]:
          view.controls.percent = if i == 0: 100 else: i * 10
    let boxTracking = view.controls.holding and view.controls.box and
      not view.controls.ordering
    let tracking = view.controls.holding
    let selectionX = if tracking: clamp(x, 0, Width) else: x
    let selectionY = if tracking: clamp(y, 0, Height) else: y
    view.controls.point(view.session.world, selectionX, selectionY)
    if not commandPointer: view.controls.hover = -1
    if view.card.shown:
      return
    if view.session.canCommand and view.transport.player.playing and
      view.transport.player.targetTick < 0:
      if window.actionPressed(OrderInput) and commandPointer:
        view.controls.pressOrder(view.session.world, x, y)
      elif commandPointer and (clicked or window.buttonPressed[DoubleClick]):
        view.controls.press(view.session.world, x, y,
          window.buttonPressed[DoubleClick], shift)
      if ((view.controls.ordering and
        window.actionReleased(OrderInput)) or (not view.controls.ordering and
        window.actionReleased(SelectInput))):
        if not commandPointer and not boxTracking:
          view.controls.releaseOutside()
        elif view.controls.release(view.session.world, selectionX, selectionY,
          if view.session.networked: view.front.prepared.submit else: nil) > 0:
          view.launchSource.playSource()

proc capture(view: View) =
  ## Saves an actual Silky back-buffer screenshot for visual verification.
  let image = newImage(view.window.size.x, view.window.size.y)
  glReadPixels(0, 0, image.width.GLsizei, image.height.GLsizei,
    GL_RGBA, GL_UNSIGNED_BYTE, image.data[0].addr)
  image.flipVertical()
  image.writeFile(view.options.screenshot)
  view.closing = true

proc layout(view: View) =
  ## Separates board scaling from the shared transport's logical coordinates.
  if view.screen in {GameScreen, TutorialScreen, EndScreen}:
    view.presentation = presentation(
      view.window.size.vec2,
      showTransport = view.session.playback
    )
    view.sk.uiScale = view.presentation.uiScale
    view.offset = vec2(0)
  else:
    view.sk.uiScale = min(view.window.size.x.float32 / Width,
      view.window.size.y.float32 / Height)
    let logicalSize = view.window.size.vec2 / view.sk.uiScale
    view.offset = (logicalSize - vec2(Width, Height)) / 2

proc frame(view: View) =
  ## Advances deterministic ticks through Polyworld's bounded transport loop.
  let
    now = getMonoTime()
    elapsed = min(0.25, (now - view.lastTime).inNanoseconds.float64 / 1e9)
    frameStart = epochTime()
  view.lastTime = now
  if view.musicSource != nil:
    let volume = if view.front.preferences.soundMuted: 0.0'f
      else: view.front.preferences.mainVolume.float32 / 100
    view.musicSource.gain = volume * view.front.preferences.musicVolume.float32 / 100
    for source in [view.launchSource, view.blastSource, view.captureSource]:
      source.gain = volume * view.front.preferences.fxVolume.float32 / 100
  when not defined(emscripten):
    view.window.updateWindowSettings()
  # Consume gameplay/UI input before draining a potentially expensive network
  # backlog. The percentage is visible this frame without waiting for any tick.
  let inputHandled = view.screen == GameScreen
  if inputHandled:
    view.layout()
    view.handleInput()
  try:
    view.front.pump()
    view.syncMatchScreen()
    if view.front.launch != nil:
      let next = view.front.launch
      view.front.launch = nil
      view.start(provided = next)
    if view.session != nil and view.session.networked:
      let match = view.front.prepared
      if not view.transport.player.playing and
        view.transport.player.targetTick < 0 and not view.session.inHistory:
          view.session.world = view.session.liveWorld.clone()
      var packet: RoomMessage
      for i in 0 ..< 8:
        if match == nil or match.finished or
          not view.front.connection.takeTick(packet, TickRate):
            break
        match.applyPacket(packet)
  except GalconError, RoomsError:
    view.front.error = getCurrentExceptionMsg()
    if view.front.prepared != nil:
      view.front.prepared.abort(view.front.error)
  if view.screen == FrontScreen:
    view.front.draw(view.sk, view.window)
    if view.front.page == HomeMenu:
      view.screen = MenuScreen
    inc view.frames
    if view.options.screenshot.len > 0 and view.frames >= view.options.frames:
      view.capture()
    view.window.presentFrame(framePaceHz)
    reportReplayFrame(0, 0)
    return
  view.layout()
  if view.screen == MenuScreen and view.front.nameDialogOpen():
    view.sk.beginUi(view.window, view.window.size)
    view.sk.clearScreen(rgbx(0, 0, 0, 255))
    view.sk.drawRasterCover("Background", vec2(0),
      view.window.size.vec2 / view.sk.uiScale)
    discard view.front.identityUi(view.sk, view.window)
    view.sk.endUi()
    view.window.presentFrame(framePaceHz)
    reportReplayFrame(0, 0)
    return
  if not inputHandled:
    view.handleInput()
  view.layout()
  if view.screen in {GameScreen, EndScreen}:
    if view.transport.player.restoreTick >= 0:
      view.effects.clear()
    if view.transport.advancePlayback(
      view.session,
      elapsed.float32,
      frameStart,
      singleTick = view.options.screenshot.len > 0,
      holdAtEnd = not view.card.terminal or
        view.card.holding(now.ticks.float64 / 1e9)
    ):
      view.controls.holding = false
      view.boardRevision = -1
    view.syncResults(getMonoTime().ticks.float64 / 1e9)
    let world = view.session.world
    if not view.session.inHistory:
      if world.captures > view.seenCaptures:
        view.captureSource.playSource()
      elif world.impacts > view.seenImpacts:
        view.blastSource.playSource()
    view.seenCaptures = world.captures
    view.seenImpacts = world.impacts
  # The background and modal are separate Silky passes. Only the modal may
  # retain previous-frame hover ownership while it is open; the background
  # must neither consume its IDs nor interact with clicks through the panel.
  let modalInteractions = view.sk.interactor
  if view.matchMenu != HiddenMatchMenu or debugMenuOpen:
    view.sk.interactor = Interactor()
  view.sk.beginUi(view.window, view.window.size)
  view.sk.clearScreen(rgbx(0, 0, 0, 255))
  if view.screen in {MenuScreen, HelpScreen}:
    view.sk.drawRasterCover("Background", vec2(0),
      view.window.size.vec2 / view.sk.uiScale)
  view.sk.pushClipRect(rect(view.offset, vec2(Width, Height)))
  case view.screen
  of MenuScreen: view.drawMenu()
  of FrontScreen: discard
  of HelpScreen:
    view.centeredLines("help", HelpText)
  else: view.drawGame()
  view.sk.popClipRect()
  if view.screen == MenuScreen:
    discard view.front.identityUi(view.sk, view.window)
  if view.screen in {GameScreen, TutorialScreen, EndScreen}:
    for vertex in view.sk.drawer.layers[NormalLayer].mitems:
      vertex.pos = view.presentation.boardOrigin +
        vertex.pos * view.presentation.boardScale
      vertex.clipPos = view.presentation.boardOrigin +
        vertex.clipPos * view.presentation.boardScale
      vertex.clipSize *= view.presentation.boardScale
    view.drawSidebar()
    view.drawSendSlider()
    view.transport.sync(view.session)
    let serial = view.transport.player.seekSerial
    if view.session.networked and view.front.connection != nil:
      let status = view.front.connection.status()
      if not view.front.connection.client.connected or view.front.error.len > 0:
        view.sk.drawLabel(if view.front.error.len > 0: view.front.error else: status,
          vec2(16, 4), vec2(1100, 34), rgbx(255, 180, 100, 255), "Default")
    if view.session.playback and view.matchMenu == HiddenMatchMenu and
        not debugMenuOpen and not view.diagnosticsOwnInput:
      view.transport.drawTransport(
        view.sk, view.window, view.presentation.panel
      )
    if serial != view.transport.player.seekSerial:
      view.controls.holding = false
  view.sk.endUi()
  if view.matchMenu != HiddenMatchMenu or debugMenuOpen:
    view.sk.interactor = modalInteractions
  view.drawMatchMenu()
  if view.matchMenu == HiddenMatchMenu:
    view.drawDiagnostics()
  view.window.runeInputEnabled = view.chatting or view.matchMenu == GameSettings
  inc view.frames
  if view.options.screenshot.len > 0 and view.frames >= view.options.frames:
    view.capture()
  view.window.presentFrame(framePaceHz)
  when defined(emscripten) and defined(galconBrowserProbe):
    # Test-only, read-only snapshots. No gameplay or room mutation exports.
    if view.session != nil:
      let w = view.session.liveWorld
      var ships: seq[string]
      for i, b in w.bodies:
        if b.active and b.kind == ShipBody:
          ships.add("[" & $i & "," & $w.ships[i].owner & "," &
            $b.x.toFloat32 & "," & $b.y.toFloat32 & "]")
      let snapshot = "{\"tick\":" & $w.tick & ",\"human\":" &
        $view.session.human & ",\"ships\":[" & ships.join(",") & "]}"
      let raw = snapshot.cstring
      {.emit: """
      EM_ASM({ if (new URLSearchParams(location.search).get('qa') === '1' && Module.polyworldGalconProbe) Module.polyworldGalconProbe(JSON.parse(UTF8ToString($0))); }, `raw`);
      """.}
  reportReplayFrame(
    if view.session == nil: 0'i32 else: view.session.world.tick, 0
  )

proc installChatInput(view: View) =
  ## Installs the same rune callback for native and browser windows.
  view.window.onRune = proc(rune: Rune) =
    if view.chatting and view.matchMenu == HiddenMatchMenu and
      not debugMenuOpen and not view.diagnosticsOwnInput and
      rune.int32 in 32 .. 0x10ffff and
      rune.int32 notin 127 .. 159 and rune.int32 notin 0xd800 .. 0xdfff:
      let value = rune.toUTF8()
      if view.chatInput.len + value.len <= MaxChatBytes - 16:
        view.chatInput.add value

proc runGraphics*(options: Options) =
  ## Opens a local Silky 2D window with the original assets and BASIC opponents.
  let
    size =
      if options.game.windowWidth > 0:
        ivec2(options.game.windowWidth, options.game.windowHeight)
      else: ivec2(960, 720)
    window = newWindow("Galcon 2006", size,
      vsync = options.game.vsync)
  window.makeContextCurrent()
  loadExtensions()
  let
    builder = newAtlasBuilder(4096, 8)
    paints = newPaints(MaxPlanets)
  doAssert builder.addImage("Background", paints.background)
  doAssert builder.addImage("Particle", paints.particle)
  builder.addRasterFont(Assets / "SAVEDBYZ.TTF", "Title", 80,
    @["g", "a", "l", "c", "o", "n", " ", "2", "0", "6"])
  builder.addRasterFont(Assets / "zeroes_3.ttf", "Menu", 36)
  builder.addRasterFont(Assets / "zeroes_3.ttf", "Hud", 24)
  builder.addRasterFont(Assets / "zeroes_3.ttf", "Small", 20)
  builder.addRasterFont(Assets / "zeroes_3.ttf", "Hover", 16)
  builder.addRasterFont(Assets / "zeroes_3.ttf", "ScoreTitle", 24)
  builder.addRasterFont(Assets / "zeroes_3.ttf", "Score", 14)
  builder.addRasterFont(Assets / "zeroes_3.ttf", "ScoreSmall", 10)
  builder.addRasterFont(Assets / "zeroes_3.ttf", "Players", 14)
  builder.addRasterFont(Assets / "zeroes_3.ttf", "Numbers", 14)
  builder.addRasterFont(Assets / "zeroes_3.ttf", "TinyNumbers", 9)
  builder.addRasterFont(Assets / "transport" / "Rubik-Regular.ttf", "Chat", 13)
  builder.addTransportAssets()
  builder.addMenuAssets()
  let particle = builder.atlas.entries["Particle"]
  for y in 0 ..< paints.particle.height:
    for x in 0 ..< paints.particle.width:
      let pixel = paints.particle[x, y]
      # Zero coverage with emissive RGB gives the original additive sparks.
      builder.atlasImage[particle.x + x, particle.y + y] =
        rgbx(pixel.r, pixel.g, pixel.b, 0)
  let view = View(
    front: newFrontend(options),
    window: window,
    sk: newSilky(window, builder.atlasImage, builder.atlas),
    paints: paints,
    options: options,
    difficulty: options.setup.difficulty,
    screen: MenuScreen,
    selection: 1,
    lastTime: getMonoTime()
  )
  view.sk.builder = builder
  view.sk.theme = galconTheme()
  view.front.preferences.applyPreferences(window, options.game.windowWidth == 0)
  if view.front.page != HomeMenu:
    view.screen = FrontScreen
  # All connection entry routes go through the identity-gated frontend pump.
  # Invite/autoconnect startup must not open a socket before confirmation.
  view.initSounds()
  view.installChatInput()
  view.installPointerCapture()
  if options.start:
    view.start(options.setup.tutorial)
  window.onButtonPress = proc(button: Button) =
    ## Applies the shared UI scale shortcuts to menu screens.
    if view.screen == FrontScreen:
      discard window.scaleKey(button, view.front.preferences,
        view.sk.uiScale, AppName)
  window.onFrame = proc() =
    ## Presents one interactive game frame.
    view.frame()
  while not window.closeRequested and not view.closing:
    pollEvents()

  view.front.leave()
  if view.session != nil:
    view.session.observer = nil
    view.session.tickObserver = nil
    view.session.finish()
  for source in [view.musicSource, view.launchSource, view.blastSource,
    view.captureSource]:
      if source != nil:
        source.stop()
  window.close()
