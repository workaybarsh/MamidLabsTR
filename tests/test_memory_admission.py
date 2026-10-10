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
    assert "Test-MemoryBudget $model $Profile $projector" in manager
    # Tek GPU sahibi: varsayilan davranista bizim CUDA baglamimiz (ComfyUI) olcumden
    # once kapatilir (comfyKeepAlive=false). Bkz. test_comfy_keep_alive_*.
    assert "[void](Stop-IdleComfy)" in manager
    # Kontrol, dosya varlik kontrollerinden SONRA (model yolu belliyken) ama
    # model sureci baslatilmadan ONCE calismali; ComfyUI kapatma da olcumden once.
    idx_comfy = manager.index("[void](Stop-IdleComfy)")
    idx_check = manager.index("Test-MemoryBudget $model $Profile $projector")
    idx_start = manager.index("$child = Start-DetachedProcess $server")
    assert idx_comfy < idx_check < idx_start


def test_comfy_keep_alive_setting_defaults_to_open():
    """settings/api.json -> comfyKeepAlive. Varsayilan true: ComfyUI acik tutulur; medya
    isleri arasinda yeniden acilma (~15-20 sn) olmaz. Sohbet ~%11 yavaslar (olculdu
    49,7 -> 44,2 tok/s) ama TASMA OLMAZ: GPU tampon yerlesimi iki durumda da birebir ayni
    (CPU_Mapped 644 MiB, CUDA0 model 13945 MiB; graph splits 2). false ile tam hiz."""
    manager = read_text("scripts/manage-qwen.ps1")
    assert "$comfyKeepAlive = $true" in manager
    assert "$settings.comfyKeepAlive" in manager
    # Kapali tutma yalnizca ayar kapaliyken kosulsuz uygulanir.
    assert "if (!$comfyKeepAlive) { [void](Stop-IdleComfy) }" in manager
    # Ayar acikken yer yetmezse guvenlik icin yine de kapatilip tekrar olculur.
    assert "if ($comfyKeepAlive -and (Stop-IdleComfy)) { Test-MemoryBudget $model $Profile $projector }" in manager


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


def test_memory_budget_tolerates_small_overflow_for_mtp_grown_lite():
    """MTP basligi eklenince LITE modeli ~464 MiB buyur; 8 GB kartta kontrol artik
    'sigmaz' deyip modeli hic acmiyordu ("Model islemi basarisiz"). Gercekte llama.cpp
    buyuk gomme tensorunu CPU'da tutup kucuk asimi kaldirir (olculdu: ~165 MiB asimda
    model yuklendi, ~41 tok/s). LITE'ta kucuk asim engellenmemeli."""
    manager = read_text("scripts/manage-qwen.ps1")
    assert "$toleranceMiB = if ($profileName -eq 'lite') { 1024 } else { 0 }" in manager
    assert "if ($freeMiB -lt ($neededMiB - $toleranceMiB))" in manager
    # Kucuk asimda kullanici uyarilir ama yukleme surer.
    assert "Write-Warning" in manager


def test_max_tolerance_is_tighter_than_lite_to_prevent_shared_memory_spill():
    """16 GB MAX/FLASH'ta tolerans 0'dır: 27B model kartın sınırında çalışır ve
    ~185 MiB'lik küçük bir aşım bile MTP draft bağlamını CPU'ya taşıyıp üretimi
    ~6-7 tok/s'ye düşürüyordu. LITE'ta geniş tolerans korunur."""
    manager = read_text("scripts/manage-qwen.ps1")
    line = next(
        (l for l in manager.splitlines() if "$toleranceMiB = if" in l), ""
    )
    assert line, "profil-farkinda tolerans satiri bulunamadi"
    assert "{ 1024 } else { 0 }" in line
    # Ifade yalnizca 'lite' icin 1024 verir; diger (16 GB) profiller 0 alir.
    assert "$profileName -eq 'lite'" in line


def test_max_budget_fits_a_16_gb_card():
    """RTX 5060 Ti 16 GB'ta ölçüldü: temiz GPU'da (ComfyUI kapalı) 27B model 15244 MiB
    boş VRAM ile yüklendi ve ~45 tok/s çalıştı; dosya 14600 MiB olduğundan gerçek pay
    ~600 MiB'dır. Eski 800/1000 MiB paylar (eşik 15400/15600) bu durumu yanlış reddedip
    "Model işlemi başarısız" hatası veriyordu. Asıl koruma paydan çok ComfyUI'nin her
    zaman kapatılmasıdır: başka bir CUDA bağlamı varken 15290 MiB boş VRAM bile taşıp
    ~6 tok/s'ye düşürüyordu."""
    import re

    manager = read_text("scripts/manage-qwen.ps1")
    match = re.search(r"\$overheadMiB = if \(\$profileName -eq 'lite'\) \{ (\d+) \} else \{ (\d+) \}", manager)
    assert match, "profil-farkinda overheadMiB satiri bulunamadi"
    overhead = int(match.group(2))  # else dali = MAX/FLASH
    assert overhead == 600
    max_model_mib = 14600
    measured_free_ok = 15244  # temiz GPU'da 45 tok/s ile yuklendi
    needed = max_model_mib + overhead  # 15200
    # Model bu boş değerle yüklenebilmeli...
    assert needed <= measured_free_ok
    # ...ama eski 800 MiB'lik pay (eşik 15400) makineyi yanlış reddediyordu.
    assert needed < max_model_mib + 800


def test_lite_budget_is_not_tightened_by_the_max_fix():
    """Kök neden düzeltmesi (pay artışı, tolerans 0) yalnızca 16 GB profillerine
    uygulanmalı. LITE 8 GB kartta zaten sınırda çalışır ve küçük aşımı llama.cpp
    (token_embd CPU'da) kaldırır; pay orada büyütülürse çalışan LITE kurulumu boşa
    reddedilirdi. Bu yüzden LITE payı 300 MiB ve toleransı 1024 kalmalı."""
    import re

    manager = read_text("scripts/manage-qwen.ps1")
    match = re.search(r"\$overheadMiB = if \(\$profileName -eq 'lite'\) \{ (\d+) \} else \{ (\d+) \}", manager)
    assert match, "profil-farkinda overheadMiB satiri bulunamadi"
    assert int(match.group(1)) == 300, "LITE payi buyutulmus (LITE kurulumu bozulur)"
    tol = next((l for l in manager.splitlines() if "$toleranceMiB = if" in l), "")
    assert "{ 1024 } else { 0 }" in tol


def test_max_projector_runs_on_cpu_and_stays_out_of_vram_budget():
    """mmproj F16 GPU'da 1133 MiB ister; dil modeliyle birlikte 16 GB karti
    tasirip paylasilan bellege dusuruyordu (sohbet 19,6 tok/s, gorsel 56 sn).
    CPU'da: sohbet 24,8 tok/s, gorsel 30 sn."""
    manager = read_text("scripts/manage-qwen.ps1")
    assert "'--mmproj', $projector, '--no-mmproj-offload'" in manager
    assert "$profileName -eq 'lite' -and $projectorPath" in manager
