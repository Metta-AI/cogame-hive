## Claude-backed decision making for Hive. Each seat's policy is just a
## prompt: the game server composes that colony's view and asks Claude for one
## DOCTRINE - nine integers, a target block and two strings - every ten
## seconds of sim time.
##
## Decisions are simultaneous by rule, so game-hosted model requests go out
## as ONE PARALLEL BATCH (`curly.makeRequests`, bullwhip's `decideAll` shape);
## failed seats are retried once as a smaller batch - with a "your reply was
## invalid" hint only when the model actually replied with something
## unusable, and after a short backoff when the provider throttled or errored
## - and anything still failing falls back to the `marcher` scripted doctrine
## and writes a `fallback` event. Seats are NEVER queried sequentially.
##
## Credentials, in order of preference:
##   COWORLD_LLM_ENDPOINT            - hosted sidecar
##   Bedrock bearer token            - local play
##   ANTHROPIC_API_KEY                - the key itself
##   ANTHROPIC_API_KEY_URI            - a URI holding the key
## With no credentials the client disables itself on first discovery, every
## turn falls back instantly with no network wait, and offline certification
## still completes. That fallback is load-bearing.

import std/[json, os, strutils, times, unicode]
import bitworld/runtime
import curly
import types, doctrine, baselines, broadcast, sim, prompts

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


type
  LlmTransport = enum
    ltNone, ltSidecar, ltBedrock, ltAnthropic

  LlmClient* = ref object
    curl: Curly
    transport: LlmTransport
    apiKey: string
    sidecarEndpoint: string
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
    client.curl.makeRequests(batch, timeoutSeconds)
  let sidecarEndpoint = getEnv("COWORLD_LLM_ENDPOINT").strip()
  if sidecarEndpoint.len > 0:
    result.transport = ltSidecar
    result.sidecarEndpoint = sidecarEndpoint.strip(chars = {'/'}, leading = false)
    result.model = getEnv("COWORLD_LLM_MODEL", "anthropic/claude-haiku-4.5")
    result.curl = newCurly()
    return
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
  system, user: string, slot: int
): tuple[url: string, headers: HttpHeaders, body: string] =
  var body = %*{
    "max_tokens": client.maxOutputTokens,
    "temperature": 0.4,
    "system": system,
    "messages": [{"role": "user", "content": user}]
  }
  var headers: HttpHeaders
  if client.transport == ltSidecar and slot >= 0:
    headers["X-Coworld-Player-Slot"] = $slot
  headers["content-type"] = "application/json"
  if client.transport == ltBedrock:
    body["anthropic_version"] = %BedrockAnthropicVersion
    if client.bedrockToken.len > 0:
      headers["authorization"] = "Bearer " & client.bedrockToken
    result.url = client.bedrockUrl()
  elif client.transport == ltSidecar:
    body["model"] = %client.model
    headers["anthropic-version"] = AnthropicVersion
    result.url = client.sidecarEndpoint & "/v1/messages"
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
  ## no_credentials / budget_guard / throttled / refusal / provider_error
  ## (`budget_guard` is assigned by the server, never here). Matched against
  ## the strings `textOf` raises, in this order; `parse_error` is the
  ## catch-all for a reply the model really did send and we could not use,
  ## so a 429, a 5xx, a per-model 403 and a refusal must be caught first or
  ## `results.fallback_causes` blames the player's prompt for a provider
  ## outage (#4).
  let lowered = message.toLowerAscii()
  if "timed out" in lowered or "timeout" in lowered:
    "timeout"
  elif "transport" in lowered or "resolve" in lowered or "connect" in lowered:
    "transport_error"
  elif "auth" in lowered or "credential" in lowered:
    "no_credentials"
  elif "throttled" in lowered or "(429)" in lowered:
    "throttled"
  elif "refusal" in lowered:
    "refusal"
  elif "rejected" in lowered or "unavailable" in lowered or
      "anthropic error 5" in lowered:
    "provider_error"
  else:
    "parse_error"

proc retryBackoffSeconds*(retryAfter: int, remaining: float): float =
  ## How long the retry batch waits after a `throttled` or `provider_error`
  ## first attempt: the provider's `retry-after` when it sent a usable one
  ## (`retryAfter` < 0 means it did not), else 2 s; never more than 4 s and
  ## never so long that the retry attempt no longer fits in `remaining`, what
  ## is left of the outer turn deadline. Firing the retry ~150 ms into the
  ## same rate limit only deepens the throttle (#4).
  let wanted = if retryAfter >= 0: retryAfter.float else: 2.0
  min(wanted, min(4.0, max(0.0, remaining - RetryAttemptSeconds.float - 1.0)))

proc withNote(detail, note: string): string =
  ## Appends `note` to a recorded detail only when the result still fits
  ## `MaxDetailRunes`; the caller echoes the note regardless.
  if note.len > 0 and (detail & note).runeLen <= MaxDetailRunes:
    detail & note
  else:
    detail

proc needsBackoff(open: seq[int],
    outcomes: array[Colonies, SeatOutcome]): bool =
  for seat in open:
    if outcomes[seat].cause == "throttled" or
        outcomes[seat].cause == "provider_error":
      return true
  false

proc decideAll*(
  client: LlmClient,
  match: Sim,
  prompts: array[Colonies, string],
  scripted: array[Colonies, ScriptKind],
  memory: var array[Colonies, BaselineMemory],
  turn: int,
  selection: PromptSelection,
  external: array[Colonies, bool] = [false, false, false, false]
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
    if external[seat]:
      discard
    elif scripted[seat] != skNone or client.disabled or prompts[seat].len == 0:
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
  var retryAfter = -1
    ## Seconds from a `retry-after` header on a throttled / provider-error
    ## response in the first batch; -1 when none carried a usable one.
  var backoffNote: array[Colonies, string]
  for attempt in 0 .. 1:
    if open.len == 0 or client.disabled:
      break
    if attempt == 1 and needsBackoff(open, result):
      ## The provider said "not now": wait before the one retry, inside the
      ## outer deadline, instead of hammering the same rate limit.
      let backoff = retryBackoffSeconds(retryAfter, turnDeadline - epochTime())
      if backoff > 0.0:
        let label = formatFloat(backoff, ffDecimal, 1) & "s"
        echo "hive llm: first attempt throttled or provider error; backing " &
          "off ", label, " before the retry (retry-after ",
          (if retryAfter >= 0: $retryAfter & "s" else: "absent"), ")"
        for seat in open:
          backoffNote[seat] = " [retried after " & label & " backoff]"
        sleep(int(backoff * 1000.0))
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
      ## The hint is for a model that REPLIED with something unusable. A seat
      ## that was throttled, timed out or hit a provider error never saw its
      ## first message answered, so it gets the unmodified message again.
      if attempt > 0 and result[seat].cause == "parse_error":
        user.add("\n\nYour previous reply was invalid. Respond with ONLY the " &
          "requested JSON object, beginning with '{' and containing the " &
          "integer keys scouts, trail_gain, poach, spread, lay_food, " &
          "lay_home, focus_weight and the keys recall, focus, note, say.")
      let request = client.requestFor(selection.systemPrompt(), user, seat)
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
        let cause = classify(error.msg)
        if attempt == 0 and (cause == "throttled" or cause == "provider_error"):
          ## Honour `retry-after` (integer seconds only; an HTTP-date or any
          ## other junk is ignored). The largest value in the batch wins.
          let header =
            responses[position].response.headers["retry-after"].strip()
          if header.len > 0:
            try:
              retryAfter = max(retryAfter, parseInt(header))
            except ValueError:
              discard
        result[seat] = SeatOutcome(
          cause: cause,
          detail: withNote(truncateRunes(error.msg, MaxDetailRunes),
            backoffNote[seat]),
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
