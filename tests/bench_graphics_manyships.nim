## Real native GL renderer baseline. No synthetic ship bodies: public launch + advance.
include ../src/galcon/graphics
import fluffy/measure
import std/[json, sequtils]

let outDir = getEnv("GALCON_GRAPHICS_OUT", Root / "build" / "graphics-profile")
createDir(outDir)
let window = newWindow("Galcon graphical profiling", ivec2(1280, 800), vsync = false)
window.makeContextCurrent()
loadExtensions()
echo "GL vendor=", cast[cstring](glGetString(GL_VENDOR)), " renderer=", cast[cstring](glGetString(GL_RENDERER)), " version=", cast[cstring](glGetString(GL_VERSION))
let builder = newAtlasBuilder(4096, 8)
let paints = newPaints(MaxPlanets)
doAssert builder.addImage("Background", paints.background)
doAssert builder.addImage("Particle", paints.particle)
for spec in [("Hud",24), ("Small",20), ("Hover",16), ("ScoreTitle",24), ("Score",14), ("ScoreSmall",10), ("Players",14), ("Numbers",14), ("TinyNumbers",9)]:
  builder.addRasterFont(Assets / "zeroes_3.ttf", spec[0], spec[1].float32)
builder.addRasterFont(Assets / "transport" / "Rubik-Regular.ttf", "Chat", 13)
let sk = newSilky(window, builder.atlasImage, builder.atlas)
sk.builder = builder
let opts = parseOptions(@["--player", "1", "--players", "2", "--planets", "128", "--mute", "--seed", "424242"])
var setup = opts.setup
setup.enemyShipsPassThrough = true
let world = newWorld(setup)
# Explicit seeded stress initial conditions, identical planets for low/high pair.
for i, p in world.planets:
  p.owner = 1 + i mod 2
  p.ships = stock(10000)
let session = Session(world: world, liveWorld: world, human: 1, maximumTicks: 10000)
let view = View(window: window, sk: sk, options: opts, paints: paints,
  session: session, effects: Effects(seed: setup.seed), screen: GameScreen,
  controls: Controls(player: 1, percent: 50, anchor: -1, hover: -1),
  summary: newSummary(10000), boardRevision: -1,
  transport: Transport(player: initPlayer(true, 10000, true)))
view.summary.observe(world)
for i, p in world.planets:
  view.planetSprites[i] = "Planet" & $i
  view.planetOwners[i] = p.owner
  doAssert builder.addImage(view.planetSprites[i], paints.planetSprite(p, p.owner, 116))
sk.uploadAtlas()
view.layout()
var targets: seq[int]
for i, p in world.planets:
  var best = -1'i64
  var target = 0
  for j, q in world.planets:
    let d = lengthSquared(p.x-q.x, p.y-q.y)
    if i != j and d > best:
      best = d
      target = j
  targets.add target
proc launchWave(amount: int) =
  for i, p in world.planets:
    discard world.launch(p.owner, i, targets[i], amount)
proc stepWorld() =
  world.advance(proc(a: Arrival) = view.effects.observe(a))
  view.summary.observe(world)
proc drawOne() =
  sk.beginUi(window, window.size)
  sk.clearScreen(rgbx(0,0,0,255))
  sk.pushClipRect(rect(view.offset, vec2(Width,Height)))
  view.drawGame()
  sk.popClipRect()
  measurePush("board_vertex_transform")
  for vertex in sk.drawer.layers[NormalLayer].mitems:
    vertex.pos = view.presentation.boardOrigin + vertex.pos * view.presentation.boardScale
    vertex.clipPos = view.presentation.boardOrigin + vertex.clipPos * view.presentation.boardScale
    vertex.clipSize *= view.presentation.boardScale
  measurePop()
  measurePush("sidebar_ui")
  view.drawSidebar()
  measurePop()
  measurePush("silky_endUi_upload_submit")
  sk.endUi()
  measurePop()
proc shot(label: string) =
  let image = newImage(window.size.x,window.size.y)
  glReadPixels(0,0,image.width.GLsizei,image.height.GLsizei,GL_RGBA,GL_UNSIGNED_BYTE,image.data[0].addr)
  image.flipVertical()
  image.writeFile(outDir / (label & ".png"))
var rows = newJArray()
proc sample(label: string) =
  # Six bounded chunks: text instrumentation adds hundreds of events/frame.
  for chunk in 0..<6:
    startTrace()
    for frame in 0..<24:
      measurePush("cpu_frame_excluding_gpu_wait_and_present")
      measurePush("simulation_step")
      if frame mod 2 == 0: stepWorld()
      measurePop()
      measurePush("render_cpu")
      drawOne()
      measurePop()
      measurePop()
      measurePush("glFinish_completion_wait_not_gpu_timer")
      glFinish()
      measurePop()
      if chunk == 0 and frame == 20: shot(label)
      measurePush("swapBuffers_vsync_off")
      window.swapBuffers()
      measurePop()
      rows.add(%*{"case":label,"chunk":chunk,"frame":frame,"tick":world.tick,
        "ships":world.activeShips,"vertices":sk.drawer.layers[NormalLayer].len,
        "pendingLaunches":world.pendingLaunchCount,"fingerprint": $world.fingerprint()})
    endTrace()
    dumpMeasures(outDir / (label & "-" & $chunk & ".json"))
  writeFile(outDir / "samples.json", $rows)
# Warm GL/fonts, then baseline while the actual simulation advances.
for i in 0..<8: drawOne(); glFinish(); window.swapBuffers()
sample("low")
launchWave(500)
for i in 0..<1200:
  stepWorld()
  if i mod 32 == 0:
    echo "warmup tick=", world.tick, " ships=", world.activeShips
  if world.activeShips >= 3300: break
  if world.pendingLaunchCount < 256 and i mod 64 == 0: launchWave(500)
echo "high capture starts tick=",world.tick," ships=",world.activeShips
doAssert world.activeShips >= 3000, "Stress case failed to reach genuine 3000 airborne ships"
sample("high")
view.card.shown = true
sample("high-history-card")
writeFile(outDir / "metadata.json", $(%*{"seed":424242,"viewport":[1280,800],
  "renderer": $cast[cstring](glGetString(GL_RENDERER)),"vendor": $cast[cstring](glGetString(GL_VENDOR)),
  "version": $cast[cstring](glGetString(GL_VERSION)),"vsync":false,"maxBodies":MaxBodies,
  "planetCount":world.planets.len,"note":"Native GL; CPU timing plus explicit completion wait, not GPU elapsed timer. Simulation one tick per two rendered frames; no realtime pacing."}))
window.close()
