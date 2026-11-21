import
  std/[os, strutils],
  polyworld/cli,
  common, replays

export cli.GameOptions

const GalconFlags = AllCommonFlags - {LlmModeFlag}

type
  Options* = ref object
    game*: GameOptions
    setup*: Setup
    start*, headless*, muted*: bool
    menu*, server*, name*, join*: string
    playerCount*: int
    planetCount*: int = 26
    balancedMap*: bool
    neutralsPerPlayer*: int
    enemyShipsPassThrough*, neutralsDontProduce*: bool = true

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
    result.balancedMap = options.balancedMap
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
  result.game.tickRate = TickRate
  result.game.setMaximumTicks(TickRate * 60 * 20)
  when defined(headless):
    result.headless = true
  var index = 0
  while index < arguments.len:
    let
      argument = arguments[index]
      (name, _, _) = splitFlag(argument)
    if result.game.takeCommonFlag(arguments, index, argument):
      discard
    else:
      case name
      of "--players":
        result.playerCount = parsePositiveInt32(
          arguments.flagValue(index, argument), name
        ).int
      of "--planets":
        result.planetCount = parsePositiveInt32(
          arguments.flagValue(index, argument), name
        ).int
      of "--neutrals-per-player":
        result.neutralsPerPlayer = parsePositiveInt32(
          arguments.flagValue(index, argument), name
        ).int
        if result.neutralsPerPlayer >= MaxPlanets:
          raise newException(GalconError,
            "--neutrals-per-player exceeds the planet limit")
      of "--balanced-map", "--enemy-ships-pass-through", "--neutrals-dont-produce":
        let text = arguments.flagValue(index, argument).toLowerAscii()
        if text notin ["true", "false"]:
          raise newException(GalconError, name & " must be true or false")
        if name == "--balanced-map":
          result.balancedMap = text == "true"
        elif name == "--enemy-ships-pass-through":
          result.enemyShipsPassThrough = text == "true"
        else:
          result.neutralsDontProduce = text == "true"
      of "--menu":
        result.menu = arguments.flagValue(index, argument)
        if result.menu notin ["main", "multiplayer", "battle", "settings"]:
          when defined(emscripten):
            raise newException(GalconError,
              "--menu must be main, multiplayer, battle, or settings")
          else:
            if result.menu != "replays":
              raise newException(GalconError,
                "--menu must be main, multiplayer, battle, settings, or replays")
      of "--start":
        result.start = true
      of "--headless":
        result.headless = true
        result.start = true
      of "--difficulty":
        let text = arguments.flagValue(index, argument).toLowerAscii()
        case text
        of "easy": result.setup.difficulty = Easy
        of "medium": result.setup.difficulty = Medium
        of "hard": result.setup.difficulty = Hard
        of "crazy": result.setup.difficulty = Crazy
        else:
          raise newException(GalconError,
            "--difficulty must be easy, medium, hard, or crazy")
      of "--tutorial":
        result.setup.tutorial = parsePositiveInt32(
          arguments.flagValue(index, argument), name
        ).int
        result.start = true
      of "--help", "-h":
        echo "Galcon 2006 by Phil Hassey, ported to Nim on Polyworld."
        echo commonUsageFor(GalconFlags)
        echo "--start --difficulty easy|medium|hard|crazy --tutorial 1|2|3"
        echo "--players N --planets N --headless"
        echo "--neutrals-per-player N: one home with N nearby neutrals each"
        echo "--balanced-map true|false"
        echo "--enemy-ships-pass-through true|false"
        echo "--neutrals-dont-produce true|false"
        echo "--menu main|multiplayer|battle|settings"
        when not defined(emscripten):
          echo "--menu replays: open the desktop replay library"
        quit(0)
      else:
        raise newException(GalconError, "Unknown argument: " & argument)
    inc index
  result.game.rejectUnsupportedFlags(
    if result.headless: GalconFlags
    else: GalconFlags - {HeadlessTickRateFlag}
  )
  result.game.validateGameOptions(0, "")
  if result.headless:
    result.game.validateHeadlessOptions()
  result.server = result.game.serverUrl
  result.name = result.game.playerName
  result.join = result.game.roomCode
  if (result.server.len > 0 or result.join.len > 0) and
    (result.game.botGroups.len > 0 or result.game.playerSlot > 0 or
      result.game.replayPath.len > 0):
      raise newException(GalconError,
        "--server and --room cannot combine with --bot, --player, or --replay")
  if result.headless and (result.server.len > 0 or result.join.len > 0):
    raise newException(GalconError,
      "--server and --room require the graphical multiplayer client")
  result.resolveOptions()
  if result.game.maximumTicks > MaxTicks or result.game.maximumTicks <= 0:
    raise newException(GalconError,
      "Duration must be 1 through " & $MaxTicks & " ticks")
  if result.game.botGroups.len > 0 or result.game.replayPath.len > 0 or
    result.game.playerSlot > 0:
      result.start = true
  try:
    result.game.capture.validateCapture(
      graphical = not result.headless and not defined(emscripten)
    )
  except ScreenshotError as error:
    raise newException(GalconError, error.msg)
  if result.game.capture.captureRequested():
    result.muted = true

proc commandOptions*(): Options =
  ## Resolves input and output paths before starting any executable services.
  try:
    result = parseOptions(commandLineParams())
    result.game.resolveGamePaths()
  except CliError as error:
    raise newException(GalconError, error.msg)
