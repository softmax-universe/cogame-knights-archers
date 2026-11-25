## The game sends one private observation per seat before waiting for actions.

import std/[json, options]
import kaz/[sim, decide, control, directives]
import bitworld/decision_trajectory
import ./helpers

proc check(condition: bool, what: string) =
  if not condition:
    echo "FAIL: ", what
    quit(1)

proc llmWorld(): SimServer =
  result = newHordeSim(maxTicks = 2304, maxGames = 1)
  result.gameEventLoggingEnabled = false
  result.config.turnSpacingMs = 0

proc seatEveryoneLlm(engine: var DecisionEngine) =
  for seat in 0 ..< engine.seats.len:
    engine.seats[seat].isLlm = true
    engine.seats[seat].registered = true
    engine.seats[seat].label = "prompt"

proc validReply(request: JsonNode): string =
  $ %*{
    "type": "action",
    "protocol": "kaz.player.v2",
    "id": request["id"],
    "source": "llm",
    "action": {
      "note": "hold the line",
      "cogs": [{
        "id": request["view"]["you"]["id"],
        "intent": "screen",
        "target": [560, 240],
        "say": "line"
      }]
    }
  }

block allFourSeatsSeeOnePreActionState:
  var world = llmWorld()
  var engine = initDecisionEngine(world, PromptSelection())
  engine.seatEveryoneLlm()
  engine.ctl.observeHeroes(world)
  var batches: seq[seq[JsonNode]]
  let exchange: DecisionExchange = proc(
    requests: seq[JsonNode], timeoutMs: int
  ): seq[string] {.closure.} =
    batches.add(requests)
    result = newSeq[string](requests.len)
    for position, request in requests:
      result[position] = validReply(request)
  let records = engine.turn(world, 0, 24, 0, exchange)
  check(batches.len == 1, "one batch for four simultaneous seats")
  check(batches[0].len == 4, "the batch must contain four private views")
  for seat, request in batches[0]:
    check(request["slot"].getInt() == seat, "slot order is stable")
    check(request["view"]["you"]["id"].getStr() == world.cogAlias(seat),
      "each seat sees its own alias")
    check(request["view"]["turn"].getInt() == 0,
      "all seats see the same pre-action turn")
    check(engine.haveDirective[seat], "seat has an accepted directive")
    check(engine.directives[seat].source == dsLlm,
      "accepted player action is model-sourced")
    check(engine.directives[seat].orders[0].cogIndex == seat,
      "an action commands only its own hero")
  for record in records:
    check(parseJson(record){"k"}.getStr() != "fallback",
      "valid actions produce no fallback")

block invalidActionsFailOnFirstAttemptWithNoRetry:
  var world = llmWorld()
  var engine = initDecisionEngine(world, PromptSelection())
  engine.seatEveryoneLlm()
  engine.ctl.observeHeroes(world)
  var attempts = 0
  let exchange: DecisionExchange = proc(
    requests: seq[JsonNode], timeoutMs: int
  ): seq[string] {.closure.} =
    inc attempts
    result = newSeq[string](requests.len)
    for position, request in requests:
      result[position] = "not json"
  let records = engine.turn(world, 0, 24, 0, exchange)
  check(attempts == 1, "one attempt per model decision, no silent retry")
  check(engine.failed, "invalid model reply must fail the turn")
  check(engine.failedSeat == 0, "first failed seat is recorded")
  check(engine.failureKind == FailureKindInvalidAction, "invalid reply is invalid_action")
  check(engine.failureCause == "parse_error", "cause is parse_error")
  var errors = 0
  for record in records:
    let node = parseJson(record)
    if node{"k"}.getStr() == "fallback":
      check(node["attempt"].getInt() == 1, "only single attempt runs")
      if node["cause"].getStr() == "parse_error":
        inc errors
  check(errors == 4, "each unusable action records one parse error")
  for seat in 0 ..< world.seatCount():
    check(not engine.haveDirective[seat], "failed turn installs no directive")
    check(engine.decisions[seat].status == asRejected, "invalid reply records rejected status")
    check(engine.decisions[seat].executedAction.kind == JNull, "invalid reply executes no directive")

block missingActionsHaveOneSharedDeadlineAndNoFallback:
  var world = llmWorld()
  var engine = initDecisionEngine(world, PromptSelection())
  engine.seatEveryoneLlm()
  engine.ctl.observeHeroes(world)
  var deadlines: seq[int]
  let exchange: DecisionExchange = proc(
    requests: seq[JsonNode], timeoutMs: int
  ): seq[string] {.closure.} =
    deadlines.add(timeoutMs)
    check(requests.len == 4, "attempt sends all four views together")
    newSeq[string](requests.len)
  let records = engine.turn(world, 0, 24, 0, exchange)
  check(deadlines.len == 1 and deadlines[0] > 0 and
        deadlines[0] <= world.config.turnBudgetMs and
        deadlines[0] >= world.config.turnBudgetMs - 100,
    "single batch deadline is bounded by remaining turnBudgetMs")
  check(engine.failed and engine.failureKind == FailureKindInfra and engine.failureCause == "timeout",
    "timeout is recorded as infrastructure failure")
  for seat in 0 ..< world.seatCount():
    check(not engine.haveDirective[seat],
      "a missing action must not silently install a phalanx fallback")
    check(engine.decisions[seat].status == asMissing,
      "timed-out turn records missing status")
    check(engine.decisions[seat].executedAction.kind == JNull,
      "timed-out turn executes no directive")
  for decision in engine.decisions:
    for attempt in decision.attempts:
      check(attempt.origin == aoUnknown and attempt.prompt.kind == JNull,
        "unserved socket waits cannot invent a model prompt")
  var timeouts = 0
  for record in records:
    if parseJson(record){"cause"}.getStr() == "timeout":
      inc timeouts
  check(timeouts == 4, "single attempt names every seat timeout")

block aCredentialFreePlayerReportsFailureImmediately:
  var world = llmWorld()
  var engine = initDecisionEngine(world, PromptSelection())
  engine.seatEveryoneLlm()
  engine.ctl.observeHeroes(world)
  var batches = 0
  let exchange: DecisionExchange = proc(
    requests: seq[JsonNode], timeoutMs: int
  ): seq[string] {.closure.} =
    inc batches
    result = newSeq[string](requests.len)
    for position, request in requests:
      result[position] = $ %*{
        "type": "action", "protocol": "kaz.player.v2",
        "id": request["id"], "source": "fallback",
        "cause": "no_credentials"
      }
  let records = engine.turn(world, 0, 24, 0, exchange)
  check(batches == 1, "explicit no-credential failure does not retry")
  check(engine.failed and engine.failureKind == FailureKindInfra and
        engine.failureCause == "no_credentials",
    "no_credentials is recorded as infrastructure failure")
  var noCredentials = 0
  for record in records:
    if parseJson(record){"cause"}.getStr() == "no_credentials":
      inc noCredentials
  check(noCredentials == 4, "each credential-free seat records a failure")
  for seat in 0 ..< world.seatCount():
    check(not engine.haveDirective[seat],
      "credential-free seats must not silently play phalanx")
    check(engine.decisions[seat].status == asMissing,
      "credential-free seat records missing status")
    check(engine.decisions[seat].executedAction.kind == JNull,
      "credential-free seat executes no directive")

block theBudgetGuardInterruptsModelTurnsUnscored:
  var world = llmWorld()
  var engine = initDecisionEngine(world, PromptSelection())
  engine.seatEveryoneLlm()
  engine.ctl.observeHeroes(world)
  let elapsed = world.config.wallClockBudgetSeconds -
    (world.config.turnBudgetMs div 1000)
  let exchange: DecisionExchange = proc(
    requests: seq[JsonNode], timeoutMs: int
  ): seq[string] {.closure.} =
    raise newException(ValueError, "budget guard must avoid the exchange")
  let records = engine.turn(world, 20, 24, elapsed, exchange)
  check(engine.llmOff, "the budget guard must latch")
  check(engine.failed and engine.failureKind == FailureKindInfra and
        engine.failureCause == "budget_guard",
    "budget guard records infrastructure failure for model seats")
  var guarded = false
  for record in records:
    if parseJson(record){"k"}.getStr() == "budget_guard":
      guarded = true
  check(guarded, "the guard must name the turn it fired on")
  for seat in 0 ..< world.seatCount():
    check(not engine.haveDirective[seat],
      "budget guard must not silently substitute phalanx for model seats")
    check(engine.decisions[seat].status == asMissing,
      "budget-guarded model seat records missing status")
    check(engine.decisions[seat].executedAction.kind == JNull,
      "budget-guarded model seat executes no directive")

block theShippedVariantsPaceThemselvesInsideTheBudget:
  let manifest = parseJson(readFile("coworld_manifest_template.json"))
  for variant in manifest["variants"]:
    let
      cfg = variant["game_config"]
      id = variant["id"].getStr()
      seats = cfg["num_agents"].getInt()
      spacing = cfg["turnSpacingMs"].getInt()
      budget = cfg["turnBudgetMs"].getInt()
      stop = cfg["wallClockBudgetSeconds"].getInt()
    let perMinute = seats * 60_000 div max(1, spacing)
    check(perMinute <= 30, id & ": too many model calls per minute")
    check(spacing > budget, id & ": spacing must exceed the turn budget")
    check(not cfg.hasKey("attempt1Ms") and not cfg.hasKey("retryMs"),
      id & ": stale attempt/retry fields must not be present")
    check(budget >= 1000, id & ": turnBudgetMs must be at least 1000 ms")
    let turns = max(1, cfg["maxTicks"].getInt() div
      cfg["turnTicks"].getInt()) * max(1, cfg["maxGames"].getInt())
    let worst = turns * spacing div 1000 +
      cfg["lobbyJoinTimeoutTicks"].getInt() div TargetFps + 60 + 20
    check(worst <= stop, id & ": episode can overrun the engine stop")
    check(stop <= 720, id & ": engine stop exceeds 60% of platform timeout")

block playerCannotAssertServerTeacherOrigin:
  var world = llmWorld()
  var engine = initDecisionEngine(world, PromptSelection())
  engine.seatEveryoneLlm()
  let exchange: DecisionExchange = proc(requests: seq[JsonNode], timeoutMs: int): seq[string] =
    result = newSeq[string](requests.len)
    for position, request in requests:
      var reply = parseJson(validReply(request))
      var asserted = newDecisionAttempt("player", "asserted-origin",
        if position mod 2 == 0: aoTeacher else: aoHuman)
      asserted.response = %($reply["action"])
      reply["training_attempt"] = attemptEvidenceJson(asserted)
      result[position] = $reply
  discard engine.turn(world, 0, 24, 0, exchange)
  for decision in engine.decisions:
    check(decision.attempts.len == 1, "external teacher assertion is retained")
    check(decision.attempts[0].origin == aoUnknown, "player cannot qualify itself as an engine teacher or human")

block modelResponseMustMatchExecutedProposal:
  var world = llmWorld()
  var engine = initDecisionEngine(world, PromptSelection())
  engine.seatEveryoneLlm()
  let exchange: DecisionExchange = proc(requests: seq[JsonNode], timeoutMs: int): seq[string] =
    result = newSeq[string](requests.len)
    for position, request in requests:
      var reply = parseJson(validReply(request))
      var generated = copy(reply["action"])
      generated["note"] = %"another model reply"
      var evidence = newDecisionAttempt("player", "model-fixture", aoModel)
      evidence.response = %($generated)
      evidence.rawResponse = %($generated)
      reply["training_attempt"] = attemptEvidenceJson(evidence)
      result[position] = $reply
  discard engine.turn(world, 0, 24, 0, exchange)
  check(engine.failed and engine.failureKind == FailureKindInvalidAction,
    "model/action mismatch fails the turn")
  for seat, decision in engine.decisions:
    check(not engine.haveDirective[seat], "model/action mismatch installs no directive")
    check(decision.status == asRejected, "model/action mismatch records rejected status")
    check(decision.executedAction.kind == JNull, "rejected turn executes no directive")
    check(decision.attempts.len == 1, "single mismatched attempt is retained")
    for attempt in decision.attempts:
      check(not attempt.accepted, "mismatched model response cannot become a target")
      check(attempt.parsedAction != decision.executedAction, "independent proposal remains distinct from empty execution")

block fencedModelResponseAcceptedAndProseRejected:
  var world = llmWorld()
  var engine = initDecisionEngine(world, PromptSelection())
  engine.seatEveryoneLlm()
  let fencedExchange: DecisionExchange = proc(requests: seq[JsonNode], timeoutMs: int): seq[string] =
    result = newSeq[string](requests.len)
    for position, request in requests:
      var reply = parseJson(validReply(request))
      var evidence = newDecisionAttempt("player", "model-fixture", aoModel)
      let rawAction = $reply["action"]
      evidence.response = %("```json\n" & rawAction & "\n```")
      evidence.rawResponse = evidence.response
      reply["training_attempt"] = attemptEvidenceJson(evidence)
      result[position] = $reply
  discard engine.turn(world, 0, 24, 0, fencedExchange)
  check(not engine.failed, "all-fenced valid turn succeeds")
  for seat in 0 ..< world.seatCount():
    check(engine.haveDirective[seat] and engine.decisions[seat].status == asAccepted,
      "single outer json fence is accepted")

  var proseWorld = llmWorld()
  var proseEngine = initDecisionEngine(proseWorld, PromptSelection())
  proseEngine.seatEveryoneLlm()
  let proseExchange: DecisionExchange = proc(requests: seq[JsonNode], timeoutMs: int): seq[string] =
    result = newSeq[string](requests.len)
    for position, request in requests:
      var reply = parseJson(validReply(request))
      var evidence = newDecisionAttempt("player", "model-fixture", aoModel)
      let rawAction = $reply["action"]
      if request["slot"].getInt() == 0:
        evidence.response = %("```json\n" & rawAction & "\n```")
      else:
        evidence.response = %("Here is my order:\n" & rawAction)
      evidence.rawResponse = evidence.response
      reply["training_attempt"] = attemptEvidenceJson(evidence)
      result[position] = $reply
  discard proseEngine.turn(proseWorld, 0, 24, 0, proseExchange)
  check(proseEngine.failed and proseEngine.failedSeat == 1 and
        proseEngine.failureKind == FailureKindInvalidAction,
    "surrounding prose fails the turn on seat 1")
  for seat in 0 ..< proseWorld.seatCount():
    check(proseEngine.decisions[seat].executedAction.kind == JNull,
      "aborted turn executes no directive for any seat")
  for seat in 1 ..< proseWorld.seatCount():
    check(not proseEngine.haveDirective[seat] and proseEngine.decisions[seat].status == asRejected,
      "surrounding prose is rejected without phalanx fallback")

block aScriptedTeacherDoesNotClaimModelInference:
  var world = llmWorld()
  var engine = initDecisionEngine(world, PromptSelection())
  for seat in engine.seats.mitems:
    seat.registered = true
  discard engine.turn(world, 0, 24, 0,
    proc(requests: seq[JsonNode], timeoutMs: int): seq[string] =
      raise newException(ValueError, "scripted teacher must not call a model"))
  for decision in engine.decisions:
    let teacher = decision.attempts[0]
    check(teacher.origin == aoTeacher and teacher.accepted,
      "engine-owned scripted action is an intentional teacher target")
    check(teacher.model.isNone and teacher.request.kind == JNull and
      teacher.decoder.kind == JNull and teacher.rawResponse.kind == JNull and
      teacher.platformCallId.isNone,
      "scripted teacher has no serving model, request, decoder, raw provider response, or native call")
    check(teacher.prompt.kind == JArray and
      teacher.parsedAction == decision.executedAction and
      teacher.response == %($decision.executedAction),
      "teacher preserves the production prompt and exact applied directive")

block anUnregisteredSeatStillPlaysPhalanx:
  var world = llmWorld()
  var engine = initDecisionEngine(world, PromptSelection())
  engine.ctl.observeHeroes(world)
  let exchange: DecisionExchange = proc(
    requests: seq[JsonNode], timeoutMs: int
  ): seq[string] {.closure.} =
    raise newException(ValueError, "scripted seats must not use the exchange")
  discard engine.turn(world, 0, 24, 0, exchange)
  for seat in 0 ..< world.seatCount():
    check(engine.haveDirective[seat], "unregistered seat has a directive")
    check(engine.directives[seat].source == dsScripted,
      "unregistered seat plays the published default")

block playerFailurePayloadMatchesClosedSchema:
  check(playerFailureKindFor(FailureKindInvalidAction) == PlayerFailureKindError,
    "invalid_action maps to player_error")
  check(playerFailureKindFor(FailureKindInfra) == PlayerFailureKindInconclusive,
    "infrastructure maps to episode_inconclusive")
  let errPayload = playerFailurePayload(
    2, "invalid_action:parse_error: response must be a single JSON object",
    PlayerFailureKindError)
  check(errPayload.len == 3 and
        errPayload.hasKey("failed_policy_index") and
        errPayload.hasKey("message") and
        errPayload.hasKey("kind") and
        not errPayload.hasKey("cause") and
        not errPayload.hasKey("failure_kind"),
    "GamePlayerFailure payload must contain only closed schema keys")
  check(errPayload["failed_policy_index"].getInt() == 2 and
        errPayload["kind"].getStr() == "player_error",
    "invalid reply attributes player_error to actual seat")
  let infraPayload = playerFailurePayload(
    3, "infrastructure:transport_error: HTTP 503",
    PlayerFailureKindInconclusive)
  check(infraPayload.len == 3 and
        infraPayload["failed_policy_index"].getInt() == 3 and
        infraPayload["kind"].getStr() == "episode_inconclusive",
    "provider outage attributes episode_inconclusive to actual seat")
  let emptyPayload = playerFailurePayload(1, "", PlayerFailureKindError)
  check(emptyPayload["message"].getStr().len >= 1,
    "empty message falls back to non-empty string")
  var longMsg = ""
  for _ in 0 ..< 1999:
    longMsg.add('a')
  longMsg.add("🛡x")
  let bounded = playerFailurePayload(0, longMsg, PlayerFailureKindError)["message"].getStr()
  check(bounded.len == 1999 + "🛡".len and bounded[^1] != 'x',
    "message truncates cleanly at 2000 runes on a rune boundary")
  var rejectedNegative = false
  try:
    discard playerFailurePayload(-1, "bad", PlayerFailureKindError)
  except ValueError:
    rejectedNegative = true
  check(rejectedNegative, "negative failed_policy_index must be rejected")

echo "test_engine: ok"
