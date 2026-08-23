## The grid harness behind the marcher's shipped parameters.
##
## Acceptance checklist item 7 asks that "the baseline's parameters were tuned
## with a grid harness, not guessed". This is that harness, and `ci.yml` runs
## it on every push so the claim stays true as the rules move.
##
## It sweeps the marcher's PUMP doctrine - the doctrine it plays once it can
## see a cache worth working, and the only part of the baseline whose numbers
## are a choice rather than a rule - over a grid of `scouts` x `trail_gain`,
## plays each candidate in seats 0 and 2 against the driftling in seats 1 and
## 3 at several seeds, and ranks the candidates by the share of ALL food
## delivered that the candidate pair took. Share is the game's own score, so
## the ranking is the ranking the league would see.
##
## It exits non-zero unless the shipped configuration is at or near the top of
## the grid: inside the top third by rank, or within `NearTop` share of the
## best point. A failure here is not a bug in the harness - it means the grid
## found something better and `ShippedMarcher` should move (and the golden
## fixtures be re-recorded, per AGENTS.md).
##
##   nim r --hints:off -d:release --path:src tools/tune_marcher.nim

import std/[algorithm, json, os, sequtils, strformat, strutils]
import hive/[types, config, field, sim, rules, broadcast, baselines, doctrine]

const
  Seeds = [11, 42, 907]
  Ticks = 1440           ## six decision turns: long enough for a road to pay
  NearTop = 0.02         ## share, not percent
  ScoutsGrid = [5, 15, 30]
  TrailGrid = [58, 78, 95]

type Result = object
  params: MarcherParams
  share: float
  perSeed: seq[float]

proc repoRoot(): string =
  currentSourcePath().parentDir().parentDir()

proc meadowField(): Field =
  parseFieldSpec(parseJson(readFile(repoRoot() / "data" /
    "meadow.fieldspec.json")))

proc sweepConfig(seed: int): GameConfig =
  result = defaultGameConfig()
  result.seed = seed
  result.episodeTicks = Ticks
  result.bonanzaTicks = @[720]
  result.players = @[
    PlayerConfig(name: "P1"), PlayerConfig(name: "P2"),
    PlayerConfig(name: "P3"), PlayerConfig(name: "P4")
  ]
  result.tokens = @["t0", "t1", "t2", "t3"]

proc candidateShare(meadow: Field, params: MarcherParams, seed: int): float =
  ## The candidate marcher takes seats 0 and 2; the driftling takes 1 and 3.
  var memory: array[Colonies, BaselineMemory]
  let provide = proc (match: Sim, turn: int):
      array[Colonies, ResolvedDoctrine] {.closure.} =
    for seat in 0 ..< Colonies:
      let view = buildView(match, seat)
      if seat mod 2 == 0:
        result[seat] = scriptedResolved(view, skMarcher, turn, memory[seat],
          dsScripted, params)
      else:
        result[seat] = scriptedResolved(view, skDriftling, turn, memory[seat])
  var match = newSim(sweepConfig(seed), meadow)
  match.runEpisode(provide)
  var mine = 0
  var total = 0
  for seat in 0 ..< Colonies:
    let delivered = match.delivered[match.seatNest[seat]]
    total += delivered
    if seat mod 2 == 0:
      mine += delivered
  if total == 0: 0.5 else: mine.float / total.float

proc main() =
  let meadow = meadowField()
  var grid: seq[MarcherParams]
  for scouts in ScoutsGrid:
    for trailGain in TrailGrid:
      var candidate = ShippedMarcher
      candidate.scouts = scouts
      candidate.trailGain = trailGain
      grid.add(candidate)

  var results: seq[Result]
  for params in grid:
    var entry = Result(params: params)
    var total = 0.0
    for seed in Seeds:
      let share = candidateShare(meadow, params, seed)
      entry.perSeed.add(share)
      total += share
    entry.share = total / Seeds.len.float
    results.add(entry)
    echo &"scouts {params.scouts:>3}  trail_gain {params.trailGain:>3}  " &
      "share " & formatFloat(entry.share, ffDecimal, 4) & "  per seed " &
      entry.perSeed.mapIt(formatFloat(it, ffDecimal, 3)).join(" ")

  var ranked = results
  ranked.sort(proc (a, b: Result): int = cmp(b.share, a.share))

  echo ""
  echo "ranked (", Seeds.len, " seeds x ", Ticks,
    " ticks, candidate marcher in seats 0/2 vs driftling in 1/3):"
  var shippedRank = -1
  var shippedShare = 0.0
  for index, entry in ranked:
    let shipped = entry.params.scouts == ShippedMarcher.scouts and
      entry.params.trailGain == ShippedMarcher.trailGain
    if shipped:
      shippedRank = index + 1
      shippedShare = entry.share
    echo &"  {index + 1:>2}. scouts {entry.params.scouts:>3} " &
      &"trail_gain {entry.params.trailGain:>3}  " &
      formatFloat(entry.share, ffDecimal, 4) &
      (if shipped: "   <- SHIPPED" else: "")

  if shippedRank < 0:
    echo "::error::the shipped configuration is not in the grid"
    quit(1)
  let best = ranked[0].share
  let topThird = (ranked.len + 2) div 3
  echo ""
  echo "shipped rank ", shippedRank, " of ", ranked.len,
    ", share ", formatFloat(shippedShare, ffDecimal, 4),
    ", best ", formatFloat(best, ffDecimal, 4),
    ", gap ", formatFloat(best - shippedShare, ffDecimal, 4)
  if shippedRank <= topThird or best - shippedShare <= NearTop:
    echo "marcher grid OK: the shipped parameters are at or near the top"
    quit(0)
  echo "::error::the marcher grid found a materially better configuration: " &
    "scouts " & $ranked[0].params.scouts & ", trail_gain " &
    $ranked[0].params.trailGain & ". Move ShippedMarcher in " &
    "src/hive/baselines.nim and re-record the golden fixtures."
  quit(1)

main()
