import
  std/os,
  pixie, chroma, vmath,
  polyworld/rngs,
  common

type
  Paints* = ref object
    background*, shader*, atmosphere*, particle*, terrain*: Image
    surfaces*: seq[array[MaxPlayers + 1, Image]]
    halos*: seq[array[MaxPlayers + 1, Image]]

proc plasma*(seed: int32): seq[uint8] =
  ## Recreates Phil Hassey's recursive grayscale terrain with a private seed.
  result = newSeq[uint8](TextureSize * TextureSize)
  var
    rng = initRng(seed, 0x504c41534d41'u64)
    pixels = result
  proc put(x, y, value: int) =
    ## Writes one clamped grayscale sample.
    pixels[y * TextureSize + x] = clamp(value, 0, 255).uint8
  proc get(x, y: int): int =
    ## Reads one grayscale sample.
    pixels[y * TextureSize + x].int
  proc divide(x, y, width, height, roughness: int) =
    ## Subdivides overlapping rectangles in the original four-quadrant order.
    let
      right = x + width - 1
      bottom = y + height - 1
      centerX = x + width div 2
      centerY = y + height div 2
      a = get(x, y)
      b = get(right, y)
      c = get(x, bottom)
      d = get(right, bottom)
      noise =
        if roughness > 0: rng.between(-roughness.int32, roughness.int32 - 1).int
        else: 0
    put(centerX, y, (a + b) div 2)
    put(x, centerY, (a + c) div 2)
    put(centerX, centerY, (a + b + c + d) div 4 + noise)
    put(right, centerY, (b + d) div 2)
    put(centerX, bottom, (c + d) div 2)
    if width <= 3 and height <= 3:
      return
    divide(x, y, width div 2 + 1, height div 2 + 1, roughness div 2)
    divide(centerX, y, width - width div 2, height div 2 + 1, roughness div 2)
    divide(x, centerY, width div 2 + 1, height - height div 2, roughness div 2)
    divide(centerX, centerY, width - width div 2,
      height - height div 2, roughness div 2)
  for y in [0, TextureSize - 1]:
    for x in [0, TextureSize - 1]:
      put(x, y, rng.below(256).int)
  let roughness = 1 shl rng.between(8, 13).int
  divide(0, 0, TextureSize, TextureSize, roughness)
  result = pixels

proc newPaints*(count: int): Paints =
  ## Loads the original art and initializes bounded per-owner sprite caches.
  try:
    result = Paints(
      background: readImage(Assets / "hd" / "background.png"),
      shader: readImage(Assets / "pshader.png"),
      atmosphere: readImage(Assets / "hd" / "atmosphere.png"),
      particle: readImage(Assets / "hd" / "particle.png").resize(20, 20),
      terrain: readImage(Assets / "hd" / "planet.png"),
      surfaces: newSeq[array[MaxPlayers + 1, Image]](count),
      halos: newSeq[array[MaxPlayers + 1, Image]](count)
    )
  except PixieError, IOError, OSError:
    raise newException(GalconError, "Cannot load original artwork: " &
      getCurrentExceptionMsg())

proc planetImage*(paints: Paints, planet: Planet, owner: int): Image =
  ## Combines seeded terrain with the HD sphere at four times display density.
  let
    pixels = plasma(planet.textureSeed)
    base = Colors[owner]
    surface = Surfaces[owner]
    size = (planet.radius * 2 + 1) * ArtScale
    material = paints.terrain.resize(size, size)
  result = newImage(size, size)
  for y in 0 ..< size:
    for x in 0 ..< size:
      let
        tx = x * TextureSize div size
        ty = y * TextureSize div size
        value = pixels[ty * TextureSize + tx].int
        shade = paints.shader[tx, ty]
        detail = material[x, y]
      var rgb: array[3, uint8]
      for channel in 0 ..< 3:
        let tone =
          if planet.textureKind == 0:
            if value < 128: surface[channel].int
            else: base[channel].int * value div 256
          else:
            surface[channel].int * (255 - value) div 256 +
              base[channel].int * value div 256
        let overlay = [shade.r, shade.g, shade.b][channel].int
        let lit = tone * (255 - shade.a.int) div 255 + overlay
        rgb[channel] = min(255,
          lit * (128 + detail.r.int) div 192).uint8
      if shade.r == 255 and shade.g == 0 and shade.b == 255:
        result[x, y] = rgbx(0, 0, 0, 0)
      else:
        let
          dx = x * 2 + 1 - size
          dy = y * 2 + 1 - size
          inner = size - 2
          alpha =
            if dx * dx + dy * dy < inner * inner: 255
            else: detail.a.int
        let
          rim = size - 2 * ArtScale
          ownerRim = dx * dx + dy * dy >= rim * rim
        result[x, y] = rgbx(
          ((if ownerRim: base[0].int else: rgb[0].int) * alpha div 255).uint8,
          ((if ownerRim: base[1].int else: rgb[1].int) * alpha div 255).uint8,
          ((if ownerRim: base[2].int else: rgb[2].int) * alpha div 255).uint8,
          alpha.uint8
        )

proc haloImage(paints: Paints, planet: Planet, owner: int): Image =
  ## Keeps atmospheric hue aligned with the authoritative faction color.
  let tint = Colors[owner]
  result = newImage(paints.atmosphere.width, paints.atmosphere.height)
  for i, color in paints.atmosphere.data:
    let intensity = max(color.r.int, max(color.g.int, color.b.int))
    result.data[i] = rgbx(
      uint8(intensity * tint[0].int div 510),
      uint8(intensity * tint[1].int div 510),
      uint8(intensity * tint[2].int div 510),
      255
    )
  let size = (planet.radius * 2 + 1) * ArtScale * result.width div
    (TextureSize * ArtScale)
  result = result.resize(size, size)

proc planetSprite*(
    paints: Paints, planet: Planet, owner: int, size = PlanetSpriteSize
): Image =
  ## Packs an opaque HD planet with an additive halo into one small sprite.
  let
    surface = paints.planetImage(planet, owner)
    halo = paints.haloImage(planet, owner)
    offset = (size - surface.width) div 2
    haloOffset = (size - halo.width) div 2
  doAssert size >= halo.width
  result = newImage(size, size)
  for y in 0 ..< result.height:
    for x in 0 ..< result.width:
      var glow = rgbx(0, 0, 0, 0)
      if x >= haloOffset and y >= haloOffset and
        x < haloOffset + halo.width and y < haloOffset + halo.height:
          glow = halo[x - haloOffset, y - haloOffset]
      var pixel = rgbx(0, 0, 0, 0)
      if x >= offset and y >= offset and
        x < offset + surface.width and y < offset + surface.height:
          pixel = surface[x - offset, y - offset]
      # The additive atmosphere belongs outside the sphere. Multiplying by
      # uncovered alpha preserves its exact faction rim and interior lighting.
      let uncovered = 255 - pixel.a.int
      result[x, y] = rgbx(
        min(255, pixel.r.int + glow.r.int * uncovered div 255).uint8,
        min(255, pixel.g.int + glow.g.int * uncovered div 255).uint8,
        min(255, pixel.b.int + glow.b.int * uncovered div 255).uint8,
        pixel.a
      )

proc addGlow*(destination, glow: Image, x, y: int) =
  ## Adds atmosphere channels without introducing transparent planet interiors.
  for gy in 0 ..< glow.height:
    let dy = y + gy
    if dy < 0 or dy >= destination.height:
      continue
    for gx in 0 ..< glow.width:
      let dx = x + gx
      if dx < 0 or dx >= destination.width:
        continue
      let
        a = destination[dx, dy]
        b = glow[gx, gy]
      destination[dx, dy] = rgbx(
        min(255, a.r.int + b.r.int).uint8,
        min(255, a.g.int + b.g.int).uint8,
        min(255, a.b.int + b.b.int).uint8,
        255
      )

proc boardImage*(paints: Paints, world: World): Image =
  ## Composes the unchanged 2006 background, textured planets, and bright halos.
  result = paints.background.copy()
  for i, planet in world.planets:
    let owner = planet.owner
    if paints.surfaces[i][owner] == nil:
      paints.surfaces[i][owner] = paints.planetImage(planet, owner)
      paints.halos[i][owner] = paints.haloImage(planet, owner)
    let
      surface = paints.surfaces[i][owner]
      halo = paints.halos[i][owner]
      x = planet.x.toInt.int * ArtScale
      y = planet.y.toInt.int * ArtScale
    result.addGlow(halo, x - halo.width div 2, y - halo.height div 2)
    result.draw(surface, translate(vec2(
      (x - surface.width div 2).float32,
      (y - surface.height div 2).float32
    )))
