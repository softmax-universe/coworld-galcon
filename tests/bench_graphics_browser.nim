## Browser-only production renderer stress fixture; no production edits.
when not defined(emscripten): {.error: "Build with -d:emscripten".}
include ../src/galcon/graphics
import std/[json, sequtils]
{.emit: """
EM_JS(double, bench_now, (), { return performance.now(); });
EM_JS(void, bench_publish, (char* value), {
  window.galconBench = JSON.parse(UTF8ToString(value));
});
EM_JS(void, bench_snapshot, (char* label), {
  window.galconShots = window.galconShots || {};
  window.galconShots[UTF8ToString(label)] = Module.canvas.toDataURL('image/png');
});
EM_JS(void, bench_stage, (char* value), { window.galconStage = UTF8ToString(value); });
""".}
proc benchNow(): cdouble {.importc: "bench_now".}
proc publish(value: cstring) {.importc: "bench_publish".}
proc snapshot(value: cstring) {.importc: "bench_snapshot".}
proc stage(value: cstring) {.importc: "bench_stage".}
proc yieldFrame(ms: cuint) {.importc: "emscripten_sleep".}
let window = newWindow("Galcon browser profiling", ivec2(1280,800), vsync = false)
window.makeContextCurrent()
loadExtensions()
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
var rows = newJArray()
var drawMs, transformMs, sidebarMs, submitMs: float
var vertexCount: int
proc drawOne() =
  let t0 = benchNow()
  sk.beginUi(window, window.size)
  sk.clearScreen(rgbx(0,0,0,255))
  sk.pushClipRect(rect(view.offset, vec2(Width,Height)))
  view.drawGame()
  sk.popClipRect()
  let t1 = benchNow()
  for vertex in sk.drawer.layers[NormalLayer].mitems:
    vertex.pos = view.presentation.boardOrigin + vertex.pos * view.presentation.boardScale
    vertex.clipPos = view.presentation.boardOrigin + vertex.clipPos * view.presentation.boardScale
    vertex.clipSize *= view.presentation.boardScale
  let t2 = benchNow()
  view.drawSidebar()
  vertexCount = sk.drawer.layers[NormalLayer].len
  let t3 = benchNow()
  sk.endUi()
  let t4 = benchNow()
  drawMs=t1-t0; transformMs=t2-t1; sidebarMs=t3-t2; submitMs=t4-t3
proc sample(label: string) =
  stage(label.cstring)
  var previousStart = 0.0
  for frame in 0..<144:
    let t0 = benchNow()
    let interval = if previousStart == 0: 0.0 else: t0-previousStart
    previousStart = t0
    if frame mod 2 == 0: stepWorld()
    let t1 = benchNow()
    drawOne()
    let t2 = benchNow()
    rows.add(%*{"case":label,"frame":frame,"tick":world.tick,
      "ships":world.activeShips,"vertices":vertexCount,
      "pendingLaunches":world.pendingLaunchCount,"fingerprint": $world.fingerprint(),
      "cpu_frame_ms":t2-t0,"simulation_ms":t1-t0,"simulation_tick":frame mod 2 == 0,
      "render_ms":t2-t1,"draw_game_ms":drawMs,"transform_ms":transformMs,
      "sidebar_ms":sidebarMs,"submit_ms":submitMs,"start_interval_ms":interval})
    if frame == 120: snapshot(label.cstring)
    yieldFrame(16)
stage("warmup")
for i in 0..<8: drawOne(); yieldFrame(16)
sample("low")
stage("stress-launch")
launchWave(500)
for i in 0..<1200:
  stepWorld()
  if world.activeShips >= 3900: break
  if world.pendingLaunchCount < 256 and i mod 64 == 0: launchWave(500)
  if i mod 32 == 0: yieldFrame(0)
doAssert world.activeShips >= 3900
sample("high")
let result = %*{"samples": rows,"seed":424242,"viewport":[window.size.x,window.size.y],
  "vendor": $cast[cstring](glGetString(GL_VENDOR)),
  "renderer": $cast[cstring](glGetString(GL_RENDERER)),
  "version": $cast[cstring](glGetString(GL_VERSION)),"planets":world.planets.len,
  "maxBodies":MaxBodies,"clock":"performance.now milliseconds",
  "note":"Production drawGame and sidebar, genuine launch/advance, one simulation tick every two renders; no bot/session/network. Yield sleep(16) is not display frame time; no glFinish."}
publish(($result).cstring)
stage("done")
while true: yieldFrame(1000)
