## Hive game server: the Coworld game contract.
##
## Forked from paintbot's `src/ctf/server.nim`: the same mummy HTTP/WebSocket
## server, the same routes, the same 403/409 discipline, the same
## `bitworld/runtime` artifact contract, the same end-of-episode write order
## (broadcast `done` to every seat with a 3 s per-seat deadline -> write the
## replay -> write the results), the same pre-listen field bake, and the same
## bounded shutdown grace so the certifier's post-start `/global` ping still
## finds a live process.
##
## Endpoints:
##   GET /healthz                  liveness
##   GET /client/player            a real page; NEVER opens the player socket
##   GET /client/global            a real page; NEVER opens the player socket
##   GET /client/replay            the replay chrome (replay mode)
##   GET /client/<asset>           chrome, art and fonts
##   GET /replay-data              the replay bytes (replay mode)
##   WS  /player?slot=N&token=T    the player protocol
##   WS  /global                   spectator snapshots
##
## Player protocol (hive.player.v1), all JSON text frames:
##   player -> game: {"type":"register","prompt":"...","scripted":"marcher",
##                    "policy":"..."}
##   game -> player: {"type":"welcome",...}
##                   {"type":"turn","turn":N,"tick":T,"colony":"Amber",
##                    "view":{...},"doctrine_source":"llm"}
##                   {"done":true,"result":{...}}

import std/[json, locks, os, sets, strutils, tables, times]
import bitworld/runtime
import curly
import mummy, mummy/routers
import types, config, field, doctrine, baselines, roster, sim, rules,
  broadcast, global, llm, replay, state, events

const
  ShutdownGraceSeconds* = 20.0
  DoneBroadcastSeconds* = 3.0
  PlayBudgetFraction* = 0.6

type
  GameState = object
    config: GameConfig
    match: Sim
    roster: Roster
    playerSockets: Table[int, WebSocket]
    socketSlots: Table[WebSocket, int]
    globalSockets: HashSet[WebSocket]
    started: bool
    finished: bool
    artifactsWritten: bool

var
  stateLock: Lock
  game: GameState
  gameServer: Server
  replayPayloadGlobal: string
  clientDirGlobal: string
  dataDirGlobal: string
  distDirGlobal: string

initLock(stateLock)

proc resolveDir(name: string): string =
  let appDir = getAppDir()
  for candidate in [appDir / name, appDir / ".." / name, name]:
    if dirExists(candidate):
      return candidate
  name

proc clientDir(): string =
  if clientDirGlobal.len == 0:
    clientDirGlobal = resolveDir("client")
  clientDirGlobal

proc dataDir(): string =
  if dataDirGlobal.len == 0:
    dataDirGlobal = resolveDir("data")
  dataDirGlobal

proc distDir(): string =
  if distDirGlobal.len == 0:
    let appDir = getAppDir()
    for candidate in [appDir / "replay-viewer" / "dist",
        appDir / ".." / "replay-viewer" / "dist", "replay-viewer" / "dist"]:
      if dirExists(candidate):
        distDirGlobal = candidate
        break
    if distDirGlobal.len == 0:
      distDirGlobal = "replay-viewer/dist"
  distDirGlobal

proc contentTypeFor(name: string): string =
  if name.endsWith(".html"): "text/html; charset=utf-8"
  elif name.endsWith(".js"): "application/javascript; charset=utf-8"
  elif name.endsWith(".css"): "text/css; charset=utf-8"
  elif name.endsWith(".json"): "application/json"
  elif name.endsWith(".png"): "image/png"
  elif name.endsWith(".jpg") or name.endsWith(".jpeg"): "image/jpeg"
  elif name.endsWith(".wasm"): "application/wasm"
  elif name.endsWith(".ttf"): "font/ttf"
  else: "application/octet-stream"

proc respondFile(request: Request, path: string) =
  if fileExists(path):
    var headers: HttpHeaders
    headers["Content-Type"] = contentTypeFor(path)
    request.respond(200, headers, readFile(path))
  else:
    request.respond(404)

proc splicedChrome(): string =
  ## The broadcast chrome, spliced exactly the way `Dockerfile.replay-viewer`
  ## splices it for the static bundle, so the native page and the bundle are
  ## the same document.
  let page = clientDir() / "replay_broadcast.html"
  if not fileExists(page):
    return "<!doctype html><title>hive</title><p>chrome missing</p>"
  result = readFile(page)
  result = result.replace("<!-- WIRE_CONSTANTS -->",
    "<script src=\"./wire_constants.js\"></script>")
  result = result.replace("<!-- CHROME_COMMON -->",
    "<script src=\"./chrome_common.js\"></script>")
  result = result.replace("<!-- BROADCAST_CORE -->",
    "<script src=\"./static_replay.js\"></script>")

# ---- artifact writing -------------------------------------------------------

proc writeArtifact(uri, data, contentType, methodEnv: string) =
  if uri.len == 0:
    return
  let httpMethod = getEnv(methodEnv, "PUT").toUpperAscii()
  if uri.isHttpCogameUri() and httpMethod == "POST":
    let curl = newCurly()
    var headers: HttpHeaders
    headers["content-type"] = contentType
    let response = curl.post(uri, headers, data, 60)
    if response.code < 200 or response.code >= 300:
      raise newException(IOError, "artifact POST failed: " & $response.code)
  else:
    writeCogameUri(uri, data, contentType, methodEnv)

proc requireFileUri*(name: string): string =
  ## `COGAME_EVENTS_URI` and `COGAME_METRICS_URI` are file:// only and are
  ## rejected LOUDLY otherwise.
  let value = getEnv(name).strip()
  if value.len == 0:
    return ""
  if not value.startsWith("file://"):
    raise newException(HiveError,
      name & " must be a file:// URI, got: " & value)
  value

proc declarePlayerFailure(slot: int, reason: string) =
  ## The lowest offending slot only, paintbot's `declarePlayerFailure`.
  let uri = getEnv("COGAME_PLAYER_FAILURE_URI").strip()
  if uri.len == 0:
    return
  let payload = $ %*{"slot": slot, "reason": reason}
  try:
    writeArtifact(uri, payload, "application/json",
      "COGAME_PLAYER_FAILURE_METHOD")
    echo "hive: reported player failure for slot ", slot, ": ", reason
  except CatchableError as error:
    echo "hive: could not report player failure: ", error.msg

# ---- broadcasting -----------------------------------------------------------

proc playerNamesLocked(): seq[string] =
  for player in game.config.players:
    result.add(player.name)

proc connectedLocked(): seq[bool] =
  for slot in 0 ..< Colonies:
    result.add(game.playerSockets.hasKey(slot))

proc snapshotLocked(): string =
  $globalSnapshot(game.match, playerNamesLocked(), game.started,
    game.match.finished, connectedLocked())

proc broadcastGlobalLocked() =
  if game.globalSockets.len == 0:
    return
  let payload = snapshotLocked()
  for socket in game.globalSockets:
    socket.send(payload)

# ---- the episode ------------------------------------------------------------

var gameThread: Thread[RuntimeConfig]

proc runGame(runtimeConfig: RuntimeConfig) {.gcsafe.} =
  {.gcsafe.}:
    let gameConfig = game.config
    let gameStart = epochTime()
    let connectDeadline = gameStart + gameConfig.playerConnectTimeoutSeconds

    while epochTime() < connectDeadline:
      var allConnected = false
      withLock stateLock:
        allConnected = game.playerSockets.len >= Colonies
      if allConnected:
        break
      sleep(200)

    var missing: seq[int]
    withLock stateLock:
      game.started = true
      for slot in 0 ..< Colonies:
        if not game.roster.seats[slot].everConnected:
          missing.add(slot)
      echo "hive: starting with ", game.playerSockets.len, "/", Colonies,
        " players connected"
      broadcastGlobalLocked()
    if missing.len > 0:
      ## A seat that never connects does NOT end the episode: its colony is
      ## driven by the marcher for the whole match and the no-show is
      ## reported for the lowest offending slot only.
      declarePlayerFailure(missing[0], "player never connected")

    let client = newLlmClient(
      turnBudgetSeconds = gameConfig.turnBudgetSeconds)
    var memory: array[Colonies, BaselineMemory]
    var turnsLlm: array[Colonies, int]
    var fallbackTurns: array[Colonies, int]
    var fallbackCauses: array[Colonies, array[5, int]]
    var guardEngaged = false

    let wallBudget =
      min(gameConfig.wallClockBudgetSeconds,
        gameConfig.episodeTimeoutSeconds.float * PlayBudgetFraction)
    echo "hive: wall-clock budget ", wallBudget.int, "s of an assumed ",
      gameConfig.episodeTimeoutSeconds, "s episode timeout"

    let provide = proc (match: Sim, turn: int): array[Colonies,
        ResolvedDoctrine] {.closure.} =
      var prompts: array[Colonies, string]
      var scripted: array[Colonies, ScriptKind]
      withLock stateLock:
        for seat in 0 ..< Colonies:
          prompts[seat] = game.roster.seats[seat].prompt
          ## A seat that disconnected mid-match keeps playing: its doctrine
          ## source degrades to the marcher and revives on reconnect.
          scripted[seat] =
            if game.roster.seats[seat].connected: game.roster.seats[seat].scripted
            else: skMarcher

      ## Budget guard: settle early rather than overrun. Once it engages the
      ## LLM is skipped for ALL remaining turns and the episode finishes on
      ## the scripted layer, so it ends complete/full_time, not deadline.
      let elapsed = epochTime() - gameStart
      if not guardEngaged and
          elapsed + 2.0 * gameConfig.turnBudgetSeconds > wallBudget:
        guardEngaged = true
        match.events.add(budgetGuard(match.tick, turn, wallBudget - elapsed))
        echo "hive: budget guard engaged at turn ", turn, " (", elapsed.int,
          "s elapsed)"

      var outcomes: array[Colonies, SeatOutcome]
      if guardEngaged:
        for seat in 0 ..< Colonies:
          let view = buildView(match, seat)
          outcomes[seat] = SeatOutcome(
            resolved: scriptedResolved(view, skMarcher, turn, memory[seat],
              dsFallback),
            cause: "budget_guard"
          )
      else:
        outcomes = client.decideAll(match, prompts, scripted, memory, turn)

      for seat in 0 ..< Colonies:
        result[seat] = outcomes[seat].resolved
        if outcomes[seat].resolved.source == dsLlm:
          turnsLlm[seat].inc
        if outcomes[seat].cause.len > 0 and scripted[seat] == skNone:
          fallbackTurns[seat].inc
          fallbackCauses[seat][causeIndex(outcomes[seat].cause)].inc
          match.events.add(fallbackEvent(match.tick, turn, seat,
            max(1, outcomes[seat].attempts), outcomes[seat].cause,
            truncateRunes(outcomes[seat].detail, MaxDetailRunes)))

      ## Push the informational turn frame to every connected seat. The seat
      ## is not required to answer; decisions are made server-side.
      withLock stateLock:
        for seat in 0 ..< Colonies:
          if game.playerSockets.hasKey(seat):
            try:
              game.playerSockets[seat].send(
                $turnFrame(match, seat, outcomes[seat].resolved.source))
            except CatchableError:
              discard
        broadcastGlobalLocked()

    let outOfTime = proc (match: Sim, turn: int): bool {.closure.} =
      epochTime() - gameStart > wallBudget

    var results: JsonNode
    var replayBytes: string
    try:
      game.match.runEpisode(provide, outOfTime)
    except CatchableError as error:
      echo "hive: host error: ", error.msg
      game.match.endMatch(erFault, euHostError)

    withLock stateLock:
      var names: seq[string]
      var kinds: seq[string]
      for seat in 0 ..< Colonies:
        names.add(
          if seat < game.config.players.len: game.config.players[seat].name
          else: "P" & $(seat + 1))
        kinds.add(game.roster.seats[seat].policyKind())
      results = resultsJson(game.match, names, kinds, turnsLlm,
        fallbackTurns, fallbackCauses)
      replayBytes = $buildReplay(game.match, names, kinds, results)
      game.finished = true

      ## Write order: `done` to every seat FIRST (the hosted worker tears
      ## player pods down as soon as results.json exists), then the replay,
      ## then the results.
      let done = %*{"done": true, "result": results}
      ## A 3.0 s deadline PER SEAT, not one 3.0 s allowance shared across all
      ## four: a slow socket must not eat the budget of the seats behind it
      ## and leave them without their result frame. The whole broadcast is
      ## still hard-bounded, at seats x DoneBroadcastSeconds.
      let broadcastDeadline =
        epochTime() + DoneBroadcastSeconds * float(Colonies)
      for slot, socket in game.playerSockets:
        if epochTime() > broadcastDeadline:
          echo "hive: done broadcast out of budget before slot ", slot
          break
        let seatDeadline = epochTime() + DoneBroadcastSeconds
        try:
          socket.send($done)
        except CatchableError:
          discard
        if epochTime() > seatDeadline:
          echo "hive: done broadcast to slot ", slot, " took longer than its ",
            DoneBroadcastSeconds, "s deadline"
      broadcastGlobalLocked()

    echo "hive: episode ", $game.match.reason, "/", $game.match.rule,
      " at tick ", game.match.tick, " after ",
      (epochTime() - gameStart).int, "s; writing artifacts"
    try:
      writeArtifact(runtimeConfig.replayUri, replayBytes, "application/json",
        "COGAME_SAVE_REPLAY_METHOD")
      writeArtifact(runtimeConfig.resultsUri, $results, "application/json",
        "COGAME_RESULTS_METHOD")
      let eventsUri = requireFileUri("COGAME_EVENTS_URI")
      if eventsUri.len > 0:
        writeArtifact(eventsUri,
          eventsJsonl(game.match.events.items, results), "application/x-ndjson",
          "COGAME_EVENTS_METHOD")
      let metricsUri = requireFileUri("COGAME_METRICS_URI")
      if metricsUri.len > 0:
        writeArtifact(metricsUri, $ %*{
          "total_delivered": game.match.totalDelivered(),
          "final_tick": game.match.tick,
          "turns_llm": @turnsLlm,
          "fallback_turns": @fallbackTurns
        }, "application/json", "COGAME_METRICS_METHOD")
    except CatchableError as error:
      echo "hive: artifact write failed: ", error.msg
      quit(1)
    game.artifactsWritten = true

    ## Keep /healthz and /global answering for a bounded grace: the cert
    ## runner pings /global with a 2 s deadline AFTER the player pods start,
    ## and a short episode would otherwise already be gone.
    echo "hive: artifacts written; holding /healthz and /global for ",
      ShutdownGraceSeconds.int, "s"
    sleep(int(ShutdownGraceSeconds * 1000))
    echo "hive: shutting down"
    quit(0)

# ---- HTTP -------------------------------------------------------------------

proc healthzHandler(request: Request) {.gcsafe.} =
  var headers: HttpHeaders
  headers["Content-Type"] = "application/json"
  request.respond(200, headers, """{"ok": true}""")

proc clientPlayerHandler(request: Request) {.gcsafe.} =
  ## A REAL page. The episode runner probes this before starting player pods
  ## and a 404 here is a `game_contract_violation`. It must never open the
  ## player websocket.
  {.gcsafe.}:
    respondFile(request, clientDir() / "player.html")

proc clientGlobalHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    respondFile(request, clientDir() / "global.html")

proc clientReplayHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    var headers: HttpHeaders
    headers["Content-Type"] = "text/html; charset=utf-8"
    request.respond(200, headers, splicedChrome())

proc clientAssetHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let name = request.pathParams["name"]
    if ".." in name or name.startsWith("/") or name.startsWith("."):
      request.respond(404)
      return
    for root in [clientDir(), dataDir(), distDir()]:
      let candidate = root / name
      if fileExists(candidate):
        respondFile(request, candidate)
        return
    request.respond(404)

proc clientArtHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let name = request.pathParams["name"]
    if ".." in name or name.startsWith("/") or name.startsWith("."):
      request.respond(404)
      return
    for root in [clientDir() / "art", distDir() / "art"]:
      let candidate = root / name
      if fileExists(candidate):
        respondFile(request, candidate)
        return
    request.respond(404)

proc replayDataHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    if replayPayloadGlobal.len == 0:
      request.respond(404)
      return
    var headers: HttpHeaders
    headers["Content-Type"] = "application/json"
    request.respond(200, headers, replayPayloadGlobal)

proc playerUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    var slot = -1
    try:
      slot = parseInt(request.queryParams["slot"])
    except ValueError:
      discard
    let token = request.queryParams["token"]
    var outcome = jeBadSlot
    withLock stateLock:
      outcome = game.roster.authorize(slot, token)
    case outcome
    of jeNone: discard
    of jeDuplicate:
      request.respond(409)
      return
    else:
      request.respond(403)
      return
    let websocket = request.upgradeToWebSocket()
    withLock stateLock:
      game.playerSockets[slot] = websocket
      game.socketSlots[websocket] = slot
      game.roster.seats[slot].connected = true
      game.roster.seats[slot].everConnected = true
      let colony = game.match.seatNest[slot]
      echo "hive: player slot ", slot, " connected (",
        game.playerSockets.len, "/", Colonies, ")"
      websocket.send($ %*{
        "type": "welcome",
        "protocol": "hive.player.v1",
        "slot": slot,
        "colony": game.match.meadow.nests[colony].alias,
        "colour": game.match.meadow.nests[colony].colour,
        "turns": turnsOf(game.config),
        "turn_ticks": game.config.turnTicks,
        "ants": game.config.antsPerColony
      })

proc globalUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let websocket = request.upgradeToWebSocket()
    withLock stateLock:
      game.globalSockets.incl(websocket)
      websocket.send(snapshotLocked())

proc websocketHandler(
  websocket: WebSocket,
  event: WebSocketEvent,
  message: Message
) {.gcsafe.} =
  {.gcsafe.}:
    case event
    of OpenEvent:
      discard
    of MessageEvent:
      ## mummy hands Ping frames to the application; the certifier pings
      ## /global to check the game is alive, so an unanswered ping fails
      ## certification.
      if message.kind == Ping:
        websocket.send(message.data, Pong)
        return
      if message.kind != TextMessage:
        return
      var slot = -1
      withLock stateLock:
        slot = game.socketSlots.getOrDefault(websocket, -1)
      if slot < 0:
        return
      try:
        let payload = parseJson(message.data)
        if payload{"type"}.getStr() == "register":
          let scriptedNode = payload{"scripted"}
          let scripted =
            if scriptedNode.isNil or scriptedNode.kind == JNull: ""
            elif scriptedNode.kind == JBool:
              (if scriptedNode.getBool(): "marcher" else: "")
            else: scriptedNode.getStr()
          withLock stateLock:
            game.roster.register(slot, payload{"prompt"}.getStr(), scripted,
              payload{"policy"}.getStr())
            echo "hive: slot ", slot, " registered (",
              game.roster.seats[slot].policyKind(), ", ",
              payload{"prompt"}.getStr().len, " prompt chars)"
      except CatchableError as error:
        echo "hive: ignoring bad player frame: ", error.msg
    of ErrorEvent:
      discard
    of CloseEvent:
      withLock stateLock:
        if websocket in game.socketSlots:
          let slot = game.socketSlots[websocket]
          game.socketSlots.del(websocket)
          if game.playerSockets.getOrDefault(slot) == websocket:
            game.playerSockets.del(slot)
          game.roster.seats[slot].connected = false
        game.globalSockets.excl(websocket)

proc buildRouter(replayMode: bool): Router =
  ## Both `/client/` pages are registered BEFORE the catch-all asset route.
  result.get("/healthz", healthzHandler)
  result.get("/client/player", clientPlayerHandler)
  result.get("/client/global", clientGlobalHandler)
  result.get("/client/replay", clientReplayHandler)
  result.get("/client/@name", clientAssetHandler)
  result.get("/client/art/@name", clientArtHandler)
  result.get("/replay-data", replayDataHandler)
  result.get("/global", globalUpgradeHandler)
  if not replayMode:
    result.get("/player", playerUpgradeHandler)

proc runReplayServer*(runtimeConfig: RuntimeConfig) =
  ## Replay mode: hand the recorded bytes to the same chrome the static
  ## bundle uses.
  replayPayloadGlobal = runtimeConfig.replay
  discard parseReplayBytes(replayPayloadGlobal)
  let router = buildRouter(replayMode = true)
  gameServer = newServer(router, websocketHandler, workerThreads = 4)
  echo "hive: replay mode on ", runtimeConfig.host, ":", runtimeConfig.port
  gameServer.serve(Port(runtimeConfig.port), runtimeConfig.host)

proc runGameServer*(gameConfig: GameConfig, runtimeConfig: RuntimeConfig) =
  if gameConfig.tokens.len < Colonies:
    raise newException(HiveError,
      "hive needs " & $Colonies & " tokens, got " & $gameConfig.tokens.len)
  if gameConfig.players.len < Colonies:
    raise newException(HiveError,
      "hive needs " & $Colonies & " players, got " & $gameConfig.players.len)
  ## Pre-listen field bake, so a viewer's first frame is instant.
  let meadow = ensureField(gameConfig.fieldPath)
  game.config = gameConfig
  game.match = newSim(gameConfig, meadow)
  game.roster = initRoster(gameConfig.tokens)

  let router = buildRouter(replayMode = false)
  gameServer = newServer(router, websocketHandler, workerThreads = 4)
  createThread(gameThread, runGame, runtimeConfig)
  echo "hive: serving on ", runtimeConfig.host, ":", runtimeConfig.port
  gameServer.serve(Port(runtimeConfig.port), runtimeConfig.host)
