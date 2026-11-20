import
  galcon/[common, options, sessions]

when not defined(headless):
  import galcon/graphics

when defined(coworld):
  import std/[os, uri, strutils]
  import jsony
  import polyworld/[cli, coworld]
  import galcon/replays

  type HostedMap = ref object
    planets: int = 69
    difficulty: string = "easy"
    enemyShipsPassThrough: bool = true
    neutralsDontProduce: bool = true

  proc renameHook(map: var HostedMap, key: var string) =
    ## Maps public configuration keys to their Nim field names.
    case key
    of "enemy_ships_pass_through": key = "enemyShipsPassThrough"
    of "neutrals_dont_produce": key = "neutralsDontProduce"
    else: discard

proc main*() =
  ## Starts the local Galcon port or a Polyworld Coworld policy match.
  var options = commandOptions()
  when defined(coworld):
    options.game = coworldOptions(0)
    if options.game.maximumTicks <= 0 or options.game.maximumTicks > MaxTicks:
      raise newException(GalconError, "Coworld duration exceeds Galcon limits")
    options.playerCount = options.game.botGroups.botCount()
    let map = readFile(parseUri(getEnv("COGAME_CONFIG_URI")).path.decodeUrl())
      .fromJson(HostedMap)
    options.planetCount = map.planets
    options.enemyShipsPassThrough = map.enemyShipsPassThrough
    options.neutralsDontProduce = map.neutralsDontProduce
    case map.difficulty.toLowerAscii()
    of "easy": options.setup.difficulty = Easy
    of "medium": options.setup.difficulty = Medium
    of "hard": options.setup.difficulty = Hard
    of "crazy": options.setup.difficulty = Crazy
    else:
      raise newException(GalconError, "Invalid hosted difficulty")
    options.headless = true
    options.start = true
    options.resolveOptions()
  if options.headless:
    runHeadless(options)
  else:
    when not defined(headless):
      runGraphics(options)
    else:
      raise newException(GalconError, "This binary was built without graphics")

try:
  main()
except GalconError as error:
  quit("Galcon: " & error.msg, 1)
