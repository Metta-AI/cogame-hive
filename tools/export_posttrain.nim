## Export complete Hive matches as Metta post-training examples.
## nim r --path:src tools/export_posttrain.nim OUTPUT GAMES [FIRST_SEED] [VARIANT]

import std/[json, os, osproc, strutils]
import hive/[baselines, broadcast, config, doctrine, field, llm, rules, types]

const OperatorPrompt = "Choose a doctrine that maximizes your colony's share of food over the complete match."
const Variants = ["default", "sprint"]

when isMainModule:
  let args = commandLineParams()
  if args.len notin 2 .. 4:
    quit("usage: export_posttrain OUTPUT GAMES [FIRST_SEED] [VARIANT]", 1)
  let output = args[0]
  let games = parseInt(args[1])
  let firstSeed = if args.len >= 3: parseInt(args[2]) else: 1
  let variant = if args.len == 4: args[3] else: Variants[0]
  if games < 10 or firstSeed < 1:
    quit("at least ten games and a positive first seed are required", 1)
  if variant notin Variants:
    quit("unknown variant: " & variant, 1)
  if dirExists(output) or fileExists(output):
    quit("output already exists: " & output, 1)
  createDir(output)
  let sourceRevision = execProcess("git rev-parse HEAD").strip()
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig: JsonNode
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = entry["game_config"]
  doAssert not variantConfig.isNil
  var trainRows, validationRows: seq[string]
  var runs = newJArray()
  for seed in firstSeed ..< firstSeed + games:
    var config = defaultGameConfig()
    let runtimeConfig = copy(variantConfig)
    runtimeConfig["tokens"] = %*["t0", "t1", "t2", "t3"]
    runtimeConfig["seed"] = %seed
    config.update($runtimeConfig)
    let match = newSim(config, loadField(config.fieldPath))
    var memory: array[Colonies, BaselineMemory]
    var rows: seq[string]
    let provide = proc (sim: Sim, turn: int): array[Colonies, ResolvedDoctrine] =
      for seat in 0 ..< Colonies:
        let view = buildView(sim, seat)
        let teacher = scriptedDoctrine(view, skMarcher, turn, memory[seat])
        let completion = teacher.toJson()
        let colony = sim.nestOfSeat(seat)
        let parsed = parseDoctrine($completion, sim.doctrines[colony],
          sim.hasDoctrine[colony])
        doAssert parsed == teacher
        rows.add($(%*{
          "episode_id": "hive-" & variant & "-" & $seed,
          "seed": "hive-" & variant & "-" & $seed,
          "decision_id": rows.len,
          "prompt": [
            {"role": "system", "content": SystemPrompt},
            {"role": "user", "content": userMessage(sim, seat,
              OperatorPrompt)}
          ],
          "completion": [{"role": "assistant", "content": $completion}],
          "game": "hive",
          "action_schema_revision": "hive-doctrine-v1"
        }))
        result[seat] = ResolvedDoctrine(doctrine: parsed,
          source: dsScripted, latencyMs: 0)
    match.runEpisode(provide)
    doAssert match.reason == erComplete and rows.len > 0
    let scored = match.scores()
    if seed mod 5 == 0:
      validationRows.add(rows)
    else:
      trainRows.add(rows)
    runs.add(%*{"seed": seed, "decisions": rows.len,
      "scores": scored, "ticks": match.tick})
  writeFile(output / "train.jsonl", trainRows.join("\n") & "\n")
  writeFile(output / "validation.jsonl", validationRows.join("\n") & "\n")
  writeFile(output / "manifest.json", pretty(%*{
    "schema_version": 1,
    "game": "hive",
    "variant": variant,
    "source_revision": sourceRevision,
    "teacher": "scripted-marcher",
    "operator_prompt": OperatorPrompt,
    "train_examples": trainRows.len,
    "validation_examples": validationRows.len,
    "runs": runs
  }) & "\n")
  echo "train=", trainRows.len, " validation=", validationRows.len
