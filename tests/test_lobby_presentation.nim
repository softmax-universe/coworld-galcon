import std/strutils
const source = staticRead("../src/galcon/frontends.nim")
doAssert "Participants" notin source and "participants panel" notin source
doAssert "if empty: rgbx(95, 98, 103, 255)" in source, "Empty faction bars must be neutral gray"
doAssert "tint = if empty: LobbyMuted" in source
doAssert "front.matchName" in source and "\"gameName\"" in source
doAssert "emptyCount == 0" notin source, "Empty potential seats must not prevent ready/start"
doAssert "if owner and sk.lobbyButton" in source, "Guest Start must be hidden"
doAssert "sk.lobbyLabel(playerName(" notin source, "Lobby labels must not prepend textual faction colors"
doAssert "sk.lobbyLabel(label," in source
const graphics = staticRead("../src/galcon/graphics.nim")
doAssert "view.front.connect()" notin graphics, "Startup must use the identity-gated pump"
doAssert "view.front.identityUi" in graphics, "Home must include identity prompt and button"
doAssert "reportReplayFrame(0, 0)" in graphics, "Menu-only frames must dismiss browser loading overlay"
echo "Lobby presentation source guards passed"
