import std/importutils
import polyworld/networks
import galcon/[frontends, multiplayer]
privateAccess(Frontend)

let front = Frontend(page: MultiplayerMenu, connection: Connection(
  stats: NetworkStats(), client: RoomClient(connected: true, welcomed: true)))
proc count(): int = front.connection.client.outgoing.len
front.refreshRooms(10.0)
doAssert count() == 1
for now in [10.0, 10.1, 10.999]: front.refreshRooms(now)
doAssert count() == 1, "Rendering must not flood ListRooms"
front.refreshRooms(11.0)
doAssert count() == 2
front.refreshRooms(11.1, manual = true)
doAssert count() == 3, "Manual refresh bypasses cadence"
front.refreshRooms(12.0)
doAssert count() == 3, "Manual refresh resets automatic cadence"
front.refreshRooms(12.1)
doAssert count() == 4
front.connection.client.connected = false
front.refreshRooms(20.0)
doAssert count() == 4
front.connection.client.connected = true
front.refreshRooms(20.1)
doAssert count() == 5, "Reconnect resets cadence"
front.connection.client.snapshot.room = "active"
front.refreshRooms(30.0)
doAssert count() == 5, "Never list while in a room"
front.connection.client.snapshot.room = ""
front.page = HomeMenu
front.refreshRooms(40.0, manual = true)
doAssert count() == 5, "Only the multiplayer browser refreshes"
front.page = MultiplayerMenu
front.refreshRooms(40.1)
doAssert count() == 6
front.connection.client.welcomed = false
front.refreshRooms(50.0)
doAssert count() == 6
front.connection = nil
front.refreshRooms(60.0)
echo "Room refresh explicit-clock cadence, manual, offline, room and page guards passed"
