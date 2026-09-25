## Hive's bundled scripted player. Each turn it reads its private view,
## computes a marcher or driftling doctrine, and submits it to the game.
## Prompt, Jev, and trained backends use players/ordinary/player.py.

import std/[json, options, os, strutils, times]
import whisky
import hive/[baselines, doctrine]

const
  ConnectAttempts = 4

  DefaultScripted = "marcher"
    ## "A seat that sets neither defaults to PLAYER_SCRIPTED=marcher." No
    ## A seat nobody configured plays marcher.

  ReceivePollMs = 5000
    ## The receive loop polls rather than blocking forever, so a game pod
    ## that dies without closing the socket cannot wedge this one.

  LifetimeSeconds = 1500.0
    ## Backstop: longer than the platform's 1200 s episode timeout, so it
    ## never cuts a live episode short, and short enough that a player pod
    ## always exits on its own.

when isMainModule:
  let url = getEnv("COWORLD_PLAYER_WS_URL")
  if url.len == 0:
    stderr.writeLine("hive player: COWORLD_PLAYER_WS_URL is not set")
    quit(1)

  var scripted = getEnv("PLAYER_SCRIPTED").strip()
  if scripted.len == 0:
    scripted = DefaultScripted
    echo "hive player: using the ", DefaultScripted, " baseline"
  let policy = getEnv("PLAYER_POLICY_LABEL")
  let kind = parseScriptKind(scripted)
  var memory: BaselineMemory
  var lastTurn = -1
  var lastAction: JsonNode

  proc registerFrame(): string =
    $ %*{
      "type": "register",
      "scripted": (if scripted.len > 0: %scripted else: newJNull()),
      "policy": policy
    }

  ## A bounded connect retry: an unreachable game is reported and the
  ## process exits 0 rather than hanging a pod for the episode timeout.
  var socket: WebSocket = nil
  for attempt in 1 .. ConnectAttempts:
    try:
      socket = newWebSocket(url)
      break
    except CatchableError as error:
      echo "hive player: connect attempt ", attempt, "/", ConnectAttempts,
        " failed: ", error.msg
      if attempt == ConnectAttempts:
        echo "hive player: game unreachable; exiting"
        quit(0)
      sleep(1000 * attempt)

  socket.send(registerFrame())
  echo "hive player: registered scripted ", scripted

  ## A BOUNDED receive loop. `receiveMessage(timeout)` returns none when the
  ## poll expires without a frame arriving - that is not a close, so the loop
  ## re-checks its own lifetime deadline and waits again. A game pod that
  ## dies without closing the socket therefore costs this pod a bounded wait,
  ## not the platform's kill timer.
  let lifetime = epochTime() + LifetimeSeconds
  while epochTime() < lifetime:
    let received =
      try: socket.receiveMessage(ReceivePollMs)
      except CatchableError as error:
        echo "hive player: receive failed: ", error.msg
        break
    if received.isNone:
      continue
    let message = received.get()
    if message.kind != TextMessage:
      continue
    try:
      let payload = parseJson(message.data)
      if payload{"done"}.getBool():
        echo "hive player: final scores ", payload{"result"}{"scores"}
        break
      case payload{"type"}.getStr()
      of "welcome":
        echo "hive player: seated at slot ", payload{"slot"}.getInt(),
          " as colony ", payload{"colony"}.getStr()
        ## Re-deliver the registration after the welcome, in case the first
        ## send raced the server's slot registration.
        socket.send(registerFrame())
      of "turn":
        echo "hive player: turn ", payload{"turn"}.getInt(), " (",
          payload{"doctrine_source"}.getStr(), ")"
      of "decision_request":
        let view = payload["view"]
        let turn = payload["turn"].getInt()
        if turn != lastTurn:
          let action = scriptedDoctrine(view,
            if kind == skNone: skMarcher else: kind, turn, memory)
          lastAction = action.toJson()
          lastTurn = turn
        socket.send($ %*{"type": "decision", "turn": turn,
          "action": lastAction, "source": "scripted"})
      else:
        discard
    except CatchableError as error:
      echo "hive player: ignoring bad frame: ", error.msg
  try:
    socket.close()
  except CatchableError:
    discard
