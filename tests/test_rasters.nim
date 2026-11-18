import
  std/os,
  pixie, silky, vmath,
  galcon/[common, rasters, textures, worlds]

proc testRasters*() =
  ## Verifies layered sky assets, opaque planets, and logical font metrics.
  echo "Layered sky assets and HD fonts retain their logical sizes"
  let
    original = newAtlasBuilder(512, 2)
    sharp = newAtlasBuilder(1024, 2)
    path = Assets / "zeroes_3.ttf"
  original.addFont(path, "Test", 14)
  sharp.addRasterFont(path, "Test", 14)
  let
    oldText = Silky(atlas: original.atlas)
    hdText = Silky(atlas: sharp.atlas)
    expected = oldText.getTextSize("Test", "Red (Andre Bot) 123")
    actual = hdText.rasterTextSize("Test", "Red (Andre Bot) 123")
  doAssert abs(expected.x - actual.x) < 0.01'f
  doAssert abs(expected.y - actual.y) < 0.01'f
  doAssert sharp.atlas.fonts["Test"].size == 14 * ArtScale
  let
    world = newWorld(configuredSetup(42, Easy, 16, 69))
    paints = newPaints(world.planets.len)
    planet = world.planets[0]
    before = world.fingerprint()
    surface = paints.planetImage(planet, 1)
    sprite = paints.planetSprite(planet, 1)
    board = paints.boardImage(world)
  doAssert paints.background.width >= Width * 2
  doAssert paints.background.height >= Height * 2
  doAssert paints.background.width * Height == paints.background.height * Width
  for star in paints.stars:
    doAssert star.width in 1 .. 128 and star.height in 1 .. 128
    var transparent, visible: bool
    for pixel in star.data:
      transparent = transparent or pixel.a == 0
      visible = visible or pixel.a > 16
    doAssert transparent and visible,
      "Generated star sprites must retain actual transparent backgrounds"
  doAssert paints.terrain.width == TextureSize * ArtScale
  doAssert paints.atmosphere.width == 324 * ArtScale
  doAssert surface.width == (planet.radius * 2 + 1) * ArtScale
  doAssert sprite.width == PlanetSpriteSize
  doAssert sprite.height == PlanetSpriteSize
  doAssert sprite[PlanetSpriteSize div 2, PlanetSpriteSize div 2].a == 255
  doAssert sprite[0, 0].a == 0
  doAssert board.width == Width * ArtScale
  doAssert board.height == Height * ArtScale
  for pixel in board.data:
    doAssert pixel.a == 255,
      "Resizing the native nebula must not leave transparent export edges"
  doAssert world.fingerprint() == before
