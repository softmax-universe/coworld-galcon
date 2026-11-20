import
  chroma, silky, vmath, windy,
  polyworld/replaymenus as sharedReplayMenus,
  common, rasters, replays, themes

export sharedReplayMenus except drawReplayBrowser

proc drawReplayBackground(sk: Silky, window: Window) =
  ## Keeps the replay library on Galcon's existing centered galaxy backdrop.
  sk.clearScreen(rgbx(0, 0, 0, 255))
  sk.drawSpaceCover(vec2(0), window.size.vec2 / sk.uiScale)

proc galconReplayStyle*(): ReplayBrowserStyle =
  ## Supplies Galcon's original font theme, green headings, and flat controls.
  ReplayBrowserStyle(
    title: "replays",
    titleColor: MenuGreen,
    accentColor: MenuGreen,
    mutedColor: galconTheme().disabledTextColor,
    centerTitle: true,
    navigationIcons: false,
    background: drawReplayBackground
  )

proc drawReplayBrowser*(
  sk: Silky, window: Window, browser: var ReplayBrowserState
): ReplayBrowserResult =
  ## Uses the shared replay workflow with Galcon's existing menu presentation.
  sharedReplayMenus.drawReplayBrowser(sk, window, browser,
    ReplayVersion, TickRate, style = galconReplayStyle())
