## Startup behaviour of the two shipped binaries: a broken runtime contract
## must produce ONE clean line and exit 2, `--help` must work, and an
## unreachable game must not hang the player pod for the episode timeout.
##
## The binaries are compiled here (into a shared nimcache, so the second CI
## mode is cheap) because the behaviour under test is `quit`, which only a
## real process has.

import std/[os, osproc, strtabs, strutils, times]
import support/helpers

proc build(source, output: string) =
  let cache = getTempDir() / "hive-startup-nimcache"
  let command = "nim c --hints:off --warnings:off --path:" &
    quoteShell(repoRoot() / "src") & " --nimcache:" & quoteShell(cache) &
    " -o:" & quoteShell(output) & " " & quoteShell(repoRoot() / source)
  let built = execCmdEx(command, workingDir = repoRoot())
  if built.exitCode != 0:
    stderr.writeLine(built.output)
    check(false, "failed to build " & source)

proc main() =
  let work = getTempDir() / ("hive-startup-" & $getCurrentProcessId())
  createDir(work)
  let game = work / "hive"
  let player = work / "hive-player"
  build("src/hive.nim", game)
  build("src/hive_player.nim", player)

  block helpWorks:
    let run = execCmdEx(quoteShell(game) & " --help")
    checkEqual(run.exitCode, 0, "--help exits 0")
    check("--config-uri" in run.output, "--help documents the runtime options")
    check("--save-replay-uri" in run.output, "…including the artifact URIs")
    report("--help works and documents the runtime contract")

  block missingConfig:
    var env = newStringTable()
    let run = execCmdEx(quoteShell(game), env = {"PATH": getEnv("PATH")}.
      newStringTable)
    checkEqual(run.exitCode, 2,
      "a missing COGAME_CONFIG_URI exits 2, not 1 and not a crash")
    let lines = run.output.strip().splitLines()
    checkEqual(lines.len, 1, "exactly one line, no traceback")
    check(lines[0].startsWith("hive: "), "and it is a clean hive: message")
    check("COGAME_CONFIG_URI" in lines[0], "naming what is missing")
    check("Traceback" notin run.output, "no traceback")
    report("a missing COGAME_CONFIG_URI exits 2 with one clean line")

  block invalidConfig:
    let bad = work / "bad.json"
    writeFile(bad, "{not json at all")
    let run = execCmdEx(quoteShell(game),
      env = {"PATH": getEnv("PATH"),
             "COGAME_CONFIG_URI": "file://" & bad}.newStringTable)
    checkEqual(run.exitCode, 2, "an invalid config exits 2")
    check("Traceback" notin run.output, "no traceback")
    check(run.output.strip().splitLines().len == 1, "one clean line")
    report("an invalid COGAME_CONFIG_URI exits 2 with one clean line")

  block wrongSeatCount:
    let three = work / "three.json"
    writeFile(three, """{"num_agents": 3, "players": [{"name":"a"}],
      "tokens": ["t"]}""")
    let run = execCmdEx(quoteShell(game),
      env = {"PATH": getEnv("PATH"),
             "COGAME_CONFIG_URI": "file://" & three}.newStringTable)
    checkEqual(run.exitCode, 2, "a seat count other than four exits 2")
    check("num_agents" in run.output, "and says why")
    report("hive refuses to start with a seat count other than four")

  block playerWithoutUrl:
    let run = execCmdEx(quoteShell(player),
      env = {"PATH": getEnv("PATH")}.newStringTable)
    checkEqual(run.exitCode, 1, "no COWORLD_PLAYER_WS_URL exits 1")
    check("COWORLD_PLAYER_WS_URL" in run.output, "and says so")
    report("the player reports a missing COWORLD_PLAYER_WS_URL")

  block playerUnreachable:
    ## The bounded connect retry: an unreachable game must not hang the pod.
    let started = epochTime()
    let run = execCmdEx(quoteShell(player),
      env = {"PATH": getEnv("PATH"),
             "COWORLD_PLAYER_WS_URL":
               "ws://127.0.0.1:9/player?slot=0&token=t"}.newStringTable)
    let elapsed = epochTime() - started
    checkEqual(run.exitCode, 0,
      "an unreachable game exits 0 after the bounded retry")
    check("unreachable" in run.output,
      "and says the game was unreachable")
    check(elapsed < 60.0,
      "the retry is bounded (took " & $elapsed.int & "s)")
    report("the player gives up on an unreachable game in " &
      $elapsed.int & "s and exits 0")

  removeDir(work)

main()
echo "test_startup: all checks passed"
