import
  std/[os, strutils, uri, random, monotimes, times],
  jsony, pixie, silky, chroma, vmath, bumpy,
  polyworld/[menus, lobbies, connections, chrome, policies, inputs, displays],
  common, options, sessions, worlds, bots, multiplayer, themes, rasters

when not defined(emscripten):
  import polyworld/replaysaves, replays, replaylibraries, replaymenus,
    replaysettings

export menus, connections

const
  AppName* = "Galcon 2006"
  DefaultLobbyPlayers = 4

type
  LobbyBot* = enum
    ClassicBot, TruceBot, ExpandBot, ChattyBot
  UiCue* = enum
    UiHover, UiClick
  Frontend* = ref object
    page*: MenuPage = HomeMenu
    preferences*: Preferences
    config*: MatchConfig
    localConfig: MatchConfig
    connection*: Connection
    prepared*: NetworkMatch
    launch*: Session
    error*: string
    when not defined(emscripten):
      replayPreferences*: ReplayPreferences
      unsavedReplays*: seq[Recording]
      replayBrowser*: ReplayBrowserState
      browsingReplays*: bool
      replayAction: ReplayBrowserResult
      retryReplayRequested: bool
    onUiCue*: proc(cue: UiCue)
    roomName: string
    matchName: string
    editingPlayer: bool
    playerDraft: string
    readyAttempt: uint32
    contextOwner: uint32
    contextRoom, contextKind: string
    contextSeatKind: SeatKind
    contextPolicy: LocalPolicy
    contextArmed, contextDismissed: bool
    invite, search: string
    publicRoom: bool = true
    online: bool
    revision: uint32
    pendingConfig: string
    pendingJoin: bool
    autoSeatRoom: string
    autoSeatPending: bool
    autoSeatClaim: int = -1
    autoConnect*: bool
    browserOpen: bool
    roomsRefreshArmed: bool
    roomsRefreshedAt: float64
    localHuman: int
    policies: array[MaxPlayers, LocalPolicy]
    networkPolicies: array[MaxPlayers, LocalPolicy]
    ui: LobbyUi
    contextSeat*: int = -1
    contextAt: Vec2
    roomsScroll, rosterScroll: FrameState
    preview: World
    previewKey: string
    settingsTab: int
    captureAction: int = -1
    slider: int = -1
    sliderLeft, sliderWidth, sliderScale: float32
    rng: Rand

const
  LobbyBotNames*: array[LobbyBot, string] = [
    "Classic", "Truce", "Expand", "Chatty"
  ]
  LobbyBotPolicies*: array[LobbyBot, LocalPolicy] = [
    LocalPolicy(name: "Classic Bot", bytes: BaselineSource),
    LocalPolicy(name: "Truce Bot", bytes: TruceSource),
    LocalPolicy(name: "Expand Bot",
      bytes: staticRead(Root / "players/expand.bas")),
    LocalPolicy(name: "Chatty Bot",
      bytes: staticRead(Root / "players/chatty.bas"))
  ]

proc emitUiCue*(front: Frontend, cue: UiCue) =
  ## Sends optional interface feedback without touching match state.
  if front.onUiCue != nil:
    front.onUiCue(cue)

proc menuHover(front: Frontend, sk: Silky, bounds: Rect,
    enabled = true) =
  ## Plays hover feedback only on entry into the enabled visible target.
  let previous = sk.mousePos - sk.mouseDelta
  if enabled and sk.interactor.currentId == sk.interactor.hotId and
    not sk.mouseConsumed and not sk.buttonDown[MouseLeft] and
    overlaps(sk.mousePos, bounds) and overlaps(sk.mousePos, sk.clipRect) and
    (not overlaps(previous, bounds) or not overlaps(previous, sk.clipRect)):
      front.emitUiCue(UiHover)

proc menuButton*(
    front: Frontend, sk: Silky, text: string, at: Vec2, width: float32,
    icon = "", enabled = true, selected = false, height = 44.0'f,
    tint = rgbx(255, 255, 255, 255), iconTint = rgbx(0, 0, 0, 0)
): bool =
  ## Adds entry and activation cues to the shared button's real hit testing.
  result = lobbies.lobbyButton(sk, text, at, width, icon, enabled,
    selected, height, tint, iconTint)
  front.menuHover(sk, rect(at, vec2(width, height)), enabled)
  if result:
    front.emitUiCue(UiClick)

proc menuSelect[T](
    front: Frontend, sk: Silky, window: Window, value: var T,
    choices: openArray[T], at: Vec2, width: float32, enabled = true
) =
  ## Acknowledges changed dropdown choices through local interface feedback.
  let previous = value
  sk.lobbySelect(window, value, choices, at, width, enabled)
  front.menuHover(sk, rect(at, vec2(width, 44)), enabled)
  if value != previous:
    front.emitUiCue(UiClick)

proc menuCheckBox(front: Frontend, sk: Silky, window: Window,
    caption: string, value: var bool) =
  ## Acknowledges checkbox changes using the shared widget's activation.
  let previous = value
  checkBox caption, value
  if value != previous:
    front.emitUiCue(UiClick)

proc newFrontend*(options: Options): Frontend =
  ## Loads saved settings and an independent, editable local match roster.
  result = Frontend(config: MatchConfig(players: DefaultLobbyPlayers,
    seed: options.game.seed,
    difficulty: options.setup.difficulty), roomsScroll: FrameState(),
    rosterScroll: FrameState(), rng: initRand(2006))
  if options.playerCount > 2 or options.planetCount != 26:
    result.config.players = options.playerCount
    result.config.planets = options.planetCount
  configureSoundLaunch(options.game.soundMuted, options.game.soundOverride)
  try:
    result.preferences = readPreferences(AppName)
  except MenusError, IOError, OSError:
    result.error = getCurrentExceptionMsg()
  when not defined(emscripten):
    result.replayBrowser = initReplayBrowser(Library)
    try:
      result.replayPreferences = readReplayPreferences()
    except MenusError, IOError, OSError:
      result.error = getCurrentExceptionMsg()
  if getConfig(AppName, "settings.json").len == 0:
    result.preferences.bindings = GalconControls.defaults
  result.invite = inviteParameter("room")
  let server = inviteParameter("server")
  if server.len > 0:
    result.preferences.server = server
  if options.server.len > 0: result.preferences.server = options.server
  if options.name.len > 0: result.preferences.name = options.name
  result.roomName = result.preferences.name & "'s game"
  if options.join.len > 0: result.invite = options.join
  case options.menu
  of "multiplayer": result.page = MultiplayerMenu
  of "battle": result.page = SingleMenu
  of "settings": result.page = SettingsMenu
  of "replays":
    when not defined(emscripten):
      result.browsingReplays = true
  else: discard
  result.pendingJoin = result.invite.len > 0
  result.autoConnect = result.pendingJoin or options.server.len > 0
  if result.pendingJoin:
    result.page = MultiplayerMenu
    when not defined(emscripten):
      result.browsingReplays = false

proc confirmedPlayerName(name: string): bool =
  ## Requires a confirmed name instead of the automatic Player placeholder.
  name.len <= 64 and validName(name) and name.strip().toLowerAscii() != "player"

proc needsPlayerName*(front: Frontend): bool =
  not confirmedPlayerName(front.preferences.name)

proc savePlayerName*(front: Frontend, name: string) =
  ## Names are opaque; persist only after validation and preserve custom titles.
  if not confirmedPlayerName(name): reject("Enter your name, not Player (1-64 bytes, no line breaks)")
  let defaultName = front.preferences.name & "'s game"
  var updated = front.preferences
  updated.name = name
  updated.savePreferences(AppName)
  if front.roomName == defaultName or front.roomName.len == 0:
    front.roomName = name & "'s game"
  front.preferences = updated
  if front.connection != nil and front.connection.client.name != name:
    front.connection.client.name = name
    if front.connection.address.len > 0: front.connection.reconnectAfter(0)
  front.editingPlayer = false
  front.error = ""

proc renameGame*(front: Frontend, name: string) =
  if not front.online or front.pendingConfig.len > 0: reject("Not in an editable lobby")
  let client = front.connection.client
  if not client.connected or client.snapshot.phase != Lobby or
    client.snapshot.participant != client.participant or not validName(name):
    reject("Only the lobby owner can edit the game name")
  client.send(RoomMessage(kind: ConfigureRoom, name: name,
    number: client.snapshot.seats.len.uint32, tickRate: client.snapshot.tickRate,
    flag: client.snapshot.flag, payload: client.snapshot.payload))
  front.matchName = name

proc sources(front: Frontend): seq[string] =
  ## Keeps policy bytes local while the room shares names and seat owners.
  result = newSeq[string](front.config.players)
  for i in 0 ..< result.len:
    result[i] = front.networkPolicies[i].bytes

proc connect*(front: Frontend) =
  ## Opens the same native/browser WebSocket transport used by GotA and LvD.
  if front.needsPlayerName() or front.editingPlayer:
    raise newException(GalconError, "Enter a player name in settings")
  front.connection.close()
  front.connection = connect(front.preferences.server,
    front.preferences.name, identity())
  front.preferences.savePreferences(AppName)
  front.prepared = nil
  front.revision = 0
  front.pendingConfig = ""
  front.autoSeatRoom = ""
  front.autoSeatPending = false
  front.autoSeatClaim = -1
  front.error = ""
  front.networkPolicies = default(array[MaxPlayers, LocalPolicy])

proc leave*(front: Frontend) =
  ## Releases room ownership and callbacks before returning to the main menu.
  front.connection.close()
  front.connection = nil
  front.prepared = nil
  front.online = false
  if front.localConfig != nil:
    front.config = front.localConfig
    front.localConfig = nil
  front.contextSeat = -1
  front.ui.selectedSeat = -1
  front.ui.fillBotMenu = LobbyBotMenu()
  front.page = HomeMenu
  front.pendingConfig = ""
  front.autoSeatRoom = ""
  front.autoSeatPending = false
  front.autoSeatClaim = -1
  front.revision = 0

when not defined(emscripten):
  proc openReplays*(front: Frontend) =
    ## Opens the local library after releasing any previous room membership.
    front.leave()
    front.browsingReplays = true
    front.replayBrowser.refreshRequested = true
    front.replayBrowser.message = front.error
    front.replayAction = ReplayBrowserResult()

  proc retryPendingReplays*(front: Frontend) =
    ## Keeps retained recordings until each shared library write succeeds.
    try:
      front.unsavedReplays.retryReplaySaves(
        proc(recording: Recording): string =
          ## Stores one retained Galcon recording in its user library.
          saveLibraryReplay(recording)
      )
      front.error = ""
      front.replayBrowser.refreshRequested = true
    except CatchableError as error:
      front.error = "Cannot save replay: " & error.msg

  proc processReplayActions*(front: Frontend) =
    ## Performs desktop dialogs and replay loading after window event polling.
    if front.retryReplayRequested:
      front.retryReplayRequested = false
      front.retryPendingReplays()
    let action = front.replayAction
    front.replayAction = ReplayBrowserResult()
    if not front.browsingReplays:
      return
    let selected = front.replayBrowser.updateReplayBrowser(Library, action)
    case selected.action
    of BackFromReplays:
      front.browsingReplays = false
      front.page = HomeMenu
    of PlayReplay:
      try:
        front.launch = newSession(parseOptions(@["--replay", selected.path]))
        front.error = ""
        front.replayBrowser.message = ""
      except CatchableError as error:
        front.replayBrowser.message = error.msg
    else:
      discard

  proc drawReplayNotice*(front: Frontend, sk: Silky, at: Vec2,
      width = 600.0'f) =
    ## Shows a retained-save retry and its latest error in Galcon's theme.
    var messageAt = at
    if front.unsavedReplays.len > 0:
      if front.menuButton(sk, "Retry saving replay", at, min(300.0'f, width)):
        front.retryReplayRequested = true
      messageAt.y += 48
    if front.error.len > 0:
      sk.lobbyLabel(sk.fittedLabel(front.error, width, "LobbyBody"),
        messageAt, width, tint = rgbx(255, 140, 130, 255))

proc createRoom*(front: Frontend) =
  ## Defaults new online rooms independently of the local roster preference.
  let config = parseConfig(front.config.toJson())
  config.players = DefaultLobbyPlayers
  config.planets = max(DefaultLobbyPlayers, config.planets)
  config.validate()
  front.connection.client.send(RoomMessage(kind: CreateRoom,
    name: (if front.roomName.len > 0: front.roomName else: front.preferences.name & "'s game"),
    number: DefaultLobbyPlayers.uint32, tickRate: TickRate.uint32,
    flag: front.publicRoom, payload: config.toJson()))

proc synchronizing*(front: Frontend): bool =
  ## Exposes the in-flight server roster acknowledgement to controls and tests.
  front.pendingConfig.len > 0 or front.autoSeatPending

proc claimJoiningSeat(front: Frontend) =
  ## Claims an empty human seat once per room, retrying contested assignments.
  let
    client = front.connection.client
    snapshot = client.snapshot
  if front.autoSeatRoom != snapshot.room:
    front.autoSeatRoom = snapshot.room
    front.autoSeatPending = snapshot.phase == Lobby
    front.autoSeatClaim = -1
  if not front.autoSeatPending:
    return
  if snapshot.phase != Lobby or snapshot.humanSeat(client.participant) > 0:
    front.autoSeatPending = false
    front.autoSeatClaim = -1
    return
  if not client.connected or not client.welcomed:
    # A disconnected transport drops its outbox; resend after reconnection.
    front.autoSeatClaim = -1
    return
  if front.pendingConfig.len > 0:
    return
  if front.autoSeatClaim >= 0 and front.autoSeatClaim < snapshot.seats.len and
    snapshot.seats[front.autoSeatClaim].owner == 0:
      return
  front.autoSeatClaim = -1
  for i, seat in snapshot.seats:
    if seat.owner == 0:
      client.claimHuman(i)
      front.autoSeatClaim = i
      return
  # Full lobbies remain watchable without replacing anyone's bot or human.
  front.autoSeatPending = false

proc resizeRoster*(front: Frontend, count: int) =
  ## Publishes host-owned roster size and game settings as separate metadata.
  if count notin 2 .. MaxPlayers or front.synchronizing():
    reject("Wait for roster synchronization or choose 2-16 players")
  if front.online:
    let client = front.connection.client
    if client.snapshot.phase != Lobby or
      client.snapshot.participant != client.participant:
        reject("Only the lobby host can resize the roster")
  front.config.players = count
  front.config.planets = max(front.config.planets, count)
  if front.online:
    front.pendingConfig = front.config.toJson()
    let client = front.connection.client
    client.send(RoomMessage(kind: ResizeRoom, name: client.snapshot.name,
      number: count.uint32, tickRate: TickRate.uint32,
      flag: client.snapshot.flag, payload: front.pendingConfig))
  else:
    if front.localHuman > count: front.localHuman = 0
    for i in count ..< MaxPlayers:
      front.policies[i] = LocalPolicy()

proc removePlayer*(front: Frontend, index: int) =
  ## Releases one owned slot or any host-managed slot without kicking its owner.
  if front.synchronizing() or index notin 0 ..< front.config.players:
    reject("Player is unavailable while synchronizing")
  if front.online:
    let client = front.connection.client
    let seat = client.snapshot.seats[index]
    if seat.owner != client.participant and
      client.snapshot.participant != client.participant:
        reject("Only the slot owner or host can remove this player")
    client.send(RoomMessage(kind: ReleaseSeat, seat: index.uint32))
    front.networkPolicies[index] = LocalPolicy()
  else:
    front.policies[index] = LocalPolicy()
    if front.localHuman == index + 1: front.localHuman = 0

proc administer(front: Frontend): bool =
  if not front.online: return true
  let client = front.connection.client
  client.connected and client.welcomed and client.snapshot.room.len > 0 and
    client.snapshot.phase == Lobby and client.snapshot.participant == client.participant

proc canManagePlayer(front: Frontend, index: int): bool =
  ## Allows occupied local slots, owned network slots, and host moderation.
  if front.synchronizing() or index notin 0 ..< front.config.players:
    return false
  if not front.online:
    return front.localHuman == index + 1 or front.policies[index].bytes.len > 0
  if front.connection == nil or front.connection.client == nil:
    return false
  let client = front.connection.client
  if not client.connected or not client.welcomed or
    client.snapshot.room.len == 0 or index >= client.snapshot.seats.len:
      return false
  let seat = client.snapshot.seats[index]
  seat.owner != 0 and (seat.owner == client.participant or
    client.snapshot.participant == client.participant)

proc playerContext*(front: Frontend, index: int) =
  ## Store exact identity and revalidate before dispatch, never a recycled index.
  front.contextSeat = -1
  if not front.canManagePlayer(index): return
  if front.online:
    let client = front.connection.client
    let seat = client.snapshot.seats[index]
    front.contextOwner = seat.owner
    front.contextKind = seat.name
    front.contextSeatKind = seat.kind
    front.contextRoom = client.snapshot.room
  else:
    front.contextKind = if front.localHuman == index + 1: "Human" else: "Bot"
    front.contextPolicy = front.policies[index]
  front.contextSeat = index
  front.contextArmed = false

proc activateContext*(front: Frontend) =
  ## Revalidates the target before leaving a slot, removing a bot, or kicking.
  let index = front.contextSeat
  if not front.canManagePlayer(index):
    reject("Player action is no longer available")
  if front.online:
    let client = front.connection.client
    if client.snapshot.room != front.contextRoom or index >= client.snapshot.seats.len:
      reject("Room changed")
    let seat = client.snapshot.seats[index]
    if seat.owner != front.contextOwner or seat.name != front.contextKind or
      seat.kind != front.contextSeatKind:
      reject("Player changed")
    var present = false
    for participant in client.snapshot.participants:
      if participant.id == seat.owner: present = true
    if not present: reject("Player left")
    if seat.kind == HumanSeat and seat.owner != client.participant:
      client.send(RoomMessage(kind: KickParticipant, participant: seat.owner))
    else:
      front.removePlayer(index)
  else:
    if (front.localHuman == index + 1) != (front.contextKind == "Human") or
      front.policies[index] != front.contextPolicy:
        reject("Player changed")
    front.removePlayer(index)
  front.contextSeat = -1

proc fillBots*(front: Frontend, bot = TruceBot) =
  ## Fills only open seats with the chosen bundled policy.
  if not front.administer() or front.synchronizing(): reject("Only host can fill bots")
  let policy = LobbyBotPolicies[bot]
  for i in 0 ..< front.config.players:
    if front.online:
      let client = front.connection.client
      if client.snapshot.seats[i].owner == 0:
        front.networkPolicies[i] = policy
        client.send(RoomMessage(kind: ClaimSeat, seat: i.uint32,
          seatKind: BotSeat, name: policy.name))
    elif front.localHuman != i + 1 and front.policies[i].bytes.len == 0:
      front.policies[i] = policy

proc shuffleTeam*(front: Frontend) =
  if not front.administer() or front.synchronizing(): reject("Only host can shuffle")
  var seats: seq[int]
  for i in 0 ..< front.config.players:
    if not front.online or front.connection.client.snapshot.seats[i].owner ==
      front.connection.client.participant: seats.add i
  var shuffled: seq[int]
  for index in seats: shuffled.add index
  front.rng.shuffle(shuffled)
  let policies = if front.online: front.networkPolicies else: front.policies
  let human = front.localHuman
  for j, destination in seats:
    let source = shuffled[j]
    if front.online:
      front.networkPolicies[destination] = policies[source]
      front.connection.client.send(RoomMessage(kind: ClaimSeat, seat: destination.uint32,
        name: front.connection.client.snapshot.seats[source].name,
        seatKind: front.connection.client.snapshot.seats[source].kind))
    else:
      front.policies[destination] = policies[source]
      if source + 1 == human: front.localHuman = destination + 1

proc kickPlayer*(front: Frontend, index: int) =
  ## Requests an existing host-authorized participant kick for a human only.
  if not front.online or front.pendingConfig.len > 0: reject("Not in an editable lobby")
  let client = front.connection.client
  if index notin 0 ..< client.snapshot.seats.len: reject("Unknown player")
  let seat = client.snapshot.seats[index]
  if client.snapshot.participant != client.participant or
    seat.kind != HumanSeat or seat.owner in [0'u32, client.participant]:
      reject("Only the host can kick another human participant")
  client.send(RoomMessage(kind: KickParticipant, participant: seat.owner))

proc refreshRooms*(front: Frontend, now: float64, manual = false) =
  ## Explicit monotonic clock keeps browser polling deterministic and testable.
  if front.page != MultiplayerMenu or front.connection == nil or
    not front.connection.client.connected or not front.connection.client.welcomed or
    front.connection.client.snapshot.room.len > 0:
    front.roomsRefreshArmed = false
    return
  if manual or not front.roomsRefreshArmed or now < front.roomsRefreshedAt or
    now - front.roomsRefreshedAt >= 1.0 - 1e-9:
    front.connection.client.send(RoomMessage(kind: ListRooms))
    front.roomsRefreshedAt = now
    front.roomsRefreshArmed = true

proc syncLobby*(front: Frontend)

proc pump*(front: Frontend) =
  ## Handles room updates, reconnects, readiness revisions, and match starts.
  if front.page == MultiplayerMenu and not front.needsPlayerName() and not front.editingPlayer:
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
    front.roomsRefreshArmed = false
    return
  front.connection.pump()
  front.syncLobby()
  front.refreshRooms(getMonoTime().ticks.float64 / 1_000_000_000)

proc syncLobby*(front: Frontend) =
  ## Caches local setup and starts from the immutable shared initialization.
  let client = front.connection.client
  if client.error.len > 0:
    let claimRace = front.autoSeatPending and front.autoSeatClaim >= 0 and
      (client.error == "Seat belongs to another participant" or
        (front.autoSeatClaim >= client.snapshot.seats.len and
          client.error == "Seat is outside this room"))
    if claimRace:
      front.autoSeatClaim = -1
    else:
      front.error = client.error
    if front.pendingConfig.len > 0 and client.snapshot.payload.len > 0:
      front.config = parseConfig(client.snapshot.payload)
    front.pendingConfig = ""
    client.error = ""
  if client.welcomed and front.pendingJoin and client.snapshot.room.len == 0:
    client.send(RoomMessage(kind: JoinRoom, room: front.invite))
    front.pendingJoin = false
  if client.snapshot.room.len == 0:
    front.pendingConfig = ""
    front.autoSeatRoom = ""
    front.autoSeatPending = false
    front.autoSeatClaim = -1
    front.contextSeat = -1
    front.ui.selectedSeat = -1
    front.ui.fillBotMenu = LobbyBotMenu()
    if front.localConfig != nil:
      front.config = front.localConfig
      front.localConfig = nil
    front.prepared = nil
    front.revision = 0
    front.readyAttempt = 0
    if front.online:
      front.online = false
      front.page = MultiplayerMenu
    return
  if not front.online and front.localConfig == nil:
    front.localConfig = parseConfig(front.config.toJson())
  front.online = true
  # Lobby is the authoritative end of the previous match for every participant,
  # not just the host who clicked ReturnLobby. Retain seats/config/private policy
  # bytes, but never reuse a started simulation as the next setup confirmation.
  if client.snapshot.phase == Lobby and front.prepared != nil and front.prepared.started:
    front.prepared = nil
    front.launch = nil
    front.readyAttempt = 0
  if front.prepared == nil or not front.prepared.started:
    front.page = LobbyMenu
  if front.revision != client.snapshot.revision:
    front.matchName = client.snapshot.name
    front.contextSeat = -1
    front.ui.selectedSeat = -1
    front.ui.fillBotMenu = LobbyBotMenu()
    front.config = parseConfig(client.snapshot.payload)
    front.revision = client.snapshot.revision
    if front.prepared != nil and not front.prepared.started:
      front.prepared = nil
    if front.pendingConfig == client.snapshot.payload:
      front.pendingConfig = ""
  front.claimJoiningSeat()
  if client.snapshot.phase == Lobby and front.prepared == nil and
    not front.autoSeatPending:
      var connected, ownsSeat: bool
      for participant in client.snapshot.participants:
        if participant.id == client.participant:
          connected = participant.connected
      for i, seat in client.snapshot.seats:
        if seat.owner == client.participant:
          ownsSeat = true
      if connected and ownsSeat and front.readyAttempt != client.snapshot.revision:
        front.readyAttempt = client.snapshot.revision
        try:
          front.prepared = prepareMatch(client, front.sources())
        except GalconError, RoomsError, PolicyError:
          front.error = getCurrentExceptionMsg()
  if client.events.len > 0:
    let event = client.events[0]
    client.events.delete(0)
    if front.prepared == nil or front.prepared.revision != event.revision:
      front.prepared = prepareMatch(client, front.sources())
    front.prepared.start(event)
    front.launch = front.prepared.session
  if front.prepared != nil and front.prepared.started:
    front.prepared.refreshControllers(front.sources())
    front.prepared.resumeCommands()

proc localMatch*(front: Frontend): Session =
  ## Starts the configured FFA with the exact visible roster.
  var policies, names: seq[string]
  var human = 0
  for i in 0 ..< front.config.players:
    if i + 1 == front.localHuman:
      policies.add ""
      names.add front.preferences.name
      human = names.len
    elif front.policies[i].bytes.len > 0:
      policies.add loadPolicy(front.policies[i].bytes).source
      names.add front.policies[i].name
  if names.len == 0: reject("Assign at least one player")
  let options = front.config.matchOptions()
  options.playerCount = names.len
  options.setup = options.matchSetup(front.config.difficulty)
  newSession(options, policies, names, human, true)

proc settingsScale*(front: Frontend, proposed: float32): float32 =
  ## Freeze the settings canvas during pointer capture; apply scale on release.
  if front.slider >= 0: front.sliderScale else: proposed

proc begin(front: Frontend, sk: Silky, window: Window, title: string): LobbyLayout =
  ## Fits the approved Galcon layout without repeating the main-menu logo.
  sk.uiScale = front.settingsScale(selectedUiScale(min(window.size.x.float32 / 1514,
    window.size.y.float32 / 970), 1080.0'f / 970))
  sk.beginUi(window, window.size)
  sk.textStyle = "LobbyBody"
  let
    view = window.size.vec2 / sk.uiScale
    origin = (view - vec2(1514, 970)) / 2
    top = if front.page == MultiplayerMenu: 224.0'f else: 142.0'f
  sk.clearScreen(rgbx(0, 0, 0, 255))
  sk.drawSpaceCover(vec2(0), view)
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
  if front.menuButton(sk, if connected: "reconnect" else: "connect",
    at + vec2(1080, 16), 190):
      front.connect()
  sk.lobbyLabel(if connected: "online" else: "offline",
    at + vec2(1290, 16), 150, tint = if connected: MenuGreen else: LobbyMuted)
  sk.lobbyPanel(layout.left, vec2(layout.leftWidth, layout.panelHeight))
  let list = layout.left + vec2(24)
  sk.lobbyLabel("public rooms", list, 600, "LobbyHeading", MenuGreen)
  if front.menuButton(sk, "refresh", list + vec2(704, 0), 178, enabled = connected):
    front.refreshRooms(getMonoTime().ticks.float64 / 1_000_000_000, manual = true)
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
    if front.menuButton(sk, if room.phase == Lobby: "join" else: "watch",
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
  if front.menuButton(sk, "public", create + vec2(0, 168), 220,
    selected = front.publicRoom):
      front.publicRoom = true
  if front.menuButton(sk, "private", create + vec2(232, 168), 220,
    selected = not front.publicRoom):
      front.publicRoom = false
  if front.menuButton(sk, "create room", create + vec2(0, 232), 452,
    enabled = connected and front.roomName.strip().len > 0):
      front.createRoom()
  sk.lobbyLabel("join by invite", create + vec2(0, 332), 452,
    "LobbyHeading", MenuGreen)
  sk.lobbyLabel("link or room code", create + vec2(0, 388), 452)
  sk.lobbyInput(window, "invite", front.invite, create + vec2(0, 432), 452)
  if front.menuButton(sk, "join room", create + vec2(0, 496), 452,
    enabled = connected and front.invite.strip().len > 0):
      if '?' in front.invite:
        for key, value in decodeQuery(parseUri(front.invite).query):
          if key == "room": front.invite = value
      front.pendingJoin = true
  if front.menuButton(sk, "back", layout.footer, 190):
    front.leave()

proc configPanel(front: Frontend, sk: Silky, window: Window,
    at: Vec2, height: float32, enabled: bool) =
  ## Previews the real deterministic map and edits typed match settings.
  let before = front.config.toJson()
  let oldPlayers = front.config.players
  sk.lobbyPanel(at, vec2(500, height))
  let point = at + vec2(24)
  sk.lobbyLabel("match settings", point, 452, "LobbyHeading", MenuGreen)
  if front.online:
    if front.matchName.len == 0: front.matchName = front.connection.client.snapshot.name
    if enabled:
      sk.lobbyInput(window, "gameName", front.matchName, point + vec2(0, 48), 330)
      if front.menuButton(sk, "save", point + vec2(342, 48), 110,
        enabled = validName(front.matchName) and front.matchName != front.connection.client.snapshot.name):
          front.renameGame(front.matchName)
    else:
      sk.lobbyLabel(front.connection.client.snapshot.name, point + vec2(0, 48), 452, tint = LobbyMuted)
  else:
    sk.lobbyLabel(if front.roomName.len > 0: front.roomName else: "Local battle",
      point + vec2(0, 48), 452)
  let content = point + vec2(0, 48)
  if front.previewKey != before:
    front.preview = newWorld(front.config.matchOptions().setup)
    front.previewKey = before
  sk.lobbyPanel(content + vec2(0, 54), vec2(452, 164), true)
  for planet in front.preview.planets:
    let
      c = Colors[planet.owner]
      pos = content + vec2(112, 58) +
        vec2(planet.x.toFloat32, planet.y.toFloat32) * 0.32'f
      size = max(2.0'f, planet.radius.float32 * 0.32'f)
    sk.drawRect(pos - vec2(size / 2), vec2(size), rgbx(c[0], c[1], c[2], 255))
  sk.lobbyNumber("players", front.config.players, content + vec2(0, 230),
    452, 2, MaxPlayers, 1, enabled)
  front.config.planets = max(front.config.planets, front.config.players)
  sk.lobbyNumber("planets", front.config.planets, content + vec2(0, 278),
    452, front.config.players, MaxPlanets, 1, enabled)
  sk.lobbyNumber("map seed", front.config.seed, content + vec2(0, 326),
    452, 0'i32, int32.high - 1, 1'i32, enabled)
  var minutes = front.config.maximumTicks div (TickRate * 60)
  sk.lobbyNumber("minutes", minutes, content + vec2(0, 374),
    452, 1'i32, 30'i32, 1'i32, enabled)
  if enabled: front.config.maximumTicks = minutes * TickRate * 60
  sk.lobbyLabel("difficulty", content + vec2(0, 422), 190)
  front.menuSelect(sk, window, front.config.difficulty, [Easy, Medium, Hard, Crazy],
    content + vec2(196, 422), 256, enabled)
  if enabled:
    sk.at = content + vec2(0, 478)
    front.menuCheckBox(sk, window, "enemy fleets pass through", front.config.enemyShipsPassThrough)
    sk.at = content + vec2(0, 526)
    front.menuCheckBox(sk, window, "neutrals do not grow", front.config.neutralsDontProduce)
    sk.at = content + vec2(0, 566)
    front.menuCheckBox(sk, window, "Balanced Map", front.config.balancedMap)
  else:
    sk.lobbyLabel("fleets pass through: " & $front.config.enemyShipsPassThrough,
      content + vec2(0, 478), 452)
    sk.lobbyLabel("neutrals don't grow: " & $front.config.neutralsDontProduce,
      content + vec2(0, 526), 452)
    sk.lobbyLabel("Balanced Map: " & $front.config.balancedMap,
      content + vec2(0, 566), 452)
  sk.lobbyLabel("neutral ships: " &
    (if front.config.neutralsDontProduce: "0-100" else: "classic"),
    content + vec2(0, 606), 452, tint = LobbyMuted)
  let after = front.config.toJson()
  if enabled and front.online and after != before:
    front.pendingConfig = after
    let prior = parseConfig(before)
    prior.players = front.config.players
    front.connection.client.send(RoomMessage(kind:
      if prior.toJson() == after and oldPlayers != front.config.players:
        ResizeRoom else: ConfigureRoom,
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
    modal = front.ui.selectedSeat >= 0 or front.contextSeat >= 0 or
      front.contextDismissed or front.ui.fillBotMenu.open
    enabled = editable and not front.synchronizing() and not modal
  sk.lobbyPanel(layout.left, vec2(930, layout.panelHeight))
  let at = layout.left + vec2(24)
  sk.lobbyLabel("players", at, 600, "LobbyHeading", MenuGreen)
  sk.lobbyLabel(if front.synchronizing(): "synchronizing roster..."
    else: "free for all / right-click a player for actions",
    at + vec2(0, 42), 850, tint = LobbyMuted)
  let area = rect(at + vec2(0, 94), vec2(882, layout.panelHeight - 268))
  sk.frameScrollbars(window, front.rosterScroll, area,
    vec2(882, ((front.config.players + 1) div 2).float32 * 74), vec2(1))
  sk.pushClipRect(rect(area.xy, area.wh - vec2(20, 0)))
  var emptyCount, ownCount: int
  for i in 0 ..< front.config.players:
    let
      seat = if online and i < snapshot.seats.len: snapshot.seats[i] else: Seat()
      empty = if online: seat.owner == 0
        else: front.localHuman != i + 1 and front.policies[i].bytes.len == 0
      mine = not online or seat.owner == client.participant
      human = if online: seat.kind == HumanSeat else: front.localHuman == i + 1
      point = area.xy + vec2((i mod 2).float32 * 436,
        (i div 2).float32 * 74) - front.rosterScroll.scrollPos
      color = Colors[i + 1]
      visible = overlaps(rect(point, vec2(418, 64)), area)
      hovered = visible and overlaps(window.mousePos.vec2 / sk.uiScale,
        rect(point, vec2(418, 64))) and
        overlaps(window.mousePos.vec2 / sk.uiScale, area)
    if enabled and hovered and window.buttonPressed[MouseRight]:
      front.playerContext(i)
      front.contextAt = point + vec2(80, 10)
    if empty:
      inc emptyCount
    if mine and not empty: inc ownCount
    var label = if empty: "open slot"
      elif human: front.preferences.name
      elif online: seat.name else: front.policies[i].name
    var status = if empty: "empty slot" elif human: "human" else: "bot"
    if online and not empty:
      for participant in snapshot.participants:
        if participant.id == seat.owner:
          if human: label = participant.name
          status = if participant.ready: "ready" else: "not ready"
    if front.menuButton(sk, "", point, 418, height = 64,
      enabled = enabled and visible and hovered and (owner or mine or empty)):
        front.ui.selectedSeat = i
    sk.drawRect(point + vec2(12, 20), vec2(24, 24),
      if empty: rgbx(95, 98, 103, 255) else: rgbx(color[0], color[1], color[2], 255))
    sk.lobbyLabel(label,
      point + vec2(48, 0), 360, tint = if empty: LobbyMuted else: rgbx(240, 237, 225, 255))
    sk.lobbyLabel(status, point + vec2(48, 28), 360,
      tint = if online and not empty: readinessColor(status == "ready")
        else: LobbyMuted)
  sk.popClipRect()
  let fill = layout.left + vec2(24, layout.panelHeight - 142)
  if owner:
    if front.menuButton(sk, "shuffle team", fill + vec2(436, 0), 418,
      enabled = enabled): front.shuffleTeam()
  sk.lobbyLabel(if online: "Shuffles host-owned slots only; guests keep their seats."
    else: "each color is an independent player",
    fill + vec2(0, 54), 880, tint = LobbyMuted)
  when not defined(emscripten):
    let previousSave = front.replayPreferences.saveReplay
    sk.at = layout.left + vec2(24, layout.panelHeight - 40)
    if not modal:
      front.menuCheckBox(sk, window, "Save replay",
        front.replayPreferences.saveReplay)
    else:
      sk.lobbyLabel("Save replay: " &
        (if front.replayPreferences.saveReplay: "On" else: "Off"),
        sk.at, 300, tint = LobbyMuted)
    if previousSave != front.replayPreferences.saveReplay:
      front.replayPreferences.saveReplayPreferences()
  front.configPanel(sk, window, layout.right, layout.panelHeight, enabled and owner)
  if front.menuButton(sk, "back", layout.footer, 190, enabled = not modal):
    if online:
      client.send(RoomMessage(kind: LeaveRoom))
      front.online = false
      front.prepared = nil
      front.page = MultiplayerMenu
    else: front.page = HomeMenu
  if online:
    if front.menuButton(sk, "copy invite", layout.footer + vec2(206, 0), 230,
      enabled = not modal):
        copyInvite(inviteBase() & "?server=" & encodeUrl(front.preferences.server) &
          "&room=" & encodeUrl(snapshot.room))
    var selfReady = false
    for participant in snapshot.participants:
      if participant.id == client.participant:
        selfReady = participant.ready
    if front.menuButton(sk, "ready", layout.footer + vec2(452, 0), 190,
      enabled = enabled and ownCount > 0):
        client.send(RoomMessage(kind: ReadyStatus, flag: not selfReady))
    # Galcon has no shared status-icon atlas; keep GotA's readiness colors
    # directly on the button without changing its label or interaction.
    sk.drawRect(layout.footer + vec2(468, 16), vec2(12),
      if enabled and ownCount > 0: readinessColor(selfReady)
      else: sk.theme.disabledTextColor)
  if owner and front.menuButton(sk, if online and snapshot.phase in {Ended, Desynced}:
    "return to lobby" else: "start game", layout.primary, 250,
    enabled = not modal and owner and not front.synchronizing() and
      emptyCount < front.config.players, tint = rgbx(143, 255, 162, 255)):
      if online:
        if snapshot.phase in {Ended, Desynced}:
          client.send(RoomMessage(kind: ReturnLobby))
        else:
          client.send(RoomMessage(kind: StartMatch, revision: snapshot.revision,
            hash: setupHash(snapshot)))
        if snapshot.phase in {Ended, Desynced}: front.prepared = nil
      else:
        front.launch = front.localMatch()
  if front.contextSeat >= 0:
    let index = front.contextSeat
    let valid = front.canManagePlayer(index)
    let seat = if online and valid: snapshot.seats[index] else: Seat()
    let human = if online: front.contextSeatKind == HumanSeat
      else: front.contextKind == "Human"
    let action = if online and human and seat.owner != client.participant:
        "kick player"
      elif human: "leave slot"
      else: "remove bot"
    let popup = vec2(clamp(front.contextAt.x, 0.0'f,
      window.size.x.float32 / sk.uiScale - 280),
      clamp(front.contextAt.y, 0.0'f,
        window.size.y.float32 / sk.uiScale - 176))
    sk.lobbyPanel(popup, vec2(280, 176))
    sk.lobbyLabel("player actions", popup + vec2(12, 0), 256)
    if front.menuButton(sk, action,
      popup + vec2(12, 44), 256, enabled = valid) and
      front.contextArmed:
        front.activateContext()
    let inside = overlaps(window.mousePos.vec2 / sk.uiScale, rect(popup, vec2(280, 176)))
    if window.buttonPressed[MouseLeft]:
      front.contextArmed = inside
      if not inside:
        front.contextSeat = -1
        front.contextDismissed = true
    if front.menuButton(sk, "cancel", popup + vec2(12, 104), 256) or
      window.buttonPressed[KeyEscape]:
        front.contextSeat = -1
  if front.ui.selectedSeat >= 0:
    var knownBot = false
    for policy in LobbyBotPolicies:
      if policy.name == front.ui.selectedSeatBot:
        knownBot = true
        break
    if not knownBot:
      front.ui.selectedSeatBot = LobbyBotPolicies[TruceBot].name
    let choice = sk.seatPicker(window, front.ui, LobbyBotPolicies)
    if choice.chosen:
      front.emitUiCue(UiClick)
      let index = front.ui.selectedSeat
      var policy: LocalPolicy
      if not choice.clear and not choice.human:
        policy = if choice.file: selectPolicy()
          else: LobbyBotPolicies[LobbyBot(choice.bot)]
        if policy.bytes.len == 0: return
      if online:
        if choice.human: client.claimHuman(index)
        elif choice.clear: client.send(RoomMessage(kind: ReleaseSeat, seat: index.uint32))
        else:
          front.networkPolicies[index] = policy
          client.send(RoomMessage(kind: ClaimSeat, seat: index.uint32,
            seatKind: BotSeat, name: policy.name))
      else:
        if choice.human: front.localHuman = index + 1
        elif front.localHuman == index + 1: front.localHuman = 0
        front.policies[index] = policy
      front.ui.selectedSeat = -1
  if owner:
    let
      wasOpen = front.ui.fillBotMenu.open
      canFill = editable and not front.synchronizing() and
        front.ui.selectedSeat < 0 and front.contextSeat < 0 and
        not front.contextDismissed and emptyCount > 0
    var choice = "Fill"
    let selectorHeight = sk.atlas.fonts[sk.textStyle].lineHeight +
      sk.theme.padding.float32 * 2
    if canFill:
      sk.lobbyBotSelect(window, choice, LobbyBotNames,
        front.ui.fillBotMenu, fill, 420)
    else:
      front.ui.fillBotMenu = LobbyBotMenu()
      discard front.menuButton(sk, "", fill, 420,
        enabled = false, height = selectorHeight)
      let
        arrowSize = sk.getImageSize("droparrow")
        padding = sk.theme.padding.float32
      sk.drawLabel(choice, fill + vec2(padding, 0),
        vec2(420 - arrowSize.x - padding * 3, selectorHeight),
        sk.theme.disabledTextColor, sk.textStyle)
      sk.drawImage("droparrow", fill + vec2(
        420 - arrowSize.x - padding,
        (selectorHeight - arrowSize.y) / 2
      ), sk.theme.disabledTextColor)
    front.menuHover(sk, rect(fill, vec2(420, selectorHeight)), canFill)
    if choice != "Fill" or (canFill and wasOpen != front.ui.fillBotMenu.open):
      front.emitUiCue(UiClick)
    if choice != "Fill":
      for bot in LobbyBot:
        if choice == LobbyBotNames[bot]:
          front.fillBots(bot)
          break
      front.ui.fillBotMenu = LobbyBotMenu()
    elif wasOpen and not front.ui.fillBotMenu.open and
      window.buttonPressed[MouseLeft]:
        front.contextDismissed = true
  else:
    front.ui.fillBotMenu = LobbyBotMenu()

proc localPercentSlider*(front: Frontend, sk: Silky, window: Window,
    id: int, value: var int, track: Rect, enabled = true) =
  ## Silky-owned, client-local integer slider with physical-pixel drag capture.
  let interaction = sk.interact(track, enabled)
  if not enabled and front.slider == id:
    front.slider = -1
  if enabled and interaction == Pressed and front.slider < 0:
    front.slider = id
    front.sliderLeft = track.x * sk.uiScale
    front.sliderWidth = track.w * sk.uiScale
    front.sliderScale = sk.uiScale
  if enabled and front.slider == id:
    let fraction = clamp((window.mousePos.x.float32 - front.sliderLeft) /
      front.sliderWidth, 0.0'f, 1.0'f)
    value = 1 + int(fraction * 99 + 0.5'f)
    if window.buttonReleased[MouseLeft] or not window.buttonDown[MouseLeft]:
      front.slider = -1
  let fraction = (value - 1).float32 / 99
  let middle = track.y + track.h / 2
  sk.drawRect(vec2(track.x, middle - 3), vec2(track.w, 6), rgbx(55, 65, 85, 255))
  sk.drawRect(vec2(track.x, middle - 3), vec2(track.w * fraction, 6),
    if enabled: rgbx(100, 185, 240, 255) else: rgbx(90, 95, 105, 255))
  sk.drawRect(vec2(track.x + clamp(track.w * fraction - 5, 0.0'f, track.w - 10),
    middle - 10), vec2(10, 20),
    if enabled: rgbx(230, 238, 255, 255) else: rgbx(110, 115, 125, 255))

proc localPercentCaptured*(front: Frontend, id: int): bool =
  front.slider == id

proc cancelLocalPercent*(front: Frontend, id: int) =
  if front.slider == id: front.slider = -1

proc settingSlider(front: Frontend, sk: Silky, window: Window,
    id: int, caption: string, value: var int, at: Vec2,
    minimum, maximum: int, enabled = true) =
  let track = at + vec2(280, 0)
  let width = 580.0'f
  let active = front.slider == id
  let interaction = sk.interact(rect(track, vec2(width, 44)), enabled)
  if not enabled and active:
    front.slider = -1
  if enabled and interaction == Pressed and front.slider < 0:
    front.slider = id
    front.sliderLeft = track.x * sk.uiScale
    front.sliderWidth = width * sk.uiScale
    front.sliderScale = sk.uiScale
  if enabled and front.slider == id:
    let fraction = clamp((window.mousePos.x.float32 - front.sliderLeft) /
      front.sliderWidth, 0.0'f, 1.0'f)
    value = minimum + int(fraction * (maximum - minimum).float32 + 0.5'f)
    if window.buttonReleased[MouseLeft] or not window.buttonDown[MouseLeft]:
      front.slider = -1
  sk.lobbyLabel(caption & "  " & $value & "%", at, 270,
    tint = if enabled: sk.theme.defaultTextColor else: LobbyMuted)
  sk.drawRect(track + vec2(0, 18), vec2(width, 8), rgbx(55, 65, 85, 255))
  let fraction = (value - minimum).float32 / (maximum - minimum).float32
  sk.drawRect(track + vec2(0, 18), vec2(width * fraction, 8),
    if enabled: rgbx(100, 185, 240, 255) else: rgbx(90, 95, 105, 255))
  sk.drawRect(track + vec2(clamp(width * fraction - 6, 0.0'f, width - 12), 7),
    vec2(12, 30), if enabled: rgbx(230, 238, 255, 255) else: rgbx(110, 115, 125, 255))

proc settings*(front: Frontend, sk: Silky, window: Window, at: Vec2): bool =
  ## Applies shared preferences using Galcon-specific controls and audio.
  let before = front.preferences.toJson()
  sk.lobbyPanel(at - vec2(24), vec2(928, 620))
  for i, caption in ["display", "sound", "controls", "networking"]:
    if front.menuButton(sk, caption, at + vec2(i.float32 * 224, 0), 208,
      selected = front.settingsTab == i):
        front.settingsTab = i
        front.captureAction = -1
        front.slider = -1
  let p = at + vec2(0, 80)
  template selectRow(caption: string, value: untyped, choices: untyped, y: float32) =
    sk.lobbyLabel(caption, p + vec2(0, y), 260)
    front.menuSelect(sk, window, value, choices, p + vec2(280, y), 580)
  case front.settingsTab
  of 0:
    selectRow("window mode", front.preferences.windowMode,
      [Windowed, Fullscreen], 0)
    selectRow("resolution", front.preferences.resolution,
      [CurrentResolution, Resolution720, Resolution900, Resolution1080,
        Resolution1440, Resolution2160], 62)
    sk.at = p + vec2(0, 136)
    front.menuCheckBox(sk, window, "visual interpolation", front.preferences.interpolation)
    selectRow("fps limit", front.preferences.fps, [30, 60, 120, 0], 196)
    selectRow("ui scaling", front.preferences.uiScaleMode,
      [AutoUiScale, CustomUiScale], 258)
    front.settingSlider(sk, window, 0, "scale", front.preferences.uiScalePercent,
      p + vec2(0, 320), 25, 200,
      front.preferences.uiScaleMode == CustomUiScale)
    sk.lobbyLabel("0 fps = unlimited", p + vec2(0, 380), 860, tint = LobbyMuted)
  of 1:
    sk.at = p
    sk.lobbyLabel("Set main volume to 0 to mute", p, 860, tint = LobbyMuted)
    front.settingSlider(sk, window, 1, "main volume", front.preferences.mainVolume,
      p + vec2(0, 70), 0, 100)
    front.settingSlider(sk, window, 2, "music volume", front.preferences.musicVolume,
      p + vec2(0, 140), 0, 100)
    front.settingSlider(sk, window, 3, "effects volume", front.preferences.fxVolume,
      p + vec2(0, 210), 0, 100)
    front.settingSlider(sk, window, 4, "interface volume", front.preferences.uiVolume,
      p + vec2(0, 280), 0, 100)
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
      if front.menuButton(sk, if front.captureAction == i: "press a key..."
        else: front.preferences.bindings[control.action][0].bindingLabel,
        row + vec2(500, 0), 360, enabled = front.captureAction < 0):
          front.captureAction = i
    sk.lobbyLabel("tab: scores   enter: chat   0-9: fleet size",
      p + vec2(0, 336), 860, tint = LobbyMuted)
    if front.menuButton(sk, "reset controls", p + vec2(0, 390), 360):
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
  if front.menuButton(sk, "save and back", at + vec2(0, 520), 300,
    enabled = front.captureAction < 0):
      if front.preferences.name.strip().len == 0 or front.preferences.name.len > 64:
        raise newException(GalconError, "Player name must be 1 to 64 characters")
      discard serverUrl(front.preferences.server)
      front.preferences.savePreferences(AppName)
      result = true

proc cancelSettingsCapture*(front: Frontend): bool =
  ## Escape first cancels rebinding rather than closing its parent overlay.
  result = front.captureAction >= 0 or front.slider >= 0
  front.captureAction = -1
  front.slider = -1

proc nameDialogOpen*(front: Frontend): bool =
  front.editingPlayer or front.needsPlayerName()

proc identityUi*(front: Frontend, sk: Silky, window: Window): bool =
  ## Return true while the name dialog owns the complete input frame.
  if front.editingPlayer or front.needsPlayerName():
    result = true
    let view = window.size.vec2 / sk.uiScale
    let at = (view - vec2(620, 260)) * 0.5'f
    sk.drawRect(vec2(0), view, rgbx(0, 0, 0, 210))
    sk.lobbyPanel(at, vec2(620, 260))
    sk.lobbyLabel(if front.needsPlayerName(): "Please enter your player name"
      else: "Change your player name", at + vec2(24, 20), 572, "LobbyHeading")
    sk.lobbyInput(window, "newPlayerName", front.playerDraft, at + vec2(24, 80), 572)
    let valid = confirmedPlayerName(front.playerDraft)
    if front.menuButton(sk, "Cancel", at + vec2(24, 188), 180) or window.buttonPressed[KeyEscape]:
      front.editingPlayer = false
      front.playerDraft = ""
      front.page = HomeMenu
    elif front.menuButton(sk, if front.needsPlayerName(): "Continue" else: "Save",
      at + vec2(396, 188), 200, enabled = valid) or
      (valid and window.buttonPressed[KeyEnter]):
        front.savePlayerName(front.playerDraft)
    return
  let
    view = window.size.vec2 / sk.uiScale
    label = if front.preferences.name.len == 0: "Player name"
      else: front.preferences.name
    enabled = not front.ui.fillBotMenu.open and not front.contextDismissed and
      (not front.online or front.connection.client.snapshot.phase == Lobby)
  if front.menuButton(sk, sk.fittedLabel(label, 180, "LobbyBody"),
    vec2(view.x - 264, 16), 240, "character", enabled):
    front.playerDraft = front.preferences.name
    front.editingPlayer = true
    result = true

proc draw*(front: Frontend, sk: Silky, window: Window) =
  ## Renders native Silky menus and reports launch transitions to the game view.
  when not defined(emscripten):
    if front.browsingReplays:
      front.replayAction = sk.drawReplayBrowser(window, front.replayBrowser)
      sk.endUi()
      return
  let title = case front.page
    of SettingsMenu: "settings"
    of MultiplayerMenu: "multiplayer"
    else: "battle setup"
  let wasModal = front.ui.selectedSeat >= 0 or front.captureAction >= 0 or
    front.contextSeat >= 0 or front.ui.fillBotMenu.open
  let layout = front.begin(sk, window, title)
  try:
    if front.identityUi(sk, window):
      sk.endUi()
      return
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
  when not defined(emscripten):
    if front.unsavedReplays.len > 0 and not wasModal:
      if front.menuButton(sk, "Retry saving replay",
        layout.origin + vec2(32, 84), 300):
          front.retryReplayRequested = true
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
  if front.contextDismissed and window.buttonReleased[MouseLeft]:
    front.contextDismissed = false
  sk.endUi()
