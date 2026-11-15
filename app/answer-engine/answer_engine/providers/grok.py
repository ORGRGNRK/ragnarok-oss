"""Grok adapter.

`grok --help` lists machine-readable output formats: json, streaming-json, and
streaming-messages-json. This adapter uses streaming-messages-json, which the
CLI describes as NDJSON in the Messages stream-json shape (assistant content
blocks, tool results, and a terminal result). streaming-json is a separate
native event stream and is not parsed here.
"""

from answer_engine.providers.base import Provider
from answer_engine.providers.claude import resolve_bin
from answer_engine.providers import messages

# Names are the built-in tools the CLI documents, other than web_search and web_fetch.
_REMOVED = ",".join(
    (
        "read_file",
        "search_replace",
        "grep",
        "list_dir",
        "run_terminal_command",
        "todo_write",
        "spawn_subagent",
    )
)


class GrokProvider(Provider):
    name = "grok"

    def new_state(self):
        return messages.new_state()

    def build_command(self, question, workdir):
        return [
            resolve_bin(self.binary),
            "--output-format",
            "streaming-messages-json",
            "--include-partial-messages",
            "--tools",
            "web_search,web_fetch",
            "--disallowed-tools",
            _REMOVED,
            "--no-subagents",
            "--sandbox",
            "strict",
            "--permission-mode",
            "dontAsk",
            "--cwd",
            workdir,
            "--verbatim",
            "-p",
            question,
        ]

    def parse_line(self, obj, state):
        return messages.parse_obj(obj, state)
