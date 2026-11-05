import
  std/[os, strutils],
  polyworld/cli,
  common, replays

export cli.GameOptions

type
  Options* = ref object
    game*: GameOptions
    setup*: Setup
    start*, headless*, muted*: bool
    menu*, server*, name*, join*: string
    screenshot*: string
    frames*: int = 1
    playerCount*: int
    planetCount*: int = 26
    neutralsPerPlayer*: int
    enemyShipsPassThrough*, neutralsDontProduce*: bool = true

proc setDuration(options: var Options, name, text: string) =
  ## Converts seconds and minutes using Galcon's original 32 Hz tick rate.
  let count = parsePositiveInt32(text, name).int64
  let ticks = count * TickRate * (if name == "--minutes": 60 else: 1)
  if ticks > MaxTicks:
    fail("Duration must not exceed 30 minutes")
  options.game.maximumTicks = ticks.int32

proc clone*(options: Options): Options =
  ## Makes an explicit menu configuration copy before starting another match.
  result = Options()
  result[] = options[]
  result.setup = options.setup.clone()

proc matchSetup*(
    options: Options, difficulty: Difficulty, tutorial = 0
): Setup =
  ## Builds a match or tutorial with the selected rule switches.
  if tutorial > 0:
    result = tutorialSetup(options.game.seed, tutorial)
  else:
    result = configuredSetup(
      options.game.seed,
      difficulty,
      options.playerCount,
      if options.neutralsPerPlayer > 0:
        options.playerCount * (options.neutralsPerPlayer + 1)
      else:
        options.planetCount
    )
    if options.neutralsPerPlayer > 0:
      result.placement = ClusteredPlacement
      result.counts[0] = options.playerCount * options.neutralsPerPlayer
      for owner in 1 .. options.playerCount:
        result.counts[owner] = 1
  result.enemyShipsPassThrough = options.enemyShipsPassThrough
  result.neutralsDontProduce = options.neutralsDontProduce

proc resolveOptions*(options: var Options) =
  ## Validates controller counts and infers the roster from standard flags.
  var bots = 0
  for group in options.game.botGroups:
    if group.count < 1 or group.count > MaxPlayers:
      raise newException(GalconError, "A bot group exceeds the player limit")
    bots += group.count
    if bots > MaxPlayers:
      raise newException(GalconError, "Too many BASIC policies")
  if options.playerCount == 0:
    options.playerCount =
      if bots > 0: bots + int(options.game.playerSlot > 0)
      else: max(2, options.game.playerSlot.int)
  if options.setup.tutorial > 0:
    if options.playerCount != 2 or options.planetCount != 26 or
      options.neutralsPerPlayer > 0:
      raise newException(GalconError,
        "Tutorials use their original player and planet counts")
  options.setup = options.matchSetup(
    options.setup.difficulty,
    options.setup.tutorial
  )
  if options.game.playerSlot > options.setup.players.int32:
    raise newException(GalconError, "--player is outside the configured roster")
  if options.headless and options.game.playerSlot != 0:
    raise newException(GalconError, "--player requires the graphical client")
  let human =
    if options.game.playerSlot > 0: 1
    elif not options.headless and bots == 0: 1
    else: 0
  if bots > 0 and bots != options.setup.players - human:
    raise newException(GalconError, "Expected " &
      $(options.setup.players - human) & " BASIC policies for this roster")

proc parseOptions*(arguments: seq[string]): Options =
  ## Adds original Galcon settings to the shared Polyworld command-line flags.
  result = Options()
  result.setup = defaultSetup()
  result.game.seed = result.setup.seed
  result.game.speed = 1
  result.game.maximumTicks = TickRate * 60 * 20
  when defined(headless):
    result.headless = true
  var index = 0
  while index < arguments.len:
    let argument = arguments[index]
    if argument.startsWith("--players=") or
      argument.startsWith("--players:") or
      argument.startsWith("--planets=") or
      argument.startsWith("--planets:"):
        let value = parsePositiveInt32(argument[10 .. ^1], argument[0 .. 8])
        if argument.startsWith("--players"):
          result.playerCount = value.int
        else:
          result.planetCount = value.int
        inc index
        continue
    if argument.startsWith("--seconds=") or
      argument.startsWith("--minutes="):
        let separator = argument.find('=')
        result.setDuration(
          argument[0 ..< separator],
          argument[separator + 1 .. ^1]
        )
        inc index
        continue
    case argument
    of "--players":
      result.playerCount = parsePositiveInt32(
        arguments.argumentValue(index, argument), argument
      ).int
    of "--planets":
      result.planetCount = parsePositiveInt32(
        arguments.argumentValue(index, argument), argument
      ).int
    of "--neutrals-per-player":
      result.neutralsPerPlayer = parsePositiveInt32(
        arguments.argumentValue(index, argument), argument
      ).int
      if result.neutralsPerPlayer >= MaxPlanets:
        fail("--neutrals-per-player exceeds the planet limit")
    of "--enemy-ships-pass-through", "--neutrals-dont-produce":
      let text = arguments.argumentValue(index, argument).toLowerAscii()
      if text notin ["true", "false"]:
        fail(argument & " must be true or false")
      if argument == "--enemy-ships-pass-through":
        result.enemyShipsPassThrough = text == "true"
      else:
        result.neutralsDontProduce = text == "true"
    of "--player":
      if index + 1 < arguments.len and
        arguments[index + 1].len > 0 and
        arguments[index + 1][0] in {'0' .. '9'}:
          if result.game.playerSlot != 0:
            fail("only one --player allowed")
          result.game.playerSlot = parsePositiveInt32(
            arguments.argumentValue(index, argument), argument
          )
      else:
        discard result.game.takeCommonFlag(arguments, index, argument)
      result.start = true
    of "--menu":
      result.menu = arguments.argumentValue(index, argument)
      if result.menu notin ["main", "multiplayer", "battle", "settings"]:
        fail("--menu must be main, multiplayer, battle, or settings")
    of "--server": result.server = arguments.argumentValue(index, argument)
    of "--name": result.name = arguments.argumentValue(index, argument)
    of "--join": result.join = arguments.argumentValue(index, argument)
    of "--start":
      result.start = true
    of "--headless":
      result.headless = true
      result.start = true
    of "--mute":
      result.muted = true
    of "--screenshot":
      result.screenshot = arguments.argumentValue(index, argument)
      result.muted = true
    of "--frames":
      result.frames = parsePositiveInt32(
        arguments.argumentValue(index, argument), argument
      ).int
    of "--difficulty":
      let text = arguments.argumentValue(index, argument).toLowerAscii()
      case text
      of "easy": result.setup.difficulty = Easy
      of "medium": result.setup.difficulty = Medium
      of "hard": result.setup.difficulty = Hard
      of "crazy": result.setup.difficulty = Crazy
      else: fail("--difficulty must be easy, medium, hard, or crazy")
    of "--tutorial":
      result.setup.tutorial = parsePositiveInt32(
        arguments.argumentValue(index, argument), argument
      ).int
      result.start = true
    of "--seconds", "--minutes":
      result.setDuration(argument, arguments.argumentValue(index, argument))
    of "--help", "-h":
      echo "Galcon 2006 by Phil Hassey, ported to Nim on Polyworld."
      echo "--start --difficulty easy|medium|hard|crazy --tutorial 1|2|3"
      echo "--players N --planets N --player[:SLOT] --bot PATH[:COUNT]"
      echo "--neutrals-per-player N: one home with N nearby neutrals each"
      echo "--seed N --headless --mute"
      echo "--enemy-ships-pass-through true|false"
      echo "--neutrals-dont-produce true|false"
      echo "--ticks N --seconds N --minutes N --record FILE --replay FILE"
      echo "--play true|false --speed N --windowSize WIDTHxHEIGHT"
      echo "--vsync on|off"
      echo "--screenshot FILE --frames N"
      echo "--menu main|multiplayer|battle|settings --server URL --name NAME --join ROOM"
      quit(0)
    else:
      if not result.game.takeCommonFlag(arguments, index, argument):
        fail("Unknown argument: " & argument)
    inc index
  result.resolveOptions()
  if result.game.maximumTicks > MaxTicks or result.game.maximumTicks <= 0:
    fail("Duration must be 1 through " & $MaxTicks & " ticks")
  if result.game.botGroups.len > 0 or result.game.replayPath.len > 0 or
    result.game.playerSlot > 0:
    result.start = true
  if result.game.replayPath.len > 0 and
    (result.game.botGroups.len > 0 or result.game.recordPath.len > 0 or
    result.game.playerSlot > 0):
      fail("--replay cannot combine with --bot, --player, or --record")
  if result.headless and result.screenshot.len > 0:
    fail("--screenshot requires the graphical client")

proc commandOptions*(): Options =
  ## Parses the process arguments at the executable boundary.
  parseOptions(commandLineParams())
