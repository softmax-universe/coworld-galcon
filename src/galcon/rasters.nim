import
  pixie, silky, vmath,
  common

proc addRasterFont*(
    builder: AtlasBuilder, path, name: string, size: float32,
    chars = AsciiGlyphs
) =
  ## Rasterizes vector fonts at four times their logical display size.
  builder.addFont(path, name, size * ArtScale.float32, chars)

proc rasterTextSize*(sk: Silky, font, text: string): Vec2 =
  ## Measures high-resolution glyphs in logical game coordinates.
  sk.getTextSize(font, text) / ArtScale.float32

proc drawRasterText*(
    sk: Silky, font, text: string, pos: Vec2, color: ColorRGBX,
    maxWidth = float32.high, maxHeight = float32.high,
    clip = true, wordWrap = false,
    hAlign: HorizontalAlignment = LeftAlign,
    vAlign: VerticalAlignment = TopAlign
): Vec2 =
  ## Draws full-resolution glyph UVs with resolution-independent geometry.
  let
    scale = ArtScale.float32
    layer = sk.drawer.currentLayer
    first = sk.drawer.layers[layer].len
  if clip:
    sk.pushClipRect(rect(pos, vec2(maxWidth, maxHeight)))
  result = sk.drawText(
    font, text, pos * scale, color,
    maxWidth = min(maxWidth, float32.high / scale) * scale,
    maxHeight = min(maxHeight, float32.high / scale) * scale,
    clip = false,
    wordWrap = wordWrap,
    hAlign = hAlign,
    vAlign = vAlign
  ) / scale
  for i in first ..< sk.drawer.layers[layer].len:
    sk.drawer.layers[layer][i].pos /= scale
  if clip:
    sk.popClipRect()

proc drawRasterImage*(
    sk: Silky, name: string, pos, size: Vec2,
    color = rgbx(255, 255, 255, 255)
) =
  ## Samples a full-resolution atlas entry at an explicit logical size.
  let entry = sk.atlas.entries[name]
  sk.drawQuad(
    pos, size,
    vec2(entry.x.float32, entry.y.float32),
    vec2(entry.width.float32, entry.height.float32),
    color
  )

proc drawRasterCover*(sk: Silky, name: string, pos, size: Vec2) =
  ## Uniformly scales the actual atlas image, centering the overflow crop.
  let
    entry = sk.atlas.entries[name]
    source = vec2(entry.width.float32, entry.height.float32)
    scale = max(size.x / source.x, size.y / source.y)
    extent = source * scale
  sk.pushClipRect(rect(pos, size))
  sk.drawRasterImage(name, pos + (size - extent) / 2, extent)
  sk.popClipRect()

proc replaceRasterImage*(sk: Silky, name: string, image: Image) =
  ## Replaces one cached sprite, uploading it immediately on native GL.
  let entry = sk.atlas.entries[name]
  doAssert image.width == entry.width and image.height == entry.height
  sk.image.draw(image,
    translate(vec2(entry.x.float32, entry.y.float32)), OverwriteBlend)
  when not defined(emscripten):
    glActiveTexture(GL_TEXTURE0)
    glBindTexture(GL_TEXTURE_2D, sk.atlasTextureId())
    glTexSubImage2D(
      GL_TEXTURE_2D, 0, entry.x.GLint, entry.y.GLint,
      image.width.GLsizei, image.height.GLsizei,
      GL_RGBA, GL_UNSIGNED_BYTE, image.data[0].addr
    )

proc finishRasterUpdates*(sk: Silky) =
  ## Refreshes filtered sprite levels once after the current capture batch.
  when defined(emscripten):
    # Use Silky's full WebGL upload to keep static atlas sprites intact.
    sk.uploadAtlas()
  else:
    glActiveTexture(GL_TEXTURE0)
    glBindTexture(GL_TEXTURE_2D, sk.atlasTextureId())
    glGenerateMipmap(GL_TEXTURE_2D)
