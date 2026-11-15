"""The adapter interface.

build_command returns the argv for one question.
parse_line turns one JSON object from that process into zero or more events.
Event types are thinking, tool_call, tool_result, answer, error, and done.
Done is added by the runner, not by an adapter.
"""


class Provider:
    name = ""

    def __init__(self, binary):
        self.binary = binary

    def build_command(self, question, workdir):
        raise NotImplementedError

    def new_state(self):
        return {}

    def parse_line(self, obj, state):
        raise NotImplementedError
