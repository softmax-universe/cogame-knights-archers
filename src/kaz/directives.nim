## The directive schema: what a commander (LLM or scripted) may say, how a
## reply is parsed STRICTLY, and how recorded strings are bounded on rune
## boundaries.
##
## Both policy kinds emit the SAME object, so the two are strictly comparable
## and one validator covers both — that is what makes the bounded-orders test
## in tests/test_control.nim meaningful.
##
## RUNE DISCIPLINE. Every cap in this file is measured in RUNES (Unicode
## codepoints) and every truncation lands on a rune boundary (`runeLen` /
## `runeSubStr`). Slicing a string by BYTE index anywhere on the path to the
## replay is forbidden: a byte-truncated multi-byte character renders fine in a
## browser and then fails a strict UTF-8 parser, which is exactly the class of
## bug that makes a replay unreadable to everything except the one viewer that
## happened to be lenient.

import
  std/[json, parsejson, streams, strutils, unicode],
  sim_types

type
  Intent* = enum
    ## What a hero is being told to do for the next turn. A closed enum;
    ## unknown intents are rejected rather than silently substituted.
    intIntercept = "intercept"
    intHold = "hold"
    intScreen = "screen"
    intFocus = "focus"
    intFallBack = "fall_back"
    intRegroup = "regroup"

  CogOrder* = object
    ## One commanded cog's orders for the next turn.
    cogIndex*: int             ## the live cog this order drives.
    id*: string                ## the hero's anonymous alias, e.g. "KNIGHT-alpha".
    intent*: Intent
    targetX*, targetY*: int    ## clamped into the map box.
    hasFace*: bool
    faceX*, faceY*: int
    say*: string               ## <= MaxSayRunes, sanitized; becomes a SHOUT.

  DirectiveSource* = enum
    dsLlm = "llm"
    dsScripted = "scripted"
    dsFallback = "fallback"

  SquadDirective* = object
    ## One seat's whole order set for one turn.
    note*: string              ## <= MaxNoteRunes; the commander's own line.
    orders*: seq[CogOrder]
    source*: DirectiveSource
    latencyMs*: int

  DirectiveError* = object of ValueError

proc truncateRunes*(text: string, limit: int): string =
  ## Cuts `text` to at most `limit` RUNES, on a rune boundary. The single
  ## place any recorded string is shortened.
  if limit <= 0:
    return ""
  if text.runeLen <= limit:
    return text
  text.runeSubStr(0, limit)

proc sanitizeSay*(text: string): string =
  ## A cog's shout: capped at MaxSayRunes on a rune boundary FIRST, then run
  ## through the starter's printable-ASCII shout sanitiser. Doing it in that
  ## order means the rune cut never leaves half a codepoint for the ASCII
  ## filter to smear.
  result = ""
  for rune in text.truncateRunes(MaxSayRunes).runes:
    let value = int(rune)
    # Braces are excluded deliberately: the replay chat stream carries the
    # paintball CONTROL records as JSON objects and tells them apart from a
    # cog's shout by a leading '{'. A shout that could start with one would
    # make that discrimination ambiguous.
    if value >= 32 and value < 127 and value != ord('{') and
        value != ord('}'):
      result.add($rune)
  result = result.strip()

proc sanitizeNote*(text: string): string =
  ## The commander's own line, as it reaches the replay and the match feed.
  ## Newlines collapse to spaces so one record stays one line.
  text.replace("\n", " ").replace("\r", " ").strip().truncateRunes(MaxNoteRunes)

proc parseIntent*(text: string): tuple[ok: bool, intent: Intent] =
  ## Exact match against the six documented intents; no normalisation or
  ## fallback substitution.
  for intent in Intent:
    if $intent == text:
      return (true, intent)
  (false, intIntercept)

type JsonProposal* = object
  ok*: bool
  node*: JsonNode
  reason*: string

proc parseJsonObject*(body: string): JsonProposal =
  let trimmed = body.strip()
  if trimmed.len == 0:
    return JsonProposal(node: newJNull(), reason: "empty response")
  if trimmed[0] != '{' or trimmed[^1] != '}':
    return JsonProposal(node: newJNull(), reason: "response must be a single JSON object")
  var parser: JsonParser
  parser.open(newStringStream(trimmed), "commander response")
  defer: parser.close()
  parser.next()
  if parser.kind != jsonObjectStart:
    return JsonProposal(node: newJNull(), reason: "response must be a JSON object")
  var depth = 1
  while depth > 0:
    parser.next()
    case parser.kind
    of jsonObjectStart, jsonArrayStart: inc depth
    of jsonObjectEnd, jsonArrayEnd: dec depth
    of jsonError:
      return JsonProposal(node: newJNull(), reason: parser.errorMsg())
    of jsonEof:
      return JsonProposal(node: newJNull(), reason: "unterminated JSON object")
    else: discard
  parser.next()
  if parser.kind != jsonEof:
    return JsonProposal(node: newJNull(), reason: "unexpected trailing content after JSON object")
  try:
    let node = parseJson(trimmed)
    if node.kind != JObject:
      return JsonProposal(node: newJNull(), reason: "response must be a JSON object")
    JsonProposal(ok: true, node: node)
  except CatchableError as e:
    JsonProposal(node: newJNull(), reason: e.msg)

proc jsonProposal*(text: string): JsonProposal =
  ## Accepts exactly one JSON object: bare, or inside a single ordinary outer
  ## Markdown code fence (JSON-tagged or plain). Rejects surrounding prose,
  ## extra objects, and unsupported fence tags.
  let trimmed = text.strip()
  if trimmed.len == 0:
    return JsonProposal(node: newJNull(), reason: "empty response")
  if trimmed.startsWith("```"):
    let firstNl = trimmed.find('\n')
    if firstNl < 0:
      return JsonProposal(node: newJNull(), reason: "unterminated markdown code fence")
    let tag = trimmed[3 ..< firstNl].strip()
    if tag.len > 0 and tag.toLowerAscii() != "json":
      return JsonProposal(node: newJNull(), reason: "unsupported markdown code fence tag")
    let lastNl = trimmed.rfind('\n')
    if lastNl <= firstNl:
      return JsonProposal(node: newJNull(), reason: "unterminated markdown code fence")
    if trimmed[lastNl + 1 .. ^1].strip() != "```":
      return JsonProposal(node: newJNull(), reason: "unexpected content after markdown code fence")
    return parseJsonObject(trimmed[firstNl + 1 ..< lastNl])
  parseJsonObject(trimmed)

proc readCoord(node: JsonNode): tuple[ok: bool, value: int] =
  ## One target/face coordinate: a finite JSON number (int or float).
  if node.isNil:
    return (false, 0)
  case node.kind
  of JInt:
    (true, int(node.getBiggestInt()))
  of JFloat:
    let f = node.getFloat()
    if f != f or f > 1.0e9 or f < -1.0e9: (false, 0)
    else: (true, int(f))
  else:
    (false, 0)

proc readPoint(
  node: JsonNode, maxX, maxY: int
): tuple[ok: bool, x, y: int] =
  ## Strictly a 2-element `[x, y]` array of finite JSON numbers, clamped into
  ## the map box.
  if node.isNil or node.kind != JArray or node.len != 2:
    return (false, 0, 0)
  let
    rx = readCoord(node[0])
    ry = readCoord(node[1])
  if not rx.ok or not ry.ok:
    return (false, 0, 0)
  (true, clamp(rx.value, 0, max(0, maxX)), clamp(ry.value, 0, max(0, maxY)))

type DirectiveProposal* = object
  ok*: bool
  directive*: SquadDirective
  reason*: string

proc parseSquadDirective*(
  payload: JsonNode,
  commandedIds: seq[string],
  commandedCogs: seq[int],
  maxX, maxY: int
): DirectiveProposal =
  ## Validates one parsed directive object strictly against the schema:
  ##
  ## * top-level keys: `cogs` (required), `note` (optional string/null, default "");
  ## * `cogs`: array of exact length `commandedIds.len`, each entry an object;
  ## * per-cog keys: `id` (required exact alias), `intent` (required exact enum),
  ##   `target` (required `[x, y]`), `face` (optional `[x, y]` or null),
  ##   `say` (optional string/null, default "").
  doAssert commandedIds.len == commandedCogs.len
  if payload.isNil or payload.kind != JObject:
    return DirectiveProposal(reason: "directive must be a JSON object")
  for key in payload.keys:
    if key notin ["note", "cogs"]:
      return DirectiveProposal(reason: "unexpected directive field: " & key)
  if payload.hasKey("note") and payload["note"].kind != JNull:
    if payload["note"].kind != JString:
      return DirectiveProposal(reason: "note must be a string")
    result.directive.note = sanitizeNote(payload["note"].getStr())
  result.directive.source = dsLlm

  if not payload.hasKey("cogs") or payload["cogs"].kind != JArray:
    return DirectiveProposal(reason: "directive requires a cogs array")
  let cogsNode = payload["cogs"]
  if cogsNode.len != commandedIds.len:
    return DirectiveProposal(reason: "cogs must contain exactly " & $commandedIds.len & " entry")

  var
    claimed = newSeq[bool](commandedIds.len)
    orders = newSeq[CogOrder](commandedIds.len)
  for item in cogsNode:
    if item.kind != JObject:
      return DirectiveProposal(reason: "each cog order must be an object")
    for key in item.keys:
      if key notin ["id", "intent", "target", "face", "say"]:
        return DirectiveProposal(reason: "unexpected cog order field: " & key)
    if not item.hasKey("id") or item["id"].kind != JString:
      return DirectiveProposal(reason: "cog order requires a string id")
    let id = item["id"].getStr()
    var slot = -1
    for i, mine in commandedIds:
      if not claimed[i] and mine == id:
        slot = i
        break
    if slot < 0:
      return DirectiveProposal(reason: "unknown or duplicate cog id: " & id)
    if not item.hasKey("intent") or item["intent"].kind != JString:
      return DirectiveProposal(reason: "cog order requires a string intent")
    let parsedIntent = parseIntent(item["intent"].getStr())
    if not parsedIntent.ok:
      return DirectiveProposal(reason: "unknown intent: " & item["intent"].getStr())
    if not item.hasKey("target"):
      return DirectiveProposal(reason: "cog order requires target")
    let target = readPoint(item["target"], maxX, maxY)
    if not target.ok:
      return DirectiveProposal(reason: "target must be a [x, y] coordinate pair")
    var hasFace = false
    var faceX = 0
    var faceY = 0
    if item.hasKey("face") and item["face"].kind != JNull:
      let face = readPoint(item["face"], maxX, maxY)
      if not face.ok:
        return DirectiveProposal(reason: "face must be a [x, y] coordinate pair or null")
      hasFace = true
      faceX = face.x
      faceY = face.y
    var say = ""
    if item.hasKey("say") and item["say"].kind != JNull:
      if item["say"].kind != JString:
        return DirectiveProposal(reason: "say must be a string")
      say = sanitizeSay(item["say"].getStr())
    claimed[slot] = true
    orders[slot] = CogOrder(
      cogIndex: commandedCogs[slot],
      id: commandedIds[slot],
      intent: parsedIntent.intent,
      targetX: target.x,
      targetY: target.y,
      hasFace: hasFace,
      faceX: faceX,
      faceY: faceY,
      say: say
    )
  result.directive.orders = orders
  result.ok = true

proc actionJson*(directive: SquadDirective): JsonNode =
  var cogs = newJArray()
  for order in directive.orders:
    var item = %*{
      "id": order.id,
      "intent": $order.intent,
      "target": [order.targetX, order.targetY],
      "say": order.say
    }
    if order.hasFace:
      item["face"] = %[order.faceX, order.faceY]
    else:
      item["face"] = newJNull()
    cogs.add(item)
  %*{"note": directive.note, "cogs": cogs}

proc directiveRecord*(directive: SquadDirective, wave, turn, seat: int,
    alias, role: string): JsonNode =
  ## Preserve the stored replay record's leading discriminant.
  result = %*{"k": "directive", "wave": wave, "turn": turn, "seat": seat,
    "alias": alias, "role": role, "source": $directive.source,
    "latency_ms": directive.latencyMs}
  let action = directive.actionJson()
  result["note"] = action["note"]
  result["cogs"] = action["cogs"]

proc boundedDirectiveRecord*(
  directive: SquadDirective,
  wave, turn, seat: int,
  alias, role: string
): string =
  ## The serialized directive record, guaranteed <= MaxDirectiveRunes. The
  ## note is the only unbounded-in-practice field, so it is the one that
  ## shrinks; the cut still lands on a rune boundary.
  var trimmed = directive
  result = $trimmed.directiveRecord(wave, turn, seat, alias, role)
  var guard = 0
  while result.runeLen > MaxDirectiveRunes and guard < 12:
    inc guard
    let keep = max(0, trimmed.note.runeLen - max(8, trimmed.note.runeLen div 2))
    trimmed.note = trimmed.note.truncateRunes(keep)
    for i in 0 ..< trimmed.orders.len:
      trimmed.orders[i].say = trimmed.orders[i].say.truncateRunes(
        max(0, trimmed.orders[i].say.runeLen - 2))
    result = $trimmed.directiveRecord(wave, turn, seat, alias, role)
  # The loop always converges: with an empty note and empty says the record is
  # a few hundred runes of fixed structure. Never cut the SERIALIZED string —
  # that would emit broken JSON, which is the exact failure the rune rule
  # exists to prevent.
