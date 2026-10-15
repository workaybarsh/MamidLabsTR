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
import ipaddress
import json
import os
import socket
import subprocess
import sys
import threading
import time
import types
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture
def qat():
    """mamidlabs-agent-tools.py'yi dosya yolundan yukler; import aninda
    socket.getaddrinfo degistirildigi icin testten sonra gercek haline dondurur
    (bkz. test_dns_rebinding_fix ile ayni desen)."""
    real_getaddrinfo = socket.getaddrinfo
    spec = importlib.util.spec_from_file_location("qat_offline", ROOT / "agent" / "mamidlabs-agent-tools.py")
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
        [exe, str(ROOT / "agent" / "mamidlabs-agent-tools.py")],
        input=payload, capture_output=True, text=True, encoding="utf-8",
        timeout=150, env=env,
    )

    assert proc.returncode == 0, proc.stderr
    data = json.loads(proc.stdout.strip().splitlines()[-1])
    assert "error" in data


# --- Oynak ag dayanikliligi: D1 (gorsel arama timeout), D4 (DNS timeout),
# --- D5 (search_web toplam deadline). Asagidaki testler gercek ag beklemeden
# --- ilgili dallari hizli ve deterministik bicimde kapsar.

def test_image_search_uses_an_explicit_ddgs_timeout(qat, monkeypatch):
    """D1: find_reference_image gorsel aramasi da acik timeout almali; aksi
    halde ddgs varsayilanina bagli kalir (search_web ile ayni desen)."""
    monkeypatch.setattr(os, "makedirs", lambda *a, **k: None)  # repoya klasor acmasin
    captured = {}

    class RecordingDDGS:
        def __init__(self, *args, **kwargs):
            captured.update(kwargs)

        def images(self, *args, **kwargs):
            return []  # sonuc yok: uygun gorsel bulunamadi yoluna duser

    fake = types.ModuleType("ddgs")
    fake.DDGS = RecordingDDGS
    monkeypatch.setitem(sys.modules, "ddgs", fake)

    out = qat.find_reference_image({"query": "istanbul"})

    data = json.loads(out)
    assert "error" in data
    assert captured.get("timeout") == 15


def test_pin_resolution_pins_the_validated_address(qat, monkeypatch):
    """D4: pinning davranisi korunur; cozumleme is parcaciginda yapilsa da
    dogrulanan adresler aynen saklanir."""
    qat._pinned_addresses.clear()
    fake = [(socket.AF_INET, socket.SOCK_STREAM, 6, "", ("93.184.216.34", 443))]
    monkeypatch.setattr(qat, "_real_getaddrinfo", lambda *a, **k: fake)

    addresses = qat._pin_resolution("example.com", 443)

    assert addresses == [ipaddress.ip_address("93.184.216.34")]
    assert qat._pinned_addresses["example.com"] == fake


def test_pin_resolution_propagates_dns_errors(qat, monkeypatch):
    """D4: getaddrinfo hatasi is parcacigindan cagirana aynen iletilir (mevcut
    hata akisi bozulmaz)."""
    def failing(*args, **kwargs):
        raise socket.gaierror("getaddrinfo failed")

    monkeypatch.setattr(qat, "_real_getaddrinfo", failing)

    with pytest.raises(OSError):
        qat._pin_resolution("broken.invalid", 443)


def test_pin_resolution_times_out_instead_of_blocking(qat, monkeypatch):
    """D4: yavas DNS'te _pin_resolution suresiz bloke olmamali; timeout'ta
    OSError yukseltmeli (istisna sizmaz)."""
    monkeypatch.setattr(qat, "DNS_TIMEOUT_SECONDS", 0.1)
    release = threading.Event()

    def hanging(*args, **kwargs):
        release.wait(5)
        return []

    monkeypatch.setattr(qat, "_real_getaddrinfo", hanging)
    try:
        with pytest.raises(OSError):
            qat._pin_resolution("slow-dns.invalid", 443)
    finally:
        release.set()


def test_dns_timeout_returns_clean_error_json_from_fetch_page(qat, monkeypatch):
    """D4: DNS zaman asimi istisna sizdirmaz; arac temiz hata JSON'u dondurur."""
    monkeypatch.setattr(qat, "DNS_TIMEOUT_SECONDS", 0.1)
    release = threading.Event()

    def hanging(*args, **kwargs):
        release.wait(5)
        return []

    monkeypatch.setattr(qat, "_real_getaddrinfo", hanging)
    try:
        out = qat.fetch_page({"url": "https://slow-dns-host.invalid/sayfa"})
    finally:
        release.set()

    data = json.loads(out)
    assert "error" in data


def test_search_web_returns_backend_results(qat, monkeypatch):
    """D5: zaman asimina ugramayan normal akista sonuclar aynen doner."""
    class FastDDGS:
        def __init__(self, *args, **kwargs):
            pass

        def text(self, *args, **kwargs):
            return [{"title": "a", "href": "https://a.example"}]

    fake = types.ModuleType("ddgs")
    fake.DDGS = FastDDGS
    monkeypatch.setitem(sys.modules, "ddgs", fake)

    out = qat.search_web({"query": "hizli", "count": 2})

    assert json.loads(out) == [{"title": "a", "href": "https://a.example"}]


def test_search_web_deadline_caps_total_time(qat, monkeypatch):
    """D5: takilan bir backend toplam sureyi sinirlamamali; deadline'da cagri
    hizli doner ve (sonuc yoksa) gecerli hata JSON'u uretir."""
    monkeypatch.setattr(qat, "SEARCH_DEADLINE_SECONDS", 0.2)
    release = threading.Event()

    class HangingDDGS:
        def __init__(self, *args, **kwargs):
            pass

        def text(self, *args, **kwargs):
            release.wait(5)
            return []

    fake = types.ModuleType("ddgs")
    fake.DDGS = HangingDDGS
    monkeypatch.setitem(sys.modules, "ddgs", fake)

    start = time.monotonic()
    out = qat.search_web({"query": "takilan", "count": 3})
    elapsed = time.monotonic() - start
    release.set()

    data = json.loads(out)
    assert "error" in data
    assert elapsed < 3  # backend 5 sn beklese de deadline toplam sureyi sinirladi


def test_search_web_deadline_returns_partial_results(qat, monkeypatch):
    """D5: deadline asilirken elde edilmis sonuc varsa kalan backend'ler
    beklenmeden o sonuclar dondurulur."""
    monkeypatch.setattr(qat, "SEARCH_DEADLINE_SECONDS", 0.5)
    release = threading.Event()

    class PartialDDGS:
        def __init__(self, *args, **kwargs):
            pass

        def text(self, *args, **kwargs):
            yield {"title": "kismi", "href": "https://kismi.example"}
            release.wait(5)

    fake = types.ModuleType("ddgs")
    fake.DDGS = PartialDDGS
    monkeypatch.setitem(sys.modules, "ddgs", fake)

    out = qat.search_web({"query": "kismi", "count": 3})
    release.set()

    assert json.loads(out) == [{"title": "kismi", "href": "https://kismi.example"}]
