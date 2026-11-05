import
  std/os,
  chroma, pixie, silky, vmath,
  polyworld/[player, gameuis, chrome],
  common, sessions, rasters

export player, gameuis

const
  TransportAssets = Assets / "transport"
  ControlIcons = [
    "skip_to_start", "previous_frame", "play", "next_frame", "skip_to_end"
  ]
  SpeedIcons = ["speed_1x", "speed_2x", "speed_4x", "speed_16x"]
  GlyphColor = rgbx(226, 230, 239, 255)
  GlyphActive = rgbx(235, 216, 154, 255)

type
  Transport* = object
    player*: Player
    dragging*: bool
  Presentation* = object
    uiScale*, boardScale*: float32
    boardOrigin*: Vec2
    panel*, sidebar*: GameUiPanel

proc presentation*(size: Vec2, showTransport = true): Presentation =
  ## Fits the board and sidebar, reserving a bottom ribbon only for replays.
  result.uiScale = min(size.x / 1360, size.y / 600)
  result.uiScale = max(result.uiScale, 0.01'f)
  let
    logical = size / result.uiScale
    transportHeight = if showTransport: TransportHeight else: 0.0'f
    available = vec2(logical.x, max(logical.y - transportHeight, 1))
    sidebarWidth = 300.0'f
    gap = 16.0'f
  result.boardScale = min(
    max(1.0'f, available.x - sidebarWidth - gap) / 640,
    available.y / 480
  )
  let
    boardSize = vec2(640, 480) * result.boardScale
    origin = (available - vec2(sidebarWidth + gap + boardSize.x, boardSize.y)) / 2
  result.sidebar = GameUiPanel(origin: origin, size: vec2(sidebarWidth, boardSize.y))
  result.boardOrigin = origin + vec2(sidebarWidth + gap, 0)
  result.panel = GameUiPanel(
    origin: vec2(0, available.y),
    size: vec2(logical.x, transportHeight)
  )

proc sync*(transport: var Transport, session: Session) =
  ## Reports the displayed state and complete recorded frontier to the player.
  let world = session.world
  let over = world.winner >= 0 or world.tick >= session.maximumTicks
  transport.player.sync(world.tick, session.recordedTicks, over)

proc advancePlayback*(
    transport: var Transport,
    session: Session,
    elapsed: float32,
    frameStart: float64,
    singleTick = false,
    holdAtEnd = false
): bool =
  ## Restores before synchronizing so backward seeks retain their target tick.
  let restore = transport.player.takeRestore()
  result = restore >= 0
  if result:
    session.restoreTo(restore)
  transport.sync(session)
  if holdAtEnd and transport.player.over:
    return
  transport.player.startFrame(elapsed, TickRate)
  if singleTick and transport.player.playing and
    transport.player.targetTick < 0:
      transport.player.accumulator = 1.0'f / TickRate
  while transport.player.shouldTick(frameStart):
    if session.networked and not session.inHistory:
      break
    session.step()
    transport.sync(session)
    if holdAtEnd and transport.player.over:
      break

proc addTransportAssets*(builder: AtlasBuilder) =
  ## Adds Polyworld's CC0 transport art and the separately licensed Rubik font.
  for name in ControlIcons:
    doAssert builder.addImage(
      name,
      readImage(TransportAssets / (name & ".png"))
    )
  for name in SpeedIcons:
    doAssert builder.addImage(
      name,
      readImage(TransportAssets / (name & ".png"))
    )
  for name in ["pause", "loop", "frame.pureblack.9patch",
    "bartrack.9patch", "barfill.9patch"]:
      doAssert builder.addImage(
        name,
        readImage(TransportAssets / (name & ".png"))
      )
  builder.addRasterFont(TransportAssets / "Rubik-Regular.ttf", "Transport", 15)

proc drawIcon(sk: Silky, panel: GameUiPanel, name: string, active = false) =
  ## Draws the shared Polyworld glyph in its original 64-pixel hit target.
  let uv = sk.atlas.entries[name]
  sk.drawQuad(
    panel.origin + vec2(8),
    vec2(48),
    vec2(uv.x.float32, uv.y.float32),
    vec2(uv.width.float32, uv.height.float32),
    if active: GlyphActive else: GlyphColor
  )

proc drawTransport*(
    transport: var Transport,
    sk: Silky,
    window: Window,
    panel: GameUiPanel
) =
  ## Draws Polyworld's playback controls and timeline in the 2D client.
  sk.drawRibbon(panel)
  let
    slots = panel.transportPanels()
    playing = transport.player.playing or transport.player.targetTick >= 0
    pressed = window.buttonPressed[MouseLeft]
  for i, slot in slots.controls:
    let name = if i == 2 and playing: "pause" else: ControlIcons[i]
    sk.drawIcon(slot, name)
    if pressed and slot.contains(sk.mousePos):
      case i
      of 0: transport.player.skipToStart()
      of 1: transport.player.stepBack()
      of 2: transport.player.togglePlay()
      of 3: transport.player.stepForward()
      of 4: transport.player.skipToEnd()
  sk.drawIcon(slots.loop, "loop", transport.player.repeating)
  if pressed and slots.loop.contains(sk.mousePos):
    transport.player.repeating = not transport.player.repeating
  for i, slot in slots.speeds:
    sk.drawIcon(slot, SpeedIcons[i], transport.player.speedIndex == i)
    if pressed and slot.contains(sk.mousePos):
      transport.player.setSpeed(i)
  let endTick = max(transport.player.timelineEnd, 1).float32
  sk.drawBar(
    slots.scrub.origin,
    slots.scrub.size,
    transport.player.tick.float32,
    endTick,
    rgbx(96, 132, 190, 255)
  )
  sk.drawBar(
    slots.recorded.origin,
    slots.recorded.size,
    transport.player.recordedTicks.float32,
    endTick,
    rgbx(151, 82, 199, 255)
  )
  if pressed:
    transport.dragging = slots.scrubHit.contains(sk.mousePos)
  if not window.buttonDown[MouseLeft]:
    transport.dragging = false
  if transport.dragging and slots.scrub.size.x > 0:
    let ratio = clamp(
      (sk.mousePos.x - slots.scrub.origin.x) / slots.scrub.size.x,
      0.0'f,
      1.0'f
    )
    transport.player.seekTo(int32(ratio * transport.player.timelineEnd.float32))
  let caption = "Tick " & $transport.player.tick & " / " &
    $transport.player.timelineEnd
  discard sk.drawRasterText(
    "Transport", caption, slots.tick.origin, GlyphColor,
    maxWidth = slots.tick.size.x,
    maxHeight = slots.tick.size.y,
    hAlign = RightAlign,
    vAlign = MiddleAlign
  )
