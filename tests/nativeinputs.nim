import
  std/importutils,
  windy, windy/internal

privateAccess(Window)

proc syncTestInput*(window: Window) =
  ## Copies injected frame input to the native backend's public input storage.
  when defined(linux) and not defined(emscripten):
    window.mousePos = window.state.mousePos
    window.mousePrevPos = window.state.mousePrevPos
    window.perFrame = window.state.perFrame
    window.buttonPressed = window.state.perFrame.buttonPressed
    window.buttonReleased = window.state.perFrame.buttonReleased
    window.buttonDown = window.state.buttonDown
    window.buttonToggle = window.state.buttonToggle
