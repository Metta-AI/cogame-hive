## The turn loop against a FAKE LLM transport: all four seats go out in one
## parallel batch, the per-turn budget is bounded, the budget guard settles
## early, the wall-clock stop yields deadline/wall_clock, a sim fault yields
## fault/sim_fault with 0.25 everywhere and a partial replay, an unregistered
## seat plays the marcher, and a mid-match disconnect degrades and revives.
## Also (#4): a sidecar 429 / 503 / refusal is reported as throttled /
## provider_error / refusal rather than parse_error, a throttled retry backs
## off inside the turn budget and re-sends the unmodified message.

import std/[json, os, strutils, times, unicode]
import curly
import support/helpers
import hive/[field, llm, roster, replay, sources, state, events]

type BatchRecord = object
  size: int
  opened: float
  closed: float
  bodies: seq[string]

const RetryHint = "Your previous reply was invalid"

proc bodiesOf(batch: RequestBatch): seq[string] =
  for index in 0 ..< batch.len:
    result.add(batch[index].body)

var records: seq[BatchRecord]
var windows: seq[tuple[opened, closed: float]]

proc goodBody(scouts: int): string =
  $ %*{"content": [{"type": "text", "text":
    "{\"scouts\": " & $scouts & ", \"trail_gain\": 66, \"poach\": 7, " &
    "\"spread\": 21, \"lay_food\": 80, \"lay_home\": 55, " &
    "\"recall\": false, \"focus\": [4, 5], \"focus_weight\": 60, " &
    "\"note\": \"pump the west road\", \"say\": \"west\"}"}]}

proc fakeGood(batch: RequestBatch, timeoutSeconds: int): ResponseBatch
    {.gcsafe.} =
  ## One call, every request in flight together: the in-flight window of each
  ## request is the window of the batch, so all four intersect by construction.
  {.gcsafe.}:
    let opened = epochTime()
    sleep(20)
    let closed = epochTime()
    records.add(BatchRecord(size: batch.len, opened: opened, closed: closed))
    for index in 0 ..< batch.len:
      windows.add((opened: opened, closed: closed))
      result.add((response: Response(code: 200,
        body: goodBody(10 + index * 5)), error: ""))

proc fakeHung(batch: RequestBatch, timeoutSeconds: int): ResponseBatch
    {.gcsafe.} =
  ## Emulates curl's own deadline: the batch blocks for the timeout it was
  ## given and then reports every request as timed out.
  {.gcsafe.}:
    records.add(BatchRecord(size: batch.len, opened: epochTime(),
      closed: epochTime()))
    sleep(min(timeoutSeconds, 1) * 100)
    for index in 0 ..< batch.len:
      result.add((response: Response(code: 0),
        error: "Operation timed out after " & $timeoutSeconds & " seconds"))

proc fakeGarbage(batch: RequestBatch, timeoutSeconds: int): ResponseBatch
    {.gcsafe.} =
  {.gcsafe.}:
    records.add(BatchRecord(size: batch.len, opened: epochTime(),
      closed: epochTime(), bodies: bodiesOf(batch)))
    for index in 0 ..< batch.len:
      result.add((response: Response(code: 200, body: $ %*{
        "content": [{"type": "text", "text": "I would rather not."}]}),
        error: ""))

proc fakeIgnoresItsDeadline(batch: RequestBatch, timeoutSeconds: int):
    ResponseBatch {.gcsafe.} =
  ## A transport that does NOT honour the deadline it was handed. That is
  ## exactly what the OUTER per-turn deadline exists for: the two attempt
  ## budgets are only as good as the transport that is given them.
  {.gcsafe.}:
    records.add(BatchRecord(size: batch.len, opened: epochTime(),
      closed: epochTime()))
    sleep(1200)
    for index in 0 ..< batch.len:
      result.add((response: Response(code: 0),
        error: "Operation timed out after " & $timeoutSeconds & " seconds"))

proc fakeForbidden(batch: RequestBatch, timeoutSeconds: int): ResponseBatch
    {.gcsafe.} =
  ## A Bedrock 403 whose body does NOT contain the literal string
  ## "Model access is denied" - the wording varies by account and by profile,
  ## and the note's rule is about the status code, not the prose.
  {.gcsafe.}:
    records.add(BatchRecord(size: batch.len, opened: epochTime(),
      closed: epochTime()))
    for index in 0 ..< batch.len:
      result.add((response: Response(code: 403, body:
        "{\"message\":\"You don't have access to the model with the " &
        "specified model ID.\"}"), error: ""))

proc fakeThrottled(batch: RequestBatch, timeoutSeconds: int): ResponseBatch
    {.gcsafe.} =
  ## The sidecar's 30 rpm cap exactly as the league saw it (#4), with a
  ## `retry-after` the client is expected to honour.
  {.gcsafe.}:
    records.add(BatchRecord(size: batch.len, opened: epochTime(),
      closed: epochTime(), bodies: bodiesOf(batch)))
    for index in 0 ..< batch.len:
      var headers: HttpHeaders
      headers["Retry-After"] = "1"
      result.add((response: Response(code: 429, headers: headers, body:
        "{\"message\": \"sidecar request rate limit reached " &
        "(30 requests/minute)\", \"__type\": \"ThrottlingException\"}"),
        error: ""))

proc fakeUnavailable(batch: RequestBatch, timeoutSeconds: int): ResponseBatch
    {.gcsafe.} =
  ## The other half of #4's corpus: a 503 from the sidecar, here with a
  ## `retry-after` that is not an integer and must be ignored.
  {.gcsafe.}:
    records.add(BatchRecord(size: batch.len, opened: epochTime(),
      closed: epochTime(), bodies: bodiesOf(batch)))
    for index in 0 ..< batch.len:
      var headers: HttpHeaders
      headers["retry-after"] = "Wed, 21 Oct 2026 07:28:00 GMT"
      result.add((response: Response(code: 503, headers: headers,
        body: "{\"message\":\"LLM provider is unavailable\"}"), error: ""))

proc fakeRefusal(batch: RequestBatch, timeoutSeconds: int): ResponseBatch
    {.gcsafe.} =
  {.gcsafe.}:
    records.add(BatchRecord(size: batch.len, opened: epochTime(),
      closed: epochTime(), bodies: bodiesOf(batch)))
    for index in 0 ..< batch.len:
      result.add((response: Response(code: 200, body: $ %*{
        "stop_reason": "refusal", "content": []}), error: ""))

proc enabledClient(): LlmClient =
  result = newLlmClient()
  result.disabled = false

proc promptsAll(text: string): array[Colonies, string] =
  for seat in 0 ..< Colonies:
    result[seat] = text

proc main() =
  let meadow = testField()

  block oneParallelBatch:
    records.setLen(0)
    windows.setLen(0)
    let client = enabledClient()
    client.sendBatch = fakeGood
    var match = newSim(testConfig(960, 42), meadow)
    var memory: array[Colonies, BaselineMemory]
    var scripted: array[Colonies, ScriptKind]
    var turns = 0
    let provide = proc (m: Sim, turn: int):
        array[Colonies, ResolvedDoctrine] {.closure.} =
      inc turns
      let outcomes = client.decideAll(m, promptsAll("raid the centre"),
        scripted, memory, turn)
      for seat in 0 ..< Colonies:
        result[seat] = outcomes[seat].resolved
    match.runEpisode(provide)
    checkEqual(turns, 4, "a 960-tick match has four decision turns")
    checkEqual(records.len, turns,
      "exactly ONE batch call per turn - seats are never queried sequentially")
    for record in records:
      checkEqual(record.size, Colonies, "every turn batches exactly 4 requests")
    ## All four in-flight windows must intersect.
    for turn in 0 ..< turns:
      let base = windows[turn * Colonies]
      for seat in 0 ..< Colonies:
        let other = windows[turn * Colonies + seat]
        check(other.opened <= base.closed and base.opened <= other.closed,
          "seat " & $seat & "'s in-flight window intersects seat 0's")
    for event in match.events.items:
      if event{"type"}.getStr() == "doctrine":
        checkEqual(event{"source"}.getStr(), "llm",
          "every doctrine came from the LLM")
        check(event{"note"}.getStr().len > 0, "with real note content")
    report("all four seats' calls go out as one parallel batch per turn")

  block boundedRetryThenFallback:
    records.setLen(0)
    let client = enabledClient()
    client.sendBatch = fakeGarbage
    var match = newSim(testConfig(240, 5), meadow)
    var memory: array[Colonies, BaselineMemory]
    var scripted: array[Colonies, ScriptKind]
    let outcomes = client.decideAll(match, promptsAll("go"), scripted, memory, 0)
    checkEqual(records.len, 2,
      "an unusable reply costs exactly one retry, no more")
    checkEqual(records[0].size, Colonies, "the first batch holds all four")
    checkEqual(records[1].size, Colonies, "the retry re-batches all four")
    for seat in 0 ..< Colonies:
      checkEqual($outcomes[seat].resolved.source, "fallback",
        "two failures land on the scripted fallback")
      checkEqual(outcomes[seat].cause, "parse_error", "cause is parse_error")
      check(outcomes[seat].resolved.doctrine.isLegal(),
        "the fallback doctrine is legal")
    for body in records[0].bodies:
      check(RetryHint notin body, "the first attempt carries no hint")
    for body in records[1].bodies:
      check(RetryHint in body,
        "a seat whose reply was unusable is told so on the retry")
    ## The backoff fixtures below never sleep less than 1 s, so "no backoff"
    ## is "well under that", with room for a slow debug build.
    check(records[1].opened - records[0].closed < 0.9,
      "a parse failure is retried without a backoff")
    report("tolerant parse, exactly one retry, then the marcher doctrine")

  block throttledIsNotAParseError:
    ## #4: every sidecar failure the league saw was a 429 or a 503, and
    ## `classify` filed all of them under parse_error, so
    ## results.fallback_causes blamed the player's prompt for a throttled
    ## sidecar.
    records.setLen(0)
    let client = enabledClient()
    client.turnBudgetSeconds = 9.0
    client.sendBatch = fakeThrottled
    var match = newSim(testConfig(240, 5), meadow)
    var memory: array[Colonies, BaselineMemory]
    var scripted: array[Colonies, ScriptKind]
    let started = epochTime()
    let outcomes = client.decideAll(match, promptsAll("go"), scripted, memory, 0)
    let elapsed = epochTime() - started
    checkEqual(records.len, 2, "a throttled batch is retried exactly once")
    checkEqual(records[1].size, Colonies, "the retry re-batches all four")
    for seat in 0 ..< Colonies:
      checkEqual(outcomes[seat].cause, "throttled", "the cause is throttled")
      checkEqual($outcomes[seat].resolved.source, "fallback", "it fell back")
      check(outcomes[seat].resolved.doctrine.isLegal(),
        "the fallback doctrine is legal")
      checkEqual(outcomes[seat].attempts, 2, "two attempts are recorded")
      check("429" in outcomes[seat].detail, "detail keeps the 429 text")
      check(outcomes[seat].detail.runeLen <= MaxDetailRunes,
        "detail stays within MaxDetailRunes")
    for body in records[1].bodies:
      check(RetryHint notin body,
        "a throttled seat is NOT told its reply was invalid - it never replied")
    checkEqual(records[1].bodies, records[0].bodies,
      "the retry re-sends the unmodified message")
    let gap = records[1].opened - records[0].closed
    check(gap >= 0.9, "the retry honours retry-after: 1 (waited " &
      $gap & "s)")
    check(gap < 1.8, "and no longer than that")
    check(elapsed < client.turnBudgetSeconds,
      "the backoff keeps the turn inside the outer budget (took " &
      $elapsed & "s)")
    report("a 429 is reported as throttled and the retry backs off")

  block providerErrorIsNotAParseError:
    records.setLen(0)
    let client = enabledClient()
    ## 8 s left minus the 6 s retry minus 1 s slack clamps the default 2 s
    ## backoff to 1 s: the retry must still fit the turn.
    client.turnBudgetSeconds = 8.0
    client.sendBatch = fakeUnavailable
    var match = newSim(testConfig(240, 5), meadow)
    var memory: array[Colonies, BaselineMemory]
    var scripted: array[Colonies, ScriptKind]
    let started = epochTime()
    let outcomes = client.decideAll(match, promptsAll("go"), scripted, memory, 0)
    let elapsed = epochTime() - started
    checkEqual(records.len, 2, "a 503 is retried exactly once")
    for seat in 0 ..< Colonies:
      checkEqual(outcomes[seat].cause, "provider_error",
        "the cause is provider_error")
      checkEqual($outcomes[seat].resolved.source, "fallback", "it fell back")
      check(outcomes[seat].resolved.doctrine.isLegal(),
        "the fallback doctrine is legal")
      check("unavailable" in outcomes[seat].detail, "detail keeps the body")
    for body in records[1].bodies:
      check(RetryHint notin body, "no invalid-reply hint after a 503")
    let gap = records[1].opened - records[0].closed
    check(gap >= 0.9, "a junk retry-after falls back to the default " &
      "backoff (waited " & $gap & "s)")
    check(gap < 1.8, "clamped so the 6 s retry still fits an 8 s turn")
    check(elapsed < client.turnBudgetSeconds,
      "the turn stays inside the outer budget (took " & $elapsed & "s)")
    report("a 503 is reported as provider_error with a clamped backoff")

  block refusalIsNotAParseError:
    records.setLen(0)
    let client = enabledClient()
    client.sendBatch = fakeRefusal
    var match = newSim(testConfig(240, 5), meadow)
    var memory: array[Colonies, BaselineMemory]
    var scripted: array[Colonies, ScriptKind]
    let outcomes = client.decideAll(match, promptsAll("go"), scripted, memory, 0)
    checkEqual(records.len, 2, "a refusal is retried exactly once")
    for seat in 0 ..< Colonies:
      checkEqual(outcomes[seat].cause, "refusal", "the cause is refusal")
      checkEqual($outcomes[seat].resolved.source, "fallback", "it fell back")
      check(outcomes[seat].resolved.doctrine.isLegal(),
        "the fallback doctrine is legal")
    for body in records[1].bodies:
      check(RetryHint notin body, "a refusal is not an invalid reply")
    check(records[1].opened - records[0].closed < 0.9,
      "a refusal is retried without a backoff")
    report("a refusal is reported as refusal")

  block classifyTable:
    ## Every string `textOf` raises, mapped the way #4 asks.
    let table = [
      ("llm throttled (429): {\"message\": \"sidecar request rate limit " &
        "reached (30 requests/minute)\", \"__type\": \"ThrottlingException\"}",
        "throttled"),
      ("llm throttled (429): {\"message\":\"Too many tokens per day, please " &
        "wait before trying again.\"}", "throttled"),
      ("anthropic error 503: {\"message\":\"LLM provider is unavailable\"}",
        "provider_error"),
      ("anthropic error 500: {\"type\":\"api_error\"}", "provider_error"),
      ("anthropic error 529: overloaded", "provider_error"),
      ("bedrock model rejected (403): {\"message\":\"You don't have access " &
        "to the model with the specified model ID.\"}", "provider_error"),
      ("anthropic refusal", "refusal"),
      ("llm auth failed (401) at https://api.anthropic.com/v1/messages: " &
        "{\"type\":\"authentication_error\"}", "no_credentials"),
      ("llm auth failed (403) at http://127.0.0.1:9100/model/x/invoke: denied",
        "no_credentials"),
      ("llm transport: Could not resolve host: api.anthropic.com",
        "transport_error"),
      ("llm transport: Failed to connect to 127.0.0.1 port 9100",
        "transport_error"),
      ("llm transport: Operation timed out after 14000 milliseconds",
        "timeout"),
      ("reply cut off at max_tokens before any JSON: Let me think about",
        "parse_error"),
      ("no doctrine object in reply", "parse_error"),
    ]
    for (message, expected) in table:
      checkEqual(classify(message), expected, "classify(" & message & ")")
    checkEqual(FallbackCauses.len, 8, "eight causes")
    checkEqual(@FallbackCauses, @["timeout", "parse_error", "transport_error",
      "no_credentials", "budget_guard", "throttled", "refusal",
      "provider_error"], "in append-only key order")
    for cause in FallbackCauses:
      checkEqual(FallbackCauses[causeIndex(cause)], cause,
        cause & " indexes its own counter")
    checkEqual(causeIndex("something new"), 1,
      "an unknown cause still counts as parse_error")
    var counts: array[Colonies, array[8, int]]
    counts[2][causeIndex("throttled")] = 3
    counts[2][causeIndex("provider_error")] = 1
    let histogram = fallbackCauseJson(counts, 2)
    checkEqual(histogram.len, 8, "the histogram carries all eight keys")
    checkEqual(histogram["throttled"].getInt(), 3, "throttled counted")
    checkEqual(histogram["provider_error"].getInt(), 1,
      "provider_error counted")
    checkEqual(histogram["parse_error"].getInt(), 0, "and parse_error is not")
    ## The backoff clamp: retry-after wins when usable, else 2 s, never more
    ## than 4 s, and never past what leaves the 6 s retry inside the turn.
    checkEqual(retryBackoffSeconds(-1, 22.0), 2.0, "no header: 2 s")
    checkEqual(retryBackoffSeconds(1, 22.0), 1.0, "a short retry-after wins")
    checkEqual(retryBackoffSeconds(30, 22.0), 4.0,
      "a long one is capped at 4 s")
    checkEqual(retryBackoffSeconds(-1, 8.0), 1.0,
      "clamped so RetryAttemptSeconds + 1 s still fits")
    checkEqual(retryBackoffSeconds(3, 6.0), 0.0, "never negative")
    report("classify maps every raised string to the documented cause")

  block hungClientIsBounded:
    records.setLen(0)
    let client = enabledClient()
    client.sendBatch = fakeHung
    var match = newSim(testConfig(240, 5), meadow)
    var memory: array[Colonies, BaselineMemory]
    var scripted: array[Colonies, ScriptKind]
    let started = epochTime()
    let outcomes = client.decideAll(match, promptsAll("go"), scripted, memory, 0)
    let elapsed = epochTime() - started
    check(elapsed < 5.0,
      "a hung client cannot outrun the per-turn budget (took " &
      $elapsed.int & "s)")
    for seat in 0 ..< Colonies:
      checkEqual(outcomes[seat].cause, "timeout", "the cause is timeout")
      checkEqual($outcomes[seat].resolved.source, "fallback", "it fell back")
    report("a hung client is bounded by the two attempt deadlines")

  block outerPerTurnDeadline:
    ## "one outer per-turn deadline of 22.0 s". The two attempt deadlines
    ## bound the turn at 14 + 6 only while the transport honours them; the
    ## outer deadline holds even when it does not.
    checkEqual(DefaultTurnBudgetSeconds, 22.0, "the default outer budget")
    checkEqual(newLlmClient().turnBudgetSeconds, DefaultTurnBudgetSeconds,
      "a client carries it unless the server overrides it")
    records.setLen(0)
    let client = enabledClient()
    client.turnBudgetSeconds = 1.0
    check(client.turnBudgetSeconds < FirstAttemptSeconds.float,
      "the fixture's outer budget really is tighter than the first attempt")
    client.sendBatch = fakeIgnoresItsDeadline
    var match = newSim(testConfig(240, 5), meadow)
    var memory: array[Colonies, BaselineMemory]
    var scripted: array[Colonies, ScriptKind]
    let started = epochTime()
    let outcomes = client.decideAll(match, promptsAll("go"), scripted, memory, 0)
    let elapsed = epochTime() - started
    checkEqual(records.len, 1,
      "the retry is never started once the outer deadline is spent")
    check(elapsed < 3.0,
      "the turn returns inside its own budget (took " & $elapsed & "s)")
    for seat in 0 ..< Colonies:
      checkEqual($outcomes[seat].resolved.source, "fallback",
        "every seat lands on the scripted fallback")
      checkEqual(outcomes[seat].cause, "timeout", "with cause timeout")
      check(outcomes[seat].resolved.doctrine.isLegal(),
        "and the fallback doctrine is legal")
    report("an outer per-turn deadline bounds the turn on its own")

  block bedrockLadderAdvancesOn403:
    ## "on a 403 the client advances to the next candidate". Three candidates
    ## are shipped, so two decideAll calls (two attempts each) walk the whole
    ## ladder; only when the last one has answered 403 is the client disabled.
    putEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME", "http://127.0.0.1:9/bedrock")
    putEnv("AWS_BEARER_TOKEN_BEDROCK", "test-token")
    delEnv("BEDROCK_MODEL")
    let client = newLlmClient()
    delEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME")
    delEnv("AWS_BEARER_TOKEN_BEDROCK")
    check(not client.disabled, "a bedrock client starts enabled")
    client.sendBatch = fakeForbidden
    records.setLen(0)
    var match = newSim(testConfig(240, 5), meadow)
    var memory: array[Colonies, BaselineMemory]
    var scripted: array[Colonies, ScriptKind]
    ## Three candidates; each decideAll issues two batches and each batch is
    ## one verdict on one candidate, so the first call steps off haiku and
    ## sonnet-4-6 without disabling anything.
    let first = client.decideAll(match, promptsAll("go"), scripted, memory, 0)
    check(not client.disabled,
      "a 403 walks the bedrock ladder instead of writing the client off")
    checkEqual(records.len, 2,
      "four simultaneous 403s are ONE verdict on ONE candidate, so the " &
      "three-rung ladder is not exhausted by a single batch")
    for seat in 0 ..< Colonies:
      checkEqual($first[seat].resolved.source, "fallback",
        "the turn still falls back so no colony is unactuated")
    let second = client.decideAll(match, promptsAll("go"), scripted, memory, 1)
    check(client.disabled,
      "only when the LAST candidate 403s is the client disabled")
    for seat in 0 ..< Colonies:
      check(second[seat].resolved.doctrine.isLegal(),
        "and every seat still gets a legal doctrine")
    report("a 403 advances the bedrock candidate, whatever the body says")

  block budgetGuardSettlesEarly:
    ## Once the guard engages the whole remaining match runs on the scripted
    ## layer, so the episode ends complete/full_time rather than deadline.
    var match = newSim(testConfig(960, 42), meadow)
    var memory: array[Colonies, BaselineMemory]
    var guardEngaged = false
    var guardTurn = -1
    let provide = proc (m: Sim, turn: int):
        array[Colonies, ResolvedDoctrine] {.closure.} =
      if not guardEngaged and turn >= 1:
        guardEngaged = true
        guardTurn = turn
        m.events.add(budgetGuard(m.tick, turn, 12.0))
      for seat in 0 ..< Colonies:
        result[seat] = scriptedResolved(buildView(m, seat), skMarcher, turn,
          memory[seat], (if guardEngaged: dsFallback else: dsScripted))
    match.runEpisode(provide)
    checkEqual($match.reason, "complete", "the guarded episode still completes")
    checkEqual($match.rule, "full_time", "on full time")
    checkEqual(guardTurn, 1, "the guard engaged at the turn it was asked to")
    checkEqual(match.events.countOf("budget_guard"), 1,
      "one budget_guard event records the turn it engaged")
    report("the budget guard settles early and the episode still completes")

  block wallClockStop:
    var match = newSim(testConfig(4800, 42), meadow)
    let probe = proc (m: Sim, turn: int): bool {.closure.} = m.tick >= 500
    match.runEpisode(scriptedProvider(allMarcher()), probe)
    checkEqual($match.reason, "deadline", "the wall-clock stop ends deadline")
    checkEqual($match.rule, "wall_clock", "with end_rule wall_clock")
    check(match.tick < 4800, "and it stopped short")
    var total = 0.0
    for value in match.scores():
      total += value
    checkEqual(total, 1.0, "a deadline still sums to exactly 1.0")
    report("the wall-clock stop yields deadline/wall_clock")

  block simFault:
    ## A raised invariant: corrupt a pheromone cell past the cap. Decay pulls
    ## it down slowly, so it is still illegal at the next 24-tick guard.
    var match = newSim(testConfig(960, 42), meadow)
    let provide = scriptedProvider(allMarcher())
    let sabotage = proc (m: Sim, turn: int):
        array[Colonies, ResolvedDoctrine] {.closure.} =
      if turn == 2:
        m.planes.cells[0][0][0] = 65535'u16
      provide(m, turn)
    match.runEpisode(sabotage)
    checkEqual($match.reason, "fault", "an invariant trip ends fault")
    checkEqual($match.rule, "sim_fault", "with end_rule sim_fault")
    checkEqual(match.faultDetail, "pheromone above cap",
      "the fault names what tripped")
    check(match.tick < 960, "the fault stopped the match short")

    ## And the other guards fire too.
    var offField = newSim(testConfig(240, 1), meadow)
    offField.antState[0].cx = int32(meadow.cols + 3)
    check(not offField.invariantsOk(), "an off-field ant trips the guard")
    checkEqual(offField.faultDetail, "ant off field", "named")
    var onRock = newSim(testConfig(240, 1), meadow)
    block findRock:
      for cy in 0 ..< meadow.rows:
        for cx in 0 ..< meadow.cols:
          if meadow.isRock(cx, cy):
            onRock.antState[0].cx = int32(cx)
            onRock.antState[0].cy = int32(cy)
            break findRock
    check(not onRock.invariantsOk(), "an ant on rock trips the guard")
    checkEqual(onRock.faultDetail, "ant on rock", "named")
    var negative = newSim(testConfig(240, 1), meadow)
    discard negative.sources.addSource(meadow, 60, 30, 1, 0, 100, false)
    negative.sources.items[0].amount = -1'i32
    check(not negative.invariantsOk(), "a negative source amount trips")
    checkEqual(negative.faultDetail, "source amount below zero", "named")
    var turnsLlm, fallbackTurns: array[Colonies, int]
    var causes: array[Colonies, array[8, int]]
    let results = resultsJson(match, @["a", "b", "c", "d"],
      @["llm", "llm", "scripted", "scripted"], turnsLlm, fallbackTurns, causes)
    for seat in 0 ..< Colonies:
      checkEqual(results["scores"][seat].getFloat(), 0.25,
        "a fault scores 0.25 for every seat")
    let partial = buildReplay(match, @["a", "b", "c", "d"],
      @["llm", "llm", "scripted", "scripted"], results)
    check(partial["keyframes"].len > 0, "a partial replay is still written")
    checkEqual(partial["results"]["reason"].getStr(), "fault",
      "and it carries the fault")
    discard parseReplayBytes($partial)
    report("a sim fault scores 0.25 everywhere and still writes a replay")

  block unregisteredSeatPlaysMarcher:
    var seats = initRoster(@["t0", "t1", "t2", "t3"])
    for seat in 0 ..< Colonies:
      checkEqual(seats.seats[seat].scripted, skMarcher,
        "a seat that never registers defaults to the marcher")
      checkEqual(seats.seats[seat].policyKind(), "scripted",
        "and is reported as scripted")
      check(not seats.seats[seat].everConnected, "and never connected")
    seats.register(0, "", "", "")
    checkEqual(seats.seats[0].scripted, skMarcher,
      "registering with neither field is also the marcher")
    seats.register(1, "raid the centre", "", "my-policy")
    checkEqual(seats.seats[1].scripted, skNone, "a prompt makes it an LLM seat")
    checkEqual(seats.seats[1].policyKind(), "llm", "reported as llm")
    seats.register(2, "", "driftling", "")
    checkEqual(seats.seats[2].scripted, skDriftling, "PLAYER_SCRIPTED wins")
    report("an unregistered seat plays the marcher for the whole match")

  block disconnectDegradesAndRevives:
    var seats = initRoster(@["t0", "t1", "t2", "t3"])
    seats.register(0, "raid the centre", "", "")
    checkEqual(seats.authorize(0, "t0"), jeNone, "a good token is accepted")
    seats.seats[0].connected = true
    checkEqual(seats.authorize(0, "t0"), jeDuplicate,
      "a duplicate connection is refused")
    checkEqual(seats.authorize(0, "wrong"), jeBadToken, "a bad token is refused")
    checkEqual(seats.authorize(9, "t0"), jeBadSlot, "a bad slot is refused")
    ## The server's rule: a disconnected seat degrades to the marcher.
    proc effective(seat: Seat): ScriptKind =
      if seat.connected: seat.scripted else: skMarcher
    checkEqual(effective(seats.seats[0]), skNone, "connected: the LLM plays")
    seats.seats[0].connected = false
    checkEqual(effective(seats.seats[0]), skMarcher,
      "disconnected: the doctrine source degrades to the marcher")
    seats.seats[0].connected = true
    checkEqual(effective(seats.seats[0]), skNone, "and revives on reconnect")
    checkEqual(seats.seats[0].prompt, "raid the centre",
      "the prompt survives the disconnect")
    report("a mid-match disconnect degrades to the marcher and revives")

  block policyRuneCap:
    var seats = initRoster(@["t0", "t1", "t2", "t3"])
    seats.register(0, "p", "", repeat("\u{1F41C}", 80))
    checkEqual(seats.seats[0].policyLabel.runeLen, MaxPolicyRunes,
      "register.policy caps at 48 RUNES")
    checkEqual(validateUtf8(seats.seats[0].policyLabel), -1,
      "and the cut lands on a rune boundary")
    var longPrompt = repeat("\u{1F41C}", 5000)
    seats.register(1, longPrompt, "", "")
    checkEqual(seats.seats[1].prompt.runeLen, MaxPromptRunes,
      "register.prompt is truncated at 4000 runes, not rejected")
    checkEqual(validateUtf8(seats.seats[1].prompt), -1,
      "and stays valid UTF-8")
    report("every recorded string is capped on rune boundaries")

main()
echo "test_engine: all checks passed"
