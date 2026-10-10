param(
    [ValidateSet('start', 'stop', 'switch', 'closecomfy')][string]$Action = 'switch',
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
if ($Action -notin @('stop', 'closecomfy') -and (Test-Path -LiteralPath $settingsPath)) {
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
    # MAX/FLASH gercek olcum (RTX 5060 Ti 16 GB, 32K baglam, MTP acik, llama.cpp):
    # temiz GPU'da (ComfyUI kapali) 14600 MiB'lik dosya GPU'da ~15170-15650 MiB yer
    # kaplar; llama.cpp musait bellege gore buyuk gomme tensorunu CPU'da tutar ve
    # kucuk farklari boyle kaldirir. Bos VRAM 15244 MiB iken model yuklendi ve
    # ~45 tok/s ile calisti (olculdu). 1000 MiB'lik pay (esik 15600) ve 800 MiB'lik
    # pay (esik 15400) bu durumu yanlislikla reddediyordu (gercek makinede goruldu):
    # "Model islemi basarisiz" hatasi. Bu yuzden 16 GB profillerinde pay 600 MiB'dir
    # (esik 15200); temiz GPU + makul masaustu kullanimiyla model yuklenir.
    # ASIL koruma, bos VRAM'e bakmaktan cok ComfyUI'nin HER ZAMAN kapatilmasidir
    # (bkz. asagidaki akis): baska bir CUDA baglami varken pay yetse/VRAM "bos"
    # gorunse bile surucu bellegi parcalar ve model paylasilan bellege tasip
    # ~6 tok/s'ye duser (15.290 MiB bos + baska baglam -> 6 tok/s olculdu).
    #
    # LITE'ta pay BILEREK kucuk (300 MiB) ve tolerans genistir: 8 GB kartta model zaten
    # sinirda calisir; llama.cpp buyuk gomme tensorunu CPU'da tutup kucuk asimi sorunsuz
    # kaldirir ve ~41 tok/s ile calismaya devam eder (bkz. asagidaki tolerans notu). Pay
    # burada buyutmek, ayni ambiyans kosullarinda (tarayici + masaustu ~1,5 GB VRAM tutarken)
    # LITE'i bos yere reddedip calisan kurulumu bozardi.
    $overheadMiB = if ($profileName -eq 'lite') { 300 } else { 600 }
    $neededMiB = $modelMiB + $overheadMiB
    # llama.cpp, VRAM tam yetmediginde buyuk gomme (token_embd) tensorunu CPU'da tutar ve
    # kucuk bir asimi sorunsuz kaldirir. LITE'ta MTP basligi eklenince dosya ~464 MiB
    # buyudu; 8 GB kartta ~165 MiB asimda model yine yuklendi ve ~41 tok/s ile calisti.
    # Bu yuzden LITE icin kucuk asim engellenmez; LITE'ta tolerans genis tutulur.
    # MAX/FLASH (16 GB) icin tolerans SIFIRDIR: 27B model zaten kartin sinirinda calisir
    # ve bir CUDA baglami (ComfyUI) acikken kucuk bir asim bile bir bileseni paylasilan
    # bellege tasiyip uretimi ~6 tok/s'ye dusurur. Bu yuzden olcumden once ComfyUI her
    # zaman kapatilir (bkz. asagidaki akis); toleransla asim kabul edilmez.
    $toleranceMiB = if ($profileName -eq 'lite') { 1024 } else { 0 }
    if ($freeMiB -lt ($neededMiB - $toleranceMiB)) {
        throw ("Yetersiz bos VRAM: $freeMiB MiB bos, `"$profileName`" profili icin " +
            "tahmini en az $neededMiB MiB gerekir (model ~$modelMiB MiB, onbellek/hesap " +
            "payi $overheadMiB MiB). GPU kullanan baska uygulamalari (tarayici donanim " +
            "hizlandirma, baska bir MamidLabs sureci vb.) kapatip tekrar dene, ya da " +
            "daha kucuk bir profil sec.")
    }
    if ($freeMiB -lt $neededMiB) {
        Write-Warning ("Bos VRAM tahmini ihtiyacin $($neededMiB - $freeMiB) MiB altinda; " +
            "llama.cpp buyuk gomme tensorunu CPU'da tutarak yukleyecek (kucuk hiz kaybi olabilir).")
    }
}

# ComfyUI sureci TEK surec degildir: venv baslatici (python.exe) + onun gercek alt
# sureci (base python.exe) olmak uzere bir CIFT olusur. Eski kod `Select-Object -First 1`
# ile yalnizca BIRINI hedefliyordu; kalan eslesme (ya da eski bir kacak kopya) CUDA
# baglamini tutup dil modelini tasiriyordu. Gercek makinede: iki ComfyUI sureci varken
# MAX 32K paylasilan bellege tasip 0,89 tok/s oldu; TEK ComfyUI ile ayni model 61 tok/s.
# Bu yuzden her temizlik TUM eslesen surecleri kapatir; cift/kaçak varsa hepsi gider.
function Get-ComfyProcesses {
    @(Get-CimInstance Win32_Process -Filter "Name='python.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*ComfyUI\main.py*' })
}

# Kuyrugu bos olan TUM ComfyUI sureclerini kapatir. En az biri kapatildiysa $true.
# (Acik temizlik icin: `-Action closecomfy`, install ve smoke-test hijyeni.)
function Stop-IdleComfy {
    $procs = @(Get-ComfyProcesses)
    if ($procs.Count -eq 0) { return $false }
    try {
        $queue = Invoke-RestMethod 'http://127.0.0.1:8188/queue' -TimeoutSec 3 -ErrorAction Stop
        if (@($queue.queue_running).Count -gt 0 -or @($queue.queue_pending).Count -gt 0) { return $false }
    } catch { }  # Yanit vermeyen surec zaten kullanilamaz; kapatilabilir.
    $killed = $false
    foreach ($comfy in $procs) {
        try {
            $process = [Diagnostics.Process]::GetProcessById([int]$comfy.ProcessId)
            $process.Kill($true)
            $process.WaitForExit(20000) | Out-Null
            $killed = $true
        } catch { }
    }
    # Hemen olmeyen kalirsa zorla (cift/kaçak gecikmeli kapanabiliyor).
    foreach ($comfy in $procs) {
        if (Get-Process -Id ([int]$comfy.ProcessId) -ErrorAction SilentlyContinue) {
            Stop-Process -Id ([int]$comfy.ProcessId) -Force -ErrorAction SilentlyContinue
            $killed = $true
        }
    }
    Start-Sleep -Milliseconds 1500  # Surucu VRAM'i biraz gecikmeyle serbest birakir.
    return $killed
}

# TEK ComfyUI bir surec CIFTI olabilir (launcher + child). Bu yuzden surec SAYISI ile
# "kacak" karari verilemez: saglikli tek örnek 2 surectir. Örnekleri "kök" sureclerle
# sayariz: parent'i de ComfyUI eslesen bir surec, ayni örnegin cocugudur (kök sayilmaz).
function Get-ComfyInstanceRoots($procs) {
    $ids = @($procs | ForEach-Object { [int]$_.ProcessId })
    @($procs | Where-Object { $ids -notcontains [int]$_.ParentProcessId })
}

# $p surecu, $rootId kökune ait mi? (ParentProcessId zinciri ComfyUI eslesmeleri icinde
# $rootId'ye ulasiyorsa ya da $p kendisi $rootId ise.) Kisa zincir (<=8).
function Test-ComfyUnderRoot($all, [int]$procId, [int]$rootId) {
    $cur = $procId
    for ($i = 0; $i -lt 8; $i++) {
        if ($cur -eq $rootId) { return $true }
        $m = $all | Where-Object { [int]$_.ProcessId -eq $cur } | Select-Object -First 1
        if (!$m) { return $false }
        $cur = [int]$m.ParentProcessId
    }
    return $false
}

# Yalnizca KAÇAK/mukerrer ComfyUI örneklerini kapatir; TEK saglikli örnege (cift sureciyle
# birlikte) DOKUNMAZ. 8188'i dinleyen örnek korunur. Kaçak varsa $true.
function Stop-ComfyLeaks {
    $all = @(Get-ComfyProcesses)
    if ($all.Count -eq 0) { return $false }
    $roots = @(Get-ComfyInstanceRoots $all)
    if ($roots.Count -le 1) { return $false }  # tek örnek (çift olabilir) -> dokunma
    $listener = 0
    try { $listener = [int](Get-NetTCPConnection -LocalPort 8188 -State Listen -ErrorAction Stop | Select-Object -First 1).OwningProcess } catch { }
    $keepRoot = [int]$roots[0].ProcessId
    if ($listener) {
        foreach ($r in $roots) { if (Test-ComfyUnderRoot $all $listener ([int]$r.ProcessId)) { $keepRoot = [int]$r.ProcessId; break } }
    }
    $killed = $false
    foreach ($p in $all) {
        if (Test-ComfyUnderRoot $all ([int]$p.ProcessId) $keepRoot) { continue }  # korunan örnek
        try {
            $process = [Diagnostics.Process]::GetProcessById([int]$p.ProcessId)
            $process.Kill($true)
            $process.WaitForExit(15000) | Out-Null
            $killed = $true
        } catch { }
    }
    foreach ($p in $all) {
        if ((Test-ComfyUnderRoot $all ([int]$p.ProcessId) $keepRoot)) { continue }
        if (Get-Process -Id ([int]$p.ProcessId) -ErrorAction SilentlyContinue) { Stop-Process -Id ([int]$p.ProcessId) -Force -ErrorAction SilentlyContinue; $killed = $true }
    }
    if ($killed) { Start-Sleep -Milliseconds 1500 }
    return $killed
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

    # Kaynak hijyeni: bosta kalan ComfyUI'yi kapat. Uygulama coktu/gorev sonlandirildi
    # ya da smoke testinin arayuz adimi uygulamayi zorla oldurdu ise ComfyUI artik
    # kalmis olabilir; dil modeli onun uzerine yuklenirse VRAM tasar. Cagiranlar
    # (uninstall, smoke-test, Shutdown-All) bunu acikca tetikler.
    if ($Action -eq 'closecomfy') { [void](Stop-IdleComfy); 'ComfyUI kapatildi (kuyruk bossa).'; return }

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
    # ComfyUI yasam dongusu. Varsayilan: medya isleri arasinda ACIK tutulur (~27 sn'lik
    # yeniden acilma olmaz). Gercek makinede TEK (taze) ComfyUI ile MAX 32K birlikte
    # sorunsuz calisir: 61 tok/s, 192 MiB bos. Sohbet de "medya sonrasi gecis" adiminda
    # 0,92 oraninda kaldi. TASMA yalnizca MUKERRER/kacak ComfyUI sureci varsa olur
    # (ComfyUI bir cift surec; eski kopya kalirsa VRAM asar -> 0,89 tok/s olculdu).
    # Bu yuzden yukleme ONCESI once kaçak/mukerrer temizlenir, sonra butce olculur;
    # yer yetmezse kuyrugu bos ComfyUI kapatilip yeniden olculur.
    $comfyKeepAlive = $true
    if ($settings -and $null -ne $settings.comfyKeepAlive) { $comfyKeepAlive = [bool]$settings.comfyKeepAlive }
    # Kaçak/mukerrer ComfyUI tespiti: örnek sayisi 1'den fazlaysa yalnizca kaçaklar kapatilir;
    # tek saglikli örnek (çift sureciyle) KORUNUR (bkz. Stop-ComfyLeaks). Boylece ComfyUI
    # medya isleri arasinda acik kalir.
    [void](Stop-ComfyLeaks)
    if (!$comfyKeepAlive) { [void](Stop-IdleComfy) }
    # Onceki surec zaten yukarida durduruldu; bos VRAM burada olculur ki eski
    # surecin bosalttigi bellek de sayilsin.
    if (!$SkipMemoryCheck) {
        try { Test-MemoryBudget $model $Profile $projector }
        catch {
            # Yer yetmedi (ComfyUI acik): kuyrugu bossa kapat, tekrar olc; yine yetmezse hata.
            if ((Stop-IdleComfy)) { Test-MemoryBudget $model $Profile $projector } else { throw }
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
    # GGUF basliginda MTP/nextn blogu var mi? llama.cpp `--spec-type draft-mtp` yalnizca
    # MTP katmani tasiyan modellerde calisir; tasimayan modele bayrak verilirse sunucu
    # acilmaz ("model doesn't contain MTP layers"). Ust veri ve tensor adlari baslikta duz
    # metin durur; MTP blogu "nextn" adini tasir (or. blk.32.nextn.eh_proj.weight).
    function Test-GgufHasMtp([string]$Path) {
        try {
            $fs = [IO.File]::OpenRead($Path)
            try {
                $buf = [byte[]]::new(16777216)
                $n = $fs.Read($buf, 0, $buf.Length)
            }
            finally { $fs.Dispose() }
            return ([Text.Encoding]::ASCII.GetString($buf, 0, $n)).Contains('nextn')
        }
        catch { return $false }
    }
    # MTP (Multi-Token Prediction) speculative decoding. MAX/FLASH'in 27B GGUF'u ve
    # LITE'in 9B GGUF'u (indirmede otomatik eklenir; bkz. agent/mtp_inject.py) GOMULU bir
    # MTP/nextn draft basligi tasir (blk.<N>.nextn.*, nextn_predict_layers=1); bu yuzden
    # AYRI bir draft model GEREKMEZ - ayni dosyadaki baslik kullanilir. Cikti kayipsizdir
    # (kabul edilen tokenlar hedef modelle dogrulanir) ve ~2x hiz kazanci saglar (LITE'ta
    # olculen kabul ~0,93; 27B model kartinda Q4_K_M icin kabul 0,35-0,53). Bayrak yalnizca
    # model gercekten MTP katmani tasiyorsa eklenir. Ozel modellerde de ayni kontrol gecerli.
    # settings/api.json -> "mtp": false ile kapatilabilir (bir uyumluluk sorunu cikarsa).
    $mtpEnabled = $true
    if ($settings -and $null -ne $settings.mtp) { $mtpEnabled = [bool]$settings.mtp }
    if (!$custom -and $mtpEnabled -and (Test-GgufHasMtp $model)) {
        $serverArgs += @('--spec-type', 'draft-mtp')
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
