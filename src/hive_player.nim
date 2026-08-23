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
## baseline. The server plays those deterministically, no LLM.
##
## To field your own policy, reuse this image and set PLAYER_PROMPT:
##   coworld upload-policy <hive-image> --name my-hive \
##     --run /bin/hive-player --secret-env PLAYER_PROMPT="<your strategy>"

import std/[json, options, os, strutils]
import whisky

const DefaultPrompt = """
Open wide, then commit. For the first two turns run scouts near 60 with
trail_gain under 30: you have no road yet and a strong road to nowhere is
worse than no road. The moment a cache shows up in your sources list, invert
- scouts 12, trail_gain 85, lay_food 90, focus that block with focus_weight
80 - and then leave the doctrine alone while delivered_last_turn keeps
climbing. Keep lay_home at 55 or above whenever your ants are working more
than 25 cells out, because past 12 cells the home trail is the only way back.
Poach at 15 as a standing habit. When deliveries collapse by a third in one
turn the cache is gone: recall for exactly one turn, then relaunch with
scouts 50 and focus null.
"""

const ConnectAttempts = 4

when isMainModule:
  let url = getEnv("COWORLD_PLAYER_WS_URL")
  if url.len == 0:
    stderr.writeLine("hive player: COWORLD_PLAYER_WS_URL is not set")
    quit(1)

  var prompt = getEnv("PLAYER_PROMPT")
  let scripted = getEnv("PLAYER_SCRIPTED").strip()
  if prompt.len == 0 and scripted.len == 0:
    prompt = DefaultPrompt
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

  while true:
    let received =
      try: socket.receiveMessage()
      except CatchableError as error:
        echo "hive player: receive failed: ", error.msg
        break
    if received.isNone:
      echo "hive player: connection closed, exiting"
      break
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
