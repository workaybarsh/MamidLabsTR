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


def test_whisper_binary_skip_detects_release_subfolder():
    """whisper ikilileri arsivde 'Release' alt klasorune acilir. Skip kosulu ozyinelemeli
    aramali; dogrudan yola bakarsa hic tutmaz ve her kurulumda 662 MB ikili yeniden iner."""
    installer = read_text("scripts/install-mamidlabs.ps1")
    assert "Get-ChildItem -LiteralPath $target -Recurse -Filter 'whisper-cli.exe'" in installer


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
