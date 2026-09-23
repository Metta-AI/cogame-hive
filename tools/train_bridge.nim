## Persistent numeric bridge for Metta RL and native PufferLib.
## nim c -d:release --path:src -o:hive-train-bridge tools/train_bridge.nim

import std/[json, os]
import hive/[baselines, broadcast, config, doctrine, field, llm, rules, types]

const
  OperatorPrompt = "Choose a doctrine that maximizes your colony's share of food over the complete match."
  Variants = ["default", "sprint"]
  PercentFields = ["scouts", "trail_gain", "poach", "spread", "lay_food", "lay_home"]

proc seedOf(value: string): int =
  var hash = 2166136261'u32
  for ch in value:
    hash = (hash xor uint32(ord(ch))) * 16777619'u32
  int(hash and 0x7fffffff'u32)

proc options(width: int): JsonNode =
  result = newJArray()
  for value in 0 ..< width:
    result.add(%value)

proc heads(): JsonNode =
  result = newJArray()
  for field in PercentFields:
    result.add(%*{"name": field, "choices": options(101)})
  result.add(%*{"name": "recall", "choices": [false, true]})
  result.add(%*{"name": "focus_x", "choices": options(BlockCols)})
  result.add(%*{"name": "focus_y", "choices": options(BlockRows)})
  result.add(%*{"name": "focus_weight", "choices": options(101)})

proc action(doctrine: Doctrine): JsonNode =
  %*{
    "scouts": doctrine.scouts, "trail_gain": doctrine.trailGain,
    "poach": doctrine.poach, "spread": doctrine.spread,
    "lay_food": doctrine.layFood, "lay_home": doctrine.layHome,
    "recall": doctrine.recall,
    "focus_x": (if doctrine.hasFocus: doctrine.focusBx else: 0),
    "focus_y": (if doctrine.hasFocus: doctrine.focusBy else: 0),
    "focus_weight": doctrine.focusWeight
  }

proc hostedAction(chosen: JsonNode): JsonNode =
  result = %*{"note": "", "say": ""}
  for field in PercentFields:
    result[field] = chosen[field]
  result["recall"] = chosen["recall"]
  let weight = chosen["focus_weight"].getInt()
  result["focus_weight"] = %weight
  result["focus"] = if weight == 0: newJNull()
    else: %[chosen["focus_x"].getInt(), chosen["focus_y"].getInt()]

proc decision(game: Sim, seat, id: int): JsonNode =
  let view = buildView(game, seat)
  let catalog = heads()
  var fields = newJObject()
  for head in catalog:
    fields[head["name"].getStr()] = %*{"enum": head["choices"]}
  %*{
    "kind": "decision", "game": "hive", "decision_id": id,
    "seat": seat, "engine_seat": seat, "turn": game.turn,
    "semantic_view": view,
    "inbox": [],
    "messages": [
      {"role": "system", "content": SystemPrompt},
      {"role": "user", "content": userMessage(game, seat, OperatorPrompt)}
    ],
    "speech_messages": [],
    "action_schema": {"type": "object", "properties": fields,
      "required": ["scouts", "trail_gain", "poach", "spread",
        "lay_food", "lay_home", "recall", "focus_x", "focus_y",
        "focus_weight"]},
    "typed_question": newJNull()
  }

proc gridValue(ch: char): int =
  if ch == '.': -1
  elif ch == '#': 1
  else: ord(ch) - ord('0')

proc encoding(game: Sim, seat, id: int, variant: string): JsonNode =
  let view = buildView(game, seat)
  let you = view["you"]
  var values = newJArray()
  for name in Variants:
    values.add(%(if name == variant: 1 else: 0))
  for value in [seat, view["turn"].getInt(), view["of"].getInt(),
      view["tick"].getInt(), view["ticks_left"].getInt(),
      view["sources_live_total"].getInt(),
      you["nest_block"][0].getInt(), you["nest_block"][1].getInt(),
      you["ants"].getInt(), you["carrying"].getInt(),
      you["scouts"].getInt(), you["at_nest"].getInt(),
      you["delivered"].getInt(), you["delivered_last_turn"].getInt(),
      you["mean_range_cells"].getInt()]:
    values.add(%value)
  let previous = you["last_doctrine"]
  for field in PercentFields:
    values.add(%(if previous.kind == JObject: previous[field].getInt() else: 0))
  values.add(%(if previous.kind == JObject and previous["recall"].getBool(): 1 else: 0))
  values.add(%(if previous.kind == JObject and previous["focus"].kind == JArray:
    previous["focus"][0].getInt() + 1 else: 0))
  values.add(%(if previous.kind == JObject and previous["focus"].kind == JArray:
    previous["focus"][1].getInt() + 1 else: 0))
  values.add(%(if previous.kind == JObject: previous["focus_weight"].getInt() else: 0))
  for colony in view["scoreboard"]:
    values.add(colony["delivered"])
    values.add(%(if colony["colony"] == you["colony"]: 1 else: 0))
  for layer in [view["field"]["rock"], view["trails"]["food"],
      view["trails"]["home"], view["trails"]["rival"]]:
    doAssert layer.len == BlockRows
    for row in layer:
      let text = row.getStr()
      doAssert text.len == BlockCols
      for ch in text:
        values.add(%gridValue(ch))
  var amount, age, contact: array[BlockCount, int]
  for source in view["sources"]:
    let index = source["block"][1].getInt() * BlockCols +
      source["block"][0].getInt()
    amount[index] = max(amount[index], source["amount_seen"].getInt())
    age[index] = max(age[index], source["seen_turn"].getInt() + 1)
  for rival in view["contacts"]:
    for position in rival["blocks"]:
      let index = position[1].getInt() * BlockCols + position[0].getInt()
      contact[index] += rival["ants"].getInt()
  for index in 0 ..< BlockCount:
    for value in [amount[index], age[index], contact[index]]:
      values.add(%value)
  %*{"decision_id": id, "values": values, "action_heads": heads()}

when isMainModule:
  let args = commandLineParams()
  if args.len notin 1 .. 2:
    quit("usage: hive-train-bridge MANIFEST [variant]", 1)
  let variant = if args.len == 2: args[1] else: Variants[0]
  let manifest = parseFile(args[0])
  var variantConfig: JsonNode
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = entry["game_config"]
  doAssert not variantConfig.isNil, "unknown variant: " & variant
  var game: Sim
  var memory: array[Colonies, BaselineMemory]
  var teacher: array[Colonies, Doctrine]
  var batch: array[Colonies, ResolvedDoctrine]
  var seat = 0
  var id = 0
  while not stdin.endOfFile:
    let request = parseJson(stdin.readLine())
    var response: JsonNode
    case request["kind"].getStr()
    of "reset":
      doAssert request["players"].getInt() == Colonies
      var config = defaultGameConfig()
      let runtimeConfig = copy(variantConfig)
      runtimeConfig["tokens"] = %*["t0", "t1", "t2", "t3"]
      runtimeConfig["seed"] = %seedOf(request["seed"].getStr())
      config.update($runtimeConfig)
      game = newSim(config, loadField(config.fieldPath))
      game.beginTurn()
      memory = default(array[Colonies, BaselineMemory])
      for other in 0 ..< Colonies:
        teacher[other] = scriptedDoctrine(buildView(game, other),
          skMarcher, game.turn, memory[other])
      seat = 0
      id = 0
      response = game.decision(seat, id)
    of "encode":
      doAssert not game.finished
      response = game.encoding(seat, id, variant)
    of "teacher":
      doAssert not game.finished
      response = %*{"response": $action(teacher[seat])}
    of "step":
      doAssert not game.finished and request["decision_id"].getInt() == id
      let chosen = parseJson(request["response"].getStr())
      for head in heads():
        let name = head["name"].getStr()
        doAssert chosen[name] in head["choices"], "action is masked: " & name
      let colony = game.nestOfSeat(seat)
      let parsed = parseDoctrine($hostedAction(chosen),
        game.doctrines[colony], game.hasDoctrine[colony])
      doAssert parsed.isLegal()
      batch[seat] = ResolvedDoctrine(doctrine: parsed,
        source: dsScripted, latencyMs: 0)
      inc seat
      if seat == Colonies:
        game.installDoctrines(batch)
        while not game.finished:
          game.stepTick()
          if game.tick >= game.config.episodeTicks:
            game.endMatch(erComplete, euFullTime)
            break
          if game.tick mod KeyframePeriod == 0 and not game.invariantsOk():
            game.endMatch(erFault, euSimFault)
            break
          if game.tick mod game.config.turnTicks == 0:
            game.beginTurn()
            break
        if not game.finished:
          for other in 0 ..< Colonies:
            teacher[other] = scriptedDoctrine(buildView(game, other),
              skMarcher, game.turn, memory[other])
        seat = 0
      inc id
      var observation: JsonNode
      if game.finished:
        var scores = newJObject()
        let scored = game.scores()
        for other in 0 ..< Colonies:
          scores[$other] = %scored[other]
        observation = %*{"kind": "terminal", "scores": scores}
      else:
        observation = game.decision(seat, id)
      response = %*{"kind": "accepted", "action": chosen,
        "observation": observation}
    else:
      raise newException(ValueError, "unknown command: " & request["kind"].getStr())
    stdout.writeLine($response)
    stdout.flushFile()
