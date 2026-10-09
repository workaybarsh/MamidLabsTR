# Dil modelini VRAM'den bosaltma, ComfyUI'yi baslatma/yeniden kullanma ve uretim
# sonrasi dil modelini geri yukleme akisinin tek sahibi. imagegen-run.ps1 ve
# videogen-run.ps1 ayni kodu buradan kullanir.
#
# Cagiran dosyada bir 'Emit([string]$kind, [string]$text, $data = $null)'
# fonksiyonu tanimli olmalidir; asagidaki fonksiyonlar durum mesajlarini onun
# uzerinden gonderir.

. (Join-Path $PSScriptRoot 'process-launch.ps1')
. (Join-Path $PSScriptRoot 'media-paths.ps1')

function Stop-LocalModelForMedia([string]$manage) {
    Emit 'status' 'Dil modeli VRAM''den bosaltiliyor...'
    & $manage -Action stop | Out-Null
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    while ([DateTime]::UtcNow -lt $deadline -and @(Get-Process -Name 'llama-server' -ErrorAction SilentlyContinue).Count -gt 0) {
        Start-Sleep -Milliseconds 300
    }
}

# ComfyUI'yi her iste sifirdan acmak ~20 sn suruyor (8 GB VRAM / 16 GB RAM
# makinede olculdu; bu surede VRAM'e hicbir sey yuklenmez). Bu yuzden basarili isten sonra
# surec kapatilmaz, yalnizca modeller bosaltilir; sonraki gorsel/video ayni sureci
# kullanir. Hata/iptal yolunda surec yine oldurulur ki bozuk durum tasinmasin.
function Get-RunningComfy {
    $found = Get-CimInstance Win32_Process -Filter "Name='python.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*ComfyUI\main.py*' } | Select-Object -First 1
    if (!$found) { return $null }
    try { return [Diagnostics.Process]::GetProcessById([int]$found.ProcessId) } catch { return $null }
}

function Start-OrReuseComfy([string]$python, [string]$comfyDir, [string]$comfyOut, [string]$comfyIn,
                            [string]$logs, [string]$comfyUrl, [bool]$lite, [int]$timeoutSec, [hashtable]$Shared) {
    # Harici model klasorleri (kopyalanmadan yerinde kullanilan dosyalar); bkz. media-paths.ps1.
    $extraPaths = Join-Path (Split-Path -Parent $comfyDir) 'settings\comfy-extra-models.yaml'
    $hasExtra = Test-Path -LiteralPath $extraPaths -PathType Leaf
    $existing = Get-RunningComfy
    if ($existing) {
        # Acik surec harici klasor listesi degismeden once basladiysa yeni klasoru goremez.
        $stale = $false
        try { $stale = $hasExtra -and (Get-Item -LiteralPath $extraPaths).LastWriteTime -gt $existing.StartTime } catch { }
        if ($stale) {
            try { $existing.Kill($true); $existing.WaitForExit(20000) | Out-Null } catch { }
            $existing = $null
        }
    }
    if ($existing) {
        try {
            Invoke-RestMethod "$comfyUrl/system_stats" -TimeoutSec 3 -ErrorAction Stop | Out-Null
            $Shared.Process = $existing
            return $existing
        } catch {
            # Yanit vermeyen surec portu tutar; kapatilip yenisi acilir.
            try { $existing.Kill($true); $existing.WaitForExit(20000) | Out-Null } catch { }
        }
    }
    $comfyArgs = @(
        (Join-Path $comfyDir 'main.py'), '--listen', '127.0.0.1', '--port', '8188',
        '--disable-auto-launch', '--dont-print-server',
        '--output-directory', $comfyOut, '--input-directory', $comfyIn
    )
    if ($lite) { $comfyArgs += '--lowvram' }
    if ($hasExtra) { $comfyArgs += @('--extra-model-paths-config', $extraPaths) }
    # ComfyUI isler arasinda acik kaldigi icin cagiranin borusunu devralmamali.
    $comfy = Start-DetachedProcess $python $comfyArgs $comfyDir `
        (Join-Path $logs 'comfyui.stdout.log') (Join-Path $logs 'comfyui.stderr.log')
    $Shared.Process = $comfy
    $deadline = [DateTime]::UtcNow.AddSeconds($timeoutSec)
    while ([DateTime]::UtcNow -lt $deadline) {
        if ($Shared.Cancel) { throw 'İşlem durduruldu.' }
        if ($comfy.HasExited) { throw 'ComfyUI baslatilamadi; logs\comfyui.stderr.log dosyasina bak.' }
        try { Invoke-RestMethod "$comfyUrl/system_stats" -TimeoutSec 2 -ErrorAction Stop | Out-Null; return $comfy } catch { }
        Start-Sleep -Milliseconds 500
    }
    throw "ComfyUI $timeoutSec saniyede hazir olmadi."
}

# nvidia-smi ile anlik bos VRAM (MiB). Yoksa/olculemezse $null doner; bu durumda
# cagiran ek kontrolu atlar (llama-server zaten asil hatayi verir).
function Get-MediaFreeVramMiB {
    $smi = (Get-Command nvidia-smi -ErrorAction SilentlyContinue).Source
    if (!$smi) { return $null }
    try { return [int](((& $smi --query-gpu=memory.free --format=csv,noheader,nounits) | Select-Object -First 1) -replace '\D', '') }
    catch { return $null }
}

# Modelleri ve onbellegi bosaltir; dil modeli geri yuklenmeden once VRAM'in
# gercekten bosaldigini bekler (/free bayragi ComfyUI'nin is dongusunde islenir).
# Bosalmazsa surec kapatilir - dil modeli VRAM'siz kalmasin.
#
# $minFreeMiB: geri yuklenecek dil modelinin tam sigmasi icin gereken asgari bos
# VRAM. ComfyUI /free ile kendi model onbellegini bosaltsa bile (torch_vram_total
# < 512 MB) CUDA baglami ve surucu tarafi rezervasyon bir sure VRAM tutabilir;
# yalnizca torch sayacina bakmak, dil modelinin paylasilan bellege tasinip
# ~6 tok/s'ye dusmesine yol acabiliyordu (medya sonrasi olculdu). Bu yuzden
# $minFreeMiB > 0 iken gercek bos VRAM de dogrulanir; yetmezse ComfyUI kapatilir
# ve baglamiyla birlikte VRAM'i tamamen serbest birakir.
function Release-Comfy($process, [string]$comfyUrl, [int]$minFreeMiB = 0) {
    try {
        Invoke-RestMethod "$comfyUrl/free" -Method Post -ContentType 'application/json' `
            -Body '{"unload_models":true,"free_memory":true}' -TimeoutSec 10 | Out-Null
        $deadline = [DateTime]::UtcNow.AddSeconds(20)
        while ([DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 500
            $device = @((Invoke-RestMethod "$comfyUrl/system_stats" -TimeoutSec 5).devices)[0]
            if ($device -and [double]$device.torch_vram_total -lt 512MB) {
                if ($minFreeMiB -le 0) { return }
                $free = Get-MediaFreeVramMiB
                if ($null -eq $free -or $free -ge $minFreeMiB) { return }
            }
        }
    } catch { }
    if ($process -and !$process.HasExited) {
        try { $process.Kill($true) } catch { }
        try { $process.WaitForExit(20000) | Out-Null } catch { }
    }
}

# $swallowError $false ise (basari yolu): hata oldugu gibi firlatilir, cagiranin
# kendi catch blogu yakalar. $swallowError $true ise (hata/iptal yolu, ikinci bir
# deneme): hata yutulup metin olarak dondurulur ki cagiran orijinal hatayla
# birlikte gosterebilsin - restore denemesinin KENDISI de basarisiz olursa
# kullaniciya sessizce gizlenmemesi icin (#16).
function Restore-LocalModelForMedia([string]$manage, [string]$restoreProfile, [bool]$swallowError) {
    if (!$restoreProfile) { return $null }
    Emit 'status' "Dil modeli geri yukleniyor ($restoreProfile)..."
    if ($swallowError) {
        try { & $manage -Action start -Profile $restoreProfile | Out-Null; return $null }
        catch { return $_.Exception.Message }
    }
    & $manage -Action start -Profile $restoreProfile | Out-Null
    return $null
}
