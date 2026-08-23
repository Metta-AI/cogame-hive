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
    prompt*: string
    scripted*: ScriptKind
    policyLabel*: string
    registered*: bool

  Roster* = object
    tokens*: seq[string]
    seats*: array[Colonies, Seat]

proc initRoster*(tokens: seq[string]): Roster =
  result.tokens = tokens
  for seat in 0 ..< Colonies:
    ## A seat that never registers, or registers with neither field, is
    ## treated as `scripted: "marcher"`.
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
  prompt, scripted, policy: string
) =
  ## The only frame a player container must send. Over-long prompts are
  ## TRUNCATED at the transport, not rejected, and never written to the
  ## replay or the results.
  if slot < 0 or slot >= Colonies:
    return
  var text = prompt
  if text.runeLen > MaxPromptRunes:
    text = text.runeSubStr(0, MaxPromptRunes)
  let kind = parseScriptKind(scripted)
  roster.seats[slot].prompt = text
  roster.seats[slot].scripted =
    if kind != skNone: kind
    elif text.strip().len > 0: skNone
    else: skMarcher
  roster.seats[slot].policyLabel = truncatePolicy(policy)
  roster.seats[slot].registered = true

proc policyKind*(seat: Seat): string =
  if seat.scripted == skNone: "llm" else: "scripted"
