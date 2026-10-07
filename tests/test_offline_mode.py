"""Cevrimdisi (offline) davranis testleri.

Kullanici hikayesi: internet cipi acik gorunurken ag kopsun (telefon hotspot, DNS
zaman asimi) ve model bir web araci cagirsin. Arac katmani cokmemeli, temiz bir
JSON hata dondurmeli; ajan akisi da tamamlanmis sayilip cevabin altina "[Hata]"
eklenmemelidir (akis tarafi: test_stream_watchdog.py).

Bu senaryo, gercek makinede tekrar tekrar gorulen "Varolan bir baglanti ...
zorla kapatildi" (WSAECONNRESET) hatasini besleyen durumdur: cevrimdisi web
aracasi uzun sure bekledigi icin yerel model baglantisi bos kalip kopabiliyordu.
Arac katmaninin cevrimdisi halde temiz davrandigini burada garanti ederiz.
"""
import importlib.util
import json
import os
import socket
import subprocess
import sys
import types
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture
def qat():
    """qwen-agent-tools.py'yi dosya yolundan yukler; import aninda
    socket.getaddrinfo degistirildigi icin testten sonra gercek haline dondurur
    (bkz. test_dns_rebinding_fix ile ayni desen)."""
    real_getaddrinfo = socket.getaddrinfo
    spec = importlib.util.spec_from_file_location("qat_offline", ROOT / "agent" / "qwen-agent-tools.py")
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    try:
        yield module
    finally:
        socket.getaddrinfo = real_getaddrinfo


class _OfflineDDGS:
    """DuckDuckGo'ya ulasilamadiginda ddgs'in firlattigi baglanti hatasinin taklidi
    (gercek makinede gorulen os error 10061 / ConnectError)."""

    def __init__(self, *args, **kwargs):
        pass

    def text(self, *args, **kwargs):
        raise OSError("ConnectError: error sending request for url (os error 10061)")

    def images(self, *args, **kwargs):
        raise OSError("ConnectError: error sending request for url (os error 10061)")


def _install_offline_ddgs(monkeypatch):
    fake = types.ModuleType("ddgs")
    fake.DDGS = _OfflineDDGS
    monkeypatch.setitem(sys.modules, "ddgs", fake)


def test_offline_web_search_returns_clean_error_json(qat, monkeypatch):
    """Ag yokken web aramasi istisna atmaz; modelin gorebilecegi gecerli bir
    hata JSON'u dondurur (aksi halde arac cagrisi donguyu kirardi)."""
    _install_offline_ddgs(monkeypatch)

    out = qat.search_web({"query": "einstein bilmecesi", "count": 5})

    data = json.loads(out)  # istisna yerine gecerli JSON
    assert "error" in data
    assert "basarisiz" in data["error"]


def test_offline_image_search_returns_clean_error_json(qat, monkeypatch):
    """Referans gorsel aramasi da cevrimdisi halde cokmeden hata JSON'u dondurmeli."""
    monkeypatch.setattr(os, "makedirs", lambda *a, **k: None)  # repoya klasor acmasin
    _install_offline_ddgs(monkeypatch)

    out = qat.find_reference_image({"query": "istanbul"})

    data = json.loads(out)
    assert "error" in data
    assert "basarisiz" in data["error"]


def test_offline_fetch_page_returns_clean_error_json(qat, monkeypatch):
    """Sayfa indirme basarisiz olunca (kara delik baglanti) temiz hata JSON'u donmeli."""
    # URL dogrulama DNS'e takilmasin diye gecerli bir adres dondur; asil
    # baglanti hata verince arac temiz JSON dondurmeli.
    monkeypatch.setattr(qat, "_validate_remote_url", lambda url: url)

    def boom(*args, **kwargs):
        raise OSError("baglanti kurulamadi (offline)")

    monkeypatch.setattr(qat, "_open_remote_url", boom)

    out = qat.fetch_page({"url": "https://example.com/sayfa"})

    data = json.loads(out)
    assert "error" in data


def _python_with_ddgs():
    """ddgs'i import edebilen bir Python bulur (kurulu agactaki venv\\app dahil)."""
    candidates = [sys.executable]
    venv = Path(os.path.expandvars(r"%LOCALAPPDATA%\Programs\MamidLabs\venv\app\Scripts\python.exe"))
    if venv.is_file():
        candidates.append(str(venv))
    for exe in candidates:
        try:
            probe = subprocess.run([exe, "-c", "import ddgs"], capture_output=True, timeout=40)
            if probe.returncode == 0:
                return exe
        except Exception:
            continue
    return None


def test_offline_real_tool_process_fails_cleanly():
    """Araci GERCEK alt surecte, kara delik proxy ile calistirir: surec cokmeden
    (exit 0) gecerli bir hata JSON'u dondurmeli. ddgs yoksa atlanir."""
    exe = _python_with_ddgs()
    if not exe:
        pytest.skip("ddgs kurulu bir Python bulunamadi")

    env = dict(os.environ)
    env["HTTP_PROXY"] = "http://127.0.0.1:9"
    env["HTTPS_PROXY"] = "http://127.0.0.1:9"
    payload = json.dumps({"action": "search_web", "query": "offline test", "count": 2})

    proc = subprocess.run(
        [exe, str(ROOT / "agent" / "qwen-agent-tools.py")],
        input=payload, capture_output=True, text=True, encoding="utf-8",
        timeout=150, env=env,
    )

    assert proc.returncode == 0, proc.stderr
    data = json.loads(proc.stdout.strip().splitlines()[-1])
    assert "error" in data
