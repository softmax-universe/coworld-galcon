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
  playback.seek(300)
  doAssert playback.world.fingerprint() == hash
  playback.seek(33)
  doAssert playback.world.chatCount == 4
  playback.seek(300)
  doAssert playback.world.fingerprint() == hash
  playback.names[2] = "Another Bot"
  doAssert playback.world.fingerprint() == hash
  removeFile(path)
