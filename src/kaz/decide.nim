## The decision layer: the per-turn loop that asks all four heroes what they
## do next, and always has an answer.
##
## Cadence: one turn every `turnTicks` (96 ticks = 4.0 s of sim time), 24 turns
## per wave, 48 per episode. At each turn the server builds ALL FOUR seats'
## request bodies and sends them as ONE PARALLEL BATCH to the registered player
## sockets. Knights-archers is a simultaneous-decision game, so querying seats
## one after another would quadruple the wall clock for no gain. An episode has
## at most 4 x 48 = 192 player decisions, at most 4 in flight.
##
## DEGRADE, NEVER HANG. Every wait here is bounded: each model decision gets
## one parallel attempt within `turnBudgetMs`. A provider
## throttle, credential-free player, timeout, transport error, or invalid/
## unparseable directive records the failure cause immediately without
## substituting a scripted or idle move; the host terminates the interrupted
## episode unscored.
##
## THE RATE FLOOR. Hosted inference can cap requests per minute per episode, and
## four seats per turn would exceed that at any fast cadence. A
## `turnSpacingMs` = 9000 wall-clock floor between the STARTS of consecutive
## batches holds the episode at 4 x 60 / 9 = 26.7 req/min.

import
  std/[json, monotimes, options, os, times],
  bitworld/decision_trajectory,
  sim, control, directives, baselines, llm
export prompts

const
  FailureKindInfra* = "infrastructure"
  FailureKindInvalidAction* = "invalid_action"
  PlayerFailureKindError* = "player_error"
  PlayerFailureKindInconclusive* = "episode_inconclusive"
  MaxPlayerFailureMessageRunes* = 2000

proc failureKindFor*(cause: string): string =
  if cause in ["no_credentials", "throttled", "transport_error", "timeout", "budget_guard"]:
    FailureKindInfra
  else:
    FailureKindInvalidAction

proc playerFailureKindFor*(failureKind: string): string =
  ## Maps internal failure categories to Coworld's closed GamePlayerFailure.kind.
  if failureKind == FailureKindInfra:
    PlayerFailureKindInconclusive
  else:
    PlayerFailureKindError

proc playerFailurePayload*(
  slot: int, message: string, kind = PlayerFailureKindError
): JsonNode =
  ## Builds Coworld's closed GamePlayerFailure JSON object:
  ## ONLY `failed_policy_index` (>= 0), `message` (1..2000 runes), and
  ## `kind` ("player_error" | "episode_inconclusive").
  if slot < 0:
    raise newException(ValueError, "failed_policy_index must be nonnegative")
  if kind notin [PlayerFailureKindError, PlayerFailureKindInconclusive]:
    raise newException(ValueError, "invalid player failure kind: " & kind)
  let bounded = message.truncateRunes(MaxPlayerFailureMessageRunes)
  let cleanMessage = if bounded.len > 0: bounded else: kind
  %*{
    "failed_policy_index": slot,
    "message": cleanMessage,
    "kind": kind
  }

type
  TurnDecision* = object
    observation*: JsonNode
    attempts*: seq[DecisionAttempt]
    selectedAttemptId*: Option[string]
    executedAction*: JsonNode
    status*: ActionStatus

  SeatPolicy* = object
    ## What one seat registered as. A seat that registers with neither field
    ## — or never registers at all — is `phalanx`.
    isLlm*: bool
    baseline*: Baseline
    label*: string
    registered*: bool

  DecisionEngine* = object
    selection*: PromptSelection
    decisions*: seq[TurnDecision]
    ctl*: ControlState
    seats*: seq[SeatPolicy]
    directives*: seq[SquadDirective]
    haveDirective*: seq[bool]
    lastBatchStart*: MonoTime
    batchStarted*: bool
    llmOff*: bool              ## the budget guard fired; model episode cannot continue
    failed*: bool              ## true when a model seat failed on the current turn
    failedSeat*: int
    failureCause*: string
    failureKind*: string
    failureDetail*: string
    records*: seq[string]      ## chat records queued for the replay writer
    ## The counters as they stood when the PREVIOUS turn was issued. The seat
    ## view's `last_turn` block is the difference, which is the one thing a
    ## commander needs to judge whether its last order worked: a running total
    ## says nothing about the four seconds just spent.
    markKills*: seq[int]
    markHits*: seq[int]
    markShots*: seq[int]
    markTeamKills*: int
    markSpawned*: int

  DecisionExchange* = proc(requests: seq[JsonNode], timeoutMs: int):
    seq[string] {.closure.}

proc initDecisionEngine*(sim: SimServer, selection: PromptSelection): DecisionEngine =
  result.selection = selection
  result.ctl = initControlState(sim)
  result.seats = newSeq[SeatPolicy](sim.seatCount())
  result.directives = newSeq[SquadDirective](sim.seatCount())
  result.haveDirective = newSeq[bool](sim.seatCount())
  result.failedSeat = -1
  for i in 0 ..< result.seats.len:
    result.seats[i].baseline = blPhalanx
    result.seats[i].label = "phalanx"

proc policyKind*(engine: DecisionEngine, seat: int): string =
  if seat >= 0 and seat < engine.seats.len and engine.seats[seat].isLlm:
    "llm"
  else:
    "scripted"

# ---------------------------------------------------------------------------
#  The per-seat view
# ---------------------------------------------------------------------------

proc lastTurnJson(
  engine: DecisionEngine, sim: SimServer, cogIndex: int
): JsonNode =
  ## What happened during the turn just finished, from the counters this engine
  ## marked when that turn was issued. Every field is a DELTA and never
  ## negative: `zombiesSpawned` is per wave, so a wave boundary would otherwise
  ## report a negative gain.
  let
    kills = (if cogIndex < sim.heroKills.len: sim.heroKills[cogIndex] else: 0)
    hits = (if cogIndex < sim.heroHits.len: sim.heroHits[cogIndex] else: 0)
    shots = (if cogIndex < sim.heroShots.len: sim.heroShots[cogIndex] else: 0)
    wasKills =
      (if cogIndex < engine.markKills.len: engine.markKills[cogIndex] else: 0)
    wasHits =
      (if cogIndex < engine.markHits.len: engine.markHits[cogIndex] else: 0)
    wasShots =
      (if cogIndex < engine.markShots.len: engine.markShots[cogIndex] else: 0)
  %*{
    "your_kills": max(0, kills - wasKills),
    "your_hits": max(0, hits - wasHits),
    "your_shots": max(0, shots - wasShots),
    "team_kills": max(0, sim.zombiesKilled - engine.markTeamKills),
    "zombies_gained": max(0, sim.zombiesSpawned - engine.markSpawned)
  }

proc markTurn*(engine: var DecisionEngine, sim: SimServer) =
  ## Snapshots the counters the NEXT turn's `last_turn` block subtracts from.
  ## Called once per turn, after every seat's view has been built and while the
  ## sim is still on the turn's own tick.
  engine.markKills = sim.heroKills
  engine.markHits = sim.heroHits
  engine.markShots = sim.heroShots
  engine.markTeamKills = sim.zombiesKilled
  engine.markSpawned = sim.zombiesSpawned

proc seatViewJson*(
  engine: DecisionEngine,
  sim: SimServer,
  seat, turnIndex, turnsPerGame: int
): string =
  ## Everything this seat may legitimately know, in map pixels, rounded to
  ## integers. The board is FULLY OBSERVABLE (`fogOfWar: false` in every
  ## shipped variant): PettingZoo's KAZ is, this is a cooperative game where
  ## hiding the board from partners adds a puzzle the idea never asks for, and
  ## the horde pressure bar is a public readout.
  ##
  ## HIDDEN, deliberately: the other seats' directives FOR THE TURN BEING
  ## DECIDED (all four decide simultaneously, which is exactly why `say` and
  ## `note` matter), every seat's PLAYER_PROMPT, the identity of any policy
  ## (real names never reach a seat), the episode seed, and the RNG state and
  ## therefore every future spawn row and spawn time.
  let
    cogIndex = seat
    hero =
      if cogIndex >= 0 and cogIndex < sim.players.len: sim.players[cogIndex]
      else: Player()
    hx = hero.x + CollisionW div 2
    hy = hero.y + CollisionH div 2
    role = sim.roleForSeat(seat)
    knight = role == RoleKnight
    gate = gateCentre(sim)
    played = sim.gameTicksElapsed() div TargetFps
    total = (if sim.config.maxTicks > 0: sim.config.maxTicks div TargetFps
             else: 0)
    ranked = rankedZombies(sim)
    leaderDist = sim.leaderGateDist()

  var zombies = newJArray()
  for i, slot in ranked:
    if i >= sim.config.spawnCapAlive:
      break
    let (zx, zy) = sim.zombies[slot].zombiePx()
    zombies.add(%*{
      "id": sim.zombies[slot].id,
      "pos": [zx, zy],
      "hp": max(0, sim.zombies[slot].hp),
      "gate_px": sim.gateDistOf(sim.zombies[slot]),
      "speed_px_s": sim.config.zombieSpeed * TargetFps div MotionScale,
      "lunging_at": (
        if sim.zombies[slot].lungeTarget >= 0:
          %sim.cogAlias(sim.zombies[slot].lungeTarget)
        else: newJNull())
    })

  var squad = newJArray()
  for other in 0 ..< sim.players.len:
    if other == cogIndex:
      continue
    var
      lastNote = newJNull()
      lastSay = newJNull()
      lastIntent = newJNull()
    ## LAST turn's note and say, never this turn's: `engine.directives[other]`
    ## is only overwritten at the top of a turn AFTER every seat's reply has
    ## been installed, so during a turn it still holds the previous one for
    ## every seat but this one — and this seat's own is reported separately as
    ## `your_last_directive`.
    if other < engine.haveDirective.len and engine.haveDirective[other]:
      lastNote = %engine.directives[other].note
      for order in engine.directives[other].orders:
        if order.cogIndex == other:
          lastIntent = %($order.intent)
          lastSay = %order.say
    squad.add(%*{
      "id": sim.cogAlias(other),
      "role": sim.roleOf(other),
      "pos": [sim.players[other].x + CollisionW div 2,
              sim.players[other].y + CollisionH div 2],
      "alive": sim.players[other].alive,
      "kills": (if other < sim.heroKills.len: sim.heroKills[other] else: 0),
      "last_intent": lastIntent,
      "last_note": lastNote,
      "last_say": lastSay
    })

  var node = %*{
    "wave": sim.gameIndex + 1,
    "of": max(1, sim.config.maxGames),
    "turn": turnIndex,
    "turns": turnsPerGame,
    "clock": {"played_s": played, "left_s": max(0, total - played)},
    "you": {
      "id": sim.cogAlias(cogIndex),
      "role": role,
      "alive": hero.alive,
      "pos": [hx, hy],
      "choke_post": [sim.chokePostFor(cogIndex).x, sim.chokePostFor(cogIndex).y],
      "panic_px": max(1, sim.config.archerPanicPx),
      "aim": hero.aimBrads,
      "kills": (if cogIndex < sim.heroKills.len: sim.heroKills[cogIndex] else: 0),
      "reach_px": (if knight: sim.config.knightReach else: sim.config.arrowRange),
      "cooldown_ticks": sim.heroCooldownTicks(cogIndex),
      "speed_px_s":
        sim.config.maxSpeed * sim.heroSpeedPct(cogIndex) div 100 *
          TargetFps div MotionScale,
      "ready": sim.heroWeaponReady(cogIndex)
    },
    "gate": {
      "line_x": sim.config.gateX,
      "centre": [gate.x, gate.y],
      "breach_ends_wave": true
    },
    "breach": {"line_x": sim.config.zombieSpawnX},
    "pressure": {
      "alive": sim.aliveZombies,
      "leader_gate_px": leaderDist,
      "leader_pct": sim.pressurePct(),
      "spawned": sim.zombiesSpawned,
      "killed": sim.waveKillsSoFar,
      "closest_call_px": sim.minGateDist,
      # PER-MILLE of a zombie per TICK is the sim's internal unit
      # (`spawnRatePerMille`); a seat is told zombies per SECOND, which is what
      # the docs and the design note quote (0.29/s at the start of a wave
      # rising to 1.20/s). Multiplying by TargetFps alone reported 288
      # (r1 review N10) -- a number no zombie count could ever be.
      "spawn_rate_per_s": (
        sim.spawnRatePerMille(sim.gameTicksElapsed()) * TargetFps).float / 1000.0
    },
    "zombies": zombies,
    "squad": squad,
    "score": {
      "team": sim.teamScorePermille().float / 1000.0,
      "team_kills": sim.zombiesKilled,
      "waves_cleared": sim.wavesCleared,
      "round_target": sim.config.roundTarget,
      "clear_bonus": sim.config.clearBonus
    }
  }
  node["last_turn"] = engine.lastTurnJson(sim, cogIndex)
  if seat < engine.haveDirective.len and engine.haveDirective[seat]:
    node["your_last_directive"] = %engine.directives[seat].note
  else:
    node["your_last_directive"] = newJNull()
  $node

# ---------------------------------------------------------------------------
#  Records
# ---------------------------------------------------------------------------

proc fallbackRecord(
  wave, turn, seat, attempt: int, cause, detail: string
): string =
  $(%*{
    "k": "fallback",
    "wave": wave,
    "turn": turn,
    "seat": seat,
    "attempt": attempt,
    "cause": cause,
    "detail": detail.truncateRunes(MaxFallbackDetailRunes)
  })

proc registerRecord*(
  seat: int, alias, role, policy, kind, baseline: string
): string =
  ## The REDACTED registration record. The seat's prompt is never written:
  ## only the policy label, the kind, and which baseline a scripted seat
  ## picked.
  $(%*{
    "k": "register",
    "seat": seat,
    "alias": alias,
    "role": role,
    "policy": policy.truncateRunes(MaxPolicyLabelRunes),
    "kind": kind,
    "baseline": baseline
  })

proc resultRecord*(sim: SimServer): string =
  ## The `result` control record — the episode's whole results document,
  ## written once into the replay chat stream at episode end (design §Record
  ## vocabulary, docs/PROTOCOL.md §The replay). It is what makes the replay
  ## SELF-SUFFICIENT: without it the outcome exists only at
  ## COGAME_RESULTS_URI, and `replay_summary.py`'s `results` reads `{}` for a
  ## spectator holding the bytes. The document is already valid JSON, so it is
  ## embedded verbatim rather than re-parsed: nothing on the path to the
  ## artifact writes may raise.
  "{\"k\":\"result\",\"results\":" & sim.heroResultsJson() & "}"

proc budgetGuardRecord(turn, remainingSeconds: int): string =
  $(%*{"k": "budget_guard", "turn": turn, "remaining_s": remainingSeconds})

# ---------------------------------------------------------------------------
#  The turn
# ---------------------------------------------------------------------------

proc scriptedFor(
  engine: DecisionEngine, sim: SimServer, seat: int, kind: Baseline
): SquadDirective =
  scriptedDirective(sim.policyView(seat), kind)

proc phalanxFor*(
  engine: DecisionEngine, sim: SimServer, cogs: seq[int]
): SquadDirective =
  ## The published `phalanx` directive for an arbitrary hero set — the
  ## per-turn fallback, the driver of a no-show seat, and the default.
  result.source = dsScripted
  result.note = "hold the gate"
  for cogIndex in cogs:
    result.orders.add(scriptedDirective(sim.policyView(cogIndex), blPhalanx).orders)

proc turn*(
  engine: var DecisionEngine,
  sim: SimServer,
  turnIndex, turnsPerGame: int,
  elapsedSeconds: int,
  exchange: DecisionExchange
): seq[string] =
  ## Runs ONE decision turn and installs each seat's directive. Returns the
  ## replay chat records this turn produced. Any failed model decision sets
  ## `engine.failed = true` with cause/kind/seat so the host terminates the
  ## interrupted episode unscored without substituting a scripted or idle move.
  let
    wave = sim.gameIndex + 1
    budget = initDuration(milliseconds = max(1, sim.config.turnBudgetMs))

  engine.failed = false
  engine.failedSeat = -1
  engine.failureCause = ""
  engine.failureKind = ""
  engine.failureDetail = ""

  proc recordFailure(engine: var DecisionEngine, seat: int, cause, detail: string) =
    if not engine.failed:
      engine.failed = true
      engine.failedSeat = seat
      engine.failureCause = cause
      engine.failureKind = failureKindFor(cause)
      engine.failureDetail = detail

  # --- budget guard: interrupt rather than overrun or substitute ------------
  # If two more full turns would not fit inside the engine's own wall-clock
  # stop, do not substitute scripted or idle moves for model seats.
  var hasLlmSeat = false
  for seat in 0 ..< engine.seats.len:
    if engine.seats[seat].isLlm:
      hasLlmSeat = true
      break
  if hasLlmSeat and not engine.llmOff:
    let turnSeconds = (sim.config.turnBudgetMs + sim.config.turnSpacingMs + 999) div 1000
    if elapsedSeconds + 2 * turnSeconds > sim.config.wallClockBudgetSeconds:
      engine.llmOff = true
      result.add(budgetGuardRecord(
        turnIndex, max(0, sim.config.wallClockBudgetSeconds - elapsedSeconds)))
      echo "knights-archers: budget guard fired at turn ", turnIndex,
        "; interrupting episode unscored"

  var views = newSeq[JsonNode](engine.seats.len)
  engine.decisions = newSeq[TurnDecision](engine.seats.len)
  for seat in 0 ..< engine.seats.len:
    views[seat] = parseJson(engine.seatViewJson(sim, seat, turnIndex, turnsPerGame))
    engine.decisions[seat] = TurnDecision(observation: copy(views[seat]),
      executedAction: newJNull(),
      status: if engine.seats[seat].isLlm: asMissing else: asFallback)

    engine.decisions[seat].observation["prompt_selection"] = engine.selection.selectionMetadata()

  # --- which seats need a call? --------------------------------------------
  var open: seq[int]
  for seat in 0 ..< engine.seats.len:
    if engine.seats[seat].isLlm and not engine.llmOff:
      engine.haveDirective[seat] = false
      open.add(seat)
    elif engine.seats[seat].isLlm:
      engine.haveDirective[seat] = false
      engine.decisions[seat].status = asMissing
      let cause = "budget_guard"
      let detail = "wall-clock budget guard interrupted model turn"
      result.add(fallbackRecord(wave, turnIndex, seat, 1, cause, detail))
      engine.recordFailure(seat, cause, detail)
      echo "knights-archers llm: seat ", seat, " failed (", cause,
        ") on turn ", turnIndex, "; episode interrupted"
    else:
      var directive = scriptedDirective(views[seat].policyView(), engine.seats[seat].baseline)
      directive.source = dsScripted
      engine.directives[seat] = directive
      engine.haveDirective[seat] = true
      let intentional = engine.seats[seat].registered
      var teacher = newDecisionAttempt($wave & "-" & $turnIndex & "-" & $seat & "-teacher",
        "scripted-" & $engine.seats[seat].baseline, if intentional: aoTeacher else: aoFallback)
      teacher.prompt = %*[{"role": "system", "content": systemPromptFor(engine.selection, views[seat]["you"]["role"].getStr())},
        {"role": "user", "content": userMessage(DefaultOperatorPrompt, $views[seat])}]
      teacher.parsedAction = directive.actionJson()
      teacher.response = %($teacher.parsedAction)
      teacher.accepted = intentional
      engine.decisions[seat].attempts.add(teacher)
      if intentional:
        engine.decisions[seat].selectedAttemptId = some(teacher.attemptId)
        engine.decisions[seat].status = asAccepted

  # --- the rate floor -------------------------------------------------------
  # Hosted inference may cap requests per minute per episode. Hold the start
  # of consecutive batches
  # `turnSpacingMs` apart, which pins the episode at <= 24 req/min. The cert
  # fixture sets it to 0, so offline runs pay nothing.
  if open.len > 0 and engine.batchStarted and sim.config.turnSpacingMs > 0:
    let since = (getMonoTime() - engine.lastBatchStart).inMilliseconds.int
    if since < sim.config.turnSpacingMs:
      sleep(min(sim.config.turnSpacingMs, sim.config.turnSpacingMs - since))
  if open.len > 0:
    engine.lastBatchStart = getMonoTime()
    engine.batchStarted = true

  # Rate-limit waiting precedes the per-turn inference deadline.
  let turnStart = getMonoTime()
  # --- one PARALLEL batch per model decision --------------------------------
  if open.len > 0:
    if getMonoTime() - turnStart >= budget:
      for seat in open:
        let detail = "per-turn budget exhausted before attempt 1"
        result.add(fallbackRecord(wave, turnIndex, seat, 1, "timeout", detail))
        engine.decisions[seat].status = asMissing
        engine.recordFailure(seat, "timeout", detail)
    else:
      let deadlineMs = max(1, (budget - (getMonoTime() - turnStart)).inMilliseconds.int)
      var requests: seq[JsonNode]
      for seat in open:
        requests.add(%*{
          "type": "decision",
          "protocol": "kaz.player.v2",
          "id": (sim.gameIndex + 1) * 100_000 + turnIndex * 10,
          "slot": seat,
          "attempt": 1,
          "timeout_ms": deadlineMs,
          "prompt_configuration": {"promptVariant": $engine.selection.variant, "promptSeed": engine.selection.seed},
          "view": views[seat]
        })
      let started = getMonoTime()
      let responses = exchange(requests, deadlineMs)
      let latency = (getMonoTime() - started).inMilliseconds.int
      for position, seat in open:
        var cause = "timeout"
        var evidence = newDecisionAttempt($wave & "-" & $turnIndex & "-" & $seat & "-1",
          engine.seats[seat].label, aoUnknown)
        evidence.latencyMs = some(float(latency))
        try:
          if responses[position].len == 0:
            raise newException(ValueError, "player action timed out")
          cause = "parse_error"
          let response = parseJson(responses[position])
          if response.hasKey("training_attempt") and response["training_attempt"].kind != JNull:
            evidence = readAttemptEvidence(response["training_attempt"])
            evidence.attemptId = $wave & "-" & $turnIndex & "-" & $seat & "-1"
            if evidence.origin in {aoTeacher, aoHuman}: evidence.origin = aoUnknown
          if response["type"].getStr() != "action" or
              response["protocol"].getStr() != "kaz.player.v2":
            raise newException(ValueError, "wrong player action protocol")
          if response["id"].getInt() != requests[position]["id"].getInt():
            raise newException(ValueError, "player action id mismatch")
          if response{"source"}.getStr() == "fallback":
            let reported = response{"cause"}.getStr()
            let why = if reported in ["no_credentials", "throttled",
                "transport_error", "timeout", "parse_error"]:
                reported else: "parse_error"
            let detail = block:
              let d = response{"detail"}.getStr()
              if d.len > 0: d else: "player policy reported failure: " & why
            result.add(fallbackRecord(wave, turnIndex, seat, 1, why, detail))
            engine.haveDirective[seat] = false
            engine.decisions[seat].status =
              if failureKindFor(why) == FailureKindInfra: asMissing else: asRejected
            evidence.rejectionReason = some(if evidence.origin == aoModel and evidence.rawResponse.kind == JNull:
              "incomplete_native_attempt: " & why & " before HTTP response" else: why)
            engine.decisions[seat].attempts.add(evidence)
            engine.recordFailure(seat, why, detail)
            echo "knights-archers llm: seat ", seat, " failed (", why,
              ") on turn ", turnIndex, "; episode interrupted"
            continue
          if response{"source"}.getStr() != "llm":
            raise newException(ValueError, "player action source must be llm")
          let commanded = sim.commandedCogs(seat)
          var ids: seq[string]
          for cogIndex in commanded:
            ids.add(sim.cogAlias(cogIndex))
          let parsed = parseSquadDirective(
            response["action"], ids, commanded,
            MapWidth - 1, MapHeight - 1)
          if not parsed.ok: raise newException(DirectiveError, parsed.reason)
          var directive = parsed.directive
          let proposal = directive.actionJson()
          evidence.parsedAction = proposal
          if evidence.origin == aoModel:
            let generated = jsonProposal(evidence.response.getStr())
            if not generated.ok: raise newException(DirectiveError, generated.reason)
            let independentlyParsed = parseSquadDirective(generated.node, ids, commanded,
              MapWidth - 1, MapHeight - 1)
            if not independentlyParsed.ok: raise newException(DirectiveError, independentlyParsed.reason)
            evidence.parsedAction = independentlyParsed.directive.actionJson()
            if evidence.parsedAction != proposal:
              raise newException(ValueError, "model response differs from submitted directive")
          directive.source = dsLlm
          directive.latencyMs = latency
          evidence.accepted = true
          engine.decisions[seat].selectedAttemptId = some(evidence.attemptId)
          engine.decisions[seat].status = asAccepted
          engine.directives[seat] = directive
          engine.haveDirective[seat] = true
        except CatchableError as error:
          engine.haveDirective[seat] = false
          engine.decisions[seat].status =
            if failureKindFor(cause) == FailureKindInfra: asMissing else: asRejected
          result.add(fallbackRecord(wave, turnIndex, seat, 1, cause, error.msg))
          echo "knights-archers llm: seat ", seat, " failed (", cause,
            ") on turn ", turnIndex, ": ", error.msg
          evidence.rejectionReason = some(if evidence.origin == aoModel and evidence.rawResponse.kind == JNull:
            "incomplete_native_attempt: " & cause & " before HTTP response" else: cause)
          engine.recordFailure(seat, cause, error.msg)
        engine.decisions[seat].attempts.add(evidence)

  for seat in 0 ..< engine.seats.len:
    engine.decisions[seat].executedAction =
      if not engine.failed and engine.haveDirective[seat]: engine.directives[seat].actionJson()
      else: newJNull()
    if engine.failed:
      engine.decisions[seat].selectedAttemptId = none(string)
      if engine.decisions[seat].status == asAccepted:
        engine.decisions[seat].status = asMissing
    var hashes = newJArray()
    for attempt in engine.decisions[seat].attempts:
      if attempt.prompt.kind == JArray and attempt.prompt.len == 2:
        hashes.add(%*{"attempt_id": attempt.attemptId,
          "prompt_template": engine.selection.promptMetadata(
            attempt.prompt[0]["content"].getStr(), attempt.prompt[1]["content"].getStr())})
    engine.decisions[seat].observation["prompt_hashes"] = hashes

  ## Every view for this turn has been built, and the sim is still on the
  ## turn's own tick: mark the counters the NEXT turn's `last_turn` reports
  ## against.
  engine.markTurn(sim)
