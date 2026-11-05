import
  std/unicode,
  common

from polyworld/mailboxes import Mailbox, newMailbox, push

const
  MaxReplayChats* = 16_384
  ChatLifetime* = TickRate * 12

type
  ChatHub* = ref object
    submit*: proc(sender, target: int, text: string): int32
    world*: World
    inboxes*: array[MaxPlayers + 1, Mailbox]

proc newChatHub*(world: World): ChatHub =
  ## Reserves bounded Polyworld inboxes for the color-only roster.
  result = ChatHub(world: world)
  for owner in 1 .. world.setup.players:
    result.inboxes[owner] = newMailbox()

proc addChat*(world: World, sender: int, text: openArray[char]): bool =
  ## Logs one clean global message per sender per tick in a fixed ring.
  if sender < 1 or sender > world.setup.players or
    text.len == 0 or text.len > MaxChatBytes - 16 or
    validateUtf8(text) >= 0 or world.chatOrderCount == MaxPlayers:
      return false
  for i in 0 ..< world.chatOrderCount:
    if world.chatOrders[i].player == sender.int32:
      return false
  var message = ChatMessage(tick: world.tick, player: sender.int32)
  for character in text:
    let clean = if character < ' ' or character == '\x7f': ' ' else: character
    if clean == ' ' and message.length == 0:
      continue
    message.text[message.length] = clean
    inc message.length
  while message.length > 0 and message.text[message.length - 1] == ' ':
    dec message.length
  if message.length == 0:
    return false
  let index = (world.chatFirst + world.chatCount) mod MaxChatLines
  world.chats[index] = message
  if world.chatCount == MaxChatLines:
    world.chatFirst = (world.chatFirst + 1) mod MaxChatLines
  else:
    inc world.chatCount
  world.chatOrders[world.chatOrderCount] = message
  inc world.chatOrderCount
  true

proc deliverChat*(
    hub: ChatHub, sender, target: int, text: openArray[char]
): int32 =
  ## Broadcasts color-prefixed text on Polyworld's global channel, -2.
  if target != -2 or not hub.world.addChat(sender, text):
    return 0
  let
    message = hub.world.chatOrders[hub.world.chatOrderCount - 1]
    name = playerName(sender)
  var
    colored: array[MaxChatBytes, char]
    length = 0
  for character in name:
    colored[length] = character
    inc length
  colored[length] = ':'
  colored[length + 1] = ' '
  length += 2
  for i in 0 ..< message.length:
    colored[length] = message.text[i]
    inc length
  for owner in 1 .. hub.world.setup.players:
    if hub.inboxes[owner].push(-2, colored.toOpenArray(0, length - 1)):
      inc result

proc chatText*(message: ChatMessage): string =
  ## Builds display text only at the graphical presentation boundary.
  result = newString(message.length)
  for i in 0 ..< message.length:
    result[i] = message.text[i]

proc sendChat*(
    hub: ChatHub, sender, target: int, text: openArray[char]
): int32 =
  ## Routes network messages through the relay before changing any inbox.
  if hub.submit != nil:
    var value = newString(text.len)
    for i, character in text:
      value[i] = character
    return hub.submit(sender, target, value)
  hub.deliverChat(sender, target, text)
