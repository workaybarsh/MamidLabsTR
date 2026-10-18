"""Model indirme butunlugu.

agent/profiles.json'daki her satir bir Hugging Face commit'ine (revision) ve bayt
boyutuna sabitlenir. agent/hf-hub.py indirme sonrasi (ve dosya zaten varsa) gercek
boyutu dogrular; indirilen dosyanin SHA256 ozetini de Hugging Face'in LFS ozetiyle
(ya da katalogdaki istege bagli ``sha256`` alaniyla) karsilastirir. Ozet uyusmazsa
dosya silinir ve net hata verilir. Yarim indirme ``hf_hub_download`` tarafindan
kaldigi yerden surdurulur; isci bunu durum satirinda bildirir.
"""
import hashlib
import importlib.util
import json
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
# hf-hub.py, mtp_inject'i kardes modul olarak import eder; tek dosya kosumunda da bulunsun.
_AGENT = str(ROOT / "agent")
if _AGENT not in sys.path:
    sys.path.insert(0, _AGENT)


def read_text(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8-sig")


def load_profiles() -> list[dict]:
    return json.loads((ROOT / "agent/profiles.json").read_text(encoding="utf-8"))["profiles"]


def load_hub(name: str = "hf_hub_under_test"):
    """hf-hub.py'yi yukler ve testler aga cikmasin diye HF ozet sorgusunu kapatir."""
    spec = importlib.util.spec_from_file_location(name, ROOT / "agent/hf-hub.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.lookup_sha256 = lambda item, token: None
    return module


def test_every_downloadable_catalog_entry_has_a_pinned_revision():
    for profile in load_profiles():
        for file in profile["files"]:
            if not file.get("repo"):
                continue  # elle kurulacak dosyalar (repo bos)
            assert file.get("revision"), (
                f"{profile['id']}/{file['label']}: repo dolu ama revision yok "
                "(main dalina bagli kalir, repo sahibi dosyayi degistirirse sessizce farkli bir "
                "dosya inecek)"
            )


def test_profile_catalog_passes_bytes_into_the_download_job():
    catalog = read_text("agent/profile-catalog.ps1")
    assert "bytes = [long]$file.bytes" in catalog


def test_profile_catalog_passes_optional_sha256_into_the_download_job():
    catalog = read_text("agent/profile-catalog.ps1")
    assert "sha256 = [string]$file.sha256" in catalog, (
        "katalogda sha256 varsa indirme isine gecmeli (cevrimdisi dogrulama)"
    )


def test_sha256_file_matches_hashlib(tmp_path):
    target = tmp_path / "data.bin"
    target.write_bytes(b"mamidlabs" * 1000)
    module = load_hub("hf_hub_sha_file")
    assert module.sha256_file(target) == hashlib.sha256(target.read_bytes()).hexdigest()


def test_hf_hub_verifies_size_after_download(tmp_path):
    target = tmp_path / "model.gguf"

    def fake_hf_hub_download(**kwargs):
        target.write_bytes(b"x" * 10)
        return str(target)

    module = load_hub()
    module.hf_hub_download = fake_hf_hub_download

    ok_item = {"repo": "r", "filename": "f", "target": str(target), "bytes": 10}
    module.fetch(ok_item, None, 1, 1)  # boyut eslesiyor, hata beklenmiyor
    assert target.exists()

    target.unlink()
    bad_item = {"repo": "r", "filename": "f", "target": str(target), "bytes": 999}
    with pytest.raises(ValueError, match="uyuşmuyor"):
        module.fetch(bad_item, None, 1, 1)
    assert not target.exists(), "bozuk indirme diskte kalmamali"


def test_hf_hub_verifies_size_of_already_present_file(tmp_path):
    target = tmp_path / "existing.gguf"
    target.write_bytes(b"x" * 5)

    module = load_hub("hf_hub_existing_size")
    bad_item = {"repo": "r", "filename": "f", "target": str(target), "bytes": 999}
    with pytest.raises(ValueError, match="uyuşmuyor"):
        module.fetch(bad_item, None, 1, 1)
    assert target.exists(), "mevcut dosya sessizce silinmemeli; kullanici karar versin"


def test_hf_hub_rejects_download_with_wrong_sha256(tmp_path):
    target = tmp_path / "model.gguf"
    data = b"bozuk icerik"

    module = load_hub("hf_hub_sha_bad")
    module.hf_hub_download = lambda **kwargs: (target.write_bytes(data), str(target))[1]
    item = {
        "repo": "r",
        "filename": "f.gguf",
        "target": str(target),
        "bytes": len(data),
        "sha256": "0" * 64,
    }
    with pytest.raises(ValueError, match="SHA256"):
        module.fetch(item, None, 1, 1)
    assert not target.exists(), "SHA256 uyusmayan dosya silinmeli"


def test_hf_hub_accepts_download_with_matching_sha256(tmp_path):
    target = tmp_path / "model.gguf"
    data = b"dogru icerik"
    events = []

    module = load_hub("hf_hub_sha_ok")
    module.emit = lambda kind, text: events.append((kind, text))
    module.hf_hub_download = lambda **kwargs: (target.write_bytes(data), str(target))[1]
    item = {
        "repo": "r",
        "filename": "f.gguf",
        "target": str(target),
        "bytes": len(data),
        "sha256": hashlib.sha256(data).hexdigest().upper(),
    }
    module.fetch(item, None, 1, 1)
    assert target.exists()
    assert any("SHA256" in text for _, text in events), "dogrulanan ozet bildirilmeli"


def test_existing_file_with_wrong_pinned_sha256_is_reported_not_deleted(tmp_path):
    target = tmp_path / "existing.gguf"
    target.write_bytes(b"x" * 5)

    module = load_hub("hf_hub_existing_sha")
    item = {"repo": "r", "filename": "f", "target": str(target), "bytes": 5, "sha256": "0" * 64}
    with pytest.raises(ValueError, match="SHA256"):
        module.fetch(item, None, 1, 1)
    assert target.exists(), "mevcut dosya sessizce silinmemeli"


def test_hf_hub_reports_partial_download_and_continues(tmp_path):
    target = tmp_path / "f.gguf"
    cache = target.parent / ".cache" / "huggingface" / "download"
    cache.mkdir(parents=True)
    (cache / "f.gguf.incomplete").write_bytes(b"x" * (2 * 1024 * 1024))
    events = []

    module = load_hub("hf_hub_resume")
    module.emit = lambda kind, text: events.append((kind, text))
    module.hf_hub_download = lambda **kwargs: (target.write_bytes(b"y" * 10), str(target))[1]

    module.fetch({"repo": "r", "filename": "f.gguf", "target": str(target), "bytes": 10}, None, 1, 1)
    assert target.exists()
    assert any("kaldığı yerden" in text and "2 MB" in text for _, text in events), (
        "yarim indirme kaldigi yerden surdurulmeli ve bildirilmeli"
    )
