## Captures pathing fixtures invisibly; use --interactive for the live demo.
include ../src/galcon/graphics
import flowfixtures, test_deadlocks

const
  DemoTitles = [
    "Head-on friends", "Crossing friends", "Planet passage",
    "Enemy pass-through", "Clustered destinations"
  ]
  CaptureNames = [
    "flow-demo-1-head-on.png", "flow-demo-2-crossing.png",
    "flow-demo-3-planet.png", "flow-demo-4-enemies.png",
    "flow-demo-5-deadlock.png"
  ]
  CaptureTick = 400
  MaximumDemoTicks = 4000

proc runFlowDemo(interactive: bool) =
  ## Captures or shows test fleets with the ordinary Galcon renderer.
  let
    options = parseOptions(@["--mute", "--players", "2", "--planets", "3"])
    window = newWindow("Galcon 2006 - Pathing test", ivec2(960, 720),
      visible = false, vsync = interactive)
  window.makeContextCurrent()
  loadExtensions()
  let
    builder = newAtlasBuilder(4096, 8)
    paints = newPaints(MaxPlanets)
  builder.addBackground(paints)
  doAssert builder.addImage("Particle", paints.particle)
  for font in [("Hud", 24), ("Small", 20), ("Hover", 16),
      ("ScoreTitle", 24), ("Score", 14), ("ScoreSmall", 10),
      ("Players", 14), ("Numbers", 14), ("TinyNumbers", 9)]:
    builder.addRasterFont(Assets / "zeroes_3.ttf", font[0], font[1].float32)
  builder.addRasterFont(Assets / "transport/Rubik-Regular.ttf", "Chat", 13)
  builder.addTransportAssets()
  builder.addMenuAssets()
  let
    sk = newSilky(window, builder.atlasImage, builder.atlas)
    view = View(
      front: newFrontend(options), window: window, sk: sk, paints: paints,
      options: options, difficulty: options.setup.difficulty,
      screen: GameScreen, boardRevision: -1
    )
  sk.builder = builder
  sk.theme = galconTheme()
  var
    scenario = 0
    enemies = false
    paused = false
    speed = 1.0
    accumulator = 0.0
    previousTime = getMonoTime()
    requestedScenario = -1

  proc stepDemo() =
    ## Runs actual launches, movement, and arrivals with ordinary HUD history.
    view.session.world.advance(view.session.observer)
    view.summary.observe(view.session.world)

  proc finished(): bool =
    ## Holds the final destinations on screen after every accepted ship arrives.
    let world = view.session.world
    world.activeShips == 0 and world.flowPending() == 0

  proc acceptedShips(): int =
    ## Counts every accepted order across either two streams or many routes.
    for order in view.session.world.orders:
      result += order.count.int

  proc restart() =
    ## Loads a test world through Galcon's ordinary match-view initialization.
    let kind =
      case scenario
      of 1: CrossingContact
      of 2: PlanetContact
      else: HeadOnContact
    let world =
      if scenario == 4:
        deadlockWorld(ClusteredDestinations)
      else:
        destinationFlowWorld(kind, enemies)
    let session = Session(
      world: world, liveWorld: world, human: 1,
      maximumTicks: MaximumDemoTicks
    )
    view.start(provided = session)
    accumulator = 0
    paused = false

  proc selectScenario(index: int) =
    ## Keeps the visible presets and their keyboard shortcuts identical.
    scenario = index
    enemies = scenario == 3
    restart()

  proc drawDemo() =
    ## Shares the production game drawing between hidden and interactive modes.
    let world = view.session.world
    view.transport.player.playing = not paused
    view.transport.player.accumulator = accumulator.float32
    view.layout()
    sk.beginUi(window, window.size)
    sk.clearScreen(rgbx(0, 0, 0, 255))
    sk.pushClipRect(rect(view.offset, vec2(Width, Height)))
    view.drawGame()
    for planet in world.planets:
      let labelWidth = sk.rasterTextSize("Chat", planet.name).x
      view.text("Chat", planet.name,
        vec2(planet.x.toFloat32 - labelWidth / 2,
          planet.y.toFloat32 - planet.radius.float32 - 16),
        ownerColor(planet.owner))
    sk.popClipRect()
    for vertex in sk.drawer.layers[NormalLayer].mitems:
      vertex.pos = view.presentation.boardOrigin +
        vertex.pos * view.presentation.boardScale
      vertex.clipPos = view.presentation.boardOrigin +
        vertex.clipPos * view.presentation.boardScale
      vertex.clipSize *= view.presentation.boardScale
    view.drawSidebar()
    view.drawSendSlider()
    let
      panel = view.presentation.sidebar
      at = panel.origin + vec2(12, 112)
      buttonWidth = panel.size.x - 24
    discard sk.drawRasterText("Players", "PATHING MODES", at, Green)
    discard sk.drawRasterText("Chat", "Click or press 1-5",
      at + vec2(0, 24), Gray, maxWidth = buttonWidth)
    for index, title in DemoTitles:
      let point = at + vec2(0, 48 + index.float32 * 38)
      if sk.lobbyButton("", point, buttonWidth, height = 32,
        selected = scenario == index):
          requestedScenario = index
      if scenario == index:
        sk.drawRect(point + vec2(2, 4), vec2(3, 24), Green)
      discard sk.drawRasterText("Chat", $(index + 1),
        point + vec2(12, 9), if scenario == index: Green else: White)
      discard sk.drawRasterText("Chat", title, point + vec2(35, 9),
        if scenario == index: Green else: White, maxWidth = buttonWidth - 44)
    var phasing = 0
    for body in world.bodies:
      if body.active and body.kind == ShipBody and body.escapeTicks > 0:
        inc phasing
    let
      status = at + vec2(0, 250)
      lines = [
        if enemies: "Enemy fleets pass through."
          else: "Friendly fleets collide.",
        "Escape after 3 seconds stuck",
        "Arrived: " & $world.flowArrived() & " / " & $acceptedShips(),
        "Flying: " & $world.activeShips &
          "   Queued: " & $world.flowPending(),
        "Phasing (faded): " & $phasing,
        if finished(): "All ships reached their targets."
          elif paused: "Paused"
          else: "Flying to assigned planets"
      ]
    for i, line in lines:
      discard sk.drawRasterText("Chat", line, status + vec2(0, i.float32 * 20),
        if i == 0: Green else: Gray, maxWidth = panel.size.x - 24)
    if scenario == 4:
      discard sk.drawRasterText("Chat", "18 routes between 9 crowded ports",
        status + vec2(0, 130), Green, maxWidth = buttonWidth)
      discard sk.drawRasterText("Chat", "Each ship keeps its destination",
        status + vec2(0, 150), Gray, maxWidth = buttonWidth)
    else:
      for i, order in world.orders:
        let
          source = world.planets[order.source]
          target = world.planets[order.target]
        var pending = 0
        for j in 0 ..< world.pendingLaunchCount:
          let queued = world.pendingLaunches[j]
          if queued.source == order.source and queued.target == order.target:
            pending += queued.count.int
        let arrived = order.count.int - pending - target.incoming[order.player]
        discard sk.drawRasterText("Chat",
          source.name & " > " & target.name & ": " &
            $arrived & "/" & $order.count,
          status + vec2(0, 130 + i.float32 * 20),
          ownerColor(order.player.int), maxWidth = buttonWidth)
    for i, line in [
      "Speed: " & $speed & "x",
      "Space Pause / R Restart",
      "S Speed"
    ]:
      discard sk.drawRasterText("Chat", line,
        status + vec2(0, 184 + i.float32 * 20), Gray,
        maxWidth = buttonWidth)
    sk.endUi()

  proc captureDemos() =
    ## Saves all modes without showing or swapping a native window.
    # Hidden Cocoa windows need an offscreen framebuffer, as in GotA and LvD.
    var framebuffer, texture: GLuint
    glGenFramebuffers(1, framebuffer.addr)
    glGenTextures(1, texture.addr)
    defer:
      glBindFramebuffer(GL_FRAMEBUFFER, 0)
      glDeleteTextures(1, texture.addr)
      glDeleteFramebuffers(1, framebuffer.addr)
    glBindTexture(GL_TEXTURE_2D, texture)
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8.GLint,
      window.size.x, window.size.y, 0, GL_RGBA, GL_UNSIGNED_BYTE, nil)
    glBindFramebuffer(GL_FRAMEBUFFER, framebuffer)
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
      GL_TEXTURE_2D, texture, 0)
    doAssert glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE
    createDir(Root / "build")

    proc capture(name: string) =
      ## Reads the standard game renderer from the hidden framebuffer.
      accumulator = 0.5 / TickRate
      doAssert not window.visible, "Screenshot windows must remain hidden."
      drawDemo()
      let screenshot = newImage(window.size.x, window.size.y)
      glReadPixels(0, 0, window.size.x, window.size.y, GL_RGBA,
        GL_UNSIGNED_BYTE, screenshot.data[0].addr)
      doAssert glGetError() == GL_NO_ERROR, "Hidden screenshot readback failed."
      screenshot.flipVertical()
      let path = Root / "build" / name
      screenshot.writeFile(path)
      echo "Captured ", path

    for index, name in CaptureNames:
      selectScenario(index)
      while view.session.world.tick < CaptureTick and not finished():
        stepDemo()
      capture(name)
      while view.session.world.tick < CaptureTick * 2 and not finished():
        stepDemo()
      capture(name.replace(".png", "-destinations.png"))
      while not finished() and view.session.world.tick < MaximumDemoTicks:
        doAssert view.session.world.winner < 0,
          "The demo must keep running until every fleet arrives."
        stepDemo()
      doAssert finished(), "Every demo ship must reach its assigned planet."
      doAssert view.session.world.flowArrived() == acceptedShips()
      capture(name.replace(".png", "-arrived.png"))
      echo DemoTitles[index], ": all ", acceptedShips(),
        " ships arrived at tick ", view.session.world.tick

  if interactive:
    restart()
    window.onFrame = proc() =
      ## Updates the live controls only when an interactive window was requested.
      let
        now = getMonoTime()
        elapsed = min(0.1, (now - previousTime).inNanoseconds.float64 / 1e9)
      previousTime = now
      if requestedScenario >= 0:
        selectScenario(requestedScenario)
        requestedScenario = -1
      if window.buttonPressed[KeySpace]:
        paused = not paused
      if window.buttonPressed[KeyR]:
        restart()
      for index, key in [Key1, Key2, Key3, Key4, Key5]:
        if window.buttonPressed[key]:
          selectScenario(index)
      if window.buttonPressed[KeyTab]:
        selectScenario((scenario + 1) mod DemoTitles.len)
      if window.buttonPressed[KeyE]:
        selectScenario(if enemies: 0 else: 3)
      if window.buttonPressed[KeyS]:
        speed = if speed == 1: 0.5 elif speed == 0.5: 2.0 else: 1.0
      if window.buttonPressed[KeyEscape]:
        window.closeRequested = true
      if not paused and not finished():
        accumulator += elapsed * speed
        while accumulator >= 1.0 / TickRate and not finished():
          stepDemo()
          accumulator -= 1.0 / TickRate
      drawDemo()
      window.swapBuffers()
    window.visible = true
    echo "Opened Galcon pathing test with the standard game renderer."
    while not window.closeRequested:
      pollEvents()
  else:
    captureDemos()
  view.session.finish()
  view.front.leave()
  window.close()

let arguments = commandLineParams()
if arguments.len == 0 or arguments == @["--capture"]:
  runFlowDemo(interactive = false)
elif arguments == @["--interactive"]:
  runFlowDemo(interactive = true)
elif arguments == @["--help"]:
  echo "Usage: galcon-flow-demo [--capture | --interactive]"
  echo "Default: capture all five modes in a hidden window and exit."
else:
  quit("Usage: galcon-flow-demo [--capture | --interactive]", 1)
