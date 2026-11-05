import
  std/times,
  vmath,
  galcon/[options, sessions, transports]

proc testTransports*() =
  ## Checks shared transport layout and exact scrubbing of live history.
  echo "Shared transport layout, pause, stepping, speeds, and rewind"
  for size in [
    vec2(640, 480), vec2(960, 720), vec2(1920, 1080),
    vec2(3840, 2160), vec2(2160, 3840)
  ]:
    let
      layout = presentation(size)
      slots = layout.panel.transportPanels()
      logical = size / layout.uiScale
    doAssert slots.scrub.size.x > 0
    doAssert slots.controls[0].origin.x >= 0
    doAssert slots.tick.origin.x + slots.tick.size.x <= logical.x
    doAssert layout.sidebar.origin.x >= 0
    doAssert layout.sidebar.origin.x + layout.sidebar.size.x < layout.boardOrigin.x
    doAssert layout.sidebar.origin.y + layout.sidebar.size.y <= layout.panel.origin.y
    doAssert layout.boardOrigin.x >= 0
    doAssert layout.boardOrigin.y >= 0
    doAssert layout.boardOrigin.y + 480 * layout.boardScale <=
      layout.panel.origin.y
    doAssert layout.panel.origin.y + layout.panel.size.y <= logical.y

  var transport = initPlayer(true, 3200)
  transport.sync(640, 640, false)
  transport.stepBack()
  doAssert not transport.playing
  doAssert transport.takeRestore() == 639
  transport.sync(639, 640, false)
  doAssert transport.targetTick == -1
  transport.stepForward()
  transport.startFrame(0, 32)
  doAssert transport.shouldTick(epochTime())
  transport.sync(640, 640, false)
  doAssert not transport.shouldTick(epochTime())
  transport.setSpeed(3)
  doAssert transport.speed == 16
  transport.play()
  transport.startFrame(1.0'f / 32, 32)
  doAssert transport.shouldTick(epochTime())

  transport.pause()
  doAssert not transport.shouldTick(epochTime())
  transport.seekTo(100)
  doAssert transport.takeRestore() == 100
  transport.sync(0, 640, false)
  transport.startFrame(1.0'f / 32, 32)
  doAssert transport.shouldTick(epochTime())
  transport.sync(100, 640, false)
  doAssert transport.targetTick == -1
  doAssert transport.timelineEnd == 3200
  transport.sync(640, 640, true)
  doAssert transport.timelineEnd == 640
  doAssert not transport.shouldTick(epochTime())
  transport.skipToStart()
  doAssert transport.takeRestore() == 0
  transport.sync(0, 640, false)
  transport.startFrame(1.0'f / 32, 32)
  doAssert transport.shouldTick(epochTime())

  echo "Transport reaches requested live-history ticks and resumes the frontier"
  block:
    let session = newSession(parseOptions(@["--ticks", "640"]))
    var bar = Transport(player: initPlayer(true, 640))
    for i in 0 ..< 640:
      discard bar.advancePlayback(session, 1.0'f / 32, epochTime())
    doAssert session.world.tick == 640
    doAssert session.done
    bar.player.stepBack()
    doAssert bar.advancePlayback(session, 0, epochTime())
    doAssert session.world.tick == 639
    doAssert not bar.player.playing
    doAssert bar.player.targetTick == -1
    doAssert session.inHistory
    bar.player.stepForward()
    discard bar.advancePlayback(session, 0, epochTime())
    doAssert session.world.tick == 640
    doAssert not session.inHistory
    bar.player.seekTo(137)
    bar.player.playing = false
    discard bar.advancePlayback(session, 0, epochTime())
    doAssert session.world.tick == 137
    bar.player.skipToEnd()
    while session.world.tick < 640:
      discard bar.advancePlayback(session, 0, epochTime())
    doAssert not session.inHistory
    bar.player.repeating = true
    discard bar.advancePlayback(session, 0, epochTime())
    doAssert bar.player.restoreTick == 0
    discard bar.advancePlayback(session, 0, epochTime())
    doAssert session.world.tick == 0
