## Hive player: a policy is just a prompt.
##
## The thinnest possible container. It connects, sends ONE `register` frame
## carrying its prompt (or its baseline name), and thereafter only receives
## until `{"done": true, ...}`. All of the actual decision making happens
## inside the game server, which sends this seat's prompt plus the colony's
## view to Claude once every ten seconds of sim time.
##
## PLAYER_SCRIPTED=marcher (or 1/true/yes) registers the seat as the built-in
## marcher baseline instead; PLAYER_SCRIPTED=driftling as the weaker drifting
## baseline. The server plays those deterministically, no LLM. A seat that
## sets NEITHER registers as `marcher`: no prompt is invented here.
##
## To field your own policy, reuse this image and set PLAYER_PROMPT:
##   coworld upload-policy <hive-image> --name my-hive \
##     --run /bin/hive-player --secret-env PLAYER_PROMPT="<your strategy>"

import std/[json, options, os, strutils, times]
import whisky

const
  ConnectAttempts = 4

  DefaultScripted = "marcher"
    ## "A seat that sets neither defaults to PLAYER_SCRIPTED=marcher." No
    ## prompt is invented here: a seat nobody configured must not silently
    ## become an LLM seat playing a strategy its owner never wrote.

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

  let prompt = getEnv("PLAYER_PROMPT")
  var scripted = getEnv("PLAYER_SCRIPTED").strip()
  if prompt.len == 0 and scripted.len == 0:
    scripted = DefaultScripted
    echo "hive player: neither PLAYER_PROMPT nor PLAYER_SCRIPTED is set; ",
      "registering as the ", DefaultScripted, " baseline"
  let policy = getEnv("PLAYER_POLICY_LABEL")

  proc registerFrame(): string =
    $ %*{
      "type": "register",
      "prompt": prompt,
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
  echo "hive player: registered (", prompt.len, " prompt chars",
    (if scripted.len > 0: ", scripted " & scripted else: ""), ")"

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
      else:
        discard
    except CatchableError as error:
      echo "hive player: ignoring bad frame: ", error.msg
  try:
    socket.close()
  except CatchableError:
    discard
