import std/[os, importutils]
import opengl, windy, pixie, silky, vmath
import galcon/[themes, common, textures, rasters, multiplayer]
include galcon/frontends
privateAccess(Frontend)

let window = newWindow("Galcon menu cover regression", ivec2(1514, 970), visible = false)
window.makeContextCurrent()
loadExtensions()
let builder = newAtlasBuilder(4096, 8)
builder.addMenuAssets()
let paints = newPaints(2)
doAssert builder.addImage("Background", paints.background)
let sk = newSilky(window, builder.atlasImage, builder.atlas)
sk.theme = galconTheme()
let front = Frontend(config: MatchConfig(players: 2),
  roomsScroll: FrameState(), rosterScroll: FrameState())
front.preferences.name = "Menu capture"
var framebuffer, colorTexture: GLuint
glGenFramebuffers(1, framebuffer.addr)
glGenTextures(1, colorTexture.addr)
let output = getEnv("GALCON_MENU_CAPTURES", Root / "build/menu-cover")
createDir(output)
for size in [ivec2(1514, 970), ivec2(700, 1100), ivec2(900, 900)]:
  window.size = size
  glBindTexture(GL_TEXTURE_2D, colorTexture)
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8.GLint, size.x, size.y,
    0, GL_RGBA, GL_UNSIGNED_BYTE, nil)
  glBindFramebuffer(GL_FRAMEBUFFER, framebuffer)
  glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
    GL_TEXTURE_2D, colorTexture, 0)
  doAssert glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE
  for page in [MultiplayerMenu, SingleMenu, SettingsMenu, HomeMenu]:
    front.page = page
    discard front.begin(sk, window, "background regression")
    let
      vertices = sk.drawer.layers[NormalLayer]
      start = vertices[0].pos
      extent = vertices[2].pos - start
      viewport = size.vec2 / sk.uiScale
      source = vec2(paints.background.width.float32, paints.background.height.float32)
    doAssert abs(extent.x / extent.y - source.x / source.y) < 0.0001,
      "Menu galaxy must retain source aspect ratio, not stretch"
    doAssert start.x <= 0.001 and start.y <= 0.001
    doAssert start.x + extent.x >= viewport.x - 0.001
    doAssert start.y + extent.y >= viewport.y - 0.001
    doAssert abs(start.x + extent.x / 2 - viewport.x / 2) < 0.001
    doAssert abs(start.y + extent.y / 2 - viewport.y / 2) < 0.001
    doAssert min(abs(extent.x - viewport.x), abs(extent.y - viewport.y)) < 0.001
    sk.endUi()
    front.draw(sk, window)
    let image = newImage(size.x, size.y)
    glReadPixels(0, 0, size.x, size.y, GL_RGBA, GL_UNSIGNED_BYTE, image.data[0].addr)
    image.flipVertical()
    image.writeFile(output / ($size.x & "x" & $size.y & "-" & $page & ".png"))
    echo "Cover layout/capture passed: ", size, " ", page
window.close()
