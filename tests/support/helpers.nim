## Shared test helpers. Lives in a SUBDIRECTORY on purpose: `ci.yml` runs
## every `tests/*.nim` file as a standalone program, and a helper module in
## that glob would be executed as a test.

import std/[json, os, strutils]
import hive/[types, config, field, sim, rules, broadcast, baselines, doctrine]

export types, config, field, sim, rules, broadcast, baselines, doctrine

proc repoRoot*(): string =
  ## The tests run from the repo root under `nim r`, but resolve it from the
  ## source path so a different working directory still finds `data/`.
  currentSourcePath().parentDir().parentDir().parentDir()

proc testField*(): Field =
  parseFieldSpec(parseJson(readFile(repoRoot() / "data" /
    "meadow.fieldspec.json")))

proc testConfig*(ticks = 960, seed = 42): GameConfig =
  result = defaultGameConfig()
  result.seed = seed
  result.episodeTicks = ticks
  result.bonanzaTicks = @[480]
  result.players = @[
    PlayerConfig(name: "P1"), PlayerConfig(name: "P2"),
    PlayerConfig(name: "P3"), PlayerConfig(name: "P4")
  ]
  result.tokens = @["t0", "t1", "t2", "t3"]

proc scriptedProvider*(
  kinds: array[Colonies, ScriptKind]
): DoctrineProvider =
  ## A provider that plays the named baseline in every seat, carrying the
  ## per-seat memory the marcher needs.
  var memory: array[Colonies, BaselineMemory]
  result = proc (match: Sim, turn: int): array[Colonies, ResolvedDoctrine] =
    for seat in 0 ..< Colonies:
      let view = buildView(match, seat)
      result[seat] = scriptedResolved(view, kinds[seat], turn, memory[seat])

proc allMarcher*(): array[Colonies, ScriptKind] =
  [skMarcher, skMarcher, skMarcher, skMarcher]

proc runScripted*(
  ticks = 960,
  seed = 42,
  kinds = allMarcher()
): Sim =
  ## A complete headless episode over the real sim.
  var gameConfig = testConfig(ticks, seed)
  result = newSim(gameConfig, testField())
  result.runEpisode(scriptedProvider(kinds))

proc check*(condition: bool, message: string) =
  if not condition:
    stderr.writeLine("FAIL: " & message)
    quit(1)

proc checkEqual*[T](actual, expected: T, message: string) =
  if actual != expected:
    stderr.writeLine("FAIL: " & message & ": got " & $actual &
      ", expected " & $expected)
    quit(1)

proc report*(name: string) =
  echo "ok - ", name

proc readRepoFile*(relative: string): string =
  readFile(repoRoot() / relative)

proc containsAll*(haystack: string, needles: openArray[string]): seq[string] =
  ## The needles that are MISSING, for a readable static-assertion failure.
  for needle in needles:
    if needle notin haystack:
      result.add(needle)

const IdentChars* = {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '_'}

proc hasWord*(source, word: string): int =
  ## Byte offset of `word` as a whole identifier, or -1. Used by the no-float
  ## source guard instead of a regex, because `std/re` needs libpcre at run
  ## time and CI runners do not reliably carry it.
  var start = 0
  while true:
    let hit = source.find(word, start)
    if hit < 0:
      return -1
    let before = if hit == 0: ' ' else: source[hit - 1]
    let afterIndex = hit + word.len
    let after = if afterIndex >= source.len: ' ' else: source[afterIndex]
    if before notin IdentChars and before != '.' and after notin IdentChars:
      return hit
    start = hit + 1

proc hasCall*(source, name: string): int =
  ## Byte offset of `name(` as a whole identifier followed by an open paren,
  ## or -1.
  var start = 0
  while true:
    let hit = source.find(name & "(", start)
    if hit < 0:
      return -1
    let before = if hit == 0: ' ' else: source[hit - 1]
    if before notin IdentChars and before != '.':
      return hit
    start = hit + 1

proc stripComments*(source: string): string =
  ## Nim source with `#` line comments removed, so a guard that greps for a
  ## forbidden call is not tripped by prose describing it.
  for line in source.splitLines():
    var inString = false
    var cut = line.len
    for index in 0 ..< line.len:
      if line[index] == '"' and (index == 0 or line[index - 1] != '\\'):
        inString = not inString
      elif line[index] == '#' and not inString:
        cut = index
        break
    result.add(line[0 ..< cut])
    result.add("\n")
