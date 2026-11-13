import
  std/[os, strutils],
  chroma, pixie, silky,
  polyworld/[menus, inputs],
  common

const
  MenuGreen* = rgbx(85, 255, 85, 255)
  GalconControls* = block:
    var profile = ControlProfile()
    profile.defaults[SelectInput] = [MouseLeft, ButtonUnknown]
    profile.defaults[OrderInput] = [MouseRight, ButtonUnknown]
    profile.defaults[PauseInput] = [KeySpace, KeyF10]
    profile.defaults[MenuInput] = [KeyEscape, ButtonUnknown]
    profile.defaults[FullscreenInput] = [KeyF11, ButtonUnknown]
    profile.defaults[ShiftInput] = [KeyLeftShift, KeyRightShift]
    profile.defaults[TraceInput] = [KeyF2, ButtonUnknown]
    for action in [SelectInput, OrderInput, PauseInput, MenuInput,
      FullscreenInput, ShiftInput, TraceInput]:
        profile.actions.add ControlBinding(action: action, label: $action)
    profile

proc galconTheme*(): Theme =
  ## Styles shared Silky widgets with Galcon's gray ink and green highlights.
  result = Theme(
    defaultTextColor: rgbx(220, 220, 220, 255),
    disabledTextColor: rgbx(125, 130, 145, 255),
    dropdownHoverBgColor: rgbx(165, 205, 165, 255),
    dropdownBgColor: rgbx(255, 255, 255, 255),
    dropdownPopupBgColor: rgbx(255, 255, 255, 255),
    menuPopupSelectedColor: rgbx(40, 80, 55, 255)
  )

proc addMenuAssets*(builder: AtlasBuilder) =
  ## Builds flat theme patches and original-font labels for reusable widgets.
  for name in ["window", "frame", "header", "header.hover", "header.dragging",
    "button", "button.hover", "button.down", "button.disabled", "button.error",
    "textbox", "textbox.disabled", "textbox.error", "dropdown", "tooltip",
    "scrollbar", "scrollbar.track", "scrubber.body", "progressBar.body",
    "progressBar.progress"]:
      let image = newImage(64, 64)
      var fill = rgbx(4, 8, 20, 200)
      if name == "window": fill = rgbx(3, 6, 18, 175)
      elif name.endsWith("hover"): fill = rgbx(30, 55, 45, 235)
      elif name.endsWith("down"): fill = rgbx(35, 75, 45, 240)
      elif name == "scrollbar": fill = rgbx(130, 145, 145, 240)
      image.fill(fill)
      if name != "window":
        let edge = rgbx(95, 110, 120, 190)
        for i in 0 ..< 64:
          image[i, 0] = edge
          image[0, i] = edge
          image[i, 63] = edge
          image[63, i] = edge
      doAssert builder.addImage(name & ".9patch", image)
  for name in ["check.on", "check.off", "radio.on", "radio.off", "droparrow",
    "minus", "cross", "chevron_down", "arrow_left", "arrow_right",
    "maximized", "close", "resize", "scrubber.handle"]:
      let image = newImage(24, 24)
      for y in 3 .. 20:
        for x in 3 .. 20:
          let mark =
            if name in ["check.on", "radio.on"]:
              x in 7 .. 16 and y in 7 .. 16
            elif name in ["check.off", "radio.off"]:
              x in [3, 20] or y in [3, 20]
            elif name == "minus": y in 11 .. 13
            elif name == "cross": y in 11 .. 13 or x in 11 .. 13
            elif name == "close": abs(x - y) <= 1 or abs(x + y - 23) <= 1
            elif name == "maximized": y in 11 .. 13
            elif name == "resize": x + y in 29 .. 31 or x + y in 35 .. 37
            elif name == "scrubber.handle": x in 8 .. 15
            else: abs(x - 12) + abs(y - 10) < 8 and y > 10
          if mark:
            image[x, y] = if name.endsWith("on"): MenuGreen
              else: rgbx(175, 185, 185, 255)
      doAssert builder.addImage(name, image)
  for (name, size) in [("Default", 20), ("H1", 32), ("Bold", 20),
    ("LobbyTitle", 48), ("LobbyHeading", 28), ("LobbyBody", 20),
    ("LobbyBold", 20), ("Mono", 18)]:
      builder.addFont(Assets / "zeroes_3.ttf", name, size.float32)
