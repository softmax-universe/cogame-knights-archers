## Strict directive parsing, single-object JSON / outer Markdown fence rules,
## and the RUNE discipline.
##
## Every cap in the reply schema is measured in RUNES and every truncation
## lands on a rune boundary. Slicing a string by BYTE index anywhere on the
## path to the replay is forbidden: a byte-truncated multi-byte character
## renders fine in a browser and then fails a strict UTF-8 parser.

import
  std/[json, strutils, unicode],
  kaz/[sim, directives]

proc check(condition: bool, what: string) =
  if not condition:
    echo "FAIL: ", what
    quit(1)

const Ids = @["KNIGHT-alpha"]
const Cogs = @[0]

proc parseOne(text: string): SquadDirective =
  let json = jsonProposal(text)
  doAssert json.ok, "expected JSON to parse: " & json.reason
  let parsed = parseSquadDirective(json.node, Ids, Cogs, 1234, 658)
  doAssert parsed.ok, "expected directive to parse: " & parsed.reason
  parsed.directive

proc parseFails(text: string): bool =
  let json = jsonProposal(text)
  if not json.ok: return true
  not parseSquadDirective(json.node, Ids, Cogs, 1234, 658).ok

block bareAndSingleOuterMarkdownFencesAccepted:
  let bare = parseOne(
    """{"note":"north lane","cogs":[{"id":"KNIGHT-alpha","intent":"intercept","target":[820,300],"face":[900,290],"say":"north"}]}""")
  check(bare.orders.len == 1, "one order")
  check(bare.orders[0].intent == intIntercept, "intent parsed")
  check(bare.orders[0].targetX == 820 and bare.orders[0].targetY == 300,
    "target parsed")
  check(bare.orders[0].hasFace and bare.orders[0].faceX == 900 and
    bare.orders[0].faceY == 290, "face parsed")
  check(bare.orders[0].say == "north", "say parsed")
  check(bare.note == "north lane", "note parsed")

  let jsonFenced = parseOne("""```json
{"note":"north lane","cogs":[{"id":"KNIGHT-alpha","intent":"intercept",
 "target":[820,300],"face":[900,290],"say":"north"}]}
```""")
  check(jsonFenced.orders[0].intent == intIntercept, "intent survived json fence")
  check(jsonFenced.orders[0].targetX == 820, "target survived json fence")

  let plainFenced = parseOne("""```
{"cogs":[{"id":"KNIGHT-alpha","intent":"hold","target":[500,240]}]}
```""")
  check(plainFenced.orders[0].intent == intHold, "intent survived plain fence")
  check(plainFenced.note == "", "optional note defaults to empty")
  check(not plainFenced.orders[0].hasFace, "optional face defaults to none")
  check(plainFenced.orders[0].say == "", "optional say defaults to empty")

block surroundingProseAndExtraObjectsRejected:
  check(parseFails("""Sure! Here is my order:
```json
{"note":"north lane","cogs":[{"id":"KNIGHT-alpha","intent":"intercept","target":[820,300]}]}
```
Hope that helps."""), "prose around fenced JSON must be rejected")
  check(parseFails("""Here is my move: {"cogs":[{"id":"KNIGHT-alpha","intent":"hold","target":[500,240]}]}"""),
    "leading prose before bare JSON must be rejected")
  check(parseFails("""{"cogs":[{"id":"KNIGHT-alpha","intent":"hold","target":[500,240]}]} thanks!"""),
    "trailing prose after bare JSON must be rejected")
  check(parseFails("""{"cogs":[{"id":"KNIGHT-alpha","intent":"hold","target":[500,240]}]} {"cogs":[{"id":"KNIGHT-alpha","intent":"screen","target":[600,240]}]}"""),
    "multiple bare JSON objects must be rejected")
  check(parseFails("""```json
{"cogs":[{"id":"KNIGHT-alpha","intent":"hold","target":[500,240]}]}
{"cogs":[{"id":"KNIGHT-alpha","intent":"screen","target":[600,240]}]}
```"""), "multiple JSON objects inside one fence must be rejected")
  check(parseFails("""```json
{"cogs":[{"id":"KNIGHT-alpha","intent":"hold","target":[500,240]}]}
```
```json
{"cogs":[{"id":"KNIGHT-alpha","intent":"screen","target":[600,240]}]}
```"""), "multiple fenced JSON objects must be rejected")
  check(parseFails("""```python
{"cogs":[{"id":"KNIGHT-alpha","intent":"hold","target":[500,240]}]}
```"""), "non-json fence tag must be rejected")

block legacyShapesAndAliasesRejected:
  check(parseFails(
    """{"cogs":{"KNIGHT-alpha":{"intent":"hold","target":[500,240]}}}"""),
    "id-keyed cogs object shim must be rejected")
  check(parseFails("""{"intent":"hold","target":[500,240],"say":"choke"}"""),
    "bare order object without cogs wrapper must be rejected")
  check(parseFails("""{"note":"hold the choke","intent":"screen","target":[600,300]}"""),
    "bare order object with note must be rejected")
  check(parseFails("""{"note":"thinking about it"}"""),
    "note with no cogs must be rejected")
  check(parseFails("""{"cogs":[{"id":"KNIGHT-alpha","intent":"hold","target":{"x":500,"y":240}}]}"""),
    "object target {x,y} shim must be rejected")
  check(parseFails("""{"cogs":[{"id":"KNIGHT-alpha","intent":"hold","target":[500,240]}],"extra":1}"""),
    "unexpected top-level field must be rejected")
  check(parseFails("""{"cogs":[{"id":"KNIGHT-alpha","intent":"hold","target":[500,240],"legacy":1}]}"""),
    "unexpected cog field must be rejected")

block aTargetInsideAWallIsClampedNeverRejected:
  let corner = parseOne(
    """{"cogs":[{"id":"KNIGHT-alpha","intent":"hold","target":[0,0]}]}""")
  check(corner.orders.len == 1, "a target inside the border wall is accepted")
  check(corner.orders[0].targetX == 0 and corner.orders[0].targetY == 0,
    "it is passed through to the control layer, which snaps it")
  let offMap = parseOne(
    """{"cogs":[{"id":"KNIGHT-alpha","intent":"hold","target":[99999,-5]}]}""")
  check(offMap.orders[0].targetX == 1234 and offMap.orders[0].targetY == 0,
    "an off-map target is clamped to the map box")

block intentsAreStrict:
  check(not parseIntent("FALL-BACK").ok, "hyphenated intent must be rejected")
  check(not parseIntent("  Fall Back ").ok, "spaced intent must be rejected")
  check(not parseIntent("HOLD").ok, "uppercase intent must be rejected")
  check(not parseIntent("charge!").ok, "unknown intent must be rejected")
  check(parseFails("""{"cogs":[{"id":"KNIGHT-alpha","intent":"charge!","target":[500,240]}]}"""),
    "unknown intent must reject directive")
  for intent in Intent:
    let parsed = parseIntent($intent)
    check(parsed.ok and parsed.intent == intent, $intent & " must round-trip")

block coordinatesAreValidatedStrictly:
  check(parseFails("""{"cogs":[{"id":"KNIGHT-alpha","intent":"hold"}]}"""),
    "missing target must be rejected")
  check(parseFails(
    """{"cogs":[{"id":"KNIGHT-alpha","intent":"hold","target":["oops","nope"]}]}"""),
    "non-numeric target must be rejected")
  check(parseFails(
    """{"cogs":[{"id":"KNIGHT-alpha","intent":"hold","target":["820.4","300"]}]}"""),
    "numeric string target shim must be rejected")
  check(parseFails(
    """{"cogs":[{"id":"KNIGHT-alpha","intent":"hold","target":[820,300,1]}]}"""),
    "3-element target array must be rejected")
  check(parseFails(
    """{"cogs":[{"id":"KNIGHT-alpha","intent":"hold","target":[820,300],"face":["bad","pair"]}]}"""),
    "malformed face must be rejected")
  let noFace = parseOne(
    """{"cogs":[{"id":"KNIGHT-alpha","intent":"hold","target":[500,240],"face":null}]}""")
  check(not noFace.orders[0].hasFace, "a null face is no face")

block extraWrongAndEmptyEntriesRejected:
  check(parseFails("""{"cogs":[
    {"id":"KNIGHT-alpha","intent":"hold","target":[500,240]},
    {"id":"KNIGHT-beta","intent":"screen","target":[500,240]}]}"""),
    "extra cogs entries must be rejected")
  check(parseFails(
    """{"cogs":[{"id":"ARCHER-beta","intent":"screen","target":[600,200]}]}"""),
    "entry naming another seat must be rejected")
  check(parseFails(
    """{"cogs":[{"id":"alpha","intent":"screen","target":[600,200]}]}"""),
    "suffix-only id must be rejected")
  check(parseFails("""{"note":"nothing","cogs":[]}"""),
    "an empty cogs array must be rejected")
  check(parseFails("no json here at all"), "no object must be rejected")

block runeCapsLandOnRuneBoundaries:
  ## A `say` whose 10th and 11th characters are a 4-byte emoji: the cut must
  ## land on the RUNE boundary and the result must still round-trip through
  ## parseJson and decode as UTF-8.
  let emoji = "\u{1F9DF}"                     ## 4 bytes, 1 rune
  let say = "123456789" & emoji & emoji
  check(say.runeLen == 11, "the fixture must be 11 runes")
  let a = parseOne("""{"cogs":[{"id":"KNIGHT-alpha","intent":"hold","target":[500,240],"say":""" &
    escapeJsonUnquoted(say).escapeJson() & """}]}""")
  check(a.orders[0].say.runeLen <= MaxSayRunes,
    "say is " & $a.orders[0].say.runeLen & " runes, cap is " & $MaxSayRunes)
  check(a.orders[0].say.validateUtf8() < 0,
    "the truncated say must still be valid UTF-8")
  let long = "æ".repeat(300)
  let b = parseOne("""{"note":""" & escapeJsonUnquoted(long).escapeJson() &
    ""","cogs":[{"id":"KNIGHT-alpha","intent":"hold","target":[500,240]}]}""")
  check(b.note.runeLen == MaxNoteRunes,
    "note is " & $b.note.runeLen & " runes, cap is " & $MaxNoteRunes)
  check(b.note.validateUtf8() < 0, "the truncated note must be valid UTF-8")
  discard parseJson($( %*{"note": b.note} ))

block truncateRunesNeverSplitsACodepoint:
  let text = "æøå\u{1F9DF}ﬁ"
  for limit in 0 .. text.runeLen + 3:
    let cut = text.truncateRunes(limit)
    check(cut.validateUtf8() < 0,
      "truncateRunes(" & $limit & ") produced invalid UTF-8")
    check(cut.runeLen == min(limit, text.runeLen),
      "truncateRunes(" & $limit & ") gave " & $cut.runeLen & " runes")

block theSanitizersHoldTheirContracts:
  check(sanitizeSay("{braces}") == "braces",
    "braces are stripped: the chat stream tells a record from a shout by '{'")
  check(sanitizeNote("two\nlines\r\nhere").find('\n') < 0,
    "newlines collapse so one record stays one line")

block theRecordStaysUnderItsRuneCap:
  var directive = parseOne(
    """{"cogs":[{"id":"KNIGHT-alpha","intent":"focus","target":[900,300],
       "say":"north"}]}""")
  directive.note = "æøå".repeat(200)
  let record = directive.boundedDirectiveRecord(
    1, 7, 0, "KNIGHT-alpha", RoleKnight)
  check(record.runeLen <= MaxDirectiveRunes,
    "the record is " & $record.runeLen & " runes, cap is " &
      $MaxDirectiveRunes)
  check(record.validateUtf8() < 0, "the record must be valid UTF-8")
  let node = parseJson(record)
  check(node["k"].getStr() == "directive", "it must still be a directive")
  check(node["alias"].getStr() == "KNIGHT-alpha", "the alias is carried")
  check(node["role"].getStr() == RoleKnight, "the role is carried")

echo "test_directives: ok"
