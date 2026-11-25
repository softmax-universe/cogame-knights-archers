# Writing a knights-archers prompt

A player policy receives its own private decision view and returns one ordinary
squad directive. The same player image supports scripted and prompt
policies. Model calls happen inside the player container.

```bash
coworld upload-policy coworld-knights-archers:latest \
  --name my-warden \
  --run /bin/knights-archers-player \
  --secret-env PLAYER_PROMPT="<your strategy, in plain English>"
```

`PLAYER_SCRIPTED=phalanx` or `PLAYER_SCRIPTED=stand` makes a seat play a
published baseline instead. A seat that sets neither plays `phalanx`.

## What the model is asked

Once every 4 seconds of sim time, the game sends all four seats their private
observations from one pre-action state. A prompt player combines its own
`PLAYER_PROMPT`, the rules for its role, and that observation before calling
Claude. No seat sees another's current-turn order or operator prompt.

## What it must answer

```json
{"note": "archers hold the choke, I take the north lane",
 "cogs": [{"id": "KNIGHT-alpha", "intent": "intercept", "target": [820, 300],
           "face": [900, 290], "say": "north"}]}
```

| field | cap / rule | default / bounds |
|---|---|---|
| `note` | optional string, ≤ 160 runes | defaults to `""`; truncated on a rune boundary; newlines collapse |
| `cogs` | required array with exactly 1 entry — your own hero | wrong length or non-array is rejected |
| `cogs[].id` | required exact match to your own alias | wrong or missing id is rejected |
| `cogs[].intent` | required; exact one of `intercept` `hold` `screen` `focus` `fall_back` `regroup` | unknown or non-exact intent is rejected |
| `cogs[].target` | required `[x, y]` pair of finite JSON numbers | clamped to the map box; missing or malformed is rejected |
| `cogs[].face` | optional `[x, y]` pair of finite JSON numbers, or `null` | defaults to `null` (controller aims); clamped to the map box; malformed is rejected |
| `cogs[].say` | optional string, ≤ 10 runes | defaults to `""`; truncated, then printable-ASCII filtered. It is a REAL in-game shout every hero within 247 px hears. |

Parsing is strict: reply with exactly one JSON object, either bare or inside a
single outer Markdown code fence (` ``` ` or ` ```json `). Surrounding prose,
extra JSON objects, legacy wrapper shapes, unknown fields, and invalid field
values are rejected. Missing or rejected replies get one retry; after a second
failure the seat receives no directive for that turn (its hero stands idle) and
a `fallback` record in the replay names the cause.

## What actually wins

- **The line, not the kill count.** A cleared wave is worth 20 kills, and a wave
  that ends at 0:08 to a careless knight banks whatever it had. Your score is
  the squad's score.
- **Distance is the archer's whole role.** A zombie inside 90 px charges, and it
  covers 144 px inside one turn. An archer that walks toward its target is
  usually walking into the thing that kills it.
- **A knight is not invulnerable.** It kills once every 0.9 seconds and dies to
  one touch. Three bodies at once is a losing trade even for a mace.
- **Say what you are about to do.** All four decide simultaneously, so `say` is
  the only way two seats avoid taking the same zombie.

The two shipped champions are worked examples:

- **`knights-archers-warden`** holds a LINE and never chases. Lanes are split by
  y; knights intercept the leader in their own half; archers focus from 300–450
  px and fall back the moment anything is inside 200 px.
- **`knights-archers-volley`** kills the leader first, together: both archers
  focus the same zombie every turn (two arrows in one second is a kill; two
  arrows on two zombies is two wounded zombies), while the knights screen it.
