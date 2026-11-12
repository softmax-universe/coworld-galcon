## Native production planet/selection renderer and faction-color regression.
## GALCON_PLANET_OUT selects scratch artifacts; --capture skips candidate assertions.
include ../src/galcon/graphics

let output = getEnv("GALCON_PLANET_OUT", Root / "build" / "planet-colors")
createDir(output)
let captureOnly = "--capture" in commandLineParams()
let window = newWindow("Galcon planet color review", ivec2(960, 660), visible = false)
window.makeContextCurrent()
loadExtensions()
let paints = newPaints(2)
let planet = Planet(radius: 22, textureSeed: 424242, textureKind: 0, ships: stock(50))
let builder = newAtlasBuilder(2048, 8)
for owner in [1, 3]:
  doAssert builder.addImage("Planet" & $owner, paints.planetSprite(planet, owner))
  let chip = newImage(16, 16)
  chip.fill(ownerColor(owner))
  doAssert builder.addImage("Chip" & $owner, chip)
builder.addRasterFont(Assets / "zeroes_3.ttf", "Numbers", 14)
builder.addFont(Assets / "transport" / "Rubik-Regular.ttf", "Review", 22)
let sk = newSilky(window, builder.atlasImage, builder.atlas)
let view = View(window: window, sk: sk)
var framebuffer, colorTexture: GLuint
glGenFramebuffers(1, framebuffer.addr)
glGenTextures(1, colorTexture.addr)
glBindTexture(GL_TEXTURE_2D, colorTexture)
glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8.GLint, 960, 660, 0, GL_RGBA, GL_UNSIGNED_BYTE, nil)
glBindFramebuffer(GL_FRAMEBUFFER, framebuffer)
glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, colorTexture, 0)
doAssert glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE
sk.beginUi(window, window.size)
sk.clearScreen(rgbx(9, 14, 25, 255))
discard sk.drawText("Review", "Green", vec2(210, 22), White)
discard sk.drawText("Review", "Blue", vec2(697, 22), White)
discard sk.drawText("Review", "Unselected / 4x detail", vec2(24, 69), White)
for column, owner in [1, 3]:
  let cx = 240.0'f + column.float32 * 480
  sk.drawRasterImage("Chip" & $owner, vec2(cx - 16, 54), vec2(32, 8))
  sk.drawRasterImage("Planet" & $owner, vec2(cx - 114, 116), vec2(228, 228))
  let first = sk.drawer.layers[NormalLayer].len
  discard sk.drawRasterText("Numbers", "50", vec2(cx / 4 - 7.4, 230.0 / 4 - 8), White)
  for i in first ..< sk.drawer.layers[NormalLayer].len:
    sk.drawer.layers[NormalLayer][i].pos *= 4

discard sk.drawText("Review", "Selected / 2x display", vec2(24, 389), White)
for column, owner in [1, 3]:
  let cx = 240.0'f + column.float32 * 480
  let first = sk.drawer.layers[NormalLayer].len
  sk.drawRasterImage("Planet" & $owner, vec2(cx / 2 - 28.5, 250 - 28.5), vec2(57, 57))
  view.ring(vec2(cx / 2, 250), 26, ownerColor(owner))
  discard sk.drawRasterText("Numbers", "50", vec2(cx / 2 - 7.4, 242), White)
  for i in first ..< sk.drawer.layers[NormalLayer].len:
    sk.drawer.layers[NormalLayer][i].pos *= 2

discard sk.drawText("Review", "Same radius, seed, lighting and count. Chips = exact faction color.", vec2(24, 611), White)
sk.endUi()
glFinish()
let image = newImage(960, 660)
glReadPixels(0, 0, 960, 660, GL_RGBA, GL_UNSIGNED_BYTE, image.data[0].addr)
image.flipVertical()
image.writeFile(output / "planets.png")
echo "Native GL: ", cast[cstring](glGetString(GL_RENDERER))
echo "Captured ", output / "planets.png"

# Selection outline is a separate opaque owner-color pass: it must ignore
# planet texture/atmosphere and nearby background pixels entirely.
for column, owner in [1, 3]:
  let cx = 240 + column * 480
  var exact = 0
  for y in 445 .. 555:
    for x in cx - 55 .. cx + 55:
      if image[x, y] == ownerColor(owner): inc exact
  echo ColorNames[owner], " exact selection-ring pixels: ", exact
  doAssert exact > 700
  doAssert image[cx, 57] == ownerColor(owner), "Faction chip must match GPU output exactly"
  if not captureOnly:
    doAssert image[cx + 86, 230] == ownerColor(owner),
      "GPU-rendered planet border must match the faction chip exactly"

if not captureOnly:
  for owner in 0 .. MaxPlayers:
    for kind in 0 .. 1:
      planet.textureKind = kind
      let sprite = paints.planetSprite(planet, owner)
      let center = PlanetSpriteSize div 2
      # A full-coverage limb pixel must be the unlit authoritative owner RGB.
      doAssert sprite[center + 86, center] == ownerColor(owner),
        ColorNames[owner] & " planet rim is contaminated by terrain or atmosphere"
      # Re-seeding terrain cannot change faction identity at the limb.
      planet.textureSeed = 17
      let reseeded = paints.planetSprite(planet, owner)
      doAssert reseeded[center + 86, center] == ownerColor(owner)
      planet.textureSeed = 424242
      let surface = paints.planetImage(planet, owner)
      let offset = (PlanetSpriteSize - surface.width) div 2
      for y in 50 .. 120:
        for x in 50 .. 120:
          doAssert sprite[x + offset, y + offset] == surface[x, y],
            "Atmospheric glow must not bleach the lit planet interior"
  doAssert Surfaces[1][1] > Surfaces[1][2] * 2,
    "Green's terrain must read green, not blue"
  echo "PASS: all 17 owner rims, both terrain kinds, unbleached interiors and exact GL selection colors"
window.close()
