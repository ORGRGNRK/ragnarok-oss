"""Claude Code adapter.

Flags come from `claude --help` for the installed CLI. stream-json with --print
requires --verbose. The command is not launched by the tests.
"""

import os
import shutil

from answer_engine.providers.base import Provider
from answer_engine.providers import messages

EMPTY_MCP = '{"mcpServers":{}}'


def resolve_bin(name):
    if not name:
        return name
    if os.path.sep in name:
        return name
    found = shutil.which(name)
    return found or name


class ClaudeProvider(Provider):
    name = "claude"

    def new_state(self):
        return messages.new_state()

    def build_command(self, question, workdir):
        # workdir is the empty temp directory the process is started in.
        # Claude also confines restricted file tools to that directory.
        del workdir
        return [
            resolve_bin(self.binary),
            "-p",
            "--output-format",
            "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--tools",
            "WebSearch,WebFetch",
            "--allowedTools",
            "WebSearch,WebFetch",
            "--permission-mode",
            "dontAsk",
            "--permission-prompts",
            "none",
            "--safe-mode",
            "--restricted",
            "--disable-slash-commands",
            "--strict-mcp-config",
            "--mcp-config",
            EMPTY_MCP,
            "--no-session-persistence",
            "--",
            question,
        ]

    def parse_line(self, obj, state):
        return messages.parse_obj(obj, state)
