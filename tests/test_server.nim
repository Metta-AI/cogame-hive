## The websocket and HTTP contract. The test re-execs ITSELF with
## HIVE_TEST_SERVER set, so the server runs in its own process (it calls
## quit(0) after the shutdown grace) while the parent does the assertions.

import std/[json, options, os, osproc, strtabs, strutils, times]
import curly
import webby/httpheaders
import whisky
import support/helpers
import bitworld/runtime
import hive/[roster, replay, server]

const
  LivePort = 18731
  ReplayPort = 18732

proc waitForHealth(curl: Curly, port: int, seconds = 20.0): bool =
  let deadline = epochTime() + seconds
  while epochTime() < deadline:
    try:
      let response = curl.get("http://127.0.0.1:" & $port & "/healthz", emptyHttpHeaders(), 2)
      if response.code == 200:
        return true
    except CatchableError:
      discard
    sleep(150)
  false

proc runLiveServer() =
  let work = getEnv("HIVE_TEST_WORK")
  var config = defaultGameConfig()
  config.seed = 42
  config.episodeTicks = 480
  config.turnTicks = 240
  ## Long enough that the parent can finish every HTTP assertion while the
  ## server is still waiting for players.
  config.playerConnectTimeoutSeconds = 25.0
  config.bonanzaTicks = @[]
  config.players = @[
    PlayerConfig(name: "daveey"), PlayerConfig(name: "daveey-1"),
    PlayerConfig(name: "Baseline (1)"), PlayerConfig(name: "Baseline (2)")
  ]
  config.tokens = @["token-0", "token-1", "token-2", "token-3"]
  putEnv("COGAME_RESULTS_URI", "file://" & work / "results.json")
  putEnv("COGAME_SAVE_REPLAY_URI", "file://" & work / "replay.json")
  putEnv("COGAME_EVENTS_URI", "file://" & work / "events.jsonl")
  var runtime = RuntimeConfig(host: "127.0.0.1", port: LivePort)
  runtime.resultsUri = getEnv("COGAME_RESULTS_URI")
  runtime.replayUri = getEnv("COGAME_SAVE_REPLAY_URI")
  runGameServer(config, runtime)

proc runReplayServer() =
  var runtime = RuntimeConfig(host: "127.0.0.1", port: ReplayPort)
  runtime.replay = readRepoFile("tests/fixtures/sample_replay.json")
  runtime.replayMode = true
  server.runReplayServer(runtime)

proc main() =
  let curl = newCurly()
  let work = getTempDir() / ("hive-server-test-" & $getCurrentProcessId())
  createDir(work)
  let self = getAppFilename()

  ## ---- replay mode -------------------------------------------------------
  block replayMode:
    let child = startProcess(self, options = {poParentStreams},
      env = {"HIVE_TEST_SERVER": "replay", "PATH": getEnv("PATH")}.newStringTable)
    check(waitForHealth(curl, ReplayPort), "the replay server answers /healthz")
    let base = "http://127.0.0.1:" & $ReplayPort
    let data = curl.get(base & "/replay-data", emptyHttpHeaders(), 5)
    checkEqual(data.code, 200, "/replay-data answers in replay mode")
    let parsed = parseJson(data.body)
    checkEqual(parsed["protocol"].getStr(), "hive.replay.v1",
      "/replay-data serves the recorded replay")
    let page = curl.get(base & "/client/replay", emptyHttpHeaders(), 5)
    checkEqual(page.code, 200, "/client/replay serves a page")
    check("id=\"board\"" in page.body, "the replay page carries the chrome")
    check("wire_constants.js" in page.body,
      "the served page is spliced, not raw")
    check("chrome_common.js" in page.body, "chrome_common is spliced in")
    child.terminate()
    discard child.waitForExit()
    report("replay mode serves /replay-data and a spliced /client/replay")

  ## ---- live mode ---------------------------------------------------------
  block liveMode:
    let child = startProcess(self, options = {poParentStreams},
      env = {"HIVE_TEST_SERVER": "live", "HIVE_TEST_WORK": work,
             "PATH": getEnv("PATH")}.newStringTable)
    check(waitForHealth(curl, LivePort), "the live server answers /healthz")
    let base = "http://127.0.0.1:" & $LivePort

    let health = curl.get(base & "/healthz", emptyHttpHeaders(), 5)
    checkEqual(health.code, 200, "/healthz is 200")
    checkEqual(parseJson(health.body)["ok"].getBool(), true, "and says ok")

    ## The episode runner probes BOTH client routes before starting player
    ## pods. A 404 here is a game_contract_violation.
    let playerPage = curl.get(base & "/client/player?slot=0&token=token-0", emptyHttpHeaders(), 5)
    checkEqual(playerPage.code, 200, "GET /client/player returns a real page")
    check(playerPage.body.len > 400, "and it is a real page, not a stub")
    check("new WebSocket" notin playerPage.body and
      "/player?" notin playerPage.body,
      "the player page never opens the player socket")
    let globalPage = curl.get(base & "/client/global", emptyHttpHeaders(), 5)
    checkEqual(globalPage.code, 200, "GET /client/global returns a real page")
    check(globalPage.body.len > 400, "and it is a real page")
    check("/player?" notin globalPage.body,
      "the global page never opens the player socket")
    check("/global" in globalPage.body,
      "the global page reads the spectator channel instead")

    checkEqual(curl.get(base & "/client/chrome_common.js", emptyHttpHeaders(), 5).code, 200,
      "chrome assets are served")
    checkEqual(curl.get(base & "/client/art/ant.png", emptyHttpHeaders(), 5).code, 200,
      "art is served")
    checkEqual(curl.get(base & "/client/../etc/passwd", emptyHttpHeaders(), 5).code, 404,
      "the asset route refuses traversal")

    ## A bad slot or token is 403.
    checkEqual(curl.get(base & "/player?slot=0&token=wrong", emptyHttpHeaders(), 5).code, 403,
      "a bad token is 403")
    checkEqual(curl.get(base & "/player?slot=9&token=token-0", emptyHttpHeaders(), 5).code, 403,
      "a bad slot is 403")

    ## A real seat connects, registers, and a second connection on the same
    ## slot is 409.
    var live = newWebSocket("ws://127.0.0.1:" & $LivePort &
      "/player?slot=0&token=token-0")
    live.send($ %*{"type": "register", "prompt": "",
      "scripted": "marcher", "policy": "test"})
    let welcome = live.receiveMessage()
    check(welcome.isSome, "the seat receives a welcome frame")
    let hello = parseJson(welcome.get().data)
    checkEqual(hello["type"].getStr(), "welcome", "the frame is a welcome")
    checkEqual(hello["protocol"].getStr(), "hive.player.v1", "protocol")
    checkEqual(hello["slot"].getInt(), 0, "the slot is echoed")
    check(hello["colony"].getStr() in ["Amber", "Teal", "Lime", "Magenta"],
      "the welcome names a colony ALIAS, never a player")
    checkEqual(curl.get(base & "/player?slot=0&token=token-0", emptyHttpHeaders(), 5).code, 409,
      "a duplicate connection on a live slot is 409")
    report("healthz, both client pages, 403, 409 and the register frame")

    ## /global streams a snapshot.
    var spectator = newWebSocket("ws://127.0.0.1:" & $LivePort & "/global")
    let snapshot = spectator.receiveMessage()
    check(snapshot.isSome, "/global sends a snapshot on connect")
    let state = parseJson(snapshot.get().data)
    checkEqual(state["protocol"].getStr(), "hive.global.v1", "global protocol")
    checkEqual(state["colonies"].len, Colonies, "four colonies")
    check(state.hasKey("ants") and state["ants"].len == 96, "96 ants")
    report("/global streams a complete snapshot")

    ## Seat the remaining three so the episode plays out, then assert the
    ## artifacts and the shutdown grace.
    var others: seq[WebSocket]
    for slot in 1 .. 3:
      var socket = newWebSocket("ws://127.0.0.1:" & $LivePort &
        "/player?slot=" & $slot & "&token=token-" & $slot)
      socket.send($ %*{"type": "register", "prompt": "",
        "scripted": "marcher", "policy": ""})
      others.add(socket)

    ## The episode is 480 ticks of scripted play: fast. Wait for the results
    ## file, then check /global is STILL answering during the grace.
    let deadline = epochTime() + 60.0
    while epochTime() < deadline and not fileExists(work / "results.json"):
      sleep(200)
    check(fileExists(work / "results.json"),
      "results.json lands on the file:// URI")
    check(fileExists(work / "replay.json"), "the replay lands too")
    check(fileExists(work / "events.jsonl"),
      "COGAME_EVENTS_URI is honoured for a file:// URI")

    let stillUp = curl.get(base & "/healthz", emptyHttpHeaders(), 2)
    checkEqual(stillUp.code, 200,
      "/healthz keeps answering during the shutdown grace")
    var graceSocket = newWebSocket("ws://127.0.0.1:" & $LivePort & "/global")
    check(graceSocket.receiveMessage().isSome,
      "/global keeps answering during the shutdown grace")
    graceSocket.close()

    let results = parseJson(readFile(work / "results.json"))
    checkEqual(results["names"].len, Colonies, "results carry four names")
    checkEqual(results["scores"].len, Colonies, "and four scores")
    check(results["reason"].getStr() in ["complete", "deadline", "fault"],
      "a legal reason")
    discard parseReplayBytes(readFile(work / "replay.json"))
    check(not fileExists(work / "player_failure.json"),
      "no player failure is reported when every seat connects")
    let events = readFile(work / "events.jsonl").strip().splitLines()
    check(events.len > 2, "the events file has one JSON object a line")
    for line in events:
      discard parseJson(line)
    report("artifacts land on file:// URIs and the grace keeps the pod alive")

    live.close()
    for socket in others:
      socket.close()
    spectator.close()
    child.terminate()
    discard child.waitForExit()

  ## ---- URI scheme rejection ----------------------------------------------
  block uriSchemes:
    for name in ["COGAME_EVENTS_URI", "COGAME_METRICS_URI"]:
      putEnv(name, "https://example.com/events")
      var raised = false
      try:
        discard requireFileUri(name)
      except HiveError as error:
        raised = "file://" in error.msg
      check(raised, name & " rejects a non-file scheme loudly")
      putEnv(name, "")
      checkEqual(requireFileUri(name), "", name & " may be unset")
    report("COGAME_EVENTS_URI and COGAME_METRICS_URI are file:// only")

  removeDir(work)

when isMainModule:
  case getEnv("HIVE_TEST_SERVER")
  of "live": runLiveServer()
  of "replay": runReplayServer()
  else:
    main()
    echo "test_server: all checks passed"
