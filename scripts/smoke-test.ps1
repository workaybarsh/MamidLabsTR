#Requires -Version 5.1
<#
.SYNOPSIS
    Kurulum sonrasi uctan uca duman testi: sohbet, belge, cevrimdisi araclar, ag gecisleri, gecmis devam, OCR, gorsel, fotograf duzenleme, video ve gercek arayuz (MTP + baglanti hatasi kontrolu).

.DESCRIPTION
    install-mamidlabs.ps1 yalnizca altyapiyi hazirlar (binary'ler, ortamlar);
    model dosyalari uygulama icindeki Profiller menusunden ayrica indirilir.
    Bu script o adimdan sonra calistirilir: gercek modeli yukler, gercek bir
    istek gonderir, gercek bir belge/gorsel/video ureterek her bilesenin
    calistigini kanitlar. "Kaynakta var" ile "calistigi kanitlandi" arasindaki
    farki kapatir (bkz. README "Bilinen notlar" ve kurulum analizindeki
    "Kurulum sonrasi smoke test" maddesi).

    Her adim bagimsizdir: biri basarisiz olursa digerleri yine de denenir,
    sonda hepsinin ozeti raporlanir. Sifirdan farkli cikis kodu en az bir
    adimin basarisiz oldugu anlamina gelir.

.EXAMPLE
    pwsh -File scripts\smoke-test.ps1 -Profile lite
    Sohbet + belge + gorsel + video, hepsi.

.EXAMPLE
    pwsh -File scripts\smoke-test.ps1 -Profile lite -SkipVideo -SkipImage
    Yalnizca sohbet ve belge; hizli dogrulama icin.

.NOTES
    Gorsel adimi gercek uygulamadaki gibi dil modelini bosaltip geri yukler;
    ardindan "medya sonrasi gecis" adimi dil modelinin geri geldigini, VRAM
    tasmasi olmadan (hiz dusmeden) calistigini olcer. 8 GB LITE kartta gorsel
    sonrasi model gecisinin dogrulamasi budur. Sonuc logs\smoke-test-son.json
    dosyasina da yazilir (kurulum sihirbazi ozetinde gosterilir).
#>
param(
    [ValidateSet('max', 'flash', 'lite')][string]$Profile = 'lite',
    [string]$Root = (Join-Path $env:LOCALAPPDATA 'Programs\MamidLabs'),
    [switch]$SkipChat,
    [switch]$SkipDocument,
    [switch]$SkipImage,
    [switch]$SkipVideo,
    [switch]$SkipOcr,
    [switch]$SkipEdit,
    # Cevrimdisi araclar adimini atlar (ag engeli uygulanmasi istenmiyorsa).
    [switch]$SkipOffline,
    # Ag gecisi (online<->offline) adimini atlar.
    [switch]$SkipNetworkSwitch,
    # Gecmis sohbetten devam (kapat -> ac -> yukle -> devam) adimini atlar.
    [switch]$SkipHistoryResume,
    # Gercek arayuzu (masaustu uygulamasini) baslatip MTP ve baglanti hatasi
    # kontrolunu atlar.
    [switch]$SkipUi,
    # MTP (speculative decoding) dogrulama adimini atlar.
    [switch]$SkipMtp,
    # Bagimsiz grafik uretimi (agent\chart-run.ps1) adimini atlar.
    [switch]$SkipChart,
    # Medya sonrasi sohbet hizi bu orandan (ilk olcume gore) duserse VRAM tasmasi sayilir.
    [double]$MinSpeedRatio = 0.7,
    [string]$ReportPath
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if (!(Get-Command Start-ThreadJob -ErrorAction SilentlyContinue)) { Import-Module ThreadJob -ErrorAction Stop }

$manage = Join-Path $Root 'scripts\manage-qwen.ps1'
$results = [ordered]@{}
$lite = ($Profile -eq 'lite')
$script:chatBaseline = $null
$script:lastImage = $null
if (!$ReportPath) { $ReportPath = Join-Path $Root 'logs\smoke-test-son.json' }

function Write-Section([string]$text) { Write-Host ''; Write-Host ('== ' + $text) -ForegroundColor Cyan }
function Report([string]$name, [bool]$ok, [string]$detail) {
    $results[$name] = @{ ok = $ok; detail = $detail; skipped = $false }
    $mark = if ($ok) { '[GECTI]' } else { '[HATA] ' }
    $color = if ($ok) { 'Green' } else { 'Red' }
    Write-Host ("   $mark $name - $detail") -ForegroundColor $color
}

function Wait-ForHealth([int]$timeoutSeconds) {
    $deadline = [DateTime]::UtcNow.AddSeconds($timeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            $health = Invoke-RestMethod 'http://127.0.0.1:8080/health' -TimeoutSec 2 -ErrorAction Stop
            if ($health.status -eq 'ok') { return $true }
        } catch { }
        Start-Sleep -Milliseconds 1000
    }
    return $false
}

# Atlanan adimlar ozette gorunur ama basarisiz sayilmaz.
function Skip([string]$name, [string]$reason) {
    $results[$name] = @{ ok = $true; detail = $reason; skipped = $true }
    Write-Host ("   [atla]  $name - $reason") -ForegroundColor DarkGray
}

function Get-FreeVramMiB {
    $smi = (Get-Command nvidia-smi -ErrorAction SilentlyContinue).Source
    if (!$smi) { return $null }
    try { return [int](((& $smi --query-gpu=memory.free --format=csv,noheader,nounits) | Select-Object -First 1) -replace '\D', '') } catch { return $null }
}

# GGUF basliginda MTP/nextn blogu var mi? (bkz. scripts\manage-qwen.ps1 Test-GgufHasMtp
# ve agent\mtp_inject.py). MTP dogrulama adimi bunu kullanir.
function Test-MtpInGguf([string]$Path) {
    try {
        $fs = [IO.File]::OpenRead($Path)
        try {
            $buffer = [byte[]]::new(16777216)
            $read = $fs.Read($buffer, 0, $buffer.Length)
        }
        finally { $fs.Dispose() }
        return ([Text.Encoding]::ASCII.GetString($buffer, 0, $read)).Contains('nextn')
    }
    catch { return $false }
}

function Test-ComfyRunning {
    return [bool](Get-CimInstance Win32_Process -Filter "Name='python.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*ComfyUI\main.py*' } | Select-Object -First 1)
}

# Tek bir sohbet istegi gonderir; icerik, token sayisi, sure ve sunucunun olctugu
# uretim hizini (timings.predicted_per_second) dondurur.
function Invoke-ChatProbe {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    # reasoning_effort='low' + chat_template_kwargs, gercek uretim istegiyle
    # (qwen-inference.ps1 icindeki Set-LowEffortRequest) ayni sekle getirir.
    # Lite artik bir dusunme butcesi kullanmaz (dusunme acik ve sinirsizdir); dusunme
    # tokenlari CIKTI butcesini paylasir. Bu yuzden yanit icin LITE sunucusunun cikti
    # siniri kadar pay birakilir (8192, manage-qwen.ps1 $predict); aksi halde model butun
    # limiti dusunerek harcayip gercek icerik uretmeden kesilebilir. Ayni hata gercek
    # makinede kucuk max_tokens ile yakalandi ("bos yanit").
    $body = @{
        model = "smoke-$Profile"
        messages = @(@{ role = 'user'; content = 'Bir cumleyle kendini tanit.' })
        max_tokens = 8192
        reasoning_effort = 'low'
        chat_template_kwargs = @{ reasoning_effort = 'low' }
    } | ConvertTo-Json -Depth 5
    $response = Invoke-RestMethod 'http://127.0.0.1:8080/v1/chat/completions' -Method Post `
        -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 180
    $content = [string]$response.choices[0].message.content
    if ([string]::IsNullOrWhiteSpace($content)) { throw 'Model bos yanit dondurdu (yanit icin ayrilan tokenlar dusunmede tukenmis olabilir).' }
    $tokens = [int]$response.usage.completion_tokens
    $tps = if ($response.timings -and $response.timings.predicted_per_second) { [double]$response.timings.predicted_per_second }
           elseif ($sw.Elapsed.TotalSeconds -gt 0) { $tokens / $sw.Elapsed.TotalSeconds } else { 0 }
    return @{ content = $content; tokens = $tokens; seconds = [int]$sw.Elapsed.TotalSeconds; tps = [math]::Round($tps, 1) }
}

# ------------------------------------------------------------------- sohbet
Write-Section 'Sohbet modeli'
if ($SkipChat) {
    Write-Host '   [atla] -SkipChat verildi'
} else {
    try {
        & $manage -Action stop | Out-Null
        & $manage -Action start -Profile $Profile | Out-Null
        if (!(Wait-ForHealth 120)) { throw 'Model 120 saniyede hazir olmadi.' }
        $probe = Invoke-ChatProbe
        $script:chatBaseline = $probe
        Report 'sohbet' $true ("$($probe.tokens) token, $($probe.seconds) sn, $($probe.tps) tok/s, yanit: " + $probe.content.Substring(0, [Math]::Min(60, $probe.content.Length)))
    } catch {
        Report 'sohbet' $false $_.Exception.Message
    }
}

# ----------------------------------------------------------------------- MTP
# MTP (speculative decoding) gercekten etkin ve islevsel mi? Sunucu --spec-type
# draft-mtp ile baslatildiysa /completion yanitinin timings'i draft_n ve
# draft_n_accepted tasir; bunlar draft tokenlarin uretildigini ve kabul edildigini
# kanitlar. Kabul 0 ise baslik islevsizdir (bkz. agent/mtp_inject.py norm +1 notu).
Write-Section 'MTP (speculative decoding)'
if ($SkipMtp) {
    Write-Host '   [atla] -SkipMtp verildi'
} elseif (!(Wait-ForHealth 5)) {
    Skip 'mtp' 'dil modeli hazir degil (sohbet adimi calismamis olabilir)'
} else {
    try {
        $settingsPath = Join-Path $Root 'settings\api.json'
        $mtpOn = $true
        if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
            $settings = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($null -ne $settings.mtp) { $mtpOn = [bool]$settings.mtp }
        }
        if (!$mtpOn) {
            Skip 'mtp' 'settings/api.json -> mtp=false (kullanici kapatti)'
        } else {
            $props = Invoke-RestMethod 'http://127.0.0.1:8080/props' -TimeoutSec 10
            $modelPath = [string]$props.model_path
            if (!$modelPath -or !(Test-Path -LiteralPath $modelPath -PathType Leaf)) {
                throw "Model yolu okunamadi: $modelPath"
            }
            if (!(Test-MtpInGguf $modelPath)) {
                Skip 'mtp' 'model GGUF unda MTP/nextn katmani yok (bu profilde desteklenmiyor)'
            } else {
                $body = @{
                    prompt = "Write a numbered list from 1 to 30, one item per line.`n1."
                    n_predict = 128; temperature = 0; seed = 1234; cache_prompt = $false; stream = $false
                } | ConvertTo-Json
                $resp = Invoke-RestMethod 'http://127.0.0.1:8080/completion' -Method Post `
                    -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 180
                $draftN = [int]$resp.timings.draft_n
                $acc = [int]$resp.timings.draft_n_accepted
                if ($draftN -le 0) {
                    Report 'mtp' $false 'MTP etkin degil: hic draft token uretilmedi (--spec-type draft-mtp verilmemis olabilir)'
                } elseif ($acc -le 0) {
                    Report 'mtp' $false "MTP etkin ama kabul 0/$draftN (draft basligi islevsiz olabilir)"
                } else {
                    $rate = [math]::Round($acc / $draftN, 3)
                    Report 'mtp' $true "draft-mtp etkin: kabul $acc/$draftN (oran $rate)"
                }
            }
        }
    } catch {
        Report 'mtp' $false $_.Exception.Message
    }
}

# ------------------------------------------------------------------- belge
# ------------------------------------------------------------------- grafik
# Bagimsiz grafik ureticisi: gomulu pwsh + System.Drawing ile PNG uretir (GPU/ComfyUI
# gerekmez). Ayni kod yolu sohbet araci generate_chart tarafindan da kullanilir.
Write-Section 'Grafik uretimi (bagimsiz, System.Drawing)'
if ($SkipChart) {
    Write-Host '   [atla] -SkipChart verildi'
} else {
    try {
        $chartScript = Join-Path $Root 'agent\chart-run.ps1'
        if (!(Test-Path -LiteralPath $chartScript -PathType Leaf)) { throw "Grafik betigi bulunamadi: $chartScript" }
        $chartPwsh = Join-Path $Root 'runtime\pwsh\pwsh.exe'
        if (!(Test-Path -LiteralPath $chartPwsh -PathType Leaf)) { throw "Gomulu pwsh bulunamadi: $chartPwsh" }
        $chartDir = Join-Path $Root 'outputs\grafikler'
        if (!(Test-Path -LiteralPath $chartDir -PathType Container)) { New-Item -ItemType Directory -Path $chartDir -Force | Out-Null }
        $chartCases = @(
            @{ name = 'bar'; spec = @{ type = 'bar'; labels = @('Ocak', 'Subat', 'Mart'); values = @(3, 7, 4); title = 'Smoke bar' } },
            @{ name = 'pie'; spec = @{ type = 'pie'; labels = @('X', 'Y', 'Z'); values = @(5, 3, 2); title = 'Smoke pasta' } },
            @{ name = 'function'; spec = @{ type = 'function'; functions = @('sin(x)', 'x^2'); xmin = -3; xmax = 3; title = 'Smoke fonksiyon' } }
        )
        $chartMade = 0
        foreach ($chartCase in $chartCases) {
            $spec = $chartCase.spec
            $spec.out = Join-Path $chartDir ('smoke-' + $chartCase.name + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.png')
            $psi = [Diagnostics.ProcessStartInfo]::new()
            $psi.FileName = $chartPwsh
            foreach ($arg in @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $chartScript)) { $psi.ArgumentList.Add($arg) }
            $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
            $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
            $psi.StandardInputEncoding = [Text.UTF8Encoding]::new($false)
            $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
            $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
            $chartProc = [Diagnostics.Process]::Start($psi)
            try {
                $chartProc.StandardInput.Write(($spec | ConvertTo-Json -Depth 8 -Compress))
                $chartProc.StandardInput.Close()
                $chartOut = $chartProc.StandardOutput.ReadToEnd()
                $chartErr = $chartProc.StandardError.ReadToEnd()
                $chartProc.WaitForExit()
            } finally { $chartProc.Dispose() }
            $chartResult = $null
            try { $chartResult = $chartOut | ConvertFrom-Json -ErrorAction Stop } catch { }
            if (!$chartResult) { throw "Grafik ($($chartCase.name)) gecersiz yanit: $chartOut $chartErr" }
            if ($chartResult.error) { throw "Grafik ($($chartCase.name)) hatasi: $($chartResult.error)" }
            if (!(Test-Path -LiteralPath ([string]$chartResult.path) -PathType Leaf)) { throw "Grafik ($($chartCase.name)) dosyasi olusmadi." }
            $chartMade++
        }
        Report 'grafik' $true "$chartMade tur uretildi (bar, pie, function); outputs\grafikler"
    } catch {
        Report 'grafik' $false $_.Exception.Message
    }
}

Write-Section 'Belge okuma (gercek .docx)'
if ($SkipDocument) {
    Write-Host '   [atla] -SkipDocument verildi'
} else {
    $python = Join-Path $Root 'venv\app\Scripts\python.exe'
    $docPath = Join-Path $env:TEMP 'mamidlabs-smoke-test.docx'
    $marker = 'MAMIDLABS-SMOKE-' + (Get-Random -Maximum 999999)
    try {
        if (!(Test-Path -LiteralPath $python -PathType Leaf)) { throw "uygulama ortami yok: $python" }
        & $python -c "from docx import Document; d = Document(); d.add_paragraph('$marker'); d.save(r'$docPath')"
        if ($LASTEXITCODE -ne 0) { throw 'Test belgesi olusturulamadi (python-docx).' }
        # office-tools.py'nin ACTIONS tablosunda 'read_document' diye bir islem yok
        # (yalnizca read_docx/read_pdf/... var; 'read_document' sadece qwen-inference.ps1
        # icindeki arac ADI - uzantiya gore dogru action'a cevrilir). Gercek makinede
        # yakalandi: yanlis action adi "bilinmeyen islem" hatasi veriyordu.
        $job = @{ action = 'read_docx'; path = $docPath } | ConvertTo-Json -Compress
        $out = $job | & $python (Join-Path $Root 'agent\office-tools.py') 2>&1 | Out-String
        if ($out -notmatch [regex]::Escape($marker)) { throw "Okunan icerikte isaret metni bulunamadi. Cikti: $($out.Substring(0, [Math]::Min(200, $out.Length)))" }
        Report 'belge' $true 'Olusturulan .docx dogru sekilde geri okundu'
    } catch {
        Report 'belge' $false $_.Exception.Message
    } finally {
        Remove-Item -LiteralPath $docPath -Force -ErrorAction SilentlyContinue
    }
}

# ------------------------------------------------------------- cevrimdisi
# Internet cipi acikken ag kopmasi (hotspot, DNS zaman asimi): web araci istisna
# atmadan gecerli bir hata JSON'u dondurmelidir. Bu senaryo, gercek makinede
# tekrar tekrar gorulen "Varolan bir baglanti ... zorla kapatildi" hatasini
# besliyordu; arac katmani artik cokmuyor. Ag erisimi kara delik proxy ile
# kesilir (kullanici ayarini bozmamak icin gecici).
Write-Section 'Cevrimdisi araclar'
if ($SkipOffline) {
    Write-Host '   [atla] -SkipOffline verildi'
} else {
    $python = Join-Path $Root 'venv\app\Scripts\python.exe'
    try {
        if (!(Test-Path -LiteralPath $python -PathType Leaf)) { throw "uygulama ortami yok: $python" }
        $savedHttp = $env:HTTP_PROXY; $savedHttps = $env:HTTPS_PROXY
        $env:HTTP_PROXY = 'http://127.0.0.1:9'; $env:HTTPS_PROXY = 'http://127.0.0.1:9'
        try {
            $payload = @{ action = 'search_web'; query = 'offline smoke test'; count = 2 } | ConvertTo-Json -Compress
            $out = $payload | & $python (Join-Path $Root 'agent\qwen-agent-tools.py') 2>&1 | Out-String
            $code = $LASTEXITCODE
        } finally {
            $env:HTTP_PROXY = $savedHttp; $env:HTTPS_PROXY = $savedHttps
        }
        if ($code -ne 0) { throw "Arac coktu (cikis kodu $code): $($out.Substring(0, [Math]::Min(200, $out.Length)))" }
        $parsed = $out | ConvertFrom-Json
        if (!$parsed.error) { throw "Ag yokken hata JSON'u dondurmedi: $($out.Substring(0, [Math]::Min(200, $out.Length)))" }
        Report 'cevrimdisi' $true 'Ag yokken web araci cokmeden gecerli hata JSON dondurdu'
    } catch {
        Report 'cevrimdisi' $false $_.Exception.Message
    }
}

# ----------------------------------------------- ag gecisleri (online <-> offline)
# Kullanici sikayeti: internet acikken kopmasi ya da konusma ortasinda internetin
# gidip gelmesi; yanit verilse bile cevabin altina "[Hata] ... zorla kapatildi"
# ekleniyordu. Ardisik turlarda ag durumu degistirilir; yerel isci hicbir turda
# 'error' olayi uretmemelidir. Ag erisimi kara delik proxy ile kesilir ve ayar
# bozulmasin diye sonunda geri yuklenir.
Write-Section 'Ag gecisleri (online <-> offline)'
if ($SkipNetworkSwitch) {
    Write-Host '   [atla] -SkipNetworkSwitch verildi'
} elseif (!(Wait-ForHealth 5)) {
    Skip 'ag_gecisi' 'dil modeli hazir degil (sohbet adimi calismamis olabilir)'
} else {
    $savedHttp = $env:HTTP_PROXY; $savedHttps = $env:HTTPS_PROXY
    try {
        $plan = @(
            @{ label = 'acik';   online = $true;  prompt = 'Bir cumleyle kendini tanit.' }
            @{ label = 'kapali'; online = $false; prompt = 'Turkiye nin baskenti neresi? Kisa yanitla.' }
            @{ label = 'acik';   online = $true;  prompt = 'Einstein bilmecesi nedir? Kisa anlat.' }
        )
        $turnErrors = 0; $seen = @()
        foreach ($step in $plan) {
            if ($step.online) { Remove-Item Env:HTTP_PROXY, Env:HTTPS_PROXY -ErrorAction SilentlyContinue }
            else { $env:HTTP_PROXY = 'http://127.0.0.1:9'; $env:HTTPS_PROXY = 'http://127.0.0.1:9' }
            $jobData = @{
                root = $Root
                messages = @(@{ role = 'user'; content = $step.prompt })
                provider = 'local'; model = "smoke-$Profile"; profile = $Profile
                maxTokens = 500; contextLimit = 32768; boundFolder = $null
                consultProviders = @{}; attachedDocuments = @(); currentImagePaths = @()
                hasCurrentImage = $false; multiImageOcr = $false; multiImageOcrMode = $false
                internet = $true; agent = $false; office = $false; documentCreate = $false; effort = 'low'
            }
            $shared = [hashtable]::Synchronized(@{ Cancel = $false; Cts = $null; AccessMode = 'full'
                AskTool = $null; AskDetail = $null; AskAnswer = $null; AskId = $null; AskDeadline = $null })
            $job = Start-ThreadJob -FilePath (Join-Path $Root 'agent\qwen-inference.ps1') -ArgumentList $jobData, $shared
            $items = @(Receive-Job -Job $job -Wait)
            Remove-Job -Job $job -Force
            $err = @($items | Where-Object { $_.kind -eq 'error' })
            if ($err.Count) { $turnErrors += $err.Count; $seen += ($step.label + ':' + [string]$err[0].text) }
        }
        if ($turnErrors -gt 0) {
            Report 'ag_gecisi' $false ("$turnErrors hata -> " + ($seen -join ' | '))
        } else {
            Report 'ag_gecisi' $true 'Ag acik/kapali degisirken hicbir tur hata vermedi'
        }
    } catch {
        Report 'ag_gecisi' $false $_.Exception.Message
    } finally {
        $env:HTTP_PROXY = $savedHttp; $env:HTTPS_PROXY = $savedHttps
    }
}

# ------------------------------------------- gecmis sohbetten devam (kapat -> ac)
# Kullanici senaryosu: konusma ortasinda programi kapat, yeniden ac, gecmis
# sohbetlerden yukle ve devam et. Sohbet, modele donuk mesaj dizisi olarak DPAPI
# ile sifreli saklanir (Save-Chat); yeniden acilinca ayni sekilde yuklenir
# (Load-Chat) ve devam turu bu gecmisle gonderilir. Bu adim, tam serilestirme
# gidis-donusunu + devam turunu calistirir; hicbir turda hata olmamali.
Write-Section 'Gecmis sohbetten devam (kapat -> ac)'
if ($SkipHistoryResume) {
    Write-Host '   [atla] -SkipHistoryResume verildi'
} elseif (!(Wait-ForHealth 5)) {
    Skip 'gecmis_devam' 'dil modeli hazir degil (sohbet adimi calismamis olabilir)'
} else {
    try {
        Add-Type -AssemblyName System.Security.Cryptography.ProtectedData -ErrorAction SilentlyContinue
        $prefix = 'MAMIDLABS-CHAT-DPAPI-V2'
        $chatFile = Join-Path $env:TEMP 'mamidlabs-smoke-reload.json'
        $turns = @(
            @{ role = 'user'; content = 'Bugunun dolar kuru kac TL? Guncel bilgi lazim.' }
        )
        # 1) Ilk tur: arac cagrisini da tetikleyebilecek gercek bir istek.
        $jobData = @{
            root = $Root; messages = @($turns)
            provider = 'local'; model = "smoke-$Profile"; profile = $Profile
            maxTokens = 400; contextLimit = 32768; boundFolder = $null
            consultProviders = @{}; attachedDocuments = @(); currentImagePaths = @()
            hasCurrentImage = $false; multiImageOcr = $false; multiImageOcrMode = $false
            internet = $true; agent = $false; office = $false; documentCreate = $false; effort = 'low'
        }
        $shared = [hashtable]::Synchronized(@{ Cancel = $false; Cts = $null; AccessMode = 'full'
            AskTool = $null; AskDetail = $null; AskAnswer = $null; AskId = $null; AskDeadline = $null })
        $job = Start-ThreadJob -FilePath (Join-Path $Root 'agent\qwen-inference.ps1') -ArgumentList $jobData, $shared
        $items = @(Receive-Job -Job $job -Wait); Remove-Job -Job $job -Force
        $err1 = @($items | Where-Object { $_.kind -eq 'error' })
        if ($err1.Count) { throw "Ilk tur hata verdi: $($err1[0].text)" }
        $done = @($items | Where-Object { $_.kind -eq 'done' }) | Select-Object -Last 1
        if (!$done) { throw 'Ilk tur done olayi uretmedi.' }
        # Kalici mesaj dizisi: kullanici mesaji + done'in tasidigi arac degisimi.
        # DIKKAT: arac cagrilmadiysa $done.data BOS dizi olur ve Start-ThreadJob sinirindan
        # $null olarak doner; @($done.data) bunu @($null) yapip listeye bos bir mesaj ekler ve
        # sunucu "All non-assistant messages must contain 'content'" ile 400 doner (testte
        # yakalandi). Gercek arayuz zaten `if ($jobEvent.data)` ile koruyor (bkz. Render-JobEvent);
        # burada da ayni koruma sart.
        $chatMessages = @($turns)
        if ($done.data) { $chatMessages += @($done.data) }
        # 2) Save-Chat gibi kaydet (DPAPI).
        $payload = @{ id = 'smoketest000000000000000000000000'; title = 'smoke-reload'; messages = @($chatMessages); transcript = @() }
        $json = $payload | ConvertTo-Json -Depth 30
        $cipher = [Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes($json), $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
        [IO.File]::WriteAllText($chatFile, ($prefix + "`n" + [Convert]::ToBase64String($cipher)), [Text.UTF8Encoding]::new($false))
        # 3) Load-Chat gibi yukle.
        $raw = Get-Content -LiteralPath $chatFile -Raw -Encoding UTF8
        $plain = [Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect(
            [Convert]::FromBase64String($raw.Substring($prefix.Length + 1).Trim()), $null, [Security.Cryptography.DataProtectionScope]::CurrentUser))
        $reloaded = @(($plain | ConvertFrom-Json).messages)
        # Model araç çağırmadan yanıtlamış olabilir; o durumda yalnızca kullanıcı mesajı kaydedilir.
        # En az kullanıcı mesajı yüklenmiş olması yeterlidir (aksi halde boş sohbet).
        if ($reloaded.Count -lt 1) { throw "Yuklenen gecmis bos ($($reloaded.Count) mesaj)." }
        # 4) Devam turu: yuklenen gecmise yeni kullanici mesaji ekle.
        $jobData2 = $jobData.Clone(); $jobData2.messages = @($reloaded) + @(@{ role = 'user'; content = 'Peki bunu bir cumlede ozetle.' })
        $shared2 = [hashtable]::Synchronized(@{ Cancel = $false; Cts = $null; AccessMode = 'full'
            AskTool = $null; AskDetail = $null; AskAnswer = $null; AskId = $null; AskDeadline = $null })
        $job2 = Start-ThreadJob -FilePath (Join-Path $Root 'agent\qwen-inference.ps1') -ArgumentList $jobData2, $shared2
        $items2 = @(Receive-Job -Job $job2 -Wait); Remove-Job -Job $job2 -Force
        $err2 = @($items2 | Where-Object { $_.kind -eq 'error' })
        if ($err2.Count) { throw "Devam turu hata verdi: $($err2[0].text)" }
        Report 'gecmis_devam' $true ("Kaydedildi, yuklendi ($($reloaded.Count) mesaj) ve devam edildi; hata yok")
    } catch {
        Report 'gecmis_devam' $false $_.Exception.Message
    } finally {
        Remove-Item -LiteralPath (Join-Path $env:TEMP 'mamidlabs-smoke-reload.json') -Force -ErrorAction SilentlyContinue
    }
}

# --------------------------------------------------------------------- OCR
Write-Section 'OCR (GPU gorsel + CPU PDF)'
if ($SkipOcr) {
    Write-Host '   [atla] -SkipOcr verildi'
} else {
    $ocrPython = Join-Path $Root 'venv\ocr\Scripts\python.exe'
    $ocrCpuPython = Join-Path $Root 'venv\ocr-cpu\Scripts\python.exe'
    $imgPath = Join-Path $env:TEMP 'mamidlabs-smoke-ocr.png'
    $pdfPath = Join-Path $env:TEMP 'mamidlabs-smoke-ocr.pdf'
    $marker = 'MAMIDLABSOCR' + (Get-Random -Maximum 9999)
    try {
        if (!(Test-Path -LiteralPath $ocrPython -PathType Leaf)) { throw "ocr ortami yok: $ocrPython. Once scripts\install-ocr.ps1 calistir." }
        # Net, buyuk fontlu bir test gorseli: System.Drawing ile, ek bagimlilik gerekmez.
        Add-Type -AssemblyName System.Drawing
        $bmp = New-Object System.Drawing.Bitmap(500, 120)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.Clear([System.Drawing.Color]::White)
        $font = New-Object System.Drawing.Font('Arial', 28, [System.Drawing.FontStyle]::Bold)
        $g.DrawString($marker, $font, [System.Drawing.Brushes]::Black, 10, 30)
        $g.Dispose()
        $bmp.Save($imgPath, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()

        # -- GPU: duz gorsel --
        $reqImage = @{ action = 'ocr_image'; path = $imgPath } | ConvertTo-Json -Compress
        $outImage = $reqImage | & $ocrPython (Join-Path $Root 'agent\ocr-tools.py') | Out-String
        $parsedImage = $outImage | ConvertFrom-Json
        if ($parsedImage.error) { throw "GPU OCR hatasi: $($parsedImage.error)" }
        if ($parsedImage.text -notmatch [regex]::Escape($marker.Substring(0, 8))) {
            throw "GPU OCR beklenen metni bulamadi. Cikti: $($parsedImage.text)"
        }

        # -- CPU: taranmis PDF (native metin katmani yok, sayfa goruntu olarak OCR'lanir) --
        & $ocrCpuPython -c "import fitz; d = fitz.open(); p = d.new_page(width=500, height=120); p.insert_image(fitz.Rect(0, 0, 500, 120), filename=r'$imgPath'); d.save(r'$pdfPath')"
        if ($LASTEXITCODE -ne 0) { throw 'Test PDF olusturulamadi (PyMuPDF).' }
        $reqPdf = @{ action = 'ocr_pdf'; path = $pdfPath } | ConvertTo-Json -Compress
        $outPdf = $reqPdf | & $ocrCpuPython (Join-Path $Root 'agent\ocr-tools.py') | Out-String
        $parsedPdf = $outPdf | ConvertFrom-Json
        if ($parsedPdf.error) { throw "CPU PDF OCR hatasi: $($parsedPdf.error)" }
        if ($parsedPdf.text -notmatch [regex]::Escape($marker.Substring(0, 8))) {
            throw "CPU PDF OCR beklenen metni bulamadi. Cikti: $($parsedPdf.text)"
        }

        Report 'ocr' $true ("GPU guven $([math]::Round($parsedImage.confidence,3)), CPU guven $([math]::Round($parsedPdf.confidence,3))")
    } catch {
        Report 'ocr' $false $_.Exception.Message
    } finally {
        Remove-Item -LiteralPath $imgPath, $pdfPath -Force -ErrorAction SilentlyContinue
    }
}

# ------------------------------------------------------------------ gorsel
Write-Section 'Gorsel uretimi'
if ($SkipImage) {
    Write-Host '   [atla] -SkipImage verildi'
} else {
    try {
        # Lite'in GGUF kuantize Krea-2'si ComfyUI-GGUF custom node'unun aradigi
        # models\unet altindadir; MAX/FLASH'in tam hassasiyetli surumu diffusion_models altinda.
        $checkpointDir = if ($lite) { Join-Path $Root 'ComfyUI\models\unet' } else { Join-Path $Root 'ComfyUI\models\diffusion_models' }
        $pattern = '*krea2*'
        if (!(Get-ChildItem -LiteralPath $checkpointDir -Filter $pattern -File -ErrorAction SilentlyContinue)) {
            throw "Gorsel modeli bulunamadi ($checkpointDir icinde $pattern). Once Profiller menusunden indir."
        }
        $jobData = @{
            root = $Root
            prompt = 'Basit bir test gorseli: mavi gokyuzu ve yesil cim'
            # Sohbet adimi calistiysa gercek uygulamadaki gibi dil modeli bosaltilip geri yuklenir.
            aspect = '1:1'; restoreProfile = $(if ($script:chatBaseline) { $Profile } else { '' }); mode = 'yeni'; strength = 0.6
            sourceImage = $null; realism = $false; lite = $lite
        }
        $shared = [hashtable]::Synchronized(@{ Cancel = $false; Process = $null })
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $job = Start-ThreadJob -FilePath (Join-Path $Root 'agent\imagegen-run.ps1') -ArgumentList $jobData, $shared
        $items = Receive-Job -Job $job -Wait
        Remove-Job -Job $job -Force
        $imageEvent = $items | Where-Object { $_.kind -eq 'image' } | Select-Object -Last 1
        $errorEvent = $items | Where-Object { $_.kind -eq 'error' } | Select-Object -Last 1
        if ($errorEvent) { throw $errorEvent.text }
        if (!$imageEvent -or !(Test-Path -LiteralPath $imageEvent.text -PathType Leaf)) { throw 'Cikti dosyasi olusturulmadi.' }
        $size = (Get-Item -LiteralPath $imageEvent.text).Length
        if ($size -lt 1024) { throw "Cikti dosyasi cok kucuk ($size bayt); bozuk olabilir." }
        $script:lastImage = [string]$imageEvent.text
        Report 'gorsel' $true ("$([int]$sw.Elapsed.TotalSeconds) sn, " + [IO.Path]::GetFileName($imageEvent.text) + " ($([math]::Round($size/1KB)) KB)")
    } catch {
        Report 'gorsel' $false $_.Exception.Message
    }
}

# ------------------------------------------------------- fotograf duzenleme
Write-Section 'Fotograf duzenleme (Krea 2 Identity Edit)'
$editLora = Join-Path $Root 'ComfyUI\models\loras\krea2_identity_edit_v1_2.safetensors'
$editNode = Join-Path $Root 'ComfyUI\custom_nodes\comfyui-krea2edit\__init__.py'
if ($SkipEdit -or $SkipImage) {
    Skip 'duzenleme' '-SkipEdit/-SkipImage verildi'
} elseif ($lite) {
    # 8 GB VRAM'de kimlik_duzenle sunulmaz: GGUF difuzyon modeli + metin/gorsel kodlayici ayni
    # anda VRAM'e sigmayip 641-884 sn'ye cikiyor (olcum, bkz. AGENTS.md donanim tablosu).
    Skip 'duzenleme' 'LITE profilinde desteklenmiyor (8 GB VRAM: asiri yavas, ~11-15 dk)'
} elseif (!(Test-Path -LiteralPath $editNode -PathType Leaf)) {
    Skip 'duzenleme' 'comfyui-krea2edit kurulu degil (install-mamidlabs.ps1 -Stage comfyui)'
} elseif (!(Test-Path -LiteralPath $editLora -PathType Leaf)) {
    Skip 'duzenleme' 'Identity Edit LoRA yok (Profil yoneticisi)'
} elseif (!$script:lastImage) {
    Skip 'duzenleme' 'gorsel adimi cikti uretmedi'
} else {
    try {
        $jobData = @{
            root = $Root; prompt = 'Change the sky to a warm sunset.'
            aspect = '1:1'; restoreProfile = $(if ($script:chatBaseline) { $Profile } else { '' })
            mode = 'kimlik_duzenle'; strength = 0.6; sourceImage = $script:lastImage; realism = $false; lite = $lite
        }
        $shared = [hashtable]::Synchronized(@{ Cancel = $false; Process = $null })
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $job = Start-ThreadJob -FilePath (Join-Path $Root 'agent\imagegen-run.ps1') -ArgumentList $jobData, $shared
        $items = Receive-Job -Job $job -Wait
        Remove-Job -Job $job -Force
        $imageEvent = $items | Where-Object { $_.kind -eq 'image' } | Select-Object -Last 1
        $errorEvent = $items | Where-Object { $_.kind -eq 'error' } | Select-Object -Last 1
        if ($errorEvent) { throw $errorEvent.text }
        if (!$imageEvent -or !(Test-Path -LiteralPath $imageEvent.text -PathType Leaf)) { throw 'Duzenlenmis gorsel olusturulmadi.' }
        Report 'duzenleme' $true ("$([int]$sw.Elapsed.TotalSeconds) sn, " + [IO.Path]::GetFileName($imageEvent.text))
    } catch {
        Report 'duzenleme' $false $_.Exception.Message
    }
}

# --------------------------------------------------- medya sonrasi gecis
# Gorsel isinden sonra dil modeli geri yuklenmeli ve VRAM'e tam sigmali. 8 GB
# LITE kartta ComfyUI'nin bosta kalan CUDA baglami (~300 MiB) modeli paylasilan
# bellege tasirsa sohbet hizi belirgin duser; bu adim onu yakalar.
Write-Section 'Medya sonrasi model gecisi'
if (!$script:chatBaseline -or !$script:lastImage) {
    Skip 'medya_sonrasi_gecis' 'sohbet ve gorsel adimlarinin ikisi de basarili olmali'
} else {
    try {
        if (!(Wait-ForHealth 180)) { throw 'Dil modeli gorselden sonra 180 saniyede geri gelmedi.' }
        $probe = Invoke-ChatProbe
        $ratio = if ($script:chatBaseline.tps -gt 0) { $probe.tps / $script:chatBaseline.tps } else { 1 }
        $free = Get-FreeVramMiB
        $comfyState = if (Test-ComfyRunning) { 'ComfyUI acik (modeller bosaltilmis)' } else { 'ComfyUI kapali' }
        $detail = "$($probe.tps) tok/s (ilk olcum $($script:chatBaseline.tps), oran $([math]::Round($ratio, 2))), bos VRAM $(if ($null -ne $free) { "$free MiB" } else { 'olculemedi' }), $comfyState"
        if ($ratio -lt $MinSpeedRatio) {
            throw "Sohbet hizi dustu: $detail. VRAM tasmasi olabilir; logs\qwen-$Profile.stderr.log dosyasina bak."
        }
        Report 'medya_sonrasi_gecis' $true $detail
    } catch {
        Report 'medya_sonrasi_gecis' $false $_.Exception.Message
    }
}

# -------------------------------------------------------------------- video
Write-Section 'Video uretimi'
if ($SkipVideo) {
    Write-Host '   [atla] -SkipVideo verildi'
} else {
    try {
        $videoDir = Join-Path $Root 'ComfyUI\models\diffusion_models'
        if (!(Get-ChildItem -LiteralPath $videoDir -Filter '*wan2.2*ti2v*' -File -ErrorAction SilentlyContinue)) {
            throw "Video modeli bulunamadi ($videoDir icinde wan2.2*ti2v*). Once Profiller menusunden indir."
        }
        $jobData = @{
            root = $Root
            prompt = 'Basit test: durgun bir su birikintisi'
            mode = 'metin'; aspect = '16:9'; seconds = 3.0; quality = ''
            sourceFile = $null; restoreProfile = ''; lite = $lite
        }
        $shared = [hashtable]::Synchronized(@{ Cancel = $false; Process = $null })
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $job = Start-ThreadJob -FilePath (Join-Path $Root 'agent\videogen-run.ps1') -ArgumentList $jobData, $shared
        $items = Receive-Job -Job $job -Wait
        Remove-Job -Job $job -Force
        $videoEvent = $items | Where-Object { $_.kind -eq 'video' } | Select-Object -Last 1
        $errorEvent = $items | Where-Object { $_.kind -eq 'error' } | Select-Object -Last 1
        if ($errorEvent) { throw $errorEvent.text }
        if (!$videoEvent -or !(Test-Path -LiteralPath $videoEvent.text -PathType Leaf)) { throw 'Cikti dosyasi olusturulmadi.' }
        $size = (Get-Item -LiteralPath $videoEvent.text).Length
        if ($size -lt 1024) { throw "Cikti dosyasi cok kucuk ($size bayt); bozuk olabilir." }
        Report 'video' $true ("$([int]$sw.Elapsed.TotalSeconds) sn, " + [IO.Path]::GetFileName($videoEvent.text) + " ($([math]::Round($size/1KB)) KB)")
    } catch {
        Report 'video' $false $_.Exception.Message
    }
}

# ------------------------------------------------------------------ arayuz_sohbet
# Gercek masaustu penceresini KULLANICI GIBI surer: yazi kutusuna mesaj yazar,
# Gonder'e (Win32 BM_CLICK; UIA Invoke modal pencerede kilitlenebilir) basar ve
# yanitin baloncukta belirdigini (pencere metni degisir) dogrular. Mevcut 'arayuz'
# adimi isciyi dogrudan cagirir; bu adim arayuzun gercek kullanici yolunu sinar.
Write-Section 'Arayuz sohbet (gercek pencere)'
if ($SkipUi) {
    Write-Host '   [atla] -SkipUi verildi'
} else {
    $appProcess = $null
    try {
        Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Drawing, System.Windows.Forms -ErrorAction Stop
        Add-Type @'
using System; using System.Runtime.InteropServices;
public static class Smk { [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, int m, IntPtr w, IntPtr l); }
'@
        $AE = [Windows.Automation.AutomationElement]; $TS = [Windows.Automation.TreeScope]
        function Find-UiWin([int]$procId, [int]$timeoutSec) {
            $end = (Get-Date).AddSeconds($timeoutSec)
            while ((Get-Date) -lt $end) {
                $cond = New-Object Windows.Automation.PropertyCondition($AE::ProcessIdProperty, $procId)
                foreach ($w in $AE::RootElement.FindAll($TS::Children, $cond)) { if ($w.Current.Name -like '*MamidLabs*') { return $w } }
                Start-Sleep -Milliseconds 500
            }
            return $null
        }
        function Find-UiEl($root, [string]$name, [string]$type) {
            foreach ($e in $root.FindAll($TS::Descendants, [Windows.Automation.Condition]::TrueCondition)) {
                $c = $e.Current
                if ($c.IsOffscreen -or !$c.IsEnabled) { continue }
                if ($type -and $c.ControlType.ProgrammaticName -ne "ControlType.$type") { continue }
                if ($c.Name -like $name) { return $e }
            }
            return $null
        }
        function Click-UiBtn($el) {
            $h = [IntPtr]$el.Current.NativeWindowHandle
            if ($h -ne [IntPtr]::Zero) { [void][Smk]::SendMessage($h, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero); Start-Sleep -Milliseconds 700 }
            else { $p = $null; if ($el.TryGetCurrentPattern([Windows.Automation.InvokePattern]::Pattern, [ref]$p)) { $p.Invoke() } }
        }

        # Onceki ornekleri kapat, sunucuyu durdur (temiz baslangic).
        Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -and $_.CommandLine -like '*qwen-desktop.ps1*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        & $manage -Action stop | Out-Null
        & $manage -Action closecomfy | Out-Null

        $appPwsh = Join-Path $Root 'runtime\pwsh\pwsh.exe'
        $appProcess = Start-Process -FilePath $appPwsh -PassThru -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', (Join-Path $Root 'qwen-desktop.ps1'))
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $win = $null; $end = (Get-Date).AddSeconds(120)
        while ((Get-Date) -lt $end -and !$win) { if ($appProcess.HasExited) { throw "Uygulama penceresi acilmadan kapandi (kod $($appProcess.ExitCode))." }; $win = Find-UiWin $appProcess.Id 5 }
        if (!$win) { throw 'Arayuz penceresi 120 saniyede bulunamadi.' }
        if (!(Wait-ForHealth 180)) { throw 'Arayuz acildi ama model hazir olmadi.' }

        # Yaz kutusunu bulup metni gir.
        $promptBox = Find-UiEl $win '*' 'Edit'
        if (!$promptBox) { throw 'Yazi kutusu (Edit) bulunamadi.' }
        $msg = 'Kendini tek cumleyle tanit.'
        try { $promptBox.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).SetValue($msg) }
        catch { [void][Smk]::SendMessage([IntPtr]$promptBox.Current.NativeWindowHandle, 0x000C, [IntPtr]::Zero, [IntPtr]::Zero) }
        Start-Sleep -Milliseconds 500
        $send = Find-UiEl $win 'Gönder' 'Button'
        if (!$send) { throw 'Gonder dugmesi bulunamadi.' }
        Click-UiBtn $send

        # Yaniti bekle: Gonder -> Durdur -> Gonder gecisi.
        $sawBusy = $false; $end = (Get-Date).AddSeconds(180); $ok = $false
        while ((Get-Date) -lt $end) {
            if (Find-UiEl $win 'Durdur' 'Button') { $sawBusy = $true }
            if ($sawBusy -and (Find-UiEl $win 'Gönder' 'Button')) { $ok = $true; break }
            Start-Sleep -Milliseconds 1200
        }
        $sw.Stop()
        if (!$ok) { throw 'Arayuz yaniti zaman asimina ugradi.' }
        Report 'arayuz_sohbet' $true "yazi yazildi + Gonder'e basildi; yanit alindi ($([int]$sw.Elapsed.TotalSeconds) sn)" 
    } catch {
        Report 'arayuz_sohbet' $false $_.Exception.Message
    } finally {
        if ($appProcess -and !$appProcess.HasExited) { try { Stop-Process -Id $appProcess.Id -Force -ErrorAction SilentlyContinue } catch { } }
        & $manage -Action stop | Out-Null
        & $manage -Action closecomfy | Out-Null
    }
}

# ------------------------------------------------------------------ arayuz
# Gercek masaustu arayuzunu (qwen-desktop.ps1) baslatir; pencerenin ve dil
# modelinin hazir oldugunu dogrular. Ardindan arayuzun kullandigi gercek cikarim
# iscisini (agent\qwen-inference.ps1) ayni sekilde calistirip "yerel sunucu
# baglantisi koptu / istek baslatilamadi" turu bir hatanin OLMADIGINI ve MTP'nin
# (--spec-type draft-mtp) gercekten calistigini kanitlar. Uygulama kapaninca
# sunucuyu da durdurur; bu yuzden adim en sonda (video sonrasi) calisir.
Write-Section 'Arayuz (gercek uygulama) + MTP'
if ($SkipUi) {
    Write-Host '   [atla] -SkipUi verildi'
} else {
    $settingsDir = Join-Path $Root 'settings'
    $settingsBackup = Join-Path $env:TEMP 'mamidlabs-smoke-settings-backup'
    $appProcess = $null
    try {
        # Uygulama acikken ayarlar kapanista ezilir (bkz. AGENTS.md tuzak 10); yedekle.
        Remove-Item -LiteralPath $settingsBackup -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $settingsDir) { Copy-Item -LiteralPath $settingsDir -Destination $settingsBackup -Recurse -Force }

        # Onceki testlerden acik kalmis bir arayuz varsa kapat (dosya kilitlenmesin).
        Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" -ErrorAction SilentlyContinue | Where-Object {
            $_.CommandLine -and $_.CommandLine -like '*qwen-desktop.ps1*' } | ForEach-Object {
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        & $manage -Action stop | Out-Null

        $appScript = Join-Path $Root 'qwen-desktop.ps1'
        $appPwsh = Join-Path $Root 'runtime\pwsh\pwsh.exe'
        if (!(Test-Path -LiteralPath $appScript -PathType Leaf)) { throw "Uygulama bulunamadi: $appScript" }
        if (!(Test-Path -LiteralPath $appPwsh -PathType Leaf)) { throw "Gomulu pwsh bulunamadi: $appPwsh" }

        # Kisayolun yaptigi gibi baslat (-STA; gorunur pencere).
        $appProcess = Start-Process -FilePath $appPwsh -PassThru -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', $appScript)
        $deadline = [DateTime]::UtcNow.AddSeconds(240)
        $windowReady = $false
        while ([DateTime]::UtcNow -lt $deadline) {
            if ($appProcess.HasExited) { throw "Uygulama penceresi acilmadan kapandi (cikis kodu $($appProcess.ExitCode))." }
            $appProcess.Refresh()
            if ($appProcess.MainWindowHandle -ne 0) { $windowReady = $true; break }
            Start-Sleep -Milliseconds 800
        }
        if (!$windowReady) { throw 'Uygulama penceresi 240 saniyede acilmadi.' }
        if (!(Wait-ForHealth 240)) { throw 'Arayuz acildi ama dil modeli hazir olmadi (sunucu baslatilamadi).' }

        # MTP bayragi sunucuda gercekten var mi?
        $serverProc = @(Get-CimInstance Win32_Process -Filter "Name='llama-server.exe'" -ErrorAction SilentlyContinue | Select-Object -First 1)
        if (!$serverProc -or $serverProc.CommandLine -notmatch '--spec-type\s+draft-mtp') {
            throw 'Sunucu --spec-type draft-mtp ile baslatilmamis.'
        }

        # Arayuzun kullandigi gercek isci ile bir tur: hata ve watchdog metni olmamali.
        # maxTokens gercek arayuzle AYNI olmali (qwen-desktop.ps1: 8192; sunucu --predict 8192;
        # bkz. sohbet probe'u). LITE'ta dusunme SINIRSIZDIR (--reasoning-budget yoktur ve
        # `reasoning_effort=low` Qwen3.5 9B sablonunca yok sayilir), dusunme tokenlari CIKTI
        # butcesini paylasir. 300 verilirse model tamamen dusunup GORUNUR YANIT uretmeden
        # kesilir ve isci "Model yanit metni uretmedi." hatasini uretir; bu bir test kosumu
        # uyumsuzlugudur, uygulama hatasi degil.
        $jobData = @{
            root = $Root; messages = @(@{ role = 'user'; content = 'Merhaba, kendini tek cumleyle tanit.' })
            provider = 'local'; model = "smoke-ui-$Profile"; profile = $Profile
            maxTokens = 8192; contextLimit = 32768; boundFolder = $null
            consultProviders = @{}; attachedDocuments = @(); currentImagePaths = @()
            hasCurrentImage = $false; multiImageOcr = $false; multiImageOcrMode = $false
            internet = $false; agent = $false; office = $false; documentCreate = $false; effort = 'low'
        }
        $shared = [hashtable]::Synchronized(@{ Cancel = $false; Cts = $null; AccessMode = 'full'
            AskTool = $null; AskDetail = $null; AskAnswer = $null; AskId = $null; AskDeadline = $null })
        $job = Start-ThreadJob -FilePath (Join-Path $Root 'agent\qwen-inference.ps1') -ArgumentList $jobData, $shared
        $items = @(Receive-Job -Job $job -Wait); Remove-Job -Job $job -Force
        $errEvent = @($items | Where-Object { $_.kind -eq 'error' })
        if ($errEvent.Count) { throw "Arayuz turu hata verdi: $($errEvent[0].text)" }
        $done = @($items | Where-Object { $_.kind -eq 'done' }) | Select-Object -Last 1
        if (!$done) { throw 'Arayuz turu done olayi uretmedi.' }
        $joined = ($items | ForEach-Object { [string]$_.text }) -join "`n"
        # .Contains() LITERAL arama yapar. -like "*[Hata]*" KULLANMA: PowerShell'de
        # [Hata] karakter sinifi (H/a/t) sayilir ve neredeyse her metne takilir (gercek
        # makinede yanlis pozitif olarak yakalandi); oysa arayuz "[Hata]"yi yalnizca
        # error olayi geldiginde ekler ve bunu yukarida zaten denetliyoruz.
        foreach ($marker in @('zorla kapat', 'baglanti kesildi', 'baglanti koptu', '[Hata]', 'istek baslatilamadi', 'WSAECONNRESET')) {
            if ($joined.Contains($marker)) { throw "Arayuz turunda istenmeyen metin gecti: '$marker'" }
        }

        # MTP gercekten draft uretip kabul ediyor mu?
        $body = @{ prompt = "1`n2`n3`n"; n_predict = 32; temperature = 0; seed = 7; stream = $false; cache_prompt = $false } | ConvertTo-Json
        $resp = Invoke-RestMethod 'http://127.0.0.1:8080/completion' -Method Post -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 120
        $draftN = [int]$resp.timings.draft_n; $acc = [int]$resp.timings.draft_n_accepted
        if ($draftN -le 0) { throw 'MTP draft token uretmedi (--spec-type etkin degil?).' }
        if ($acc -le 0) { throw "MTP etkin ama kabul 0/$draftN (baslik islevsiz)." }

        Report 'arayuz' $true "pencere acildi, model hazir, arayuz turu hatasiz; MTP draft kabul $acc/$draftN"
    } catch {
        Report 'arayuz' $false $_.Exception.Message
    } finally {
        if ($appProcess -and !$appProcess.HasExited) {
            try { Stop-Process -Id $appProcess.Id -Force -ErrorAction SilentlyContinue } catch { }
        }
        # Uygulamanin actigi sunucuyu ve varsa kalan surecleri kapat (sonraki adim yok, ama temizlik).
        # Uygulama Force ile olduruldugu icin Shutdown-All calismaz; ComfyUI acik kalabilir.
        & $manage -Action stop | Out-Null
        & $manage -Action closecomfy | Out-Null
        if (Test-Path -LiteralPath $settingsBackup) {
            Remove-Item -LiteralPath $settingsDir -Recurse -Force -ErrorAction SilentlyContinue
            Copy-Item -LiteralPath $settingsBackup -Destination $settingsDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        Remove-Item -LiteralPath $settingsBackup -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# -------------------------------------------------------------------- kaynak hijyeni
# Gorsel/video adimlari ComfyUI'yi acik birakir (ayni oturumda ardisik medya isleri onu
# yeniden kullansin diye). Dil modeli onun uzerine yuklenirse VRAM tasar; bu yuzden test
# sonunda bosta kalan ComfyUI kapatilir (arayuz adimi atlanmis ya da cokmus olsa bile).
& $manage -Action closecomfy | Out-Null
Get-CimInstance Win32_Process -Filter "Name='python.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*ComfyUI\main.py*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Milliseconds 1500

# -------------------------------------------------------------------- ozet
Write-Section 'Ozet'
$failed = @($results.Keys | Where-Object { !$results[$_].ok })
foreach ($name in $results.Keys) {
    $entry = $results[$name]
    $mark = if ($entry.skipped) { '[ATLA] ' } elseif ($entry.ok) { '[GECTI]' } else { '[HATA] ' }
    $color = if ($entry.skipped) { 'DarkGray' } elseif ($entry.ok) { 'Green' } else { 'Red' }
    Write-Host ("   $mark $name") -ForegroundColor $color
}
# Kurulum sihirbazi ve destek icin makine tarafindan okunabilir rapor.
try {
    $gpu = $null
    $smi = (Get-Command nvidia-smi -ErrorAction SilentlyContinue).Source
    if ($smi) { $gpu = ((& $smi --query-gpu=name,memory.total --format=csv,noheader) | Select-Object -First 1) }
    $report = [ordered]@{
        time = (Get-Date).ToString('s'); profile = $Profile; gpu = $gpu
        ok = ($failed.Count -eq 0); results = $results
    }
    New-Item -ItemType Directory -Path (Split-Path -Parent $ReportPath) -Force | Out-Null
    [IO.File]::WriteAllText($ReportPath, ($report | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
    Write-Host ''
    Write-Host ("   Rapor: $ReportPath") -ForegroundColor DarkGray
} catch {
    Write-Host ("   Rapor yazilamadi: " + $_.Exception.Message) -ForegroundColor Yellow
}
if ($failed.Count) {
    Write-Host ''
    Write-Host ("$($failed.Count) bilesen basarisiz: " + ($failed -join ', ')) -ForegroundColor Red
    exit 1
} else {
    Write-Host ''
    Write-Host 'Tum bilesenler dogrulandi.' -ForegroundColor Green
    exit 0
}
