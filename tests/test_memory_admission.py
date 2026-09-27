"""VRAM'e gore is kabulu (manage-qwen.ps1 Test-MemoryBudget).

Gereken bellek = model dosyasi (+ LITE'ta projektor) + guvenlik payi. Bos VRAM
yetmezse once bostaki ComfyUI kapatilip yeniden olculur; yine yetmezse llama-server
baslatilmaz ve kullaniciya acik bir hata gosterilir. Aksi halde katmanlar Windows'un
paylasilan bellegine tasar ve sohbet kat kat yavaslar.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read_text(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8-sig")


def test_memory_budget_function_exists_and_is_called_before_start():
    manager = read_text("scripts/manage-qwen.ps1")
    assert "function Test-MemoryBudget" in manager
    # Gorsel projektoru de VRAM'e yuklendigi icin butceye dahil edilir.
    assert "try { Test-MemoryBudget $model $Profile $projector }" in manager
    # Yer yoksa once bosta bekleyen ComfyUI kapatilir, sonra bir kez daha olculur;
    # yine de yetmezse ilk hata aynen iletilir.
    assert "if (!(Stop-IdleComfy)) { throw }" in manager
    # Kontrol, dosya varlik kontrollerinden SONRA (model yolu belliyken) ama
    # model sureci baslatilmadan ONCE calismali.
    idx_check = manager.index("Test-MemoryBudget $model $Profile $projector")
    idx_start = manager.index("$child = Start-DetachedProcess $server")
    assert idx_check < idx_start


def test_idle_comfy_is_only_stopped_when_its_queue_is_empty():
    manager = read_text("scripts/manage-qwen.ps1")
    stop = manager.split("function Stop-IdleComfy")[1].split("function Get-ManagedServers")[0]
    assert "http://127.0.0.1:8188/queue" in stop
    assert "@($queue.queue_running).Count -gt 0 -or @($queue.queue_pending).Count -gt 0) { return $false }" in stop


def test_memory_budget_uses_measured_free_vram_and_estimated_need():
    manager = read_text("scripts/manage-qwen.ps1")
    assert "memory.free" in manager
    assert "(Get-Item -LiteralPath $modelPath).Length" in manager
    assert "$freeMiB -lt $neededMiB" in manager


def test_memory_budget_skips_cleanly_when_no_nvidia_gpu():
    """nvidia-smi yoksa (AMD/Intel GPU veya surucu kurulu degil) kontrol
    sessizce atlanmali - kurulumu engellememeli, asil hatayi llama-server
    zaten verecektir."""
    manager = read_text("scripts/manage-qwen.ps1")
    assert "if (!$smi) { return }" in manager


def test_start_action_accepts_skip_memory_check_switch():
    manager = read_text("scripts/manage-qwen.ps1")
    assert "[switch]$SkipMemoryCheck" in manager


def test_max_budget_fits_a_16_gb_card():
    """RTX 5060 Ti 16 GB'ta olculdu: yuklemeden once ~15008 MiB bos, MAX dil
    modeli dosyasi 14600 MiB, GPU'daki gercek kullanim ~14640 MiB. Eski +2560
    MiB pay 17160+ MiB isteyip MAX'i hedef donaniminda hic acmiyordu."""
    import re

    manager = read_text("scripts/manage-qwen.ps1")
    match = re.search(r"\$overheadMiB = (-?\d+)\s*$", manager, re.MULTILINE)
    assert match, "overheadMiB satiri bulunamadi"
    measured_free_mib = 15008
    max_model_mib = 14600
    assert max_model_mib + int(match.group(1)) <= measured_free_mib


def test_max_projector_runs_on_cpu_and_stays_out_of_vram_budget():
    """mmproj F16 GPU'da 1133 MiB ister; dil modeliyle birlikte 16 GB karti
    tasirip paylasilan bellege dusuruyordu (sohbet 19,6 tok/s, gorsel 56 sn).
    CPU'da: sohbet 24,8 tok/s, gorsel 30 sn."""
    manager = read_text("scripts/manage-qwen.ps1")
    assert "'--mmproj', $projector, '--no-mmproj-offload'" in manager
    assert "$profileName -eq 'lite' -and $projectorPath" in manager
