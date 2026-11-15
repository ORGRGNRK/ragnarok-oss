"""Provider adapters. One module each, one shared event shape."""

from answer_engine.providers.claude import ClaudeProvider
from answer_engine.providers.codex import CodexProvider
from answer_engine.providers.grok import GrokProvider

_MAKERS = {
    "claude": ClaudeProvider,
    "codex": CodexProvider,
    "grok": GrokProvider,
}


def make_provider(name, bins):
    maker = _MAKERS.get(name)
    if maker is None:
        return None
    return maker(bins.get(name) or name)
