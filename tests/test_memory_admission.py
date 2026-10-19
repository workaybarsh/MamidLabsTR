"""VRAM'e gore is kabulu (manage-mamidlabs.ps1 Test-MemoryBudget).

Gereken bellek = model dosyasi + guvenlik payi; gorsel projektoru (mmproj) artik
uc profilde de CPU'da (--no-mmproj-offload) oldugundan VRAM butcesine girmez. Bos
VRAM yetmezse once bostaki ComfyUI kapatilip yeniden olculur; yine yetmezse
llama-server baslatilmaz ve kullaniciya acik bir hata gosterilir. Aksi halde
katmanlar Windows'un paylasilan bellegine tasar ve sohbet kat kat yavaslar.
"""
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]


def read_text(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8-sig")


def run_pwsh_functions(script: str) -> str:
    """PowerShell fonksiyonlarini gercek pwsh'ta calistirir (manage-mamidlabs.ps1'den AST ile
    cikarilan fonksiyonlar `Get-Functions` prelude'u ile yuklenir)."""
    import shutil
    import subprocess

    pwsh = shutil.which("pwsh")
    if not pwsh:
        pytest.skip("PowerShell 7 is unavailable")
    prelude = r"""
$ErrorActionPreference = 'Stop'
function Get-Functions([string]$path) {
    $tokens=$null; $errs=$null
    $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errs)
    if ($errs.Count) { throw ($errs | Out-String) }
    return (($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.FunctionDefinitionAst] } | ForEach-Object { $_.Extent.Text }) -join "`n")
}
"""
    proc = subprocess.run(
        [pwsh, "-NoProfile", "-Command", prelude + script],
        capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=60,
    )
    if proc.returncode != 0:
        raise AssertionError(f"pwsh basarisiz oldu: {proc.stderr}")
    return proc.stdout


def test_memory_budget_function_exists_and_is_called_before_start():
    manager = read_text("scripts/manage-mamidlabs.ps1")
    assert "function Test-MemoryBudget" in manager
    # Projektor butceye GIRMEZ: uc profilde de CPU'da calisir.
    assert "Test-MemoryBudget $model $Profile $projector $candidate" in manager
    # Tek GPU sahibi: bizim CUDA baglamimiz (ComfyUI) olcumden once ele alinir. Varsayilan
    # acik tutmak; mukerrer/kacak varsa kapatilir; butce yetmezse kapatilip tekrar olculur.
    # Bkz. test_idle_comfy_is_kept_open_but_leaks_are_cleaned.
    assert "[void](Stop-IdleComfy)" in manager
    # Kontrol, dosya varlik kontrollerinden SONRA (model yolu belliyken) ama
    # model sureci baslatilmadan ONCE calismali; ComfyUI kapatma da olcumden once.
    idx_comfy = manager.index("[void](Stop-IdleComfy)")
    idx_check = manager.index("Test-MemoryBudget $model $Profile $projector $candidate")
    idx_start = manager.index("$child = Start-DetachedProcess $server")
    assert idx_comfy < idx_check < idx_start


def test_idle_comfy_policy_is_profile_aware():
    """ComfyUI yasam dongusu. VARSAYILAN KAPALI: ComfyUI yalnizca medya uretiminde calisir,
    is bitince ve dil modeli yuklenmeden once kapatilir — bosta VRAM/RAM tutmaz. Gerekce:
    LITE hedef makinesi 8 GB VRAM / 16 GB RAM; 9B model kartin sinirinda, ComfyUI baglami
    tasirir. 16 GB'ta LITE isteyen `comfyKeepAlive=true` ile acik tutabilir; MAX/FLASH her
    durumda kapatir. API modunda betik cagrilmaz, ComfyUI acik kalir. Kaçak/mukerrer once temizlenir."""
    manager = read_text("scripts/manage-mamidlabs.ps1")
    # Varsayilan KAPALI: ComfyUI yalnizca medya uretiminde calisir; bosta VRAM/RAM tutmaz.
    assert "$comfyKeepAlive = $false" in manager
    assert "$settings.comfyKeepAlive" in manager
    # Kacak temizligi korunur (tek saglikli ornek korunur).
    assert "function Get-ComfyInstanceRoots" in manager
    assert "function Stop-ComfyLeaks" in manager
    assert "[void](Stop-ComfyLeaks)" in manager
    # Profil duyarli kapatma: MAX/FLASH her zaman, LITE ayara birakilir.
    assert "if (!$comfyKeepAlive -or $Profile -ne 'lite') { [void](Stop-IdleComfy) }" in manager
    # Butce yetmezse kapatip tekrar dene (guvenlik agi korunur); ASR/OCR sonrasi WDDM
    # VRAM'i gec birakabildigi icin kontrol sinirli kez yeniden denenir (yalnizca son
    # denemede hata verilir).
    assert "if ($attempt -eq 1 -and (Stop-IdleComfy)) { continue }" in manager
    assert "if (!$budgetOk) { throw $lastBudgetError }" in manager


def test_idle_comfy_is_only_stopped_when_its_queue_is_empty():
    manager = read_text("scripts/manage-mamidlabs.ps1")
    stop = manager.split("function Stop-IdleComfy")[1].split("function Get-ManagedServers")[0]
    assert "http://127.0.0.1:8188/queue" in stop
    assert "@($queue.queue_running).Count -gt 0 -or @($queue.queue_pending).Count -gt 0) { return $false }" in stop


def test_memory_budget_uses_measured_free_vram_and_estimated_need():
    manager = read_text("scripts/manage-mamidlabs.ps1")
    assert "memory.free" in manager
    assert "(Get-Item -LiteralPath $modelPath).Length" in manager
    assert "$freeMiB -lt $neededMiB" in manager


def test_memory_budget_skips_cleanly_when_no_nvidia_gpu():
    """nvidia-smi yoksa (AMD/Intel GPU veya surucu kurulu degil) kontrol
    sessizce atlanmali - kurulumu engellememeli, asil hatayi llama-server
    zaten verecektir."""
    manager = read_text("scripts/manage-mamidlabs.ps1")
    assert "if (!$smi) { return }" in manager


def test_start_action_accepts_skip_memory_check_switch():
    manager = read_text("scripts/manage-mamidlabs.ps1")
    assert "[switch]$SkipMemoryCheck" in manager


def test_memory_budget_tolerates_small_overflow_for_mtp_grown_lite():
    """MTP basligi LITE modelini ~464 MiB buyutur; 8 GB kartta kontrol 'sigmaz' deyip
    modeli hic acmiyordu ("Model islemi basarisiz"). Gercekte llama.cpp buyuk gomme
    tensorunu CPU'da tutup kucuk asimi kaldirir. Projektor CPU'ya alininca (~636 MiB
    VRAM bosalir) model 7249/8188 MiB'ye yerlesir (708 MiB bos) ve asim olmadan yuklenir;
    LITE'ta kucuk asim yine de engellenmemeli."""
    manager = read_text("scripts/manage-mamidlabs.ps1")
    assert "$toleranceMiB = if ($profileName -eq 'lite') { 1024 } else { 0 }" in manager
    assert "if ($freeMiB -lt ($neededMiB - $toleranceMiB))" in manager
    # Kucuk asimda kullanici uyarilir ama yukleme surer.
    assert "Write-Warning" in manager


def test_max_tolerance_is_tighter_than_lite_to_prevent_shared_memory_spill():
    """16 GB MAX/FLASH'ta tolerans 0'dır: 27B model kartın sınırında çalışır ve
    ~185 MiB'lik küçük bir aşım bile MTP draft bağlamını CPU'ya taşıyıp üretimi
    ~6-7 tok/s'ye düşürüyordu. LITE'ta geniş tolerans korunur."""
    manager = read_text("scripts/manage-mamidlabs.ps1")
    line = next(
        (l for l in manager.splitlines() if "$toleranceMiB = if" in l), ""
    )
    assert line, "profil-farkinda tolerans satiri bulunamadi"
    assert "{ 1024 } else { 0 }" in line
    # Ifade yalnizca 'lite' icin 1024 verir; diger (16 GB) profiller 0 alir.
    assert "$profileName -eq 'lite'" in line


def test_max_budget_margin_is_context_aware_and_prevents_spill():
    """RTX 5060 Ti 16 GB'ta 27B icin llama.cpp'nin kendi raporu + gercek nvidia-smi olcumleri
    (dedicated+shared): 15112 MiB @8192, 15324 @16384, ~15770 @32768. Bu uc olcum TEK bir
    dogru uzerindedir: ayak izi ~= 14878 + 0,02722*ctx. Eski kod 16K/32K icin SABIT pay
    (800/1200) kullaniyordu; ayni dogru uzerinde kaliyordu ama ARADA KALAN baglamlari reddedip
    bos VRAM birakiyordu. Artik pay dogrusal (taban 278 MiB + 1K token basina 27,9 MiB), yani
    16K'da 800, 32K'da 1200'e denk gelir — olcumlerle birebir."""
    import re

    manager = read_text("scripts/manage-mamidlabs.ps1")
    assert "function Get-ModelOverheadMiB" in manager
    m = re.search(r"return \[int\]\[math\]::Ceiling\((\d+) \+ \(\$ctx / 1024\.0\) \* ([\d.]+)\)", manager)
    assert m, "dogrusal pay formulu bulunamadi"
    base, per_k = int(m.group(1)), float(m.group(2))
    model_mib = 14600

    def needed(ctx):
        return model_mib + base + (ctx / 1024.0) * per_k

    # Olculen ayak izleriyle uyum (paylasilan bellege tasma siniri).
    assert abs(needed(16384) - 15324) <= 20, needed(16384)
    assert abs(needed(32768) - 15770) <= 20, needed(32768)
    assert abs(needed(8192) - 15112) <= 20, needed(8192)
    # Normal masaustunde (15497 bos) 16K SIGAR, 32K SIGMAZ (eskiden tasiyordu).
    free_normal_desktop = 15497
    assert needed(16384) <= free_normal_desktop < needed(32768)


def test_max_flash_context_is_computed_from_measured_free_vram():
    """MAX/FLASH baglami artik 16K/32K kaba adimlari yerine OLCULEN bos VRAM'den hesaplanir
    (2K adimlari, guvenlik payi 100 MiB). Boylece bos VRAM bosa harcanmaz: 15,5 GiB'de ~20K,
    15,9 GiB'de ~39K secilir. Kapi yine kademeli kucultmeyle dogrular; secilen baglam HEM
    bellek kapisina HEM --ctx-size'a verilir. LITE sabit baglamini korur."""
    manager = read_text("scripts/manage-mamidlabs.ps1")
    assert "function Get-MaxContextForProfile" in manager
    fn = manager.split("function Get-MaxContextForProfile")[1].split("function ")[0]
    assert "memory.free" in fn
    assert "$safetyMiB = 100" in fn
    assert "[math]::Floor($maxCtx / 2048) * 2048" in fn
    assert "if ($maxCtx -lt 4096) { return 0 }" in fn
    # Secim: dinamik aday + kademeli kucultme; LITE ayri dal.
    assert "$dynamicCtx = Get-MaxContextForProfile $Profile" in manager
    assert "$ctxCandidates = @($dynamicCtx)" in manager
    assert "foreach ($fallback in @(32768, 24576, 16384, 12288, 8192, 4096))" in manager
    assert "foreach ($candidate in $ctxCandidates)" in manager
    assert "if ($chosenCtx) { $modelCtx = $chosenCtx; $budgetOk = $true; break }" in manager
    assert "'--ctx-size', \"$modelCtx\", '--predict', $predict, '--parallel', '1'" in manager
    # LITE sabit baglamini korur (dinamik hesap yalnizca MAX/FLASH).
    assert "if ($Profile -eq 'lite') {" in manager and "$ctxCandidates = @([int]$liteCtx)" in manager


def test_lite_budget_is_not_tightened_by_the_max_fix():
    """Bağlam-duyarli pay (ve 32K -> 16K düşüşü) yalnızca 16 GB profillerine uygulanmalı.
    LITE 8 GB kartta sınırda çalışır ve küçük aşımı llama.cpp (token_embd CPU'da) kaldırır;
    pay orada büyütülürse çalışan LITE kurulumu boşa reddedilirdi. Bu yüzden LITE payı
    300 MiB ve toleransı 1024 kalmalı."""
    manager = read_text("scripts/manage-mamidlabs.ps1")
    assert "if ($profileName -eq 'lite') { return 300 }" in manager
    tol = next((l for l in manager.splitlines() if "$toleranceMiB = if" in l), "")
    assert "{ 1024 } else { 0 }" in tol


def test_projector_runs_on_cpu_and_stays_out_of_vram_budget():
    """MAX/FLASH: mmproj F16 GPU'da 1133 MiB ister; dil modeliyle birlikte 16 GB
    karti tasirip paylasilan bellege dusuruyordu (sohbet 19,6 tok/s, gorsel 56 sn).
    CPU'da: sohbet 24,8 tok/s, gorsel 30 sn. LITE: Q8_0 mmproj 595 MiB GPU'da
    8 GB karta sigmiyor ve buyuk gomme tensorunu CPU'ya itiyordu; CPU'da VRAM
    7249/8188 MiB'ye iner (708 MiB bos), sohbet hizi degismez. Bu yuzden UC
    profilde de mmproj CPU'da calisir ve VRAM butcesine girmez."""
    manager = read_text("scripts/manage-mamidlabs.ps1")
    # Iki profil blogunnda da --no-mmproj-offload kullaniliyor (LITE + MAX/FLASH).
    assert manager.count("'--mmproj', $projector, '--no-mmproj-offload'") >= 2
    # Lite butcesi artik projektoru model boyutuna EKLEMEZ (CPU'da, VRAM'e girmez).
    assert "$profileName -eq 'lite' -and $projectorPath" not in manager
    assert "$modelMiB += [math]::Ceiling((Get-Item -LiteralPath $projectorPath).Length / 1MB)" not in manager


def test_orphan_app_gpu_workers_are_cleaned_before_model_load():
    """Model yuklenmeden ONCE uygulamaya ait artik GPU isçileri (bosta kalmis kalici ses
    iscisi `whisper-tools.py --serve` ve OCR iscisi `ocr-tools.py`) otomatik kapatilir.
    Cokme/zorla kapatma sonrasi kalan CUDA baglamlari (~140-600 MiB) dil modelinin ince
    payini yiyip "yetersiz VRAM" hatasina yol acabiliyordu. Temizlik YALNIZCA kurulum koku
    altindaki surecleri hedefler; baska uygulamalara dokunulmaz."""
    manager = read_text("scripts/manage-mamidlabs.ps1")
    assert "function Get-AppGpuWorkers" in manager
    assert "function Stop-OrphanWorkers" in manager
    # GPU isçisi betikleri hedeflenir (ses + OCR); ComfyUI kendi yasam dongusunde (main.py).
    assert "(whisper-tools|ocr-tools)" in manager
    # Butce kontrolunden ONCE calisir (model sureci baslatilmadan once VRAM temizligi).
    idx_clean = manager.index("[void](Stop-OrphanWorkers)")
    idx_check = manager.index("Test-MemoryBudget $model $Profile $projector $candidate")
    assert idx_clean < idx_check


def test_orphan_worker_selection_only_matches_app_gpu_workers():
    """Davranis (gercek pwsh): Get-AppGpuWorkers YALNIZCA kurulum koku altindaki
    python'lardan calisan ses/OCR isçilerini secer; baska koke ait python'u, ComfyUI'yi ve
    GPU kullanmayan araclari (mamidlabs-agent-tools.py) dislar."""
    script = r"""
$root = 'C:\fake\root'
function Get-CimInstance { param([string]$Class, [string]$Filter, $ErrorAction) $script:fake }
. ([scriptblock]::Create((Get-Functions 'MANAGER_PATH')))
$script:fake = @(
  [pscustomobject]@{ ProcessId=111; ExecutablePath='C:\fake\root\venv\asr\Scripts\python.exe'; CommandLine='"C:\fake\root\venv\asr\Scripts\python.exe" "C:\fake\root\agent\whisper-tools.py" --serve' },
  [pscustomobject]@{ ProcessId=222; ExecutablePath='C:\fake\root\venv\ocr\Scripts\python.exe'; CommandLine='"C:\fake\root\venv\ocr\Scripts\python.exe" "C:\fake\root\agent\ocr-tools.py"' },
  [pscustomobject]@{ ProcessId=333; ExecutablePath='C:\Other\python.exe'; CommandLine='whisper-tools.py' },
  [pscustomobject]@{ ProcessId=444; ExecutablePath='C:\fake\root\venv\app\Scripts\python.exe'; CommandLine='"C:\fake\root\agent\mamidlabs-agent-tools.py"' },
  [pscustomobject]@{ ProcessId=555; ExecutablePath='C:\fake\root\venv\imagegen\Scripts\python.exe'; CommandLine='C:\fake\root\ComfyUI\main.py' }
)
(Get-AppGpuWorkers | ForEach-Object { [int]$_.ProcessId } | Sort-Object) -join ','
"""
    script = script.replace("MANAGER_PATH", str(ROOT / "scripts" / "manage-mamidlabs.ps1"))
    out = run_pwsh_functions(script)
    assert out.strip() == "111,222", out
