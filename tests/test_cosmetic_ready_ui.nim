## Reuse the real-input fixture without changing the controls writer's test.
## Compile/run with tests/mp_e2e_run.py's isolated HOME/server environment.
import std/[macros, strutils, os]
macro cosmeticStartup(): untyped =
  const original = """  for i in 0..<ClientCount:
    lobbyClick(i,vec2(560,922))
    awaitState("explicit ready " & $i, ready(i))
    picture(i,"ready")
"""
  const replacement = """  for i in 0..<ClientCount:
    check("starts socially unready " & $i, not ready(i))
  # Exercise the real button both directions without replacing preparation.
  let preparation = host.front.prepared
  lobbyClick(0,vec2(560,922))
  awaitState("social Ready acknowledged", ready(0))
  lobbyClick(0,vec2(560,922))
  awaitState("social Unready acknowledged", not ready(0))
  check("cosmetic toggle preserves preparation", host.front.prepared == preparation)
  for i in 0..<ClientCount:
    check("unready at host Start " & $i, not ready(i))
"""
  let fixture = staticRead("mp_e2e_native.nim")
  doAssert fixture.count(original) == 1, "Update startup seam after fixture changes"
  result = parseStmt(fixture.replace(original, replacement).replace(
    "include ../src/galcon/graphics", "include \"" &
      currentSourcePath().parentDir.parentDir / "src/galcon/graphics.nim" & "\""))
cosmeticStartup()
