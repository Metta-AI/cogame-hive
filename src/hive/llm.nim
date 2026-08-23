## Claude-backed decision making for Hive. Each seat's policy is just a
## prompt: the game server composes that colony's view and asks Claude for one
## DOCTRINE - nine integers, a target block and two strings - every ten
## seconds of sim time.
##
## Decisions are simultaneous by rule, so all four requests go out as ONE
## PARALLEL BATCH (`curly.makeRequests`, bullwhip's `decideAll` shape);
## invalid replies are retried once as a smaller batch with a hint, and
## anything still failing falls back to the `marcher` scripted doctrine and
## writes a `fallback` event. Seats are NEVER queried sequentially.
##
## Credentials, in order of preference:
##   Bedrock sidecar / bearer token   - hosted pods
##   ANTHROPIC_API_KEY                - the key itself
##   ANTHROPIC_API_KEY_URI            - a URI holding the key
## With no credentials the client disables itself on first discovery, every
## turn falls back instantly with no network wait, and offline certification
## still completes. That fallback is load-bearing.

import std/[json, os, strutils, times, unicode]
import bitworld/runtime
import curly
import types, doctrine, baselines, broadcast, sim

const
  AnthropicUrl = "https://api.anthropic.com/v1/messages"
  AnthropicVersion = "2023-06-01"
  BedrockAnthropicVersion = "bedrock-2023-05-31"
  FirstAttemptSeconds* = 14
  RetryAttemptSeconds* = 6
  DefaultTurnBudgetSeconds* = 22.0
    ## The OUTER per-turn deadline. The two attempt deadlines already bound
    ## the turn at 14 + 6 = 20 s, but that arithmetic assumes the transport
    ## honours its own timeout; this is the belt-and-braces bound the design
    ## note names, and it also covers request assembly.

  SystemPrompt* = """
You are the whole mind of one ant colony on a 160x88 cell meadow shared with three
rival colonies. You have 24 identical ants. You cannot see through their eyes, you
cannot talk to them, and you cannot move any single ant. Each ant sees only the eight
cells around it. It drops a FOOD trail while carrying food home and a HOME trail while
searching, and it steers by the trails it smells. Both trails fade with a half-life of
about 7 seconds. Ants know the way home only within 12 cells of the nest; further out
they must ride the home trail their nestmates laid.
Food caches appear in symmetric sets - one near each colony - and twice per match a big
cache appears dead centre. A cache runs out. Every unit of food an ant carries into
your nest pad is one point. You score your share of ALL food returned by ALL FOUR
colonies, so taking food a rival would have taken is worth exactly as much as finding
your own.
Every 10 seconds you set the colony's DOCTRINE: how many ants explore instead of
following roads, how strongly ants follow trails, whether they poach rival roads, how
hard they avoid their own outbound trail, how much scent they lay, and which direction
departing ants face. That is all. Everything else your colony does is emergent.
Reply with a single JSON object and NOTHING else. Your reply MUST begin with '{'.
Schema:
{"scouts":0-100,        // percent of your 24 ants that ignore trails and wander
 "trail_gain":0-100,    // how strongly searching ants follow YOUR food trail
 "poach":0-100,         // how strongly searching ants follow RIVAL food trails
 "spread":0-100,        // how hard ants avoid your own home trail (fan out)
 "lay_food":0-100,      // strength of the food trail a laden ant lays
 "lay_home":0-100,      // strength of the home trail a searching ant lays
 "recall":true|false,   // true: every ant drops its road and walks home, then waits
 "focus":[bx,by]|null,  // the 20x11 observation block departing ants head toward
 "focus_weight":0-100,  // percent of departing ants that take the focus bearing
 "note":"<=140 chars",  // your reasoning, shown to spectators only
 "say":"<=32 chars"}    // one short line, shown to spectators only
High trail_gain plus low scouts exploits a known cache hard and goes blind when it runs
out. High scouts finds the next cache but wastes ants. High poach walks your ants onto
a rival's road, which leads to their cache and puts your paint over theirs. High spread
stops your column doubling back on itself. recall is the reset: it abandons a dead road
and lets it fade before you launch somewhere else.
"""

type
  LlmTransport = enum
    ltNone, ltBedrock, ltAnthropic

  LlmClient* = ref object
    curl: Curly
    transport: LlmTransport
    apiKey: string
    bedrockEndpoint: string
    bedrockModels: seq[string]
    bedrockModel: int
    bedrockToken: string
    model*: string
    maxOutputTokens*: int
    turnBudgetSeconds*: float
      ## The outer per-turn deadline; the server sets it from the game
      ## config's turnBudgetSeconds.
    disabled*: bool
    sendBatch*: proc (batch: RequestBatch, timeoutSeconds: int): ResponseBatch
      {.gcsafe.}
      ## Seam for `tests/test_engine.nim`: the default is
      ## `curl.makeRequests`, which issues the whole batch in parallel. A
      ## test installs a fake here to assert the four seats really do go out
      ## together.

  SeatOutcome* = object
    ## What the turn produced for one seat, and why.
    resolved*: ResolvedDoctrine
    cause*: string      ## "" when the LLM answered
    detail*: string
    attempts*: int

proc resolveApiKey(): string =
  result = getEnv("ANTHROPIC_API_KEY").strip()
  if result.len > 0:
    return
  let uri = getEnv("ANTHROPIC_API_KEY_URI").strip()
  if uri.len == 0:
    return ""
  try:
    result = readCogameUri(uri, "ANTHROPIC_API_KEY_URI").strip()
  except CatchableError as error:
    echo "hive llm: failed to fetch ANTHROPIC_API_KEY_URI: ", error.msg
    result = ""

proc bedrockModelIds(): seq[string] =
  let pinned = getEnv("BEDROCK_MODEL").strip()
  if pinned.len > 0:
    return @[pinned]
  ## Haiku leads: hosted Bedrock capacity is shared account-wide and the
  ## sonnet profiles run out of daily tokens first.
  @[
    "us.anthropic.claude-haiku-4-5-20251001-v1:0",
    "us.anthropic.claude-sonnet-4-6",
    "us.anthropic.claude-sonnet-4-5-20250929-v1:0",
  ]

proc tryNextBedrockModel(client: LlmClient, why: string,
    failedModel = -1): bool =
  ## `failedModel` is the candidate the response that is complaining was sent
  ## to. Every request in a turn's batch goes to the SAME model, so four
  ## simultaneous 403s are one verdict on one candidate, not four steps down
  ## a three-rung ladder: a response about a model somebody else has already
  ## stepped off is answered "yes, handled" without moving again.
  if client.transport != ltBedrock:
    return false
  if failedModel >= 0 and failedModel != client.bedrockModel:
    return true
  if client.bedrockModel + 1 >= client.bedrockModels.len:
    return false
  client.bedrockModel.inc
  echo "hive llm: ", client.bedrockModels[client.bedrockModel - 1],
    " unusable (", why, "); falling back to ",
    client.bedrockModels[client.bedrockModel]
  true

proc bedrockUrl(client: LlmClient): string =
  client.bedrockEndpoint & "/model/" &
    client.bedrockModels[client.bedrockModel] & "/invoke"

proc newLlmClient*(model = "claude-sonnet-5", maxOutputTokens = 900,
    turnBudgetSeconds = DefaultTurnBudgetSeconds): LlmClient =
  result = LlmClient(model: model, maxOutputTokens: maxOutputTokens,
    turnBudgetSeconds: turnBudgetSeconds)
  let client = result
  result.sendBatch = proc (batch: RequestBatch, timeoutSeconds: int):
      ResponseBatch {.gcsafe.} =
    ## ONE parallel batch for the whole turn. Seats are never queried
    ## sequentially: at most four requests, all in flight together.
    client.curl.makeRequests(batch, timeoutSeconds)
  let bedrockEndpoint = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
  let bedrockToken = getEnv("AWS_BEARER_TOKEN_BEDROCK").strip()
  if bedrockEndpoint.len > 0 or bedrockToken.len > 0:
    let region = getEnv("AWS_REGION", getEnv("AWS_DEFAULT_REGION", "us-west-2"))
    let endpoint =
      if bedrockEndpoint.len > 0: bedrockEndpoint
      else: "https://bedrock-runtime." & region & ".amazonaws.com"
    result.transport = ltBedrock
    result.bedrockEndpoint = endpoint.strip(chars = {'/'}, leading = false)
    result.bedrockModels = bedrockModelIds()
    result.bedrockToken = bedrockToken
    result.curl = newCurly()
    echo "hive llm: bedrock transport, url ", result.bedrockUrl
    return
  result.apiKey = resolveApiKey()
  if result.apiKey.len > 0:
    result.transport = ltAnthropic
    result.curl = newCurly()
    echo "hive llm: anthropic transport, model ", result.model
  else:
    result.transport = ltNone
    result.disabled = true
    echo "hive llm: no LLM credentials; using scripted fallback"

proc userMessage*(match: Sim, seat: int, prompt: string): string =
  ## The seat's PLAYER_PROMPT text, a blank line, then the seat's view JSON.
  ## The prompt text is never echoed into the replay - only `policy_kind`.
  var text = prompt.strip()
  if text.runeLen > MaxPromptRunes:
    text = text.runeSubStr(0, MaxPromptRunes)
  text & "\n\n" & viewText(buildView(match, seat))

proc requestFor(
  client: LlmClient,
  system, user: string
): tuple[url: string, headers: HttpHeaders, body: string] =
  var body = %*{
    "max_tokens": client.maxOutputTokens,
    "temperature": 0.4,
    "system": system,
    "messages": [{"role": "user", "content": user}]
  }
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if client.transport == ltBedrock:
    body["anthropic_version"] = %BedrockAnthropicVersion
    if client.bedrockToken.len > 0:
      headers["authorization"] = "Bearer " & client.bedrockToken
    result.url = client.bedrockUrl()
  else:
    body["model"] = %client.model
    ## Haiku 4.5 rejects `output_config.effort` outright with a 400.
    headers["x-api-key"] = client.apiKey
    headers["anthropic-version"] = AnthropicVersion
    result.url = AnthropicUrl
  result.headers = headers
  result.body = $body

proc textOf(
  client: LlmClient,
  response: Response,
  error, url: string,
  failedModel = -1
): string =
  if error.len > 0:
    raise newException(HiveError, "llm transport: " & error)
  if response.code == 401 or response.code == 403:
    let detail = response.body[0 .. min(response.body.high, 400)]
    ## "on a 403 the client advances to the next candidate". A 403 on Bedrock
    ## is a per-MODEL verdict - no access to this inference profile, or the
    ## profile is not enabled in this account - so the ladder is walked before
    ## the whole client is written off, whatever wording the body carries.
    ## Only when the last candidate has answered 403 is the client disabled.
    if client.tryNextBedrockModel("http " & $response.code, failedModel):
      raise newException(HiveError,
        "bedrock model rejected (" & $response.code & "): " & detail)
    client.disabled = true
    raise newException(HiveError,
      "llm auth failed (" & $response.code & ") at " & url & ": " & detail)
  if response.code == 429:
    let detail = response.body[0 .. min(response.body.high, 300)]
    discard client.tryNextBedrockModel("throttled", failedModel)
    raise newException(HiveError, "llm throttled (429): " & detail)
  if response.code < 200 or response.code >= 300:
    raise newException(HiveError, "anthropic error " & $response.code & ": " &
      response.body[0 .. min(response.body.high, 300)])
  let payload = parseJson(response.body)
  if payload{"stop_reason"}.getStr() == "refusal":
    raise newException(HiveError, "anthropic refusal")
  for contentBlock in payload{"content"}:
    if contentBlock{"type"}.getStr() == "text":
      result.add(contentBlock{"text"}.getStr())
  if payload{"stop_reason"}.getStr() == "max_tokens" and '{' notin result:
    raise newException(HiveError, "reply cut off at max_tokens before any " &
      "JSON: " & result[0 .. min(result.high, 160)].replace("\n", " "))

proc classify*(message: string): string =
  ## The `fallback.cause` enum: timeout / parse_error / transport_error /
  ## no_credentials / budget_guard.
  let lowered = message.toLowerAscii()
  if "timed out" in lowered or "timeout" in lowered:
    "timeout"
  elif "transport" in lowered or "resolve" in lowered or "connect" in lowered:
    "transport_error"
  elif "auth" in lowered or "credential" in lowered:
    "no_credentials"
  else:
    "parse_error"

proc decideAll*(
  client: LlmClient,
  match: Sim,
  prompts: array[Colonies, string],
  scripted: array[Colonies, ScriptKind],
  memory: var array[Colonies, BaselineMemory],
  turn: int
): array[Colonies, SeatOutcome] =
  ## One doctrine per seat. NEVER raises and never blocks unboundedly: at
  ## most two bounded batches, then the scripted layer.
  var views: array[Colonies, JsonNode]
  var previous: array[Colonies, Doctrine]
  var hasPrevious: array[Colonies, bool]
  for seat in 0 ..< Colonies:
    let colony = match.seatNest[seat]
    views[seat] = buildView(match, seat)
    previous[seat] = match.doctrines[colony]
    hasPrevious[seat] = match.hasDoctrine[colony]

  var open: seq[int]
  for seat in 0 ..< Colonies:
    if scripted[seat] != skNone or client.disabled or prompts[seat].len == 0:
      result[seat] = SeatOutcome(
        resolved: scriptedResolved(views[seat],
          (if scripted[seat] == skNone: skMarcher else: scripted[seat]),
          turn, memory[seat]),
        cause: (if scripted[seat] != skNone: "" else: "no_credentials"),
        detail: "",
        attempts: 0
      )
    else:
      open.add(seat)

  ## The OUTER per-turn deadline. Every attempt is clamped to what is left of
  ## it, and once it is spent the remaining seats drop straight to the
  ## scripted layer instead of starting an attempt that cannot finish in time.
  let turnDeadline = epochTime() + max(1.0, client.turnBudgetSeconds)
  var outerExpired = false
  for attempt in 0 .. 1:
    if open.len == 0 or client.disabled:
      break
    let remaining = turnDeadline - epochTime()
    if remaining <= 0.0:
      outerExpired = true
      break
    let attemptBudget =
      if attempt == 0: FirstAttemptSeconds else: RetryAttemptSeconds
    let deadline = max(1, min(attemptBudget, int(remaining)))
    var batch: RequestBatch
    for seat in open:
      var user = userMessage(match, seat, prompts[seat])
      if attempt > 0:
        user.add("\n\nYour previous reply was invalid. Respond with ONLY the " &
          "requested JSON object, beginning with '{' and containing the " &
          "integer keys scouts, trail_gain, poach, spread, lay_food, " &
          "lay_home, focus_weight and the keys recall, focus, note, say.")
      let request = client.requestFor(SystemPrompt, user)
      batch.post(request.url, request.headers, request.body, $seat)
    ## Every request in this batch went to this candidate; a 403 from any of
    ## them is one verdict on it.
    let batchModel = client.bedrockModel
    let started = epochTime()
    let responses = client.sendBatch(batch, deadline)
    let latency = int((epochTime() - started) * 1000.0)
    var stillOpen: seq[int]
    for position, seat in open:
      try:
        let text = client.textOf(responses[position].response,
          responses[position].error, batch[position].url, batchModel)
        let parsed = parseDoctrine(text, previous[seat], hasPrevious[seat])
        result[seat] = SeatOutcome(
          resolved: ResolvedDoctrine(doctrine: parsed, source: dsLlm,
            latencyMs: latency),
          cause: "",
          detail: "",
          attempts: attempt + 1
        )
      except CatchableError as error:
        echo "hive llm: seat ", seat, " attempt ", attempt + 1, " failed: ",
          error.msg
        result[seat] = SeatOutcome(
          cause: classify(error.msg),
          detail: truncateRunes(error.msg, MaxDetailRunes),
          attempts: attempt + 1
        )
        stillOpen.add(seat)
    open = stillOpen

  for seat in open:
    ## Two consecutive failures, or the outer per-turn deadline: the marcher
    ## doctrine, computed in microseconds, plus the `fallback` event the
    ## caller writes.
    if outerExpired:
      echo "hive llm: seat ", seat, " out of per-turn budget (",
        client.turnBudgetSeconds, "s)"
      if result[seat].cause.len == 0:
        result[seat].cause = "timeout"
        result[seat].detail = truncateRunes(
          "per-turn deadline of " & $client.turnBudgetSeconds &
          "s expired before this seat could be asked", MaxDetailRunes)
        result[seat].attempts = max(1, result[seat].attempts)
    echo "hive llm: seat ", seat, " falling back to the scripted doctrine"
    result[seat].resolved = scriptedResolved(views[seat], skMarcher, turn,
      memory[seat], dsFallback)
