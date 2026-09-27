"""Model indirme butunlugu.

agent/profiles.json'daki her satir bir Hugging Face commit'ine (revision) ve bayt
boyutuna sabitlenir. agent/hf-hub.py indirme sonrasi (ve dosya zaten varsa) gercek
boyutu dogrular; uyusmazlikta dosyayi siler ve hata verir. Start-ProfileDownload
beklenen boyutu indirme isine gecirir.
"""
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read_text(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8-sig")


def load_profiles() -> list[dict]:
    return json.loads((ROOT / "agent/profiles.json").read_text(encoding="utf-8"))["profiles"]


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


def test_hf_hub_verifies_size_after_download(tmp_path):
    target = tmp_path / "model.gguf"

    def fake_hf_hub_download(**kwargs):
        target.write_bytes(b"x" * 10)
        return str(target)

    import importlib.util
    spec = importlib.util.spec_from_file_location("hf_hub_under_test", ROOT / "agent/hf-hub.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.hf_hub_download = fake_hf_hub_download

    ok_item = {"repo": "r", "filename": "f", "target": str(target), "bytes": 10}
    module.fetch(ok_item, None, 1, 1)  # boyut eslesiyor, hata beklenmiyor
    assert target.exists()

    target.unlink()
    bad_item = {"repo": "r", "filename": "f", "target": str(target), "bytes": 999}
    try:
        module.fetch(bad_item, None, 1, 1)
        raise AssertionError("boyut uyusmazliginda hata beklenirdi")
    except ValueError as exc:
        assert "uyuşmuyor" in str(exc)
    assert not target.exists(), "bozuk indirme diskte kalmamali"


def test_hf_hub_verifies_size_of_already_present_file(tmp_path):
    target = tmp_path / "existing.gguf"
    target.write_bytes(b"x" * 5)

    import importlib.util
    spec = importlib.util.spec_from_file_location("hf_hub_under_test2", ROOT / "agent/hf-hub.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)

    bad_item = {"repo": "r", "filename": "f", "target": str(target), "bytes": 999}
    try:
        module.fetch(bad_item, None, 1, 1)
        raise AssertionError("diskteki yarim/bozuk dosya icin hata beklenirdi")
    except ValueError as exc:
        assert "uyuşmuyor" in str(exc)
    assert target.exists(), "mevcut dosya sessizce silinmemeli; kullanici karar versin"
