"""agent/mamidlabs-agent-tools.py icin DNS rebinding korumasi.

URL dogrulanirken cozulen IP adresleri baglanti icin sabitlenir. Aksi halde gercek
baglanti ayri bir DNS sorgusuyla yapilir ve dusuk TTL'li kotu niyetli bir kayit,
dogrulamada genel bir IP, baglantida ozel/yerel bir IP dondurebilir. Sabitlenen host
icin getaddrinfo yalnizca dogrulanmis adresleri dondurur; diger hostlar normal DNS
kullanir.
"""
import importlib.util
import ipaddress
import socket
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]


def _has_internet() -> bool:
    try:
        socket.create_connection(("example.com", 443), timeout=3).close()
        return True
    except OSError:
        return False


requires_internet = pytest.mark.skipif(not _has_internet(), reason="bu makinede internet erisimi yok")


@pytest.fixture
def qat(monkeypatch):
    """mamidlabs-agent-tools.py'yi tirenli dosya adi yuzunden import degil, dosya
    yolundan yukler. Her testten sonra socket.getaddrinfo ve pin tablosu
    gercek modul durumuna geri alinir; modul import-time'da socket.getaddrinfo'yu
    degistirdigi icin testler arasi sizinti onlenir."""
    real_getaddrinfo = socket.getaddrinfo
    spec = importlib.util.spec_from_file_location("qat_under_test", ROOT / "agent" / "mamidlabs-agent-tools.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    try:
        yield module
    finally:
        socket.getaddrinfo = real_getaddrinfo


def test_module_patches_getaddrinfo_at_import_time(qat):
    assert socket.getaddrinfo.__name__ == "_patched_getaddrinfo"


@requires_internet
def test_validating_a_hostname_pins_its_resolved_addresses(qat):
    qat._pinned_addresses.clear()
    qat._validate_remote_url("https://example.com/page")

    assert "example.com" in qat._pinned_addresses
    pinned = qat._pinned_addresses["example.com"]
    assert pinned, "pinlenen adres listesi bos olmamali"


@requires_internet
def test_pinned_host_getaddrinfo_call_returns_exactly_the_validated_addresses(qat):
    """Bu, urllib/http.client'in gercek TCP baglantisi kurarken cagiracagi
    TAM AYNI fonksiyon cagrisidir (socket.create_connection icinde). Sonucun
    pinlenenle birebir ayni olmasi, dogrulama ile baglanti arasindaki DNS
    farkinin kapandigini kanitlar."""
    qat._pinned_addresses.clear()
    qat._validate_remote_url("https://example.com/page")

    result = socket.getaddrinfo("example.com", 443, type=socket.SOCK_STREAM)
    assert result == qat._pinned_addresses["example.com"]


@requires_internet
def test_unrelated_hosts_still_use_real_dns(qat):
    """Pinleme yalnizca dogrulanmis hostlari etkilemeli; DDGS gibi diger
    kutuphanelerin kendi DNS cozumlemesi bozulmamali."""
    qat._pinned_addresses.clear()
    qat._validate_remote_url("https://example.com/page")

    result = socket.getaddrinfo("one.one.one.one", 443, type=socket.SOCK_STREAM)
    assert result, "pinlenmemis host icin gercek DNS calismali"
    assert "one.one.one.one" not in qat._pinned_addresses


def test_private_and_link_local_addresses_are_still_rejected(qat):
    qat._pinned_addresses.clear()
    for url in (
        "http://169.254.169.254/latest/meta-data/",  # bulut metadata, klasik SSRF hedefi
        "http://10.0.0.1/",
        "http://192.168.1.1/",
    ):
        with pytest.raises(ValueError, match="Yerel, ozel veya ayrilmis"):
            qat._validate_remote_url(url)


def test_localhost_is_rejected_before_any_dns_pinning(qat):
    qat._pinned_addresses.clear()
    with pytest.raises(ValueError):
        qat._validate_remote_url("http://127.0.0.1:8080/health")
    # Port kontrolu DNS'ten once calisir; 127.0.0.1 hicbir sekilde pinlenmemeli.
    assert "127.0.0.1" not in qat._pinned_addresses


@requires_internet
def test_redirect_handler_pins_the_new_host_too(qat):
    """Yonlendirme zincirindeki her adim kendi pinlenmis adresine baglanmali;
    yoksa rebinding korumasi yalnizca ilk hostu kapsar."""
    qat._pinned_addresses.clear()
    handler = qat._SafeRedirectHandler()

    class FakeRequest:
        def get_full_url(self):
            return "https://example.com/"

        full_url = "https://example.com/"
        headers = {}
        unverifiable = True

        def get_method(self):
            return "GET"

    try:
        handler.redirect_request(FakeRequest(), None, 302, "Found", {}, "https://example.com/next")
    except Exception:
        pass  # HTTPRedirectHandler ic mantigi eksik alanlarla hata verebilir; onemli olan pinleme.
    assert "example.com" in qat._pinned_addresses
