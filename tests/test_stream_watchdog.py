import json
import shutil
import socket
import struct
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


class DropConnectionMidStreamHandler(BaseHTTPRequestHandler):
    """Bir icerik parcasi gonderip baglantiyi [DONE] olmadan RST ile kapatir.
    Yerel sunucu, arac calisirken (web aramasi, OCR, belge) bos kalan keep-alive
    baglantisini boyle kapatabiliyor; istemci ayni baglantiyi tekrar kullaninca
    akis ortasinda "Varolan bir baglanti ... zorla kapatildi" (WSAECONNRESET)
    hatasi olusuyordu. Elinde yanit metni varken bu artik hata sayilmamali;
    kullaniciya cevabin altinda '[Hata]' gosterilmemeli.

    `send_finish=True` ise once finish_reason parcasi gonderir (cevap TAMAMLANMIS
    demektir), sonra RST ile kapatir. Kullanicinin bildirdigi tam senaryo budur:
    cevap gelir, ardindan baglanti kopar ve hata cevabin ALTINDA belirir."""

    protocol_version = "HTTP/1.1"
    send_finish = False

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        self.wfile.write(
            b"data: "
            + json.dumps({"choices": [{"index": 0, "delta": {"content": "Merhaba"}}]}).encode()
            + b"\n\n"
        )
        if self.send_finish:
            self.wfile.write(
                b"data: "
                + json.dumps({"choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]}).encode()
                + b"\n\n"
            )
        self.wfile.flush()
        # Icerik parcasi istemciye ulasip islensin diye kisa bir bekleme; ardindan
        # [DONE] olmadan RST ile baglanti kopar (gercek senaryoda oldugu gibi:
        # once tokenlar okunur, sonra baglanti duser).
        time.sleep(1.0)
        # SO_LINGER(1,0) ile RST gonder: WSAECONNRESET'in gercekci taklidi.
        self.connection.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
        try:
            self.connection.close()
        except OSError:
            pass
        self.close_connection = True

    def log_message(self, *args):
        pass


def _run_drop_scenario(tmp_path, handler_cls, name):
    pwsh = shutil.which("pwsh")
    if not pwsh:
        pytest.skip("pwsh bulunamadi")
    server = ThreadingHTTPServer(("127.0.0.1", 0), handler_cls)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        script = tmp_path / name
        script.write_text(
            f"""
$job = @{{ messages = @(@{{ role = 'user'; content = 'selam' }}); compactOnly = $true; provider = 'local'; model = 'test'; contextLimit = 32768; maxTokens = 100; agent = $false; internet = $false; office = $false; documentCreate = $false }}
$shared = @{{ Cancel = $false }}
. '{ROOT}\\agent\\qwen-inference.ps1' $job $shared | Out-Null
$endpoint = 'http://127.0.0.1:{server.server_port}/v1/chat/completions'
$script:http = [Net.Http.HttpClient]::new(); $script:http.Timeout = [Threading.Timeout]::InfiniteTimeSpan
$turn = @{{ reasoning = ''; content = ''; usage = $null; toolParts = @{{}}; finishReason = $null }}
$threw = $false
try {{
    Invoke-ChatCompletion @{{ messages = @() }} $shared $false $turn | Out-Null
}} catch {{
    $threw = [string]$_.Exception.GetBaseException().Message
}}
@{{ content = $turn.content; finish = $turn.finishReason; threw = $threw }} | ConvertTo-Json -Compress
""",
            encoding="utf-8-sig",
        )
        result = subprocess.run(
            [pwsh, "-NoProfile", "-NonInteractive", "-File", str(script)],
            capture_output=True, encoding="utf-8", errors="replace", check=False, timeout=60,
        )
    finally:
        server.shutdown()
    assert result.returncode == 0, result.stderr or result.stdout
    return json.loads(result.stdout.strip().splitlines()[-1])


def test_dropped_stream_with_received_text_is_not_reported_as_error(tmp_path):
    got = _run_drop_scenario(tmp_path, DropConnectionMidStreamHandler, "drop.ps1")
    # Alinan metin korunur, akis tamamlanmis sayilir ve disari istisna sizmaz;
    # boylece arayuz cevabin altina '[Hata] ... zorla kapatildi' eklemez.
    assert got["content"] == "Merhaba"
    assert got["finish"] == "connection-closed"
    assert got["threw"] is False


class FinishThenDropHandler(DropConnectionMidStreamHandler):
    """Cevap finish_reason ile tamamlandiktan SONRA baglantiyi RST ile kapatir.
    Kullanicinin bildirdigi tam durum: yanit gelir, hemen ardindan hata cevabin
    altina eklenir. finish_reason zaten geldigi icin bu bir hata DEGILDIR."""

    send_finish = True


def test_dropped_stream_after_finish_reason_is_not_an_error(tmp_path):
    got = _run_drop_scenario(tmp_path, FinishThenDropHandler, "finish-drop.ps1")
    # finish_reason geldigi icin yanit TAMAMLANMIS sayilir; kopma hata gibi
    # gosterilmemeli (aksi halde cevabin altinda '[Hata] ... zorla kapatildi' cikar).
    assert got["content"] == "Merhaba"
    assert got["finish"] == "stop"
    assert got["threw"] is False


