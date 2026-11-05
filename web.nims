import std/[os, strutils]

let
  project = thisDir()
  output = absolutePath(getEnv("GALCON_WEB", project / "build/web"))
  dependencies = getEnv("GALCON_DEPS", project.parentDir())
  shell = output / "shell.html"
mkDir(output)
writeFile(shell,
  readFile(dependencies / "polyworld/src/polyworld/replay.html")
    .replace("Polyworld replay", "Galcon 2006")
    .replace("<!-- GAME_LOGO -->",
      "<img id=\"loading-logo\" alt=\"Galcon 2006 by Phil Hassey\" " &
      "src=\"banner.png\">"))
switch("nimcache", output / "nimcache")
switch("out", output / "galcon.html")
switch("threads", "off")
switch("os", "linux")
switch("cpu", "wasm32")
switch("cc", "clang")
switch("clang.exe", "emcc")
switch("clang.linkerexe", "emcc")
switch("mm", "arc")
switch("exceptions", "goto")
switch("define", "noSignalHandler")
switch("define", "noAutoGLerrorCheck")
switch("passL", "-O3 --preload-file " &
  quoteShell(project / "assets" & "@/assets") &
  " --shell-file " & quoteShell(shell))
switch("passL", "-s ASYNCIFY -s FETCH -s USE_WEBGL2=1 " &
  "-s MAX_WEBGL_VERSION=2 -s MIN_WEBGL_VERSION=2 -s FULL_ES3=1 " &
  "-s GL_ENABLE_GET_PROC_ADDRESS=1 -s ALLOW_MEMORY_GROWTH " &
  "-s STACK_SIZE=8388608 -s INITIAL_MEMORY=134217728 --profiling")

switch("passL", "-s EXPORTED_FUNCTIONS=" &
  "_main,_malloc,_free,_windy_websocket_open_callback," &
  "_windy_websocket_message_callback,_windy_websocket_error_callback," &
  "_windy_websocket_close_callback")
