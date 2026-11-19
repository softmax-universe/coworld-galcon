# Multiplayer protocol

Galcon imports the shared Polyworld room protocol. The current adapter uses
room envelope version 5 and Galcon command protocol 4. Clients must have matching
game, gameplay and command-protocol identities. The relay contains no Galcon
configuration parser or game rules.

The host starts a room with its current revision and the shared setup hash. That
hash covers the initial slot assignments, controller kinds, public names, tick
rate and exact game configuration JSON. Ready is a display preference and never
blocks starting. Each client independently constructs the game and reports its
simulation hash at tick zero and subsequent checkpoints.

BeginMatch retains the initial configuration and roster. Later room snapshots
are the current administrative roster. Tick packets carry accepted command
provenance and the roster effective at the end of that tick. This keeps admitted
commands valid when a host transfers a slot before their execution, and lets late
spectators rebuild the original map before applying history.

Human and bot controller kinds are explicit fields; names such as `Human` have
no authority. The host may release or reassign any slot. Guests may claim empty
slots for themselves or their own bots and release their own slots. Bot programs
remain private to the owning client. Galcon updates local human controls and bot
execution from the tick-applied roster, without changing simulation state.

Live reassignment controls an already initialized Galcon player. Slots that were
empty at match start do not create a new empire during play; fill those slots
before the next match. The game configuration decides how many players and
planets to create. The relay does not interpret or enforce that configuration.

Clients do not originate bot, fleet or chat decisions while disconnected or
recovering historical ticks. They resume once at the live edge. An authoritative
room removal returns the client to the multiplayer menu; a transport disconnect
retains the match for reconnection.

The match duration and victory rules belong to Galcon. Match completion is
reported with its final simulation hash. The relay orders bounded packets,
checks ownership, compares hashes and retains history for reconnecting clients.

Replay version 22 stores accepted fleet launches and global chat in one action
sequence. Each tick preserves their exact acceptance order, and seeking uses one
cursor. Chat records include their acceptance position in the simulation hash,
so moving a message across a fleet order cannot silently change replay order.
Older replay layouts are rejected rather than converted.
