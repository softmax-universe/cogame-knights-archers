"""Deterministic local release-certification reply fixture for knights-archers."""

import json


def _extract_view(request):
    messages = request.get("messages") or []
    content = ""
    if messages and isinstance(messages[0], dict):
        content = messages[0].get("content") or ""
    if not isinstance(content, str):
        raise ValueError("request messages[0].content must be a string")
    if "\n\n" in content:
        _, candidate = content.split("\n\n", 1)
        try:
            return json.loads(candidate)
        except json.JSONDecodeError:
            pass
    start = content.find("{")
    if start < 0:
        raise ValueError("seat view JSON not found in user message")
    return json.loads(content[start:])


def reply(request, slot):
    """Return one legal JSON directive string for the requested knights-archers seat."""
    view = _extract_view(request)
    you = view["you"]
    hero_id = you["id"]
    target = you.get("choke_post") or you.get("pos") or view["gate"]["centre"]
    action = {
        "note": "hold the gate",
        "cogs": [
            {
                "id": hero_id,
                "intent": "screen",
                "target": [int(target[0]), int(target[1])],
                "face": None,
                "say": "hold",
            }
        ],
    }
    return json.dumps(action)
