"""Paket disi bilesenlerin kaynak/surum/boyut manifestosu.

PowerShell 7, llama.cpp ve CUDA calisma zamani $script:Packages icinde adres ve bayt
boyutuyla tanimlidir; Invoke-Download indirme sonrasi boyutu dogrular. ComfyUI ve
custom node'lar tam commit SHA'sina kilitlenir; boylece farkli tarihlerde yapilan
kurulumlar ayni surumu alir (shallow fetch + checkout FETCH_HEAD).
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read_text(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8-sig")


def test_runtime_packages_carry_source_and_verified_size():
    installer = read_text("scripts/install-mamidlabs.ps1")
    for name in ("pwsh", "llama", "cudart"):
        assert f"{name} = @{{" in installer, f"$script:Packages icinde {name} eksik"
    assert "if ($actual -ne $expectedBytes)" in installer
    assert "Dosya silindi, tekrar calistir." in installer


def test_installer_builds_asr_venv_and_prefetches_models():
    """Ses dökum motoru faster-whisper (Whisper large-v3-tr) + AST'dir. Kurulum venv\\asr
    olusturur ve modelleri HF onbellegine ceker (whisper.cpp ve Qwen3-ASR kaldirildi)."""
    installer = read_text("scripts/install-mamidlabs.ps1")
    assert "venv\\asr" in installer
    assert "oguzhangokboru/whisper-large-v3-tr" in installer
    assert "snapshot_download" in installer
    assert "asr       = { Invoke-Asr }" in installer


def test_comfyui_clone_is_pinned_to_a_specific_commit_not_a_floating_branch():
    installer = read_text("scripts/install-mamidlabs.ps1")
    assert "$script:ComfyCommit = '" in installer
    # 40 karakterlik tam bir git SHA'si olmali, kisa/belirsiz bir referans degil.
    import re
    match = re.search(r"\$script:ComfyCommit = '([0-9a-f]+)'", installer)
    assert match, "ComfyCommit tanimi bulunamadi"
    assert len(match.group(1)) == 40, "kisa/belirsiz commit referansi kullanilmamali"
    # Eski, dala bagli klonlama deseni artik kalmamali.
    assert "git clone --depth 1 $script:ComfyRepo $target" not in installer
    assert "fetch --depth 1 origin $script:ComfyCommit" in installer
    assert "checkout -q FETCH_HEAD" in installer
