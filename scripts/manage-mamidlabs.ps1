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
    # Varsayilan Q5_K_M'dir (~6,5 GB + ~0,46 GB MTP basligi). Gercek makinede (RTX 4060 Laptop, 8 GB)
    # 32K baglamla, gorsel projektoru CPU'da olculdu: 7249 MiB VRAM kullanir,
    # 708 MiB bos kalir (mmproj GPU'dayken 7885 MiB / ~72 MiB bos idi) - kullanicinin
    # kabul ettigi bir pay (diger MAX/FLASH profilleri baska makinelerde benzer
    # paylarla calisiyor). llama.cpp kendi otomatik sigdirma kontrolu bunu tam
    # sinirda isaretleyebilir ama --gpu-layers 99 elle zorlandigi icin yine de
    # yukler; sohbet hizi degismez (icerige bagli ~40-79 tok/s). Daha rahat bir pay
    # icin settings/api.json icindeki liteModel alaniyla Q4_K_M'e (~5,7 GB)
    # donulebilir; Q6_K (~7,4 GB) 8 GB kartta hic sigmaz (dosyanin kendisi bos
    # VRAM'i asar).
    $liteFile = 'Huihui-Qwen3.5-9B-abliterated.i1-Q5_K_M.gguf'
    $liteCtx = '32768'
    # Dusunme ACIK ve SINIRSIZDIR: LITE'a düşünme bütçesi konmaz, isi bitene kadar
    # (lazim oldugu kadar) düşünsün diye sunucuya bir dusunme butcesi bayragi HIC
    # verilmez. Eskiden
    # 300 token'lik bir butce vardi (hizli ama bazi sorularda erken kesiyordu);
    # kullanici isteğiyle kaldirildi. Qwen3.5 sablonu --reasoning-effort'u yok sayar
    # ama deepseek reasoning formati ile aciк kalir; arayuz isteği `reasoning_effort`
    # gonderir (LITE sablonu yok sayar).
    if ($settings -and $settings.liteModel) { $liteFile = [string]$settings.liteModel }
    if ($settings -and $settings.liteContext) { $liteCtx = [string][int]$settings.liteContext }
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
$gate = [System.Threading.Mutex]::new($false, 'Local\MamidLabsModelControl')
$ownsGate = $false

# Bellek kapisi: tahmini ihtiyac + olculen bos VRAM + guvenlik payina gore ise
# baslama karari verir. GPU'yu baska bir uygulama tutuyorsa llama-server
# baslatilmaz; aksi halde katmanlar Windows'un paylasilan bellegine tasar ve sohbet
# kat kat yavaslar. Kullaniciya nedeni acikca soylenir.
# Agirlik disi VRAM payi (KV cache + recurrent-state tamponu + hesap tamponlari + CUDA
# baglami) RTX 5060 Ti 16 GB'da 27B MAX/FLASH icin llama.cpp'nin KENDI raporundan okundu
# (llama.cpp b10998, q4_0 KV, MTP acik): CUDA0 model tamponu 13945 MiB, KV 144 MiB @8192 /
# 288 @16384 / 576 @32768, recurrent-state tamponu 598,5 MiB (sabit), hesap tamponu 76-112 MiB;
# kalan CUDA baglamidir. Yani KV cache 1K token basina ~18 MiB buyur, gerisi sabittir.
# Olculen GPU ayak izi (dedicated + shared): 15112 MiB @8192, 15324 @16384,
# ~15770 @32768. 32K degeri SABIT 750 MiB payinin neden yanlis oldugunu gosterir: yalnizca
# ~15,50 GiB bos VRAM varken modeli kabul ediyordu, bu yuzden ~400 MiB Windows paylasilan
# bellegine tasip sohbet ~40'tan ~27 tok/s'ye dusuyordu. LITE kendi kucuk payini korur
# (9B zaten 8 GB karta sigar).
function Get-ModelOverheadMiB([string]$profileName, [int]$ctx) {
    if ($profileName -eq 'lite') { return 300 }
    if ($ctx -ge 32768) { return 1200 }
    if ($ctx -ge 16384) { return 800 }
    return 600
}

# $ctx, modelin yuklenecegi baglam boyutudur; payin KV-cache kismi buna bagli oldugundan
# tahmin baglama duyarli yapilir.
function Test-MemoryBudget([string]$modelPath, [string]$profileName, [string]$projectorPath, [int]$ctx) {
    $smi = (Get-Command nvidia-smi -ErrorAction SilentlyContinue).Source
    if (!$smi) { return }  # NVIDIA suruculeri yoksa kontrol anlamsiz; asil hata llama-server'dan gelir.
    $freeMiB = 0
    try {
        $line = (& $smi --query-gpu=memory.free --format=csv,noheader,nounits | Select-Object -First 1)
        $freeMiB = [int]($line -replace '\D', '')
    } catch { return }  # nvidia-smi beklenmedik cikti verirse kontrolu atla, kurulumu engelleme.
    if ($freeMiB -le 0) { return }
    $modelMiB = [math]::Ceiling((Get-Item -LiteralPath $modelPath).Length / 1MB)
    # Gorsel projektoru (mmproj) artik UC profilde de CPU'da calisir
    # (--no-mmproj-offload), bu yuzden VRAM butcesine girmez. LITE'ta Q8_0 mmproj
    # (595 MiB) 8 GB karta sigmadigi ve llama.cpp'yi buyuk gomme tensorunu CPU'ya
    # itmeye zorlayip VRAM'i sinirdan tasirdigi icin CPU'ya alindi: ~636 MiB VRAM
    # bosalir (olcum: 7249/8188 MiB, 708 MiB bos), sohbet hizi degismez
    # (80/61/40 tok/s - mmproj GPU'dayken de ayniydi), gorsel okuma biraz yavaslar.
    # Gercek olcum (Lite, Q5_K_M, 32K baglam, RTX 4060 Laptop, varsayilan profil):
    # projektor CPU'ya alindiktan sonra toplam VRAM kullanimi 7249 MiB'dir (708 MiB
    # bos); mmproj GPU'dayken 7885 MiB idi (~72 MiB bos). Pay yine de kucuk tutuldu:
    # cok daha genis bir pay, ayni ambiyans kosullarinda (tarayici + masaustu ~1,5 GB
    # VRAM tutarken) varsayilan profili sessizce reddedip kullaniciyi calisan bir
    # kurulumdan mahrum birakirdi.
    #
    # MAX/FLASH gercek olcum (RTX 5060 Ti 16 GB, MTP acik, llama.cpp; kirilimi icin
    # Get-ModelOverheadMiB'e bak): 14600 MiB'lik dosya arti sabit tamponlar gercek GPU ayak
    # izini 16K baglamda ~15,32 GiB, 32K baglamda ~15,77 GiB yapar (llama.cpp'nin kendi KV
    # raporu: 288 / 576 MiB). "Bos VRAM'in tamamini kullan" icin --gpu-layers 99 KORUNUR
    # (modeli tumuyle VRAM'e koyar; tam siginca ~40-55 tok/s). llama.cpp'nin --fit otomatik
    # yerlestirmesi denendi ve daha TEMKINLI cikti (tum VRAM'i kullanmadi, ~23 tok/s) - bu
    # yuzden kullanilmaz.
    # Pay bu yuzden baglama duyarlidir (16K'da 800 MiB, 32K'da 1200 MiB = olculen ayak izi):
    # model ancak tam sigacaksa yuklenir ve TUM bos VRAM'i kullanir; altinda tasacagi icin
    # net "yetersiz VRAM" mesaji verilir. Cagiran once 32K dener, 32K sigmazsa 16K'ya duser
    # (bkz. asagidaki baglam secimi).
    # ASIL koruma, bos VRAM'e bakmaktan cok ComfyUI'nin HER ZAMAN kapatilmasidir
    # (bkz. asagidaki akis): baska bir CUDA baglami varken VRAM "bos" gorunse bile surucu
    # bellegi parcalar ve model paylasilan bellege tasip ~6 tok/s'ye duser.
    #
    # LITE'ta pay BILEREK kucuk (300 MiB) ve tolerans genistir: 8 GB kartta model zaten
    # sinirda calisir; llama.cpp buyuk gomme tensorunu CPU'da tutup kucuk asimi sorunsuz
    # kaldirir ve sohbet hizini korur (icerige bagli ~40-79 tok/s). Pay burada buyutmek,
    # calisan bir LITE kurulumunu bos yere reddederdi.
    $overheadMiB = Get-ModelOverheadMiB $profileName $ctx
    $neededMiB = $modelMiB + $overheadMiB
    # llama.cpp, VRAM tam yetmediginde buyuk gomme (token_embd) tensorunu CPU'da tutar ve
    # kucuk bir asimi sorunsuz kaldirir. LITE'ta MTP basligi dosyayi ~464 MiB buyutur; 8 GB
    # kartta model sinirda kalir, ama projektor CPU'da oldugundan artik 7249/8188 MiB'ye
    # yerlesir (708 MiB bos) ve asim olusmaz. Yine de LITE icin tolerans genis tutulur:
    # ambiyans/ASR gecisi sirasinda olusabilecek kucuk asim engellenmez.
    # MAX/FLASH (16 GB) icin tolerans SIFIRDIR: model ancak TAM sigacaksa yuklenir ve, acik bir
    # CUDA baglami (ComfyUI) varken kucuk bir asim bile bir bileseni paylasilan bellege itip
    # uretimi ~6 tok/s'ye dusurur. Bu yuzden olcumden once ComfyUI her zaman kapatilir (bkz.
    # asagidaki akis); asim toleransla kabul edilmez.
    # Olculdu (RTX 5060 Ti): 32K baglamda 15095-15497 MiB bos VRAM'de 27B TASTI (~400 MiB
    # paylasilan bellege, ~27 tok/s); 16K baglamda 15497 MiB bosta TAM SIGDI (15324 MiB,
    # ~40 tok/s). Bu yuzden tasacagi bilinen bir yapilandirmayi yuklemek yerine baglam
    # sigacak sekilde secilir (32K -> 16K dususu).
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

# Uygulamaya ait ARTIK/kaçak GPU isçileri: kalici ses iscisi (`whisper-tools.py --serve`)
# ve OCR iscisi (`ocr-tools.py`). Uygulama coktugunde/gorev sonlandirildiginda bunlar
# kalabilir ve CUDA baglamlari (~140-600 MiB) dil modelinin ince payini yer; model
# "yetersiz VRAM" ile reddedilir. Yalnizca KURULUM KOKU altindaki python'lari ve bilinen
# GPU iscisi betiklerini hedefleriz; ComfyUI (main.py) kendi yasam dongusune sahiptir ve
# buraya girmez. Baska uygulamalarin sureclerine DOKUNULMAZ.
function Get-AppGpuWorkers {
    $rootFull = $root.TrimEnd('\')
    @(Get-CimInstance Win32_Process -Filter "Name='python.exe' OR Name='pythonw.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.ExecutablePath -and
            $_.ExecutablePath.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase) -and
            $_.CommandLine -match '(whisper-tools|ocr-tools)\.py'
        })
}

# Artik GPU isçilerini kapatir ve surucunun VRAM'i birakmasi icin kisa bir sure bekler.
# En az biri kapatildiysa $true doner (butce yeniden olculmeden once). Yalnizca
# Get-AppGpuWorkers'in sectigi (kurulum koku altindaki) surecleri hedefler.
function Stop-OrphanWorkers {
    $procs = @(Get-AppGpuWorkers)
    if ($procs.Count -eq 0) { return $false }
    $killed = $false
    foreach ($p in $procs) {
        try {
            $process = [Diagnostics.Process]::GetProcessById([int]$p.ProcessId)
            $process.Kill($true)
            $process.WaitForExit(10000) | Out-Null
            $killed = $true
        } catch { }
    }
    # Hemen olmeyen kalirsa zorla.
    foreach ($p in $procs) {
        if (Get-Process -Id ([int]$p.ProcessId) -ErrorAction SilentlyContinue) {
            Stop-Process -Id ([int]$p.ProcessId) -Force -ErrorAction SilentlyContinue
            $killed = $true
        }
    }
    if ($killed) { Start-Sleep -Milliseconds 1000 }  # Surucu VRAM'i biraz gecikmeyle serbest birakir.
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
    # ComfyUI yasam dongusu. VARSAYILAN KAPALI: ComfyUI yalnizca gorsel/video uretimi
    # sirasinda calisir, is bitince ve dil modeli yuklenmeden once kapatilir — bosta ne VRAM
    # ne de RAM tutar. Gerekce: LITE hedef makinesi 8 GB VRAM / 16 GB RAM'dir; 9B model zaten
    # kartin sinirinda (~6,5 GB + ~0,46 GB MTP basligi), ComfyUI baglami (~300 MiB) + masaustu eklenince tasar. 16 GB'lik
    # bir kartta LITE ile medya isleri arasinda acik tutmak isteyen `settings/api.json` ->
    # `comfyKeepAlive=true` yazar (o zaman ~27 sn yeniden acilma olmaz). MAX/FLASH (27B) her
    # durumda kapatir. API modunda bu betik cagrilmaz; ComfyUI medya sonrasi acik kalir.
    # Kaçak/mukerrer ComfyUI her profilde once temizlenir.
    $comfyKeepAlive = $false
    if ($settings -and $null -ne $settings.comfyKeepAlive) { $comfyKeepAlive = [bool]$settings.comfyKeepAlive }
    [void](Stop-ComfyLeaks)
    if (!$comfyKeepAlive -or $Profile -ne 'lite') { [void](Stop-IdleComfy) }
    # Uygulamaya ait artik GPU isçileri (bosta kalmis ses/OCR iscisi) da kapatilir: cokme ya
    # da zorla kapatma sonrasi CUDA baglamlari dil modelinin ince payini yiyebilir. Boylece
    # model yuklenmeden ONCE otomatik VRAM temizligi yapilir (yalnizca MamidLabs surecleri).
    [void](Stop-OrphanWorkers)
    # Onceki surec zaten yukarida durduruldu; bos VRAM burada olculur ki eski
    # surecin bosalttigi bellek de sayilsin.
    #
    # ASR/OCR sonrasi geri yuklemede (ozellikle 8 GB LITE'ta) kelimenin tam anlamiyla
    # bir YARIS vardir: transkripsiyon/PaddleOCR alt sureci cikar ama WDDM VRAM'i aninda
    # serbest birakmaz; hemen baslayan dil modeli "yer yetmiyor" ile reddedilir ve model
    # kapali kalir. Bu yuzden yer kontrolu sinirli kez (kisa araliklarla) yeniden denenir.
    # Baglam secimi (MAX/FLASH): once 32K denenir, sigmazsa 16K'ya dusulur. Olculdu: 32K,
    # 16 GB kartta ~15,77 GiB ister ama normal bir Windows masaustu yalnizca ~15,50 GiB
    # bos birakir; bu yuzden yuklendiginde ~400 MiB paylasilan bellege tasip sohbet
    # ~27 tok/s'ye dusuyordu. 16K'da ayak izi ~15,32 GiB olur, tam sigar ve ~40 tok/s ile
    # calisir (ayni model/agirliklar, yarim KV cache). Secilen baglam HEM bellek kapisinda
    # HEM asagidaki --ctx-size'ta kullanilir; arayuz gercek degeri calisan sunucudan geri
    # okur (bkz. mamidlabs-desktop.ps1). LITE kendi baglamini korur ve dususu yoktur
    # (9B zaten 8 GB karta sigar).
    $ctxCandidates = if ($Profile -eq 'lite') { @([int]$liteCtx) } else { @(32768, 16384) }
    $modelCtx = $ctxCandidates[0]
    if (!$SkipMemoryCheck) {
        $budgetOk = $false
        $lastBudgetError = $null
        $attempts = 8
        for ($attempt = 1; $attempt -le $attempts; $attempt++) {
            $chosenCtx = $null
            foreach ($candidate in $ctxCandidates) {
                try { Test-MemoryBudget $model $Profile $projector $candidate; $chosenCtx = $candidate; break }
                catch { $lastBudgetError = $_ }
            }
            if ($chosenCtx) { $modelCtx = $chosenCtx; $budgetOk = $true; break }
            # Ilk denemede ComfyUI acik olabilir: kuyruk bossa kapat ve hemen tekrar dene.
            if ($attempt -eq 1 -and (Stop-IdleComfy)) { continue }
            # ASR/OCR alt surecinin VRAM'i birakmasi icin kisa bekleme (toplam ~7 sn).
            if ($attempt -lt $attempts) { Start-Sleep -Milliseconds 1000 }
        }
        if (!$budgetOk) { throw $lastBudgetError }
    }
    New-Item -ItemType Directory -Path $logs -Force | Out-Null

    # Cikti siniri uc profilde de 8192: dusunme ACIK oldugu icin dusunme tokenlari bu cikti
    # butcesini paylasir; 3072/4096 kucuk kaliyordu ve model tamamen dusunup GORUNUR YANIT
    # URETMEDEN kesilebiliyordu ("bos yanit"). 8192 bir TAVANDIR, hedef degil: uretim EOS'ta
    # durur, bu yuzden normal yanitlarin hizi degismez. Arayuz istegi de max_tokens=8192
    # gonderir; sunucu bunu karsilamali.
    $predict = switch ($Profile) { 'lite' { '8192' } 'flash' { '8192' } default { '8192' } }
    # Model adları max/flash/lite'tir; llama.cpp şablonu için karşılık gelen reasoning
    # değerleri hâlâ low/xhigh olarak gönderilir.
    $reasoningEffort = if ($Profile -eq 'max') { 'xhigh' } else { 'low' }
    if ($Profile -eq 'lite') {
        # 8 GB VRAM butcesi: ~6,5 GB agirlik + ~0,46 GB MTP basligi + q4_0 KV cache + hesap tamponu.
        # Gorsel projektoru CPU'da (--no-mmproj-offload): Q8_0 mmproj (595 MiB)
        # GPU'da 8 GB karta sigmiyordu. Windows masaustu de 0,5-1 GB VRAM tuttugu
        # icin varsayilan 32K baglamdir ($liteCtx yukarida, settings.liteContext
        # ile degistirilebilir); batch kucultulerek tepe VRAM ayrica asagi cekilir.
        $serverArgs = @(
            '--model', $model,
            '--alias', $desiredAlias, '--host', '127.0.0.1', '--port', '8080',
            '--ctx-size', $liteCtx, '--predict', $predict, '--parallel', '1',
            '--gpu-layers', '99', '--flash-attn', 'on', '--cache-type-k', 'q4_0',
            '--cache-type-v', 'q4_0', '--cache-reuse', '256', '--batch-size', '256', '--ubatch-size', '128',
            '--threads', '4', '--threads-batch', '8', '--jinja', '--reasoning', 'on',
            '--reasoning-effort', $reasoningEffort, '--reasoning-format', 'deepseek',
            '--metrics', '--no-context-shift'
        )
        # Projektor yalnizca klasorde varsa eklenir; yoksa Lite metin-only calisir.
        # --no-mmproj-offload: Q8_0 mmproj (595 MiB) 8 GB karta sigmiyor ve buyuk
        # gomme tensorunu CPU'ya iterek VRAM'i sinirdan tasiriyordu; CPU'da ~636 MiB
        # VRAM bosalir, sohbet hizi degismez, gorsel okuma yalnizca biraz yavaslar.
        if ($projector) { $serverArgs += @('--mmproj', $projector, '--no-mmproj-offload', '--image-min-tokens', '512') }
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
            '--ctx-size', "$modelCtx", '--predict', $predict, '--parallel', '1',
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
    # Cagiranin stdout borusunu devretmeden baslat; yoksa "manage-mamidlabs | ..." bitmez.
    $child = Start-DetachedProcess $server $serverArgs (Split-Path $server) `
        (Join-Path $logs "mamidlabs-$Profile.stdout.log") (Join-Path $logs "mamidlabs-$Profile.stderr.log")
    if (!$child) { throw 'Model süreci başlatılamadı.' }
    "Yükleniyor: $desiredAlias (PID $($child.Id))"
}
finally {
    if ($ownsGate) { $gate.ReleaseMutex() | Out-Null }
    $gate.Dispose()
}
