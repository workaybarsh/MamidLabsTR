param(
    [ValidateSet('start', 'stop', 'switch')][string]$Action = 'switch',
    [ValidateSet('max', 'flash', 'lite')][string]$Profile = 'max',
    [string]$ModelId,
    # Bellek kontrolunu atla (sorun giderme icin). Normal kullanimda gerekmez.
    [switch]$SkipMemoryCheck
)

$ErrorActionPreference = 'Stop'
# Kurulum kokunu kendi konumundan turet: bu dosya her zaman <kok>\scripts\ altindadir.
$root = Split-Path -Parent $PSScriptRoot
$server = Join-Path $root 'llama.cpp\b10998\llama-server.exe'
# Profil basina alias. MAX ile FLASH ayni 27B dosyasini paylasir; Lite, 8 GB VRAM
# / 16 GB RAM makineler icin ayri bir 9B modeli yukler. Bu tablo model-registry.ps1
# icindeki $script:localProfileAliases ile birebir ayni kalmalidir.
$profileAliases = @{ max = 'qwen3.8-27b-max'; flash = 'qwen3.8-27b-flash'; lite = 'qwen3.5-9b-lite' }
$liteDir = Join-Path $root 'models\Huihui-Qwen3.5-9B-abliterated-i1-GGUF'
$logs = Join-Path $root 'logs'
. (Join-Path $root 'agent\process-launch.ps1')

# Ayarlar profil secimi icin gerekli oldugundan model yolu belirlenmeden once okunur.
$settings = $null
$settingsPath = Join-Path $root 'settings\api.json'
if ($Action -ne 'stop' -and (Test-Path -LiteralPath $settingsPath)) {
    $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
}

if ($Profile -eq 'lite') {
    # Varsayilan Q5_K_M'dir (~6,6 GB). Gercek makinede (RTX 4060 Laptop, 8 GB)
    # 32K baglamla olculdu: 7500 MiB VRAM kullanir, ~450-500 MiB bos kalir -
    # dar ama kullanicinin kabul ettigi bir pay (diger MAX/FLASH profilleri
    # baska makinelerde benzer paylarla calisiyor). llama.cpp kendi otomatik
    # sigdirma kontrolu bunu "tam sigmiyor" diye isaretler ama --gpu-layers 99
    # elle zorlandigi icin yine de yukler; performans dusmez (olculen ~35 tok/s,
    # Q4'ten yalnizca ~%13 daha yavas). Daha rahat bir pay icin
    # settings/api.json icindeki liteModel alaniyla Q4_K_M'e (~5,7 GB) donulebilir;
    # Q6_K (~7,4 GB) 8 GB kartta hic sigmaz (dosyanin kendisi bos VRAM'i asar).
    $liteFile = 'Huihui-Qwen3.5-9B-abliterated.i1-Q5_K_M.gguf'
    $liteCtx = '32768'
    # Dusunme acik kalir; bu yalnizca kac token dusunulecegini sinirlar.
    # -1 sinirsiz, 0 dusunmeyi hemen bitirir, N>0 token butcesi.
    #
    # Neden gerekli: Qwen3.5 sablonu --reasoning-effort'u yok sayar, bu yuzden
    # caba yalnizca sunucunun zorladigi bu butce ile ayarlanabilir. RTX 4060
    # uzerinde ayni basit istek, sinirsizken 1451-2391 token ve ~50 sn; 300
    # token butce ile 408-429 token ve ~10 sn surdu, yanit kalitesi korundu.
    $liteThinkBudget = '300'
    if ($settings -and $settings.liteModel) { $liteFile = [string]$settings.liteModel }
    if ($settings -and $settings.liteContext) { $liteCtx = [string][int]$settings.liteContext }
    if ($settings -and $null -ne $settings.liteReasoningBudget) { $liteThinkBudget = [string][int]$settings.liteReasoningBudget }
    $model = Join-Path $liteDir $liteFile
    # Lite'in gorsel projektoru (mmproj Q8_0) katalogdan ayri bir dosya olarak iner;
    # klasorde yoksa Lite metin-only calisir ve gorseller yalnizca OCR ile okunur.
    $projector = @(Get-ChildItem -LiteralPath $liteDir -Filter '*mmproj*.gguf' -File -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName)[0]
} else {
    $model = Join-Path $root 'models\Qwen3.8-27B-Abliterated-IQ4_XS\Qwen3.8-27B-Abliterated-IQ4_XS.gguf'
    $projector = Join-Path $root 'models\Qwen3.8-27B-Abliterated-IQ4_XS\mmproj-Qwen3.8-27B-Abliterated-F16.gguf'
}
$desiredAlias = $profileAliases[$Profile]
$custom=$null
if($settings){
    # UI switches carry a snapshot of the choice; OCR/media restore callers use saved settings.
    $selectedId = if ($ModelId) { $ModelId } else { [string]$settings.selectedLocalModel }
    if($selectedId -and $selectedId -notin @('builtin-max', 'builtin-flash', 'builtin-lite')){
        $custom=@($settings.localModels | Where-Object {$_.id -eq $selectedId})[0]
        if(!$custom){throw 'Kayıtlı yerel model bulunamadı.'}
        $model=[string]$custom.path;$desiredAlias=[string]$custom.id
        $projector=@(Get-ChildItem -LiteralPath (Split-Path $model) -Filter '*mmproj*.gguf' -File | Select-Object -First 1 -ExpandProperty FullName)[0]
    }
}
$gate = [System.Threading.Mutex]::new($false, 'Local\QwenLocalModelControl')
$ownsGate = $false

# Bellek kapisi: tahmini ihtiyac + olculen bos VRAM + guvenlik payina gore ise
# baslama karari verir. GPU'yu baska bir uygulama tutuyorsa llama-server
# baslatilmaz; aksi halde katmanlar Windows'un paylasilan bellegine tasar ve sohbet
# kat kat yavaslar. Kullaniciya nedeni acikca soylenir.
function Test-MemoryBudget([string]$modelPath, [string]$profileName, [string]$projectorPath) {
    $smi = (Get-Command nvidia-smi -ErrorAction SilentlyContinue).Source
    if (!$smi) { return }  # NVIDIA suruculeri yoksa kontrol anlamsiz; asil hata llama-server'dan gelir.
    $freeMiB = 0
    try {
        $line = (& $smi --query-gpu=memory.free --format=csv,noheader,nounits | Select-Object -First 1)
        $freeMiB = [int]($line -replace '\D', '')
    } catch { return }  # nvidia-smi beklenmedik cikti verirse kontrolu atla, kurulumu engelleme.
    if ($freeMiB -le 0) { return }
    $modelMiB = [math]::Ceiling((Get-Item -LiteralPath $modelPath).Length / 1MB)
    # Lite'ta gorsel projektoru modelle birlikte VRAM'e yuklenir; MAX/FLASH'ta
    # --no-mmproj-offload ile CPU'da calisir, VRAM butcesine girmez.
    if ($profileName -eq 'lite' -and $projectorPath -and (Test-Path -LiteralPath $projectorPath -PathType Leaf)) {
        $modelMiB += [math]::Ceiling((Get-Item -LiteralPath $projectorPath).Length / 1MB)
    }
    # Gercek olcum (Lite, Q5_K_M, 32K baglam, RTX 4060 Laptop, varsayilan profil):
    # 6220 MiB'lik dosya yuklendiginde toplam VRAM kullanimi ~7500 MiB'ye ulasti,
    # kartta ~450-500 MiB bos kaldi - dar ama kullanicinin acikca kabul ettigi bir
    # pay (baska makinelerde MAX/FLASH de benzer paylarla calisiyor). Bu yuzden
    # Lite icin pay kucuk tutuldu: cok daha genis bir pay, ayni ambiyans kosullarinda
    # (tarayici + masaustu ~1,5 GB VRAM tutarken) varsayilan profili sessizce
    # reddedip kullaniciyi calisan bir kurulumdan mahrum birakirdi.
    #
    # MAX/FLASH gercek olcum (RTX 5060 Ti 16 GB, 32K baglam, llama.cpp --verbose
    # bellek dokumu): 14600 MiB'lik dosyanin 644 MiB'i (token_embd) CPU'da kalir,
    # GPU'da 13729 agirlik + 576 KV + 150 recurrent + 184 hesap = ~14640 MiB, yani
    # dosya boyutu + ~40 MiB. Pay 300 MiB tutuldu. Onceki +2560 MiB pay 17160+
    # MiB istiyordu; 16 GB kartin bos alanindan (~15000-15700 MiB) buyuk oldugu
    # icin MAX hedef donaniminda hic acilamiyordu.
    $overheadMiB = 300
    $neededMiB = $modelMiB + $overheadMiB
    if ($freeMiB -lt $neededMiB) {
        throw ("Yetersiz bos VRAM: $freeMiB MiB bos, `"$profileName`" profili icin " +
            "tahmini en az $neededMiB MiB gerekir (model ~$modelMiB MiB, onbellek/hesap " +
            "payi $overheadMiB MiB). GPU kullanan baska uygulamalari (tarayici donanim " +
            "hizlandirma, baska bir MamidLabs sureci vb.) kapatip tekrar dene, ya da " +
            "daha kucuk bir profil sec.")
    }
}

# Isler arasinda acik bekleyen ComfyUI (bkz. agent\media-model-swap.ps1) modeller
# bosaltilmis olsa da CUDA baglami icin ~300 MiB VRAM tutar (RTX 5060 Ti'de olculdu).
# 8 GB Lite kartta bu pay dil modelini sigdirmayabilir. Bellek yetmezse ve ComfyUI'nin
# kuyrugu bossa kapatilir; bir sonraki gorsel/video onu yeniden acar (~15-20 sn).
# Calisan bir is varsa dokunulmaz.
function Stop-IdleComfy {
    $comfy = Get-CimInstance Win32_Process -Filter "Name='python.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*ComfyUI\main.py*' } | Select-Object -First 1
    if (!$comfy) { return $false }
    try {
        $queue = Invoke-RestMethod 'http://127.0.0.1:8188/queue' -TimeoutSec 3 -ErrorAction Stop
        if (@($queue.queue_running).Count -gt 0 -or @($queue.queue_pending).Count -gt 0) { return $false }
    } catch { }  # Yanit vermeyen surec zaten kullanilamaz; kapatilabilir.
    try {
        $process = [Diagnostics.Process]::GetProcessById([int]$comfy.ProcessId)
        $process.Kill($true)
        $process.WaitForExit(20000) | Out-Null
    } catch { return $false }
    Start-Sleep -Milliseconds 1500  # Surucu VRAM'i biraz gecikmeyle serbest birakir.
    return $true
}

function Get-ManagedServers {
    @(Get-CimInstance Win32_Process -Filter "Name='llama-server.exe'" -ErrorAction SilentlyContinue | Where-Object {
        $_.ExecutablePath -and
        $_.ExecutablePath.Equals($server, [System.StringComparison]::OrdinalIgnoreCase) -and
        $_.CommandLine -match '--port\s+8080(?:\s|$)'
    })
}

try {
    try { $ownsGate = $gate.WaitOne(30000) }
    catch [System.Threading.AbandonedMutexException] { $ownsGate = $true }
    if (!$ownsGate) { throw 'Model kontrolü başka bir işlem tarafından kullanılıyor.' }

    $running = @(Get-ManagedServers)
    if ($Action -ne 'stop' -and $running.Count -eq 1 -and $running[0].CommandLine -match ('--alias\s+' + [regex]::Escape($desiredAlias) + '(?:\s|$)')) {
        "Zaten yüklü: $desiredAlias (PID $($running[0].ProcessId))"
        return
    }

    foreach ($serverProcess in $running) {
        Stop-Process -Id $serverProcess.ProcessId -Force -ErrorAction SilentlyContinue
    }
    if ($running.Count -gt 0) {
        $deadline = [DateTime]::UtcNow.AddSeconds(20)
        while (@(Get-ManagedServers).Count -gt 0 -and [DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 250
        }
        if (@(Get-ManagedServers).Count -gt 0) { throw 'Önceki model süreci kapanmadı.' }
        Start-Sleep -Milliseconds 500
    }

    if ($Action -eq 'stop') { 'Model durduruldu.'; return }

    if (!(Test-Path -LiteralPath $server -PathType Leaf)) { throw "llama-server bulunamadı: $server" }
    if (!(Test-Path -LiteralPath $model -PathType Leaf)) { throw "Model bulunamadı: $model" }
    # Lite profili gorsel projektoru olmadan da calisir; digerlerinde mmproj zorunludur.
    if (!$custom -and $Profile -ne 'lite' -and !(Test-Path -LiteralPath $projector -PathType Leaf)) { throw "Görsel projektörü bulunamadı: $projector" }
    # Onceki surec zaten yukarida durduruldu; bos VRAM burada olculur ki eski
    # surecin bosalttigi bellek de sayilsin.
    if (!$SkipMemoryCheck) {
        try { Test-MemoryBudget $model $Profile $projector }
        catch {
            # Yer acilamazsa ilk (aciklayici) hata aynen iletilir.
            if (!(Stop-IdleComfy)) { throw }
            Test-MemoryBudget $model $Profile $projector
        }
    }
    New-Item -ItemType Directory -Path $logs -Force | Out-Null

    $predict = switch ($Profile) { 'lite' { '3072' } 'flash' { '4096' } default { '8192' } }
    # Model adları max/flash/lite'tir; llama.cpp şablonu için karşılık gelen reasoning
    # değerleri hâlâ low/xhigh olarak gönderilir.
    $reasoningEffort = if ($Profile -eq 'max') { 'xhigh' } else { 'low' }
    if ($Profile -eq 'lite') {
        # 8 GB VRAM butcesi: ~5,7 GB agirlik + q4_0 KV cache + hesap tamponu.
        # Windows masaustu de 0,5-1 GB VRAM tuttugu icin varsayilan 32K baglamdir
        # ($liteCtx yukarida, settings.liteContext ile degistirilebilir);
        # batch kucultulerek tepe VRAM ayrica asagi cekilir.
        $serverArgs = @(
            '--model', $model,
            '--alias', $desiredAlias, '--host', '127.0.0.1', '--port', '8080',
            '--ctx-size', $liteCtx, '--predict', $predict, '--parallel', '1',
            '--gpu-layers', '99', '--flash-attn', 'on', '--cache-type-k', 'q4_0',
            '--cache-type-v', 'q4_0', '--cache-reuse', '256', '--batch-size', '256', '--ubatch-size', '128',
            '--threads', '4', '--threads-batch', '8', '--jinja', '--reasoning', 'on',
            '--reasoning-effort', $reasoningEffort, '--reasoning-format', 'deepseek',
            '--reasoning-budget', $liteThinkBudget,
            '--metrics', '--no-context-shift'
        )
        # Projektor yalnizca klasorde varsa eklenir; yoksa Lite metin-only calisir.
        if ($projector) { $serverArgs += @('--mmproj', $projector, '--image-min-tokens', '512') }
    }
    else {
        # Gorsel projektoru CPU'da (--no-mmproj-offload). mmproj F16 GPU'da agirlik +
        # hesap tamponuyla 1133 MiB ister; dil modelinin ~14640 MiB'ine eklenince 16 GB
        # kartin bos alanini asiyor, ~420 MiB paylasilan bellege tasiyor ve her seyi
        # yavaslatiyordu. RTX 5060 Ti olcumu, GPU -> CPU: sohbet 19,6 -> 24,8 tok/s,
        # tek gorsel okuma 56-58 sn -> 30 sn.
        $serverArgs = @(
            '--model', $model, '--mmproj', $projector, '--no-mmproj-offload', '--image-min-tokens', '1024',
            '--alias', $desiredAlias, '--host', '127.0.0.1', '--port', '8080',
            '--ctx-size', '32768', '--predict', $predict, '--parallel', '1',
            '--gpu-layers', '99', '--flash-attn', 'on', '--cache-type-k', 'q4_0',
            '--cache-type-v', 'q4_0', '--cache-reuse', '256', '--batch-size', '512', '--ubatch-size', '256',
            '--threads', '6', '--threads-batch', '12', '--jinja', '--reasoning', 'on',
            '--reasoning-effort', $reasoningEffort, '--reasoning-format', 'deepseek',
            '--metrics', '--no-context-shift'
        )
    }
    if($custom){
        $serverArgs=@('--model',$model,'--alias',$desiredAlias,'--host','127.0.0.1','--port','8080','--ctx-size','8192','--predict','4096','--parallel','1','--gpu-layers','99','--flash-attn','on','--cache-reuse','256','--jinja','--metrics')
        if($projector){$serverArgs+=@('--mmproj',$projector)}
    }
    # Start-Process joins ArgumentList on Windows; quote paths explicitly.
    $serverArgs=@($serverArgs | ForEach-Object {if($_ -match '\s'){'"'+$_+'"'}else{$_}})
    # Cagiranin stdout borusunu devretmeden baslat; yoksa "manage-qwen | ..." bitmez.
    $child = Start-DetachedProcess $server $serverArgs (Split-Path $server) `
        (Join-Path $logs "qwen-$Profile.stdout.log") (Join-Path $logs "qwen-$Profile.stderr.log")
    if (!$child) { throw 'Model süreci başlatılamadı.' }
    "Yükleniyor: $desiredAlias (PID $($child.Id))"
}
finally {
    if ($ownsGate) { $gate.ReleaseMutex() | Out-Null }
    $gate.Dispose()
}
