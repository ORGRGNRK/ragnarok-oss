"""Plain-language notice when a provider did not share thinking."""

NOTICE = "This AI did not share its thinking"


def thinking_notice(events):
    for event in events or []:
        if not isinstance(event, dict):
            continue
        if event.get("type") != "thinking":
            continue
        if event.get("kind") == "summary":
            continue
        if event.get("text"):
            return ""
    return NOTICE
