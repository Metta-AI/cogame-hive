## Source-native reconstruction of actual native captures; fixture IDs are not receipts.
import std/[json, os, strutils, tables]
import hive/[types, config, field, sim, rules, replay, broadcast, doctrine, llm, prompts, training_capture]

if paramCount() != 3:
  quit("usage: check_native_capture CONFIG TRAJECTORY REPLAY", 2)
let configText = readFile(paramStr(1))
var cfg = defaultGameConfig()
cfg.update(configText)
let original = parseJson(readFile(paramStr(3)))
let selection = promptSelection(parseJson(configText))
var rows = initTable[string, JsonNode]()
for line in lines(paramStr(2)):
  let row = parseJson(line)
  if row{"event_type"}.getStr() == "decision": rows[row["decision_id"].getStr()] = row
var checked, requests: int
var match = newSim(cfg, ensureField(cfg.fieldPath), true)
let provide = proc (state: Sim, turn: int): array[Colonies, ResolvedDoctrine] =
  for seat in 0 ..< Colonies:
    if turn > 0:
      let previous = rows["turn-" & $(turn - 1) & "-seat-" & $seat]
      doAssert previous["observation"]["native_execution"]["observed_actor_view_sha256_after_turn"].getStr() == nativeStateHash(state, seat)
    let key = "turn-" & $turn & "-seat-" & $seat
    doAssert rows.hasKey(key), key
    let row = rows[key]
    let view = buildView(state, seat)
    doAssert row["observation"]["pre_native_sha256"].getStr() == nativeStateHash(state, seat)
    for k, value in view:
      doAssert row["observation"][k] == value, key & " view " & k
    for rival in 0 ..< Colonies:
      if rival != seat:
        doAssert not ($row["observation"]).contains("private-note-seat-" & $rival)
    let installed = original["doctrines"][turn * Colonies + seat]
    var action = copy(installed)
    for k in ["turn", "seat", "source", "latency_ms"]: action.delete(k)
    if row["executed_action"].kind != JNull:
      doAssert row["executed_action"] == action, key & " applied doctrine"
    else:
      doAssert row["action_status"].getStr() in ["rejected", "fallback"]
    doAssert row["observation"]["native_execution"]["installed_doctrine_record"] == installed
    for attempt in row["attempts"]:
      let request = attempt["request"]
      if request.kind == JObject:
        doAssert request["system"].getStr() == selection.systemPrompt()
        let expected = userMessage(state, seat, "native fixture only")
        let user = request["messages"][0]["content"].getStr()
        let hint = "\n\nYour previous reply was invalid. Respond with ONLY the " &
          "requested JSON object, beginning with '{' and containing the " &
          "integer keys scouts, trail_gain, poach, spread, lay_food, " &
          "lay_home, focus_weight and the keys recall, focus, note, say."
        doAssert user == expected or user == expected & hint, key & " actual prompt"
        inc requests
    result[seat] = ResolvedDoctrine(doctrine: fromJson(installed),
      source: parseEnum[DoctrineSource](installed["source"].getStr()),
      latencyMs: installed["latency_ms"].getInt())
    inc checked
match.runEpisode(provide)
for seat in 0 ..< Colonies:
  let last = rows["turn-" & $(cfg.episodeTicks div cfg.turnTicks - 1) & "-seat-" & $seat]
  doAssert last["observation"]["native_execution"]["observed_actor_view_sha256_after_turn"].getStr() == nativeStateHash(match, seat)
var names, kinds: seq[string]
for name in original["names"]["players"]: names.add(name.getStr())
for kind in original["names"]["policy_kinds"]: kinds.add(kind.getStr())
let rebuilt = buildReplay(match, names, kinds, original["results"])
for key in ["keyframes", "ants_b64", "doctrines", "field", "seat_nests", "tick_count"]:
  doAssert rebuilt[key] == original[key], "native replay " & key
for seat in 0 ..< Colonies:
  doAssert match.delivered[match.seatNest[seat]] == original["results"]["delivered"][seat].getInt()
  doAssert match.scores()[seat] == original["results"]["scores"][seat].getFloat()
doAssert match.reason == erComplete
echo $(%*{"status": "PASS", "private_views": checked, "actual_requests": requests,
  "all_keyframes_antframes_applied_doctrines_native_scores": true,
  "event_failure_counters": "not independently reconstructed", "authenticated_teachers": 0})
