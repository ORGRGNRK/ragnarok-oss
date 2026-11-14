"""Offline: fixloop.ollama records the model name Ollama REPORTS in its answers (a stub server here)."""
import json
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer

from fixloop import ollama
from fixloop.config import settings


class Stub(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if self.path == "/api/embed":
            out = {"model": "nomic-embed-text:latest", "embeddings": [[0.1, 0.2]]}
        else:
            out = {"model": body["model"] + "-as-served\n", "message": {"content": "ok"}}
        data = json.dumps(out).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


class ReportedModel(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.srv = HTTPServer(("127.0.0.1", 0), Stub)
        threading.Thread(target=cls.srv.serve_forever, daemon=True).start()
        cls.old = settings.ollama_host
        object.__setattr__(settings, "ollama_host", "http://127.0.0.1:%d" % cls.srv.server_port)

    @classmethod
    def tearDownClass(cls):
        object.__setattr__(settings, "ollama_host", cls.old)
        cls.srv.shutdown()

    def test_embed_and_chat_record_the_reported_name(self):
        self.assertEqual(ollama.embed("E x", kind="query"), [0.1, 0.2])
        self.assertEqual(ollama.reported["embed"], "nomic-embed-text:latest")
        self.assertEqual(ollama.chat("s", "u"), "ok")
        name = settings.coder_model + "-as-served"          # control characters stripped
        self.assertEqual(ollama.reported["chat"], name)
        ollama.chat("s", "u")
        self.assertEqual(ollama.chat_models_reported().count(name), 1)   # listed once

    def test_name_cleaning(self):
        self.assertIsNone(ollama._name(None))
        self.assertIsNone(ollama._name("  "))
        self.assertEqual(len(ollama._name("m" * 500)), 200)


if __name__ == "__main__":
    unittest.main()
