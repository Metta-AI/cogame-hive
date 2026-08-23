## The manifest is the ladder's contract. A missing num_agents schedules zero
## episodes; URI-form docs go missing on the coworld page; an image
## placeholder that does not match the compose service name fails
## `coworld build`.

import std/[algorithm, json, strutils]
import support/helpers

proc main() =
  let manifest = parseJson(readRepoFile("coworld_manifest_template.json"))
  let game = manifest["game"]

  block seatCountEverywhere:
    checkEqual(manifest["variants"].len, 2, "two variants")
    for variant in manifest["variants"]:
      check(variant["game_config"].hasKey("num_agents"),
        "variant " & variant["id"].getStr() & " declares num_agents")
      checkEqual(variant["game_config"]["num_agents"].getInt(), Colonies,
        "variant " & variant["id"].getStr() & " seats four colonies")
      checkEqual(variant["game_config"]["players"].len, Colonies,
        "variant " & variant["id"].getStr() & " lists four players")
      checkEqual(variant["game_config"]["antsPerColony"].getInt(), 24,
        "the sprint variant never changes antsPerColony")
    let cert = manifest["certification"]
    checkEqual(cert["game_config"]["num_agents"].getInt(), Colonies,
      "the certification fixture declares num_agents")
    checkEqual(cert["players"].len, Colonies,
      "certification.players seats four")
    checkEqual(cert["game_config"]["players"].len, Colonies,
      "certification.game_config.players seats four")
    for entry in cert["players"]:
      checkEqual(entry["player_id"].getStr(), "baseline",
        "the certification fixture seats the bundled baseline")
    checkEqual(cert["game_config"]["seed"].getInt(), 42, "cert seed")
    checkEqual(cert["game_config"]["episodeTicks"].getInt(), 960, "cert ticks")
    report("num_agents is 4 in every variant and in the cert fixture")

  block budgets:
    checkEqual(game["episode_timeout_minutes"].getInt(), 20,
      "episode_timeout_minutes is 20")
    let platform = game["episode_timeout_minutes"].getInt() * 60
    for variant in manifest["variants"]:
      let budget = variant["game_config"]["wallClockBudgetSeconds"].getFloat()
      check(budget * 10 <= platform.float * 6,
        "variant " & variant["id"].getStr() &
        " settles inside 60% of episodeTimeoutSeconds (" & $budget & "s of " &
        $platform & "s)")
    check(manifest["certification"]["game_config"][
      "wallClockBudgetSeconds"].getFloat() * 10 <= platform.float * 6,
      "the cert fixture settles inside 60% too")
    report("every variant settles inside 60% of the episode timeout")

  block imagePlaceholder:
    let compose = readRepoFile("compose.yaml")
    var service = ""
    for line in compose.splitLines():
      let trimmed = line.strip()
      if trimmed.len > 0 and line.startsWith("  ") and
          not line.startsWith("    ") and trimmed.endsWith(":"):
        service = trimmed[0 ..< trimmed.high]
        break
    checkEqual(service, "hive", "the compose service is named hive")
    checkEqual(game["runnable"]["image"].getStr(),
      "{{" & service.toUpperAscii() & "_IMAGE}}",
      "the image placeholder is derived from the compose service name")
    check("image: coworld-hive:latest" in compose,
      "compose pins the image name coworld-hive:latest")
    check("platform: linux/amd64" in compose, "compose pins linux/amd64")
    check("network: host" in compose, "compose builds with network: host")
    checkEqual(game["runnable"]["run"][0].getStr(), "/bin/hive",
      "the game entrypoint")
    checkEqual(game["player"][0]["run"][0].getStr(), "/bin/hive-player",
      "the bundled player entrypoint")
    checkEqual(game["player"][0]["env"]["PLAYER_SCRIPTED"].getStr(), "marcher",
      "the certification player is the marcher, no LLM")
    checkEqual(game["player"][0]["image"].getStr(),
      game["runnable"]["image"].getStr(),
      "one image, two entrypoints")
    report("the image placeholder matches the compose service name")

  block staticViewer:
    checkEqual(game["replay_viewer"]["bundle"].getStr(),
      "static-replay-viewer",
      "the replay viewer is the static bundle, never a pod")
    report("replay_viewer.bundle is static-replay-viewer")

  block docsAndProtocols:
    check(game.hasKey("protocols"), "the manifest carries protocols")
    for key in ["player", "global"]:
      check(game["protocols"].hasKey(key),
        "game.protocols carries " & key)
      checkEqual(game["protocols"][key]["type"].getStr(), "text",
        key & " is TEXT, not a URI")
      check(game["protocols"][key]["value"].getStr().len > 400,
        key & " protocol text is substantial")
    checkEqual(game["docs"]["readme"]["type"].getStr(), "text",
      "the readme is inlined text")
    check(game["docs"]["readme"]["value"].getStr().len > 400,
      "the readme is non-empty")
    checkEqual(game["docs"]["pages"].len, 2, "two doc pages")
    var ids: seq[string]
    for page in game["docs"]["pages"]:
      ids.add(page["id"].getStr())
      check(page["title"].getStr().len > 0, "every page has a title")
      checkEqual(page["content"]["type"].getStr(), "text",
        "every page is inlined text")
      check(page["content"]["value"].getStr().len > 400,
        "every page is non-empty")
    ids.sort()
    checkEqual(ids, @["protocol.md", "rules.md"], "the two documented pages")
    report("docs and both protocols are non-empty inlined text")

  block resultsSchemaMatchesTheBuilder:
    ## The schema must equal the key set `src/hive/rules.nim` actually emits.
    var match = newSim(testConfig(240, 42), testField())
    match.runEpisode(scriptedProvider(allMarcher()))
    var turnsLlm, fallbackTurns: array[Colonies, int]
    var causes: array[Colonies, array[5, int]]
    let emitted = resultsJson(match, @["a", "b", "c", "d"],
      @["llm", "llm", "scripted", "scripted"], turnsLlm, fallbackTurns, causes)
    var emittedKeys: seq[string]
    for key, _ in emitted:
      emittedKeys.add(key)
    emittedKeys.sort()
    var schemaKeys: seq[string]
    for key, _ in game["results_schema"]["properties"]:
      schemaKeys.add(key)
    schemaKeys.sort()
    checkEqual(schemaKeys, emittedKeys,
      "results_schema keys equal the keys the results builder emits")
    var declared = @ResultsKeys
    declared.sort()
    checkEqual(declared, emittedKeys,
      "the documented key list also matches")
    var required: seq[string]
    for key in game["results_schema"]["required"]:
      required.add(key.getStr())
    required.sort()
    checkEqual(required, emittedKeys, "every key is required")
    checkEqual(
      game["results_schema"]["properties"]["reason"]["enum"],
      %["complete", "deadline", "fault"], "the reason enum is closed")
    checkEqual(
      game["results_schema"]["properties"]["end_rule"]["enum"],
      %["full_time", "wall_clock", "sim_fault", "host_error"],
      "the end_rule enum is closed")
    report("results_schema is key-for-key what the server emits")

  block configSchema:
    let schema = game["config_schema"]
    for key in ["tokens", "players", "seed", "num_agents", "antsPerColony",
        "episodeTicks", "turnTicks", "antStepTicks", "cellPx", "pheromoneMax",
        "pheromoneFloor", "pheromoneDecayNum", "decayPeriodTicks",
        "nestSenseCells", "maxOrbits", "sourceSpawnPeriod", "sourceAmount",
        "sourceLifeTicks", "minNestClearance", "bonanzaTicks", "bonanzaAmount",
        "bonanzaLifeTicks", "raidRadius", "trailWarThreshold",
        "turnBudgetSeconds", "wallClockBudgetSeconds",
        "playerConnectTimeoutSeconds", "fieldPath", "showPlayerLabels",
        "gameOverTicks"]:
      check(schema.hasKey(key), "config_schema declares " & key)
    checkEqual(schema["num_agents"]["default"].getInt(), Colonies,
      "num_agents defaults to four")
    ## Every schema default must match the engine default, or the hosted
    ## episode plays a different game from the documented one.
    let defaults = defaultGameConfig()
    checkEqual(schema["antsPerColony"]["default"].getInt(),
      defaults.antsPerColony, "antsPerColony default")
    checkEqual(schema["episodeTicks"]["default"].getInt(),
      defaults.episodeTicks, "episodeTicks default")
    checkEqual(schema["turnTicks"]["default"].getInt(), defaults.turnTicks,
      "turnTicks default")
    checkEqual(schema["pheromoneMax"]["default"].getInt(),
      defaults.pheromoneMax, "pheromoneMax default")
    checkEqual(schema["pheromoneDecayNum"]["default"].getInt(),
      defaults.pheromoneDecayNum, "pheromoneDecayNum default")
    checkEqual(schema["raidRadius"]["default"].getInt(), defaults.raidRadius,
      "raidRadius default")
    checkEqual(schema["fieldPath"]["default"].getStr(), defaults.fieldPath,
      "fieldPath default")
    report("config_schema is complete and agrees with the engine defaults")

  block policySet:
    let policies = parseJson(readRepoFile("tools/ci/policies.json"))
    checkEqual(policies.len, 4, "two champions and two fillers")
    var prompts = 0
    var scripted = 0
    var owned = 0
    var names: seq[string]
    for entry in policies:
      names.add(entry["name"].getStr())
      checkEqual(entry["run"].getStr(), "/bin/hive-player",
        "every policy runs the one player entrypoint")
      if entry["env"].hasKey("PLAYER_PROMPT"):
        inc prompts
        check(entry["env"]["PLAYER_PROMPT"].getStr().len > 400,
          "a champion prompt is a real strategy")
      if entry["env"].hasKey("PLAYER_SCRIPTED"):
        inc scripted
        check(entry["env"]["PLAYER_SCRIPTED"].getStr() in
          ["marcher", "driftling"], "a filler names a real baseline")
      if entry.hasKey("player"):
        inc owned
        checkEqual(entry["player"].getStr(),
          "ply_bac48eb1-662e-44f8-973d-f3e016dccf5d",
          "champion #2 is uploaded as daveey-1")
    checkEqual(prompts, 2, "two LLM prompt champions")
    checkEqual(scripted, 2, "two scripted fillers")
    checkEqual(owned, 1, "exactly one policy carries an owner override")
    checkEqual(names, @["hive-pathwright", "hive-swarmraid", "hive-marcher",
      "hive-driftling"], "the documented policy set")
    checkEqual(policies[0]["env"]["PLAYER_PROMPT"].getStr() ==
      policies[1]["env"]["PLAYER_PROMPT"].getStr(), false,
      "the two champion prompts differ, so they mint distinct versions")
    report("tools/ci/policies.json is the documented four-policy set")

main()
echo "test_manifest: all checks passed"
