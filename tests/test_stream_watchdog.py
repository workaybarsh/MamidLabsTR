import json
import shutil
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]


class FinishedButOpenHandler(BaseHTTPRequestHandler):
    """Yaniti finish_reason ile bitirir ama [DONE] gondermez ve baglantiyi acik tutar
    (gercek arayuz testinde goruldu: is ~5 dk isletim sistemi zaman asimini bekledi)."""

    protocol_version = "HTTP/1.1"

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        for chunk in (
            {"choices": [{"index": 0, "delta": {"content": "Merhaba"}}]},
            {"choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]},
        ):
            self.wfile.write(b"data: " + json.dumps(chunk).encode() + b"\n\n")
            self.wfile.flush()
        time.sleep(60)

    def log_message(self, *args):
        pass


def test_finished_stream_that_never_closes_does_not_hang(tmp_path):
    pwsh = shutil.which("pwsh")
    if not pwsh:
        pytest.skip("pwsh bulunamadi")
    server = ThreadingHTTPServer(("127.0.0.1", 0), FinishedButOpenHandler)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        script = tmp_path / "watchdog.ps1"
        script.write_text(
            f"""
$job = @{{ messages = @(@{{ role = 'user'; content = 'selam' }}); compactOnly = $true; provider = 'local'; model = 'test'; contextLimit = 32768; maxTokens = 100; agent = $false; internet = $false; office = $false; documentCreate = $false }}
$shared = @{{ Cancel = $false }}
. '{ROOT}\\agent\\qwen-inference.ps1' $job $shared | Out-Null
$endpoint = 'http://127.0.0.1:{server.server_port}/v1/chat/completions'
# compactOnly cikisinda betik kendi HttpClient'ini kapatir.
$script:http = [Net.Http.HttpClient]::new(); $script:http.Timeout = [Threading.Timeout]::InfiniteTimeSpan
$turn = @{{ reasoning = ''; content = ''; usage = $null; toolParts = @{{}}; finishReason = $null }}
$sw = [Diagnostics.Stopwatch]::StartNew()
Invoke-ChatCompletion @{{ messages = @() }} $shared $false $turn | Out-Null
@{{ content = $turn.content; finish = $turn.finishReason; seconds = $sw.Elapsed.TotalSeconds }} | ConvertTo-Json -Compress
""",
            encoding="utf-8-sig",
        )
        result = subprocess.run(
            [pwsh, "-NoProfile", "-NonInteractive", "-File", str(script)],
            capture_output=True, encoding="utf-8", errors="replace", check=False, timeout=90,
        )
    finally:
        server.shutdown()
    assert result.returncode == 0, result.stderr or result.stdout
    got = json.loads(result.stdout.strip().splitlines()[-1])
    assert got["content"] == "Merhaba"
    assert got["finish"] == "stop"
    assert got["seconds"] < 15, got
