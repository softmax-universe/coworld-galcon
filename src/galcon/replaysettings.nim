import polyworld/replaysettings as sharedSettings

export sharedSettings.ReplayPreferences

proc readReplayPreferences*(): ReplayPreferences =
  ## Reads Galcon's recording choice from its existing device configuration.
  sharedSettings.readReplayPreferences("Galcon 2006")

proc saveReplayPreferences*(preferences: ReplayPreferences) =
  ## Saves Galcon's recording choice separately from shared match settings.
  sharedSettings.saveReplayPreferences(preferences, "Galcon 2006")
