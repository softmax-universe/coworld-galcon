import common, sessions

const CardSeconds* = 10.0

type
  ShipSample* = object
    ships*: array[MaxPlayers + 1, int64]
    maximum*: int64
  Summary* = ref object
    samples*: seq[ShipSample]
    eliminated*: array[MaxPlayers + 1, int32]
    lastTick*: int32 = -1
  Card* = object
    shown*, terminal*, manual*: bool
    until*: float64

proc resultTitle*(session: Session, interrupted = false): string =
  ## Timeout/interruption never invent a simulation winner or draw.
  if session.world.winner > 0:
    session.displayName(session.world.winner) & " wins"
  elif session.world.winner == 0:
    "Draw"
  elif session.world.tick >= session.maximumTicks:
    "Time limit reached"
  elif interrupted:
    "Match interrupted"
  else:
    "Players"

proc newSummary*(maximumTicks: int32): Summary =
  ## Reserves bounded viewer history without adding data to the simulation.
  result = Summary(samples: newSeq[ShipSample](maximumTicks.int + 1))
  for tick in result.eliminated.mitems:
    tick = -1

proc observe*(summary: Summary, world: World) =
  ## Counts planet stocks and airborne ships once per new recorded tick.
  if world.tick <= summary.lastTick:
    return
  doAssert world.tick.int < summary.samples.len
  doAssert world.tick == summary.lastTick + 1
  var
    sample: ShipSample
    present: array[MaxPlayers + 1, bool]
  for planet in world.planets:
    if planet.owner > 0:
      sample.ships[planet.owner] += planet.shipCount.int64
      present[planet.owner] = true
  for i, body in world.bodies:
    if body.active and body.kind == ShipBody:
      let owner = world.ships[i].owner
      inc sample.ships[owner]
      present[owner] = true
  if world.tick > 0:
    sample.maximum = summary.samples[world.tick - 1].maximum
  for owner in 1 .. world.setup.players:
    if world.winner >= 0 and world.winner != owner:
      present[owner] = false
      sample.ships[owner] = 0
    if not present[owner] and summary.eliminated[owner] < 0:
      summary.eliminated[owner] = world.tick
    sample.maximum = max(sample.maximum, sample.ships[owner])
  summary.samples[world.tick] = sample
  summary.lastTick = world.tick

proc update*(card: var Card, terminal: bool, now: float64) =
  ## Final results belong to the match, never to a wall-clock timeout.
  if terminal and not card.terminal:
    card.shown = true
    card.manual = false
    card.until = now + CardSeconds
  elif not terminal and card.terminal:
    card.shown = false
    card.manual = false
    card.until = 0
  card.terminal = terminal

proc toggle*(card: var Card) =
  ## Live statistics can toggle; completed results stay until navigation.
  if card.terminal:
    return
  card.shown = not card.shown
  card.manual = card.shown

proc holding*(card: Card, now: float64): bool =
  ## Keep the final frame and results stable until explicit navigation/seek.
  card.terminal
