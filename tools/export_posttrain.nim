## Export complete Hive matches as Metta post-training examples.
## nim r --path:src tools/export_posttrain.nim OUTPUT GAMES [FIRST_SEED] [VARIANT]

import std/[json, os, osproc, strutils]
import hive/[baselines, broadcast, config, doctrine, field, llm, rules, types, prompts, evidence, replay]

const OperatorPrompt = "Choose a doctrine that maximizes your colony's share of food over the complete match."
const Variants = ["default", "sprint"]

when isMainModule:
  let args = commandLineParams()
  if args.len notin [2, 3, 4, 6]:
    quit("usage: export_posttrain OUTPUT GAMES [FIRST_SEED] [VARIANT] [PROMPT_VARIANT PROMPT_SEED]", 1)
  let output = args[0]
  let games = parseInt(args[1])
  let firstSeed = if args.len >= 3: parseInt(args[2]) else: 1
  let variant = if args.len >= 4: args[3] else: Variants[0]
  let selection = promptSelection(if args.len == 6:
    %*{"promptVariant": args[4], "promptSeed": parseInt(args[5])} else: newJObject())
  doAssert selection.selectedVariant notin {pvHeldoutBriefing, pvHeldoutReference},
    "held-out wording is evaluation only"
  let status = execCmdEx("git status --porcelain")
  doAssert status.exitCode == 0 and status.output.strip().len == 0,
    "Commit qualified source before exporting pinned candidates"
  if games < 10 or firstSeed < 1:
    quit("at least ten games and a positive first seed are required", 1)
  if variant notin Variants:
    quit("unknown variant: " & variant, 1)
  if dirExists(output) or fileExists(output):
    quit("output already exists: " & output, 1)
  writePrivate(output / "trajectories.jsonl", "")
  let sourceRevision = execProcess("git rev-parse HEAD").strip()
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig: JsonNode
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = entry["game_config"]
  doAssert not variantConfig.isNil
  var records: seq[string]
  var runs = newJArray()
  for seed in firstSeed ..< firstSeed + games:
    var config = defaultGameConfig()
    let runtimeConfig = copy(variantConfig)
    runtimeConfig["tokens"] = %*["t0", "t1", "t2", "t3"]
    runtimeConfig["seed"] = %seed
    config.update($runtimeConfig)
    let match = newSim(config, loadField(config.fieldPath))
    var memory: array[Colonies, BaselineMemory]
    let family = "hive-" & $seed
    let episode = family & "-" & variant & "-" & $selection.selectedVariant
    var rows: seq[JsonNode]
    let provide = proc (sim: Sim, turn: int): array[Colonies, ResolvedDoctrine] =
      for seat in 0 ..< Colonies:
        let view = buildView(sim, seat)
        let teacher = scriptedDoctrine(view, skMarcher, turn, memory[seat])
        let completion = teacher.toJson()
        let colony = sim.nestOfSeat(seat)
        let parsed = parseDoctrine($completion, sim.doctrines[colony],
          sim.hasDoctrine[colony])
        doAssert parsed == teacher
        let system = selection.systemPrompt()
        let user = userMessage(sim, seat, OperatorPrompt)
        let messages = %*[{"role": "system", "content": system}, {"role": "user", "content": user}]
        let attemptId = $rows.len & "-teacher"
        rows.add(%*{"schema_version": "1", "event_type": "decision",
          "episode_id": episode, "decision_id": $rows.len, "decision_index": rows.len,
          "game": "hive", "game_version": "source-" & sourceRevision,
          "source_revision": sourceRevision, "seat": $seat, "visibility": "private",
          "observation": {"view": view, "prompt_template": selection.promptMetadata(system, user)},
          "prompt": messages, "attempts": [{"attempt_id": attemptId,
            "policy": "scripted-marcher", "origin": "teacher", "inference_mode": "text_action",
            "prompt": messages, "response": $completion, "parsed_action": parsed.toJson(),
            "accepted": true, "rejection_reason": newJNull(), "request": newJNull(),
            "platform_call_id": newJNull(), "behavior_logprobs": newJNull()}],
          "selected_attempt_id": attemptId, "executed_action": newJNull(),
          "action_status": "accepted", "fallback_origin": newJNull(), "terminal": false})
        result[seat] = ResolvedDoctrine(doctrine: parsed,
          source: dsScripted, latencyMs: 0)
    match.runEpisode(provide)
    doAssert match.reason == erComplete and rows.len > 0
    doAssert rows.len == match.doctrineLog.len
    for index, installed in match.doctrineLog:
      let actual = copy(installed)
      for key in ["turn", "seat", "source", "latency_ms"]: actual.delete(key)
      doAssert actual == rows[index]["attempts"][0]["parsed_action"]
      doAssert installed["seat"].getInt() == parseInt(rows[index]["seat"].getStr())
      rows[index]["executed_action"] = actual
      rows[index]["observation"]["applied_doctrine"] = installed
      rows[index]["terminal"] = %(index == rows.high)
      records.add($rows[index])
    let names = @["teacher-0", "teacher-1", "teacher-2", "teacher-3"]
    let kinds = @["scripted", "scripted", "scripted", "scripted"]
    let outcome = resultsJson(match, names, kinds, default(array[Colonies, int]),
      default(array[Colonies, int]), default(array[Colonies, array[8, int]]))
    var participants = newJObject()
    for seat in 0 ..< Colonies: participants[$seat] = %*{"score": outcome["scores"][seat]}
    records.add($(%*{"schema_version": "1", "event_type": "episode", "episode_id": episode,
      "seed_family": family, "game": "hive", "game_version": "source-" & sourceRevision,
      "source_revision": sourceRevision, "status": "completed", "outcome": outcome,
      "participant_outcomes": participants}))
    writePrivate(output / (episode & ".replay.json"), $buildReplay(match, names, kinds, outcome))
    runs.add(%*{"seed": seed, "episode_id": episode, "decisions": rows.len,
      "scores": outcome["scores"], "ticks": match.tick, "replay": episode & ".replay.json"})
  let stream = open(output / "trajectories.jsonl", fmAppend)
  try:
    stream.write(records.join("\n") & "\n")
  finally:
    stream.close()
  writePrivate(output / "manifest.json", pretty(%*{
    "schema_version": "1", "format": "coworld-private-candidates-v1", "review_required": true,
    "game": "hive", "variant": variant, "source_revision": sourceRevision,
    "teacher": "scripted-marcher", "operator_prompt": OperatorPrompt,
    "prompt_selection": selection.selectionMetadata(), "runs": runs}) & "\n")
  echo "complete games=", games
