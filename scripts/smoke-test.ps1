#Requires -Version 5.1
<#
.SYNOPSIS
    Kurulum sonrasi uctan uca duman testi: sohbet, belge, cevrimdisi araclar, ag gecisleri, gecmis devam, OCR, gorsel, video.

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
    # Bu olmadan Lite'in sunucu tarafinda zorlanan dusunme butcesi (300 token)
    # max_tokens'i tek basina tuketip gercek icerik uretmeden kesilebilir -
    # bu tam olarak gercek makinede yakalandi: max_tokens=200 ile model
    # 200 tokenin tamamini dusunerek harcadi, "bos yanit" hatasi verdi.
    $body = @{
        model = "smoke-$Profile"
        messages = @(@{ role = 'user'; content = 'Bir cumleyle kendini tanit.' })
        max_tokens = 600
        reasoning_effort = 'low'
        chat_template_kwargs = @{ reasoning_effort = 'low' }
    } | ConvertTo-Json -Depth 5
    $response = Invoke-RestMethod 'http://127.0.0.1:8080/v1/chat/completions' -Method Post `
        -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 180
    $content = [string]$response.choices[0].message.content
    if ([string]::IsNullOrWhiteSpace($content)) { throw 'Model bos yanit dondurdu (dusunme butcesi tukenmis olabilir).' }
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

# ------------------------------------------------------------------- belge
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
