import galcon/frontends

let front = Frontend(page: HomeMenu)
front.preferences.name = "Reconnect test"
front.preferences.server = "not a valid server"
front.pump()
doAssert front.error.len == 0, "Home must not attempt a connection"
front.page = MultiplayerMenu
front.pump()
doAssert front.error.len > 0, "Entering multiplayer must attempt to connect"
front.error = ""
front.pump()
doAssert front.error.len == 0, "A failed attempt must not repeat every frame"
front.page = HomeMenu
front.pump()
front.page = MultiplayerMenu
front.pump()
doAssert front.error.len > 0, "Re-entering multiplayer must retry connecting"
echo "Multiplayer entry reconnect checks passed"
