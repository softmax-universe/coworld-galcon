import
  std/[strutils, uri, random],
  jsony, pixie, silky, chroma, vmath, bumpy,
  polyworld/[menus, lobbies, connections, chrome, policies, inputs, displays],
  common, options, sessions, worlds, bots, multiplayer, themes, rasters

export menus, connections

const AppName* = "Galcon 2006"

type
  Frontend* = ref object
    page*: MenuPage = HomeMenu
    preferences*: Preferences
    config*: MatchConfig
    connection*: Connection
    prepared*: NetworkMatch
    launch*: Session
    error*: string
    roomName: string = "Galcon room"
    invite, search: string
    publicRoom: bool = true
    online: bool
    revision: uint32
    pendingConfig: string
    pendingJoin: bool
    autoConnect*: bool
    browserOpen: bool
    localHuman: int = 1
    policies: array[MaxPlayers, LocalPolicy]
    networkPolicies: array[MaxPlayers, LocalPolicy]
    ui: LobbyUi
    roomsScroll, rosterScroll: FrameState
    preview: World
    previewKey: string
    settingsTab: int
    captureAction: int = -1
    rng: Rand

proc newFrontend*(options: Options): Frontend =
  ## Loads saved settings and an independent, editable local match roster.
  result = Frontend(config: MatchConfig(seed: options.game.seed,
    difficulty: options.setup.difficulty), roomsScroll: FrameState(),
    rosterScroll: FrameState(), rng: initRand(2006))
  if options.playerCount > 2 or options.planetCount != 26:
    result.config.players = options.playerCount
    result.config.planets = options.planetCount
  try:
    result.preferences = readPreferences(AppName)
  except MenusError, IOError, OSError:
    result.error = getCurrentExceptionMsg()
  if getConfig(AppName, "settings.json").len == 0:
    result.preferences.bindings = GalconControls.defaults
  if result.preferences.name.len == 0:
    result.preferences.name = "Player"
  for policy in result.policies.mitems:
    policy = LocalPolicy(name: "Truce Bot", bytes: TruceSource)
  result.invite = inviteParameter("room")
  let server = inviteParameter("server")
  if server.len > 0:
    result.preferences.server = server
  if options.server.len > 0: result.preferences.server = options.server
  if options.name.len > 0: result.preferences.name = options.name
  if options.join.len > 0: result.invite = options.join
  case options.menu
  of "multiplayer": result.page = MultiplayerMenu
  of "battle": result.page = SingleMenu
  of "settings": result.page = SettingsMenu
  else: discard
  result.pendingJoin = result.invite.len > 0
  result.autoConnect = result.pendingJoin or options.server.len > 0
  if result.pendingJoin:
    result.page = MultiplayerMenu

proc sources(front: Frontend): seq[string] =
  ## Keeps policy bytes local while the room shares names and seat owners.
  result = newSeq[string](front.config.players)
  for i in 0 ..< result.len:
    result[i] = front.networkPolicies[i].bytes

proc connect*(front: Frontend) =
  ## Opens the same native/browser WebSocket transport used by GotA and LvD.
  if front.preferences.name.strip().len == 0:
    raise newException(GalconError, "Enter a player name in settings")
  front.connection.close()
  front.connection = connect(front.preferences.server,
    front.preferences.name, identity())
  front.preferences.savePreferences(AppName)
  front.prepared = nil
  front.revision = 0
  front.pendingConfig = ""
  front.error = ""
  front.networkPolicies = default(array[MaxPlayers, LocalPolicy])

proc leave*(front: Frontend) =
  ## Releases room ownership and callbacks before returning to the main menu.
  front.connection.close()
  front.connection = nil
  front.prepared = nil
  front.online = false
  front.page = HomeMenu
  front.pendingConfig = ""
  front.revision = 0

proc pump*(front: Frontend) =
  ## Handles room updates, reconnects, readiness revisions, and match starts.
  if front.page == MultiplayerMenu:
    if not front.browserOpen:
      front.browserOpen = true
      if front.connection == nil or
        (not front.connection.client.welcomed and not front.connection.connecting):
        try:
          front.connect()
        except GalconError, RoomsError, MenusError, IOError, OSError:
          front.error = getCurrentExceptionMsg()
  else:
    front.browserOpen = false
  if front.connection == nil:
    return
  front.connection.pump()
  let client = front.connection.client
  if client.error.len > 0:
    front.error = client.error
    if front.pendingConfig.len > 0 and client.snapshot.payload.len > 0:
      front.config = parseConfig(client.snapshot.payload)
    front.pendingConfig = ""
    client.error = ""
  if client.welcomed and front.pendingJoin and client.snapshot.room.len == 0:
    client.send(RoomMessage(kind: JoinRoom, room: front.invite))
    front.pendingJoin = false
  if client.snapshot.room.len == 0:
    if front.online:
      front.online = false
      front.page = MultiplayerMenu
    return
  front.online = true
  if front.prepared == nil or not front.prepared.started:
    front.page = LobbyMenu
  if front.revision != client.snapshot.revision:
    front.config = parseConfig(client.snapshot.payload)
    front.revision = client.snapshot.revision
    if front.prepared != nil and not front.prepared.started:
      front.prepared = nil
    if front.pendingConfig == client.snapshot.payload:
      front.pendingConfig = ""
  if client.events.len > 0:
    let event = client.events[0]
    client.events.delete(0)
    if front.prepared == nil or front.prepared.revision != event.revision:
      front.prepared = prepareMatch(client, front.sources())
    front.prepared.start(event)
    front.launch = front.prepared.session

proc localMatch*(front: Frontend): Session =
  ## Starts the configured FFA with the exact visible roster.
  var
    policies = newSeq[string](front.config.players)
    names = newSeq[string](front.config.players)
  for i in 0 ..< policies.len:
    if i + 1 == front.localHuman:
      names[i] = front.preferences.name
    else:
      if front.policies[i].bytes.len == 0:
        raise newException(GalconError, "Fill every player slot first")
      policies[i] = loadPolicy(front.policies[i].bytes).source
      names[i] = front.policies[i].name
  newSession(front.config.matchOptions(), policies, names,
    front.localHuman, true)

proc begin(front: Frontend, sk: Silky, window: Window, title: string): LobbyLayout =
  ## Fits the approved Galcon layout without repeating the main-menu logo.
  sk.uiScale = selectedUiScale(min(window.size.x.float32 / 1514,
    window.size.y.float32 / 970), 1080.0'f / 970)
  sk.beginUi(window, window.size)
  sk.textStyle = "LobbyBody"
  let
    view = window.size.vec2 / sk.uiScale
    origin = (view - vec2(1514, 970)) / 2
    top = if front.page == MultiplayerMenu: 224.0'f else: 142.0'f
  sk.clearScreen(rgbx(0, 0, 0, 255))
  sk.drawRasterImage("Background", vec2(0), view)
  sk.drawLabel(title, origin + vec2(0, 36), vec2(1514, 64),
    MenuGreen, "LobbyTitle", CenterAlign)
  result = LobbyLayout(origin: origin,
    left: origin + vec2(32, top), right: origin + vec2(982, top),
    leftWidth: 930, rightWidth: 500, panelHeight: 864 - top,
    footer: origin + vec2(32, 900), primary: origin + vec2(1232, 900))

proc browser(front: Frontend, sk: Silky, window: Window, layout: LobbyLayout) =
  ## Reuses GotA and LvD's room listing, creation, and invitation workflow.
  let
    connected = front.connection != nil and front.connection.client.welcomed
    at = layout.origin + vec2(32, 122)
  sk.lobbyPanel(at, vec2(1450, 76))
  sk.lobbyLabel("server", at + vec2(20, 16), 110)
  sk.lobbyInput(window, "server", front.preferences.server,
    at + vec2(132, 16), 930)
  if sk.lobbyButton(if connected: "reconnect" else: "connect",
    at + vec2(1080, 16), 190):
      front.connect()
  sk.lobbyLabel(if connected: "online" else: "offline",
    at + vec2(1290, 16), 150, tint = if connected: MenuGreen else: LobbyMuted)
  sk.lobbyPanel(layout.left, vec2(layout.leftWidth, layout.panelHeight))
  let list = layout.left + vec2(24)
  sk.lobbyLabel("public rooms", list, 600, "LobbyHeading", MenuGreen)
  if sk.lobbyButton("refresh", list + vec2(704, 0), 178, enabled = connected):
    front.connection.client.send(RoomMessage(kind: ListRooms))
  sk.lobbyInput(window, "search", front.search, list + vec2(0, 60), 882)
  sk.lobbyLabel("room", list + vec2(0, 116), 390, tint = LobbyMuted)
  sk.lobbyLabel("players", list + vec2(400, 116), 150, tint = LobbyMuted)
  sk.lobbyLabel("status", list + vec2(560, 116), 150, tint = LobbyMuted)
  var listings: seq[RoomListing]
  if connected:
    for room in front.connection.client.listings:
      if front.search.toLowerAscii() in room.name.toLowerAscii():
        listings.add room
  let area = rect(list + vec2(0, 170), vec2(882, layout.panelHeight - 230))
  sk.frameScrollbars(window, front.roomsScroll, area,
    vec2(882, listings.len.float32 * 64), vec2(1))
  sk.pushClipRect(rect(area.xy, area.wh - vec2(18, 0)))
  for i, room in listings:
    let point = area.xy + vec2(0, i.float32 * 64) - front.roomsScroll.scrollPos
    sk.lobbyLabel(room.name, point, 390)
    sk.lobbyLabel($room.occupied & "/" & $room.seats,
      point + vec2(400, 0), 140)
    sk.lobbyLabel($room.phase, point + vec2(560, 0), 160)
    if sk.lobbyButton(if room.phase == Lobby: "join" else: "watch",
      point + vec2(730, 0), 130):
        front.connection.client.send(RoomMessage(kind: JoinRoom, room: room.id))
  if listings.len == 0:
    sk.lobbyLabel(if connected: "no rooms yet. create one to begin."
      else: front.connection.status(), area.xy, 850, tint = LobbyMuted)
  sk.popClipRect()
  sk.lobbyPanel(layout.right, vec2(layout.rightWidth, layout.panelHeight))
  let create = layout.right + vec2(24)
  sk.lobbyLabel("create room", create, 452, "LobbyHeading", MenuGreen)
  sk.lobbyLabel("room name", create + vec2(0, 60), 452)
  sk.lobbyInput(window, "room", front.roomName, create + vec2(0, 104), 452)
  if sk.lobbyButton("public", create + vec2(0, 168), 220,
    selected = front.publicRoom):
      front.publicRoom = true
  if sk.lobbyButton("private", create + vec2(232, 168), 220,
    selected = not front.publicRoom):
      front.publicRoom = false
  if sk.lobbyButton("create room", create + vec2(0, 232), 452,
    enabled = connected and front.roomName.strip().len > 0):
      front.config.validate()
      front.connection.client.send(RoomMessage(kind: CreateRoom,
        name: front.roomName, number: front.config.players.uint32,
        tickRate: TickRate.uint32, flag: front.publicRoom,
        payload: front.config.toJson()))
  sk.lobbyLabel("join by invite", create + vec2(0, 332), 452,
    "LobbyHeading", MenuGreen)
  sk.lobbyLabel("link or room code", create + vec2(0, 388), 452)
  sk.lobbyInput(window, "invite", front.invite, create + vec2(0, 432), 452)
  if sk.lobbyButton("join room", create + vec2(0, 496), 452,
    enabled = connected and front.invite.strip().len > 0):
      if '?' in front.invite:
        for key, value in decodeQuery(parseUri(front.invite).query):
          if key == "room": front.invite = value
      front.pendingJoin = true
  if sk.lobbyButton("back", layout.footer, 190):
    front.leave()

proc configPanel(front: Frontend, sk: Silky, window: Window,
    at: Vec2, height: float32, enabled: bool) =
  ## Previews the real deterministic map and edits typed match settings.
  let before = front.config.toJson()
  sk.lobbyPanel(at, vec2(500, height))
  let point = at + vec2(24)
  sk.lobbyLabel("match settings", point, 452, "LobbyHeading", MenuGreen)
  if front.previewKey != before:
    front.preview = newWorld(front.config.matchOptions().setup)
    front.previewKey = before
  sk.lobbyPanel(point + vec2(0, 54), vec2(452, 164), true)
  for planet in front.preview.planets:
    let
      c = Colors[planet.owner]
      pos = point + vec2(112, 58) +
        vec2(planet.x.toFloat32, planet.y.toFloat32) * 0.32'f
      size = max(2.0'f, planet.radius.float32 * 0.32'f)
    sk.drawRect(pos - vec2(size / 2), vec2(size), rgbx(c[0], c[1], c[2], 255))
  sk.lobbyNumber("players", front.config.players, point + vec2(0, 230),
    452, 2, MaxPlayers, 1, enabled)
  front.config.planets = max(front.config.planets, front.config.players)
  sk.lobbyNumber("planets", front.config.planets, point + vec2(0, 278),
    452, front.config.players, MaxPlanets, 1, enabled)
  sk.lobbyNumber("map seed", front.config.seed, point + vec2(0, 326),
    452, 0'i32, int32.high - 1, 1'i32, enabled)
  var minutes = front.config.maximumTicks div (TickRate * 60)
  sk.lobbyNumber("minutes", minutes, point + vec2(0, 374),
    452, 1'i32, 30'i32, 1'i32, enabled)
  if enabled: front.config.maximumTicks = minutes * TickRate * 60
  sk.lobbyLabel("difficulty", point + vec2(0, 422), 190)
  sk.lobbySelect(window, front.config.difficulty, [Easy, Medium, Hard, Crazy],
    point + vec2(196, 422), 256, enabled)
  if enabled:
    sk.at = point + vec2(0, 478)
    checkBox "enemy fleets pass through", front.config.enemyShipsPassThrough
    sk.at = point + vec2(0, 526)
    checkBox "neutrals do not grow", front.config.neutralsDontProduce
  else:
    sk.lobbyLabel("fleets pass through: " & $front.config.enemyShipsPassThrough,
      point + vec2(0, 478), 452)
    sk.lobbyLabel("neutrals don't grow: " & $front.config.neutralsDontProduce,
      point + vec2(0, 526), 452)
  sk.lobbyLabel("neutral ships: " &
    (if front.config.neutralsDontProduce: "0-100" else: "classic"),
    point + vec2(0, 576), 452, tint = LobbyMuted)
  let after = front.config.toJson()
  if enabled and front.online and after != before:
    front.pendingConfig = after
    front.connection.client.send(RoomMessage(kind: ConfigureRoom,
      name: front.connection.client.snapshot.name,
      number: front.config.players.uint32, tickRate: TickRate.uint32,
      flag: front.connection.client.snapshot.flag, payload: after))
  if front.localHuman > front.config.players:
    front.localHuman = 0

proc battle(front: Frontend, sk: Silky, window: Window, layout: LobbyLayout) =
  ## Edits a team-free roster with local policies and server-enforced ownership.
  let
    online = front.online
    client = if online: front.connection.client else: nil
    snapshot = if online: client.snapshot else: RoomMessage()
    editable = not online or snapshot.phase == Lobby
    owner = not online or snapshot.participant == client.participant
    modal = front.ui.selectedSeat >= 0
    enabled = editable and front.pendingConfig.len == 0 and not modal
  sk.lobbyPanel(layout.left, vec2(930, layout.panelHeight))
  let at = layout.left + vec2(24)
  sk.lobbyLabel("players", at, 600, "LobbyHeading", MenuGreen)
  sk.lobbyLabel("free for all", at + vec2(0, 42), 600, tint = LobbyMuted)
  let area = rect(at + vec2(0, 94), vec2(882, layout.panelHeight - 268))
  sk.frameScrollbars(window, front.rosterScroll, area,
    vec2(882, ((front.config.players + 1) div 2).float32 * 74), vec2(1))
  sk.pushClipRect(rect(area.xy, area.wh - vec2(20, 0)))
  var emptyCount, ownCount: int
  var ready = true
  for i in 0 ..< front.config.players:
    let
      seat = if online and i < snapshot.seats.len: snapshot.seats[i] else: Seat()
      empty = if online: seat.owner == 0
        else: front.localHuman != i + 1 and front.policies[i].bytes.len == 0
      mine = not online or seat.owner == client.participant
      human = if online: seat.name == "Human" else: front.localHuman == i + 1
      point = area.xy + vec2((i mod 2).float32 * 436,
        (i div 2).float32 * 74) - front.rosterScroll.scrollPos
      color = Colors[i + 1]
    if empty:
      inc emptyCount
      ready = false
    if mine and not empty: inc ownCount
    var label = if empty: "open slot"
      elif human: front.preferences.name
      elif online: seat.name else: front.policies[i].name
    var status = if human: "human" else: "bot"
    if online and not empty:
      for participant in snapshot.participants:
        if participant.id == seat.owner:
          if human: label = participant.name
          status = if participant.ready: "ready" else: "not ready"
          ready = ready and participant.ready and participant.connected
    if sk.lobbyButton("", point, 418, height = 64,
      enabled = enabled and (mine or empty)):
        front.ui.selectedSeat = i
    sk.drawRect(point + vec2(12, 16), vec2(14, 32),
      rgbx(color[0], color[1], color[2], 255))
    sk.lobbyLabel(playerName(i + 1) & "  " & label,
      point + vec2(38, 0), 368)
    sk.lobbyLabel(status, point + vec2(38, 28), 368, tint = LobbyMuted)
  sk.popClipRect()
  let fill = layout.left + vec2(24, layout.panelHeight - 142)
  if sk.lobbyButton("fill with truce bots", fill, 420,
    enabled = enabled and emptyCount > 0):
      for i in 0 ..< front.config.players:
        if online:
          if snapshot.seats[i].owner == 0:
            front.networkPolicies[i] = LocalPolicy(name: "Truce Bot", bytes: TruceSource)
            client.send(RoomMessage(kind: ClaimSeat, seat: i.uint32, name: "Truce Bot"))
        elif front.localHuman != i + 1 and front.policies[i].bytes.len == 0:
          front.policies[i] = LocalPolicy(name: "Truce Bot", bytes: TruceSource)
  if sk.lobbyButton("shuffle", fill + vec2(436, 0), 418,
    enabled = enabled and not online):
      var order: seq[int]
      for i in 0 ..< front.config.players: order.add i
      front.rng.shuffle(order)
      let old = front.policies
      let human = front.localHuman
      for i, source in order:
        front.policies[i] = old[source]
        if source + 1 == human: front.localHuman = i + 1
  sk.lobbyLabel(if online: snapshot.name else: "each color is an independent player",
    fill + vec2(0, 54), 880, tint = LobbyMuted)
  front.configPanel(sk, window, layout.right, layout.panelHeight, enabled and owner)
  if sk.lobbyButton("back", layout.footer, 190, enabled = not modal):
    if online:
      client.send(RoomMessage(kind: LeaveRoom))
      front.online = false
      front.prepared = nil
      front.page = MultiplayerMenu
    else: front.page = HomeMenu
  if online:
    if sk.lobbyButton("copy invite", layout.footer + vec2(206, 0), 230,
      enabled = not modal):
        copyInvite(inviteBase() & "?server=" & encodeUrl(front.preferences.server) &
          "&room=" & encodeUrl(snapshot.room))
    if sk.lobbyButton("ready", layout.footer + vec2(452, 0), 190,
      enabled = enabled and ownCount > 0 and emptyCount == 0):
        front.prepared = prepareMatch(client, front.sources())
        client.send(RoomMessage(kind: Ready, revision: snapshot.revision,
          hash: front.prepared.stateHash()))
  if sk.lobbyButton(if online and snapshot.phase in {Ended, Desynced}:
    "return to lobby" else: "start game", layout.primary, 250,
    enabled = not modal and owner and (not online or ready or
      snapshot.phase in {Ended, Desynced}) and front.pendingConfig.len == 0 and
      emptyCount == 0):
      if online:
        client.send(RoomMessage(kind:
          if snapshot.phase in {Ended, Desynced}: ReturnLobby else: StartMatch))
        if snapshot.phase in {Ended, Desynced}: front.prepared = nil
      else:
        front.launch = front.localMatch()
  if modal:
    let choice = sk.seatPicker(window, front.ui, @[
      LocalPolicy(name: "Truce Bot", bytes: TruceSource),
      LocalPolicy(name: "Classic Bot", bytes: BaselineSource)
    ])
    if choice.chosen:
      let index = front.ui.selectedSeat
      var policy: LocalPolicy
      if not choice.clear and not choice.human:
        policy = if choice.file: selectPolicy()
          elif choice.bot == 0: LocalPolicy(name: "Truce Bot", bytes: TruceSource)
          else: LocalPolicy(name: "Classic Bot", bytes: BaselineSource)
        if policy.bytes.len == 0: return
      if online:
        if choice.human: client.claimHuman(index)
        elif choice.clear: client.send(RoomMessage(kind: ReleaseSeat, seat: index.uint32))
        else:
          front.networkPolicies[index] = policy
          client.send(RoomMessage(kind: ClaimSeat, seat: index.uint32, name: policy.name))
      else:
        if choice.human: front.localHuman = index + 1
        elif front.localHuman == index + 1: front.localHuman = 0
        front.policies[index] = policy
      front.ui.selectedSeat = -1

proc settings(front: Frontend, sk: Silky, window: Window, at: Vec2): bool =
  ## Applies shared preferences using Galcon-specific controls and audio.
  let before = front.preferences.toJson()
  sk.lobbyPanel(at - vec2(24), vec2(928, 620))
  for i, caption in ["display", "sound", "controls", "networking"]:
    if sk.lobbyButton(caption, at + vec2(i.float32 * 224, 0), 208,
      selected = front.settingsTab == i):
        front.settingsTab = i
        front.captureAction = -1
  let p = at + vec2(0, 80)
  template selectRow(caption: string, value: untyped, choices: untyped, y: float32) =
    sk.lobbyLabel(caption, p + vec2(0, y), 260)
    sk.lobbySelect(window, value, choices, p + vec2(280, y), 580)
  case front.settingsTab
  of 0:
    selectRow("window mode", front.preferences.windowMode,
      [Windowed, Fullscreen], 0)
    selectRow("resolution", front.preferences.resolution,
      [CurrentResolution, Resolution720, Resolution900, Resolution1080,
        Resolution1440, Resolution2160], 62)
    sk.at = p + vec2(0, 136)
    checkBox "visual interpolation", front.preferences.interpolation
    selectRow("fps limit", front.preferences.fps, [30, 60, 120, 0], 196)
    selectRow("ui scaling", front.preferences.uiScaleMode,
      [AutoUiScale, CustomUiScale], 258)
    sk.lobbyNumber("scale %", front.preferences.uiScalePercent,
      p + vec2(0, 320), 860, 25, 200, 10,
      front.preferences.uiScaleMode == CustomUiScale)
    sk.lobbyLabel("0 fps = unlimited", p + vec2(0, 380), 860, tint = LobbyMuted)
  of 1:
    sk.at = p
    checkBox "mute all sound", front.preferences.soundMuted
    sk.lobbyNumber("main volume", front.preferences.mainVolume,
      p + vec2(0, 70), 860, 0, 100, 5)
    sk.lobbyNumber("music volume", front.preferences.musicVolume,
      p + vec2(0, 140), 860, 0, 100, 5)
    sk.lobbyNumber("effects volume", front.preferences.fxVolume,
      p + vec2(0, 210), 860, 0, 100, 5)
  of 2:
    if front.captureAction >= 0:
      for key in Button:
        if key notin {ButtonUnknown, DoubleClick, TripleClick, QuadrupleClick} and
          window.buttonPressed[key]:
            if key != KeyEscape:
              front.preferences.bindings.bindInput(
                GalconControls.actions[front.captureAction].action, 0,
                if key == KeyBackspace: ButtonUnknown else: key
              )
            front.captureAction = -1
            break
    for i, control in GalconControls.actions:
      let row = p + vec2(0, i.float32 * 46)
      sk.lobbyLabel(control.label, row, 490)
      if sk.lobbyButton(if front.captureAction == i: "press a key..."
        else: front.preferences.bindings[control.action][0].bindingLabel,
        row + vec2(500, 0), 360, enabled = front.captureAction < 0):
          front.captureAction = i
    sk.lobbyLabel("tab: scores   enter: chat   0-9: fleet size",
      p + vec2(0, 336), 860, tint = LobbyMuted)
    if sk.lobbyButton("reset controls", p + vec2(0, 390), 360):
      front.preferences.bindings = GalconControls.defaults
  else:
    sk.lobbyLabel("player name", p, 260)
    sk.lobbyInput(window, "playerName", front.preferences.name,
      p + vec2(280, 0), 580)
    sk.lobbyLabel("server", p + vec2(0, 72), 260)
    sk.lobbyInput(window, "preferredServer", front.preferences.server,
      p + vec2(280, 72), 580)
    sk.lobbyLabel("unified polyworld server", p + vec2(0, 156), 860,
      tint = LobbyMuted)
  if front.preferences.toJson() != before:
    let previous = before.fromJson(Preferences)
    front.preferences.applyPreferences(window,
      previous.windowMode != front.preferences.windowMode or
      previous.resolution != front.preferences.resolution)
  if sk.lobbyButton("save and back", at + vec2(0, 520), 300,
    enabled = front.captureAction < 0):
      if front.preferences.name.strip().len == 0 or front.preferences.name.len > 64:
        raise newException(GalconError, "Player name must be 1 to 64 characters")
      discard serverUrl(front.preferences.server)
      front.preferences.savePreferences(AppName)
      result = true

proc draw*(front: Frontend, sk: Silky, window: Window) =
  ## Renders native Silky menus and reports launch transitions to the game view.
  let title = case front.page
    of SettingsMenu: "settings"
    of MultiplayerMenu: "multiplayer"
    else: "battle setup"
  let wasModal = front.ui.selectedSeat >= 0 or front.captureAction >= 0
  let layout = front.begin(sk, window, title)
  try:
    case front.page
    of MultiplayerMenu: front.browser(sk, window, layout)
    of SingleMenu, LobbyMenu: front.battle(sk, window, layout)
    of SettingsMenu:
      if front.settings(sk, window, layout.origin + vec2(317, 230)):
        front.page = HomeMenu
    of HomeMenu: discard
  except GalconError, RoomsError, PolicyError, MenusError, IOError, OSError:
    front.error = getCurrentExceptionMsg()
  if front.error.len > 0:
    sk.drawLabel(front.error, layout.origin + vec2(32, 866), vec2(1450, 30),
      rgbx(255, 140, 130, 255), "Default")
  if window.buttonPressed[KeyEscape] and not wasModal:
      if front.online:
        front.connection.client.send(RoomMessage(kind: LeaveRoom))
        front.online = false
        front.prepared = nil
        front.page = MultiplayerMenu
      elif front.page == MultiplayerMenu:
        front.leave()
      else:
        front.page = HomeMenu
  sk.endUi()
