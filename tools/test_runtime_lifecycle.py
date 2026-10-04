"""Initialization owners join before private sealing; upload failures stay loud."""

import base64
import http.server
import json
import os
import signal
import subprocess
import sys
import tempfile
import threading
from pathlib import Path


game = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix="sokoban-runtime-private-") as directory:
    root = Path(directory)
    for mode in ("status", "TERM", "INT", "upload_failure"):
        output = root / mode
        output.mkdir(mode=0o700)
        entered = threading.Event()
        release = threading.Event()
        uploads = []
        raw = b'{"PRIVATE_CONFIG_SENTINEL"'
        partial = mode in ("TERM", "INT")

        class Fixture(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(200 if partial else 503)
                self.send_header("Content-Length", str(len(raw) + (100 if partial else 0)))
                self.end_headers()
                self.wfile.write(raw)
                self.wfile.flush()
                entered.set()
                if partial:
                    release.wait(3)

            def do_PUT(self):
                uploads.append(self.rfile.read(int(self.headers["Content-Length"])))
                self.send_response(503)
                self.send_header("Content-Length", "0")
                self.end_headers()

            def log_message(self, *_args):
                pass

        with http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fixture) as server:
            owner = threading.Thread(target=server.serve_forever)
            owner.start()
            destination = output / "private.jsonl"
            env = os.environ | {
                "COGAME_CONFIG_URI": f"http://127.0.0.1:{server.server_port}/config",
                "COGAME_SAVE_TRAJECTORY_URI": (
                    f"http://127.0.0.1:{server.server_port}/private"
                    if mode == "upload_failure" else destination.as_uri()
                ),
                "COGAME_RESULTS_URI": (output / "results").as_uri(),
                "COGAME_SAVE_REPLAY_URI": (output / "replay").as_uri(),
                "COWORLD_EPISODE_ID": f"sokoban-runtime-{mode}",
                "COWORLD_GAME_VERSION": "source-diagnostic",
                "COWORLD_SOURCE_REVISION": "a" * 40,
                "COWORLD_TIMEOUT_SECONDS": "45",
            }
            process = subprocess.Popen([str(game)], env=env, stdout=subprocess.PIPE,
                                       stderr=subprocess.PIPE, text=True)
            try:
                if partial:
                    assert entered.wait(2)
                    process.send_signal(signal.SIGTERM if mode == "TERM" else signal.SIGINT)
                stdout, stderr = process.communicate(timeout=3)
                assert process.returncode == (1 if mode == "upload_failure" else 0 if partial else 2)
                assert "PRIVATE_CONFIG_SENTINEL" not in stdout + stderr
                if mode == "upload_failure":
                    assert len(uploads) == 1
                    lines = uploads[0].decode().splitlines()
                else:
                    assert destination.stat().st_mode & 0o777 == 0o600
                    lines = destination.read_text().splitlines()
                assert len(lines) == 1
                episode = json.loads(lines[0])
                assert episode["event_type"] == "episode"
                assert episode["status"] == ("truncated" if partial else "failed")
                captures = episode["outcome"]["runtime_inputs"]
                assert len(captures) == 1
                transport = captures[0]["transport"]
                assert transport["response_reader_joined"] is True
                assert transport["response_complete"] is (not partial)
                retained = base64.b64decode(transport["response_body_b64"], validate=True)
                assert raw.startswith(retained) if partial else retained == raw
                assert not (output / "results").exists() and not (output / "replay").exists()
                print(mode, "joined/private-only", flush=True)
            finally:
                if process.poll() is None:
                    process.terminate()
                process.wait(timeout=3)
                release.set()
                server.shutdown()
                owner.join(timeout=3)
                assert not owner.is_alive()
