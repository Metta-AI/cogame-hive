## Slots, tokens and connection bookkeeping. Forked from paintbot's
## `src/ctf/roster.nim`: the same join / auth / slot / token discipline, the
## same 403 on a bad slot or token and 409 on a duplicate connection.

import std/[strutils, unicode]
import types, baselines

proc truncatePolicy*(label: string): string =
  ## `register.policy` is capped at 48 RUNES, never bytes.
  let cleaned = label.replace("\n", " ").strip()
  if cleaned.runeLen <= MaxPolicyRunes: cleaned
  else: cleaned.runeSubStr(0, MaxPolicyRunes)

type
  JoinError* = enum
    jeNone
    jeBadSlot
    jeBadToken
    jeDuplicate

  Seat* = object
    connected*: bool
    everConnected*: bool
    scripted*: ScriptKind
    external*: bool
    prompt*: string
    model*: string
    policyLabel*: string
    registered*: bool

  Roster* = object
    tokens*: seq[string]
    seats*: array[Colonies, Seat]

proc initRoster*(tokens: seq[string]): Roster =
  result.tokens = tokens
  for seat in 0 ..< Colonies:
    ## A seat that never registers plays marcher as the game fallback.
    result.seats[seat] = Seat(scripted: skMarcher, policyLabel: "")

proc authorize*(roster: Roster, slot: int, token: string): JoinError =
  if slot < 0 or slot >= Colonies or slot >= roster.tokens.len:
    return jeBadSlot
  if roster.tokens[slot] != token:
    return jeBadToken
  if roster.seats[slot].connected:
    return jeDuplicate
  jeNone

proc register*(
  roster: var Roster,
  slot: int,
  scripted, policy: string,
  external = false,
  prompt = "",
  model = ""
) =
  if slot < 0 or slot >= Colonies:
    return
  let selectedModel = model.strip()
  if selectedModel.len > 128:
    raise newException(HiveError, "register.model exceeds 128 ASCII characters")
  for character in selectedModel:
    if character notin {'a'..'z', 'A'..'Z', '0'..'9', '-', '_', '.', '/', ':'}:
      raise newException(HiveError, "invalid register.model character")
  let kind = parseScriptKind(scripted)
  roster.seats[slot].model = selectedModel
  roster.seats[slot].external = external
  let cleaned = prompt.strip()
  roster.seats[slot].prompt =
    if cleaned.runeLen <= 4000: cleaned
    else: cleaned.runeSubStr(0, 4000)
  roster.seats[slot].scripted =
    if kind != skNone: kind
    elif external or roster.seats[slot].prompt.len > 0: skNone
    else: skMarcher
  roster.seats[slot].policyLabel = truncatePolicy(policy)
  roster.seats[slot].registered = true

proc policyKind*(seat: Seat): string =
  if seat.scripted != skNone: "scripted"
  elif seat.external: "external"
  else: "llm"
