"""Medya sonrasi dil modeli geri yuklemesinin sagi (agent/media-model-swap.ps1).

ComfyUI /free ile kendi torch onbellegini bosaltsa bile CUDA baglami ve surucu
tarafi rezervasyon bir sure VRAM tutabilir. Yalnizca torch sayacina bakmak, dil
modelinin paylasilan bellege tasinip ~6 tok/s'ye dusmesine yol acabiliyordu.
Release-Comfy artik gercek bos VRAM'i de dogrular; yetmezse ComfyUI'yi kapatir.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read_text(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8-sig")


def test_release_comfy_verifies_real_free_vram_before_returning():
    swap = read_text("agent/media-model-swap.ps1")
    # Yeni parametre ve nvidia-smi tabanli gercek VRAM olcumu.
    assert "[int]$minFreeMiB = 0" in swap
    assert "function Get-MediaFreeVramMiB" in swap
    assert "--query-gpu=memory.free" in swap
    # torch onbellegi bosalinca bile gercek bos VRAM yetmezse tekrar beklenir.
    assert "if ($null -eq $free -or $free -ge $minFreeMiB) { return }" in swap
    # Yetmezse surec kapatilir (VRAM baglamiyla birlikte serbest kalsin).
    assert "$process.Kill($true)" in swap


def test_image_and_video_release_require_enough_vram_for_the_language_model():
    image = read_text("agent/imagegen-run.ps1")
    video = read_text("agent/videogen-run.ps1")
    for script in (image, video):
        assert "Release-Comfy $comfy $comfyUrl $(if ($lite) { 6000 } else { 14000 })" in script


def test_media_free_vram_helper_returns_null_when_no_nvidia():
    """nvidia-smi yoksa cagiran ek kontrolu atlamali (llama-server asil hatayi verir)."""
    swap = read_text("agent/media-model-swap.ps1")
    helper = swap.split("function Get-MediaFreeVramMiB")[1].split("function Release-Comfy")[0]
    assert "if (!$smi) { return $null }" in helper
