import
  std/[os, strutils],
  bassy,
  galcon/[common, worlds, chats, bots, sessions, options, replays]

const
  ChatPolicy = """
name$ = playerName$(selfPlayer())
color$ = playerColor$(selfPlayer())
addressColor$ = mailboxName$(mailboxSelf())
message$ = pullMailbox$()
if message$ <> "" then
  last$ = message$
  channel = mailboxId()
end if
if worldTick() mod 32 = 0 then
  sent = sendChat(-2, "Ready.")
  duplicate = sendChat(-2, "Spam.")
  private = sendChat(0, "Hidden.")
end if
"""
  ReactivePolicy = """
message$ = pullMailbox$()
if message$ = "Green: Go 空🙂" then
  source = -1
  target = -1
  for p = 0 to planetCount() - 1
    if owner(p) = selfPlayer() then source = p
    if owner(p) = 1 then target = p
  next p
  sent = launch(source, target, 3)
  replied = sendChat(-2, "On my way 空🙂")
end if
"""

proc expectChatDivergence(recording: Recording, tick: int32) =
  ## Requires a changed chat tape to fail at its first affected tick.
  let world = newWorld(recording.setup)
  var
    cursor = 0
    rejected = false
  try:
    while world.tick < recording.hashes.len.int32:
      recording.replayTick(world, cursor)
  except GalconError as error:
    doAssert error.msg == "Replay diverged at tick " & $tick
    rejected = true
  doAssert rejected, "Missing or altered replay chat must not pass verification"

proc testChats*() =
  ## Checks color-only mailboxes, bounded chat, replay hashes, and scrubbing.
  echo "Global chat exposes color names through Polyworld mailboxes"
  let
    world = newWorld(configuredSetup(8, Easy, 5, 26))
    hub = newChatHub(world)
    brain = newBrain(world, 3, ChatPolicy, hub)
  doAssert hub.sendChat(2, -2, " Hello\nGreen. ") == 5
  doAssert hub.sendChat(2, -2, "Again") == 0
  doAssert hub.sendChat(1, -1, "Team") == 0
  doAssert hub.sendChat(1, 2, "Private") == 0
  doAssert hub.sendChat(0, -2, "Nobody") == 0
  doAssert hub.sendChat(1, -2, "\xFF") == 0
  doAssert hub.sendChat(1, -2, " ") == 0
  doAssert hub.sendChat(1, -2, repeat('a', MaxChatBytes)) == 0
  brain.decide()
  doAssert not brain.failed, brain.error
  doAssert brain.runtime.getStringGlobal("name$") == "Blue"
  doAssert brain.runtime.getStringGlobal("color$") == "Blue"
  doAssert brain.runtime.getStringGlobal("addressColor$") == "Blue"
  doAssert brain.runtime.getStringGlobal("last$") == "Red: Hello Green."
  doAssert brain.runtime.getGlobal("channel") == -2
  doAssert brain.runtime.getGlobal("sent") == 5
  doAssert brain.runtime.getGlobal("duplicate") == 0
  doAssert brain.runtime.getGlobal("private") == 0
  for first in 1 .. MaxPlayers:
    for second in first + 1 .. MaxPlayers:
      doAssert playerName(first) != playerName(second)
  let copy = world.clone()
  copy.chats[0].text[0] = 'X'
  doAssert world.chats[0].text[0] == 'H'

  echo "Chat rings, mailbox limits, and delivery do not allocate per message"
  let bounded = newChatHub(newWorld(defaultSetup()))
  when defined(nimTypeNames):
    let before = getMemCounters()
  for i in 0 ..< 140:
    bounded.world.tick = i.int32
    bounded.world.chatOrderCount = 0
    discard bounded.sendChat(1, -2, "Hello.")
  when defined(nimTypeNames):
    let after = getMemCounters()
    doAssert after[0] == before[0]
    doAssert after[1] == before[1]
  doAssert bounded.world.chatCount == MaxChatLines
  doAssert bounded.inboxes[1].count == 100
  doAssert bounded.inboxes[2].count == 100
  doAssert bounded.world.chats[bounded.world.chatFirst].tick == 124

  echo "Recorded global chat follows live and file replay scrubbing"
  let
    path = Root / "build" / "chat-test.replay"
    green = Root / "build" / "Green Bot.bas"
    red = Root / "build" / "Andre Bot.bas"
  writeFile(green, ChatPolicy)
  writeFile(red, ChatPolicy)
  let
    live = newSession(parseOptions(@[
      "--headless", "--players", "2", "--ticks", "640", "--record", path,
      "--bot", green, "--bot", red
    ]))
  removeFile(green)
  removeFile(red)
  doAssert live.displayName(2) == "Andre Bot"
  doAssert live.recording.names[2] == "Andre Bot"
  for i in 0 ..< 300:
    live.step()
  let
    hash = live.world.fingerprint()
    unread = live.chat.inboxes[1].count
    decisions = live.brains[1].decisions
  doAssert live.world.chatCount == MaxChatLines
  doAssert live.recording.chats.len == 20
  for i, message in live.recording.chats:
    doAssert message.tick == (i div 2 * 32).int32
    doAssert message.player == (if i mod 2 == 0: 2 else: 1)
    doAssert message.chatText() == "Ready."
  doAssert live.brains[2].runtime.getStringGlobal("name$") == "Red"
  doAssert live.brains[2].runtime.getStringGlobal("color$") == "Red"
  doAssert live.brains[2].runtime.getStringGlobal("addressColor$") == "Red"
  doAssert not live.brains[1].runtime.getStringGlobal("last$").contains("Andre")
  doAssert not live.brains[2].runtime.getStringGlobal("last$").contains("Bot")
  let cloned = live.recording.clone()
  cloned.names[2][0] = 'X'
  doAssert live.recording.names[2] == "Andre Bot"
  live.seek(0)
  doAssert live.world.chatCount == 0
  live.seek(33)
  doAssert live.world.chatCount == 4
  doAssert live.chat.inboxes[1].count == unread
  doAssert live.brains[1].decisions == decisions
  live.seek(300)
  doAssert not live.inHistory
  doAssert live.world.fingerprint() == hash
  live.finish()
  let playback = newSession(parseOptions(@["--headless", "--replay", path]))
  doAssert playback.displayName(2) == "Andre Bot"
  doAssert playback.replay.chats == live.recording.chats
  playback.seek(300)
  doAssert playback.world.fingerprint() == hash
  playback.seek(33)
  doAssert playback.world.chatCount == 4
  playback.seek(300)
  doAssert playback.world.fingerprint() == hash
  playback.names[2] = "Another Bot"
  doAssert playback.world.fingerprint() == hash
  removeFile(path)

  echo "Missing, edited, reordered, or mistimed chat fails replay verification"
  for change in 0 .. 4:
    let damaged = live.recording.clone()
    case change
    of 0:
      damaged.chats.setLen(0)
    of 1:
      damaged.chats.delete(0)
    of 2:
      damaged.chats[0].text[0] = 'X'
    of 3:
      swap(damaged.chats[0], damaged.chats[1])
    else:
      damaged.chats[0].tick = 1
      damaged.chats[1].tick = 1
    damaged.expectChatDivergence(0)
  let missingLater = live.recording.clone()
  missingLater.chats.delete(10)
  missingLater.expectChatDivergence(160)

  echo "Human chat and the bot orders it triggers survive saves and seeking"
  block:
    let
      path = Root / "build" / "human-chat-test.replay"
      live = newSession(
        parseOptions(@[
          "--headless", "--players", "2", "--ticks", "300", "--record", path
        ]),
        @["", ReactivePolicy],
        @["Human", "Reactive Bot"],
        1,
        true
      )
    defer:
      removeFile(path)
    for tick in 0 ..< 300:
      if tick == 7:
        doAssert live.chat.sendChat(1, -2, " Go 空🙂\n") == 2
      live.step()
    doAssert not live.brains[2].failed, live.brains[2].error
    doAssert live.recording.chats.len == 2
    doAssert live.recording.chats[0].player == 1
    doAssert live.recording.chats[0].tick == 7
    doAssert live.recording.chats[0].chatText() == "Go 空🙂"
    doAssert live.recording.chats[1].player == 2
    doAssert live.recording.chats[1].tick == 7
    doAssert live.recording.chats[1].chatText() == "On my way 空🙂"
    doAssert live.recording.orders.len == 1
    doAssert live.recording.orders[0].tick == 7
    doAssert live.recording.orders[0].player == 2
    doAssert live.recording.orders[0].count == 3
    let playback = newSession(parseOptions(@["--headless", "--replay", path]))
    doAssert playback.replay.chats == live.recording.chats
    for brain in playback.brains:
      doAssert brain == nil, "Playback must use recorded bot orders"
    for tick in [300'i32, 7, 8, 129, 0, 256, 300]:
      playback.seek(tick)
      live.seek(tick)
      doAssert playback.world.fingerprint() == live.world.fingerprint()
      doAssert playback.world.chatCount == (if tick > 7: 2 else: 0)
      for i in 0 ..< playback.world.chatCount:
        let
          actual = playback.world.chats[i]
          expected = live.recording.chats[i]
        doAssert actual.tick == expected.tick
        doAssert actual.player == expected.player
        doAssert actual.chatText() == expected.chatText()
    live.seek(0)
    live.saveRecording(path)
    doAssert loadRecording(path).chats == live.recording.chats
