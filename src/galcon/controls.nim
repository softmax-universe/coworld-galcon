import common, worlds

type
  Controls* = object
    selected*: array[MaxPlanets, bool]
    before: array[MaxPlanets, bool]
    player*: int
    percent*: int = 50
    anchor*, hover*: int = -1
    x*, y*, startX*, startY*: int
    holding*, box*, moved*, added*, double*: bool

proc planetAt*(world: World, x, y: int): int =
  ## Finds the closest planet under a quantized logical pointer.
  result = -1
  var nearest = int64.high
  for i, planet in world.planets:
    let
      dx = fixed(x.int32) - planet.x
      dy = fixed(y.int32) - planet.y
      distance = lengthSquared(dx, dy)
      radius = fixed((planet.radius + 3).int32)
    if distance <= int64(int32(radius)) * int32(radius) and distance < nearest:
      nearest = distance
      result = i

proc clear*(controls: var Controls) =
  ## Clears a bounded selection without affecting the simulation.
  controls.selected = default(array[MaxPlanets, bool])

proc clean*(controls: var Controls, world: World) =
  ## Drops planets captured by another player from the current selection.
  for i in 0 ..< MaxPlanets:
    if not world.validPlanet(i) or world.planets[i].owner != controls.player:
      controls.selected[i] = false

proc selectAll*(controls: var Controls, world: World) =
  ## Selects every planet currently owned by the human player.
  for i in 0 ..< world.planets.len:
    controls.selected[i] = world.planets[i].owner == controls.player

proc point*(controls: var Controls, world: World, x, y: int) =
  ## Updates hover and box previews using integer screen coordinates.
  controls.x = x
  controls.y = y
  controls.hover = world.planetAt(x, y)
  if controls.holding:
    let
      dx = x - controls.startX
      dy = y - controls.startY
    controls.moved = controls.moved or dx * dx + dy * dy >= 16
    if controls.box and controls.moved:
      let
        left = min(x, controls.startX)
        right = max(x, controls.startX)
        top = min(y, controls.startY)
        bottom = max(y, controls.startY)
      for i, planet in world.planets:
        controls.selected[i] = controls.before[i] or (
          planet.owner == controls.player and
          planet.x.toInt.int in left .. right and
          planet.y.toInt.int in top .. bottom
        )

proc press*(
    controls: var Controls, world: World, x, y: int,
    double = false, additive = false
) =
  ## Starts a planet drag or box selection and handles select-all double clicks.
  controls.clean(world)
  controls.point(world, x, y)
  controls.startX = x
  controls.startY = y
  controls.anchor = controls.hover
  controls.holding = true
  controls.box = controls.anchor < 0
  controls.moved = false
  controls.double = double
  controls.added = false
  if controls.box:
    if not additive:
      controls.clear()
    controls.before = controls.selected
  elif world.planets[controls.anchor].owner == controls.player:
    if double:
      controls.selectAll(world)
    elif not controls.selected[controls.anchor]:
      controls.selected[controls.anchor] = true
      controls.added = true

proc release*(
    controls: var Controls, world: World, x, y: int,
    submit: SubmitOrder = nil
): int =
  ## Sends every selected source from any planet anchor to the released target.
  if not controls.holding:
    return 0
  controls.point(world, x, y)
  controls.clean(world)
  let target = controls.hover
  if not controls.box and not controls.double:
    if target >= 0 and target != controls.anchor:
      for i in 0 ..< world.planets.len:
        if controls.selected[i]:
          if submit != nil:
            result += submit(controls.player, i, target, controls.percent, true)
          else:
            result += world.send(controls.player, i, target, controls.percent)
    elif not controls.moved and target >= 0 and
      world.planets[target].owner == controls.player and not controls.added:
        controls.selected[target] = not controls.selected[target]
  controls.holding = false
  controls.box = false
