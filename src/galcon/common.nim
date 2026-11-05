import
  std/os,
  fixxy,
  polyworld/rngs

export fixxy

const
  Width* = 640
  Height* = 480
  TickRate* = 32
  MaxBodies* = 4096
  MaxPlayers* = 16
  MaxPlanets* = 128
  MaxPendingLaunches* = MaxPlanets * 8
  CompactPlanetThreshold* = 52
  PlanetGap* = 18
  ShipRadius* = 6
  MaxChatLines* = 16
  MaxChatBytes* = 1024
  ColorNames*: array[MaxPlayers + 1, string] = [
    "Gray", "Green", "Red", "Blue", "Purple", "Yellow", "Pink", "Cyan",
    "Lavender", "Orange", "Lime", "Azure", "Scarlet", "Violet", "Mint",
    "Rose", "Ice"
  ]
  MaxGridCells* = ((Width + 15) div 16) * ((Height + 15) div 16)
  TextureSize* = 256
  ArtScale* = 4
  PlanetSpriteSize* = 228
  Root* = currentSourcePath().parentDir.parentDir.parentDir
  Assets* =
    when defined(emscripten): "/assets"
    else: Root / "assets"
  Baseline* = Root / "players" / "classic.bas"
  Colors*: array[MaxPlayers + 1, array[3, uint8]] = [
    [68'u8, 68, 68], [85'u8, 255, 85], [255'u8, 170, 0],
    [85'u8, 210, 255], [220'u8, 85, 255], [255'u8, 235, 85],
    [255'u8, 85, 170], [85'u8, 255, 210], [170'u8, 170, 255],
    [255'u8, 120, 85], [185'u8, 255, 85], [85'u8, 150, 255],
    [255'u8, 85, 85], [210'u8, 160, 255], [85'u8, 255, 150],
    [255'u8, 185, 210], [210'u8, 235, 255]
  ]
  Surfaces*: array[MaxPlayers + 1, array[3, uint8]] = [
    [153'u8, 153, 153], [85'u8, 85, 255], [255'u8, 85, 85],
    [45'u8, 85, 190], [85'u8, 45, 190], [210'u8, 110, 35],
    [130'u8, 45, 100], [35'u8, 120, 100], [70'u8, 70, 180],
    [170'u8, 65, 30], [85'u8, 120, 30], [35'u8, 65, 190],
    [150'u8, 45, 85], [130'u8, 85, 180], [35'u8, 130, 70],
    [190'u8, 70, 120], [70'u8, 120, 180]
  ]
  Atmospheres*: array[MaxPlayers + 1, array[3, uint8]] = [
    [68'u8, 68, 68], [68'u8, 170, 170], [170'u8, 68, 68],
    [45'u8, 130, 170], [145'u8, 65, 170], [170'u8, 155, 65],
    [170'u8, 65, 120], [65'u8, 170, 145], [120'u8, 120, 170],
    [170'u8, 95, 65], [130'u8, 170, 65], [65'u8, 110, 170],
    [170'u8, 65, 85], [145'u8, 110, 170], [65'u8, 170, 110],
    [170'u8, 130, 145], [145'u8, 160, 170]
  ]

type
  GalconError* = object of CatchableError
  Difficulty* = enum
    Easy, Medium, Hard, Crazy
  Placement* = enum
    RandomPlacement, ClassicPlacement, ClusteredPlacement
  BodyKind* = enum
    PlanetBody, ShipBody
  CollisionKind* = enum
    AllPairs, SortAxis, Grid16, Grid32, Grid64
  SpatialEntry* = object
    x*: int32
    id*: uint16
  Body* = object
    active*, hit*: bool
    kind*: BodyKind
    x*, y*, previousX*, previousY*: Fixed
    targetX*, targetY*, radius*, speed*, heading*: Fixed
    weight*: int32
    target*: int
  Planet* = ref object
    name*: string
    owner*, production*, morale*, realMorale*: int
    ships*, realShips*: int64
      ## Ship stocks are extended Q48.16 so large fleets cannot wrap.
    x*, y*: Fixed
    radius*, body*: int
    frame*: int32
    incoming*: array[MaxPlayers + 1, int]
    neighbors*: seq[int]
    textureSeed*: int32
    textureKind*: int
  Ship* = object
    owner*, target*: int
  Arrival* = object
    tick*: int32
    x*, y*, planetX*, planetY*: Fixed
    radius*, impacts*, captures*: int
    captured*: bool
  ArrivalObserver* = proc(arrival: Arrival)
  SubmitOrder* = proc(player, source, target, value: int, percent: bool): int
  Order* = object
    tick*: int32
    player*, source*, target*, count*: int32
  ChatMessage* = object
    tick*, player*: int32
    length*: int
    text*: array[MaxChatBytes, char]
  Setup* = ref object
    seed*: int32
    difficulty*: Difficulty
    tutorial*: int
    players*: int = 2
    collisions*: CollisionKind = Grid16
    placement*: Placement
    enemyShipsPassThrough*, neutralsDontProduce*: bool = true
    counts*: seq[int]
    legacyLaunches*: bool
      ## Old replay orders describe immediate spawns, not accepted intentions.
  World* = ref object
    setup*: Setup
    rng*: Rng
    tick*: int32
    planets*: seq[Planet]
    bodies*: array[MaxBodies, Body]
    ships*: array[MaxBodies, Ship]
    activeBodies*: array[MaxBodies, uint16]
      ## Scratch indices enumerate active pool slots without tick allocations.
    spatialX*, spatialY*: array[MaxBodies, int32]
    sorted*: array[MaxBodies, SpatialEntry]
    sortedCounts*: array[BodyKind, int]
    gridHeads*: array[MaxGridCells, uint16]
    gridPlanetHeads*: array[MaxGridCells, uint16]
    gridNext*: array[MaxBodies, uint16]
    spawnRadii*: array[BodyKind, Fixed]
    spawnGridReady*: bool
    bodyCursor*, activeShips*: int
    endWait*, winner*, revision*, captures*, impacts*: int
    orders*: seq[Order]
    pendingLaunches*: array[MaxPendingLaunches, Order]
    pendingLaunchCount*: int
      ## FIFO escrow: accepted stocks are deducted once, before rim retries.
    chats*: array[MaxChatLines, ChatMessage]
    chatFirst*, chatCount*: int
    chatOrders*: array[MaxPlayers, ChatMessage]
    chatOrderCount*: int

proc playerName*(owner: int): string {.raises: [].} =
  ## Identifies factions only by their distinct palette colors.
  if owner in 0 .. MaxPlayers:
    ColorNames[owner]
  else:
    ""

proc defaultSetup*(seed = 8'i32, difficulty = Easy): Setup =
  ## Selects the original difficulty's neutral, human, and computer counts.
  result = Setup(
    seed: seed, difficulty: difficulty, placement: ClassicPlacement
  )
  case difficulty
  of Easy:
    result.counts = @[24, 1, 1]
  of Medium:
    result.counts = @[22, 1, 3]
  of Hard:
    result.counts = @[19, 1, 6]
  of Crazy:
    result.counts = @[15, 1, 10]

proc tutorialSetup*(seed: int32, stage: int): Setup =
  ## Selects one of Phil Hassey's three original tutorial stages.
  result = defaultSetup(seed)
  result.tutorial = stage
  case stage
  of 1:
    result.counts = @[3, 1, 0]
  of 2:
    result.counts = @[3, 1, 1]
  of 3:
    result.counts = @[10, 1, 1]
  else:
    raise newException(GalconError, "Tutorial stage must be 1, 2, or 3")

proc stock*(count: int): int64 {.inline, raises: [].} =
  ## Converts whole ships to extended fixed-point stock.
  count.int64 * FixedScale

proc clone*(setup: Setup): Setup =
  ## Copies mutable setup counts only at an explicit snapshot boundary.
  result = Setup()
  result[] = setup[]
  result.counts = newSeq[int](setup.counts.len)
  for i, count in setup.counts:
    result.counts[i] = count

proc shipCount*(planet: Planet): int {.inline, raises: [].} =
  ## Truncates a fixed-point ship stock at the UI and policy boundaries.
  int(planet.ships div FixedScale)

proc roundedRatio*(numerator, denominator: int64): int64 =
  ## Rounds an integer ratio toward positive infinity at half steps.
  doAssert denominator > 0
  if numerator >= 0:
    (numerator + denominator div 2) div denominator
  else:
    -((-numerator + denominator div 2 - 1) div denominator)

proc configuredSetup*(
    seed: int32, difficulty: Difficulty, players, planets: int
): Setup =
  ## Gives every faction the same starting resources and neutral remainder.
  if players < 1 or players > MaxPlayers:
    raise newException(GalconError, "Players must be 1 through " & $MaxPlayers)
  if planets < max(2, players) or planets > MaxPlanets:
    raise newException(
      GalconError,
      "Planets must be at least the player count and 2 through " & $MaxPlanets
    )
  result = Setup(seed: seed, difficulty: difficulty, players: players)
  result.counts = newSeq[int](players + 1)
  for owner in 1 .. players:
    result.counts[owner] = 1
  var remaining = planets - players
  let extras = defaultSetup(seed, difficulty).counts[2] - 1
  for round in 0 ..< extras:
    if remaining < players:
      break
    for owner in 1 .. players:
      inc result.counts[owner]
      dec remaining
  result.counts[0] = remaining
