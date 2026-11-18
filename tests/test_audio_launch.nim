import
  std/os,
  jsony, windy,
  polyworld/menus,
  galcon/[frontends, options]

proc testAudioLaunch() =
  ## Launch flags override saved volume without preventing session changes.
  let defaults = parseOptions(@[])
  doAssert not defaults.game.soundOverride and not defaults.muted,
    "Default launches restore the saved master level"
  for arguments in [@["--mute"], @["--mute=true"],
    @["--mute:on"], @["--mute=1"], @["--mute:yes"],
    @["--unmute", "--mute"]]:
      let options = parseOptions(arguments)
      doAssert options.game.soundMuted and options.game.soundOverride
      doAssert not options.muted,
        "Ordinary mute leaves audio available for the settings menu"
  for arguments in [@["--unmute"], @["--mute=false"], @["--mute:off"],
    @["--mute=0"], @["--mute:no"], @["--mute", "--unmute"]]:
      let options = parseOptions(arguments)
      doAssert not options.game.soundMuted and options.game.soundOverride
      doAssert not options.muted
  let
    path = getConfigHome(AppName) / "settings.json"
    existed = fileExists(path)
    original = getConfig(AppName, "settings.json")
    saved = Preferences(mainVolume: 72, musicVolume: 33,
      fxVolume: 44, uiVolume: 55)
  defer:
    if existed:
      setConfig(AppName, "settings.json", original)
    elif fileExists(path):
      removeFile(path)
    configureSoundLaunch(false, false)
  setConfig(AppName, "settings.json", saved.toJson())
  doAssert newFrontend(parseOptions(@[])).preferences.mainVolume == 72
  for arguments in [@["--mute"], @["--mute=true"]]:
    let front = newFrontend(parseOptions(arguments))
    doAssert front.preferences.mainVolume == 0,
      "Saved sound-on settings must not override a quiet launch"
    doAssert front.preferences.musicVolume == 33
    doAssert front.preferences.fxVolume == 44
    doAssert front.preferences.uiVolume == 55
    front.preferences.savePreferences(AppName)
    doAssert getConfig(AppName, "settings.json").fromJson(Preferences).
      mainVolume == 72, "A quiet launch must preserve the saved master level"
  for arguments in [@["--unmute"], @["--mute=false"]]:
    let front = newFrontend(parseOptions(arguments))
    doAssert front.preferences.mainVolume == 72
    doAssert front.preferences.musicVolume == 33
  let front = newFrontend(parseOptions(@["--mute"]))
  front.preferences.mainVolume = 36
  front.preferences.savePreferences(AppName)
  doAssert readPreferences(AppName).mainVolume == 36,
    "An intentional settings change persists within the current session"
  doAssert newFrontend(parseOptions(@[])).preferences.mainVolume == 36,
    "The next launch restores the intentional saved volume"
  doAssert newFrontend(parseOptions(@["--unmute"])).preferences.mainVolume == 36
  setConfig(AppName, "settings.json", "")
  doAssert newFrontend(parseOptions(@[])).preferences.mainVolume == 100
  doAssert newFrontend(parseOptions(@["--unmute"])).preferences.mainVolume == 100
  echo "Saved-volume launch, shared mute flags and session unmute passed"

testAudioLaunch()
