#Requires -Version 5.1
<#
.SYNOPSIS
    Tek tikla kurulumun is yuku: sihirbazin sectiklerini sirayla uygular ve ozet yazar.

.DESCRIPTION
    Kurulum sihirbazi (packaging\windows\mamidlabs.iss) program dosyalarini acar ve
    bu betigi gorunur bir konsolda calistirir. Adimlar:

      1. On kosullar: Python 3.10+ ve Git yoksa winget ile kurulur (-InstallPrereqs).
      2. Profil raporu: logs\profil-raporu.txt
      3. Altyapi: install-mamidlabs.ps1 (PowerShell 7, llama.cpp, Python, ComfyUI)
      4. Modeller: secilen profilin dosyalari indirilir (-DownloadModels)
      5. Kendi modelleri / API tercihi settings\api.json dosyasina yazilir
      6. OCR (istege bagli)
      7. Smoke testi: sohbet, belge, cevrimdisi araclar, gorsel, fotograf duzenleme, medya sonrasi gecis
      8. Ozet: logs\kurulum-ozeti.txt (sihirbazin son sayfasinda gosterilir)

    Her adim bagimsiz raporlanir; bir adim basarisiz olursa sonrakiler anlamliysa
    yine denenir, ozet hepsini listeler. Tum cikti logs\kurulum.log dosyasina da yazilir.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\setup-run.ps1 -Profile lite -DownloadModels -SmokeTest
#>
param(
    # none: yerel profil simdi kurulmaz (API, kendi modeli ya da sonra kurulacak profil).
    [ValidateSet('max', 'flash', 'lite', 'none')][string]$Profile = 'lite',
    [string]$Root = (Join-Path $env:LOCALAPPDATA 'Programs\MamidLabs'),
    [string]$Source,
    [switch]$InstallPrereqs,
    [switch]$DownloadModels,
    [switch]$SmokeTest,
    [switch]$Ocr,
    [string]$LlmPath,
    [string]$ImageModelPath,
    [string]$VideoModelPath,
    [switch]$OpenApiSettings,
    [string]$SummaryPath,
    # Sihirbazdan cagrildi: kaldirma kaydini sihirbaz yazar, betik ikinci kayit acmaz.
    [switch]$FromWizard
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if (!$Source) { $Source = Split-Path -Parent $PSScriptRoot }
$logs = Join-Path $Root 'logs'
New-Item -ItemType Directory -Path $logs -Force | Out-Null
if (!$SummaryPath) { $SummaryPath = Join-Path $logs 'kurulum-ozeti.txt' }
$started = Get-Date
try { Start-Transcript -LiteralPath (Join-Path $logs 'kurulum.log') -Append | Out-Null } catch { }

# Sihirbaz (mamidlabs.iss, CurStepChanged) bu betigi bekletmeden (ewNoWait) baslatir ve
# kurulumun surdugunu/bittigini bu iki dosyadan anlar: PID dosyasi Iptal'e basilinca
# sureci (ve tum alt sureclerini, taskkill /T ile) sonlandirmak icin; "tamam" bayragi
# ise dongunun ne zaman durup ozeti okuyacagini bilmesi icin. Iptal edilmezse normal
# bitiste de yazilir - sihirbaz onsuz sonsuza kadar bekler.
$pidFile = Join-Path $logs 'kurulum.pid'
$doneFlag = Join-Path $logs 'kurulum-tamam.flag'
Remove-Item -LiteralPath $doneFlag -ErrorAction SilentlyContinue
try { [System.Diagnostics.Process]::GetCurrentProcess().Id | Out-File -LiteralPath $pidFile -Encoding ascii -Force } catch { }

# Betik gizli calisir; ilerleme sihirbazda gosterilir. Her adimda 3 satirlik bir dosyaya
# (adim no / toplam / adim adi) yazilir, sihirbaz bunu ~200 ms'de bir okur. Toplam adim
# sayisi bastan bellidir (OCR istenmediyse o adim sayilmaz).
$progressFile = Join-Path $logs 'kurulum-adim.txt'
Remove-Item -LiteralPath $progressFile -ErrorAction SilentlyContinue
$totalSteps = 6 + $(if ($Ocr) { 1 } else { 0 })
$script:stepIndex = 0
function Set-InstallProgress([string]$name) {
    $script:stepIndex++
    try { [IO.File]::WriteAllText($progressFile, "$script:stepIndex`r`n$totalSteps`r`n$name") } catch { }
}
trap {
    $trapMsg = "hata: $($_.Exception.Message)"
    try { [IO.File]::WriteAllText($doneFlag, $trapMsg) } catch {
        try { $trapMsg | Out-File -LiteralPath $doneFlag -Encoding utf8 -Force } catch { }
    }
    try { Stop-Transcript | Out-Null } catch { }
    exit 1
}

$steps = [Collections.Generic.List[object]]::new()
function Add-Step([string]$name, [string]$state, [string]$detail, [TimeSpan]$elapsed) {
    $steps.Add([pscustomobject]@{ name = $name; state = $state; detail = $detail; seconds = [int]$elapsed.TotalSeconds })
    $color = switch ($state) { 'tamam' { 'Green' } 'atlandı' { 'DarkGray' } default { 'Red' } }
    Write-Host ("   [$state] $name" + $(if ($detail) { " - $detail" } else { '' })) -ForegroundColor $color
}

# Adimi calistirir; sure ve sonucu kaydeder. Betik blogu $false dondururse ya da hata
# firlatirsa adim basarisiz sayilir.
function Invoke-Step([string]$name, [scriptblock]$body) {
    Set-InstallProgress $name
    Write-Host ''
    Write-Host ('== ' + $name) -ForegroundColor Cyan
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $detail = & $body
        Add-Step $name 'tamam' ([string]($detail | Select-Object -Last 1)) $sw.Elapsed
        return $true
    } catch {
        Add-Step $name 'hata' $_.Exception.Message $sw.Elapsed
        return $false
    }
}

function Update-SessionPath {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = (@($machine, $user) | Where-Object { $_ }) -join ';'
}

function Test-PythonReady {
    $python = (Get-Command python -ErrorAction SilentlyContinue).Source
    # WindowsApps altindaki python.exe, Store'a yonlendiren bos bir kisayoldur.
    if (!$python -or $python -like '*\WindowsApps\*') { return $false }
    $previous = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $version = ('import sys; print(sys.version_info[0]*100+sys.version_info[1])' | & $python - 2>$null) } finally { $ErrorActionPreference = $previous }
    return ([int]"0$version" -ge 310)
}

function Install-WithWinget([string]$id, [string]$label) {
    $winget = (Get-Command winget -ErrorAction SilentlyContinue).Source
    if (!$winget) { throw "$label bulunamadı ve winget yok. $label'u elle kurup kurulumu yeniden çalıştır." }
    Write-Host "   $label winget ile kuruluyor ($id)..."
    & $winget install --exact --id $id --scope user --silent --accept-package-agreements --accept-source-agreements --disable-interactivity
    # Kullanici kapsaminda paket yoksa makine kapsamini dener (yonetici onayi isteyebilir).
    if ($LASTEXITCODE -ne 0) {
        & $winget install --exact --id $id --silent --accept-package-agreements --accept-source-agreements --disable-interactivity
    }
    if ($LASTEXITCODE -ne 0) { throw "$label kurulamadı (winget çıkış kodu $LASTEXITCODE)." }
    Update-SessionPath
    Add-InstallRecord $id
}

# MamidLabs'in kurdugu on kosullari kaydeder; uninstall-mamidlabs.ps1 yalnizca bunlari
# kaldirir, kullanicinin onceden kurulu Python/Git'ine dokunmaz.
function Add-InstallRecord([string]$id) {
    $path = Join-Path $Root 'settings\kurulum-kaydi.json'
    New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
    $record = @{ wingetPackages = @() }
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        try { $record.wingetPackages = @((Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).wingetPackages) } catch { }
    }
    $record.wingetPackages = @(@($record.wingetPackages) + $id | Where-Object { $_ } | Select-Object -Unique)
    $record | ConvertTo-Json | Set-Content -LiteralPath $path -Encoding UTF8
}

$pwsh = Join-Path $Root 'runtime\pwsh\pwsh.exe'
$installProfile = if ($Profile -eq 'none') { 'lite' } else { $Profile }
$infraOk = $false
$modelsReady = $false

Write-Host ''
Write-Host 'MamidLabs tek tıkla kurulum' -ForegroundColor White
Write-Host ("  hedef : $Root")
Write-Host ("  profil: $Profile")

# RAR aciminin calismasi icin gereken 7z.exe'yi standart kurulum konumlarinda arar;
# agent/office-tools.py'deki read_rar ile ayni konumlari kontrol eder (bkz. orada).
function Test-SevenZipReady {
    foreach ($base in @(${env:ProgramFiles}, ${env:ProgramFiles(x86)})) {
        if (!$base) { continue }
        $candidate = Join-Path $base '7-Zip\7z.exe'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $true }
    }
    return [bool](Get-Command 7z.exe -ErrorAction SilentlyContinue)
}

# VC++ Redistributable 2015-2022 (x64) kurulunca System32'ye vcruntime140.dll koyar;
# llama-server.exe gibi native derlemeler buna ihtiyac duyar.
function Test-VCRedistReady {
    if (!$env:WINDIR) { return $false }
    return (Test-Path -LiteralPath (Join-Path $env:WINDIR 'System32\vcruntime140.dll') -PathType Leaf)
}

# 1. On kosullar
$prereqOk = Invoke-Step 'Ön koşullar (Python, Git, 7-Zip, VC++ Redistributable)' {
    $notes = @()
    if (!(Test-PythonReady)) {
        if (!$InstallPrereqs) { throw 'Python 3.10+ bulunamadı.' }
        Install-WithWinget 'Python.Python.3.12' 'Python'
        if (!(Test-PythonReady)) { throw 'Python kuruldu ama bu oturumda bulunamadı; bilgisayarı yeniden başlatıp kurulumu tekrar çalıştır.' }
        $notes += 'Python kuruldu'
    }
    if (!(Get-Command git -ErrorAction SilentlyContinue)) {
        if (!$InstallPrereqs) { throw 'Git bulunamadı.' }
        Install-WithWinget 'Git.Git' 'Git'
        if (!(Get-Command git -ErrorAction SilentlyContinue)) { throw 'Git kuruldu ama bu oturumda bulunamadı.' }
        $notes += 'Git kuruldu'
    }
    # 7-Zip ve VC++ Redistributable eksikse kurulumu durdurmaz (RAR acma / native
    # derlemeler bunlarsiz calismayabilir ama sohbet ve gorsel uretimi etkilenmez);
    # -InstallPrereqs yoksa sessizce atlanir, kullaniciya elle kurmasi soylenir.
    if (!(Test-SevenZipReady)) {
        if ($InstallPrereqs) {
            try { Install-WithWinget '7zip.7zip' '7-Zip'; $notes += '7-Zip kuruldu' }
            catch { $notes += ('7-Zip kurulamadi (' + $_.Exception.Message + '); RAR açma çalışmayabilir') }
        } else { $notes += '7-Zip yok; RAR açma çalışmayabilir' }
    }
    if (!(Test-VCRedistReady)) {
        if ($InstallPrereqs) {
            try { Install-WithWinget 'Microsoft.VCRedist.2015+.x64' 'Visual C++ Redistributable'; $notes += 'VC++ Redistributable kuruldu' }
            catch { $notes += ('VC++ Redistributable kurulamadi (' + $_.Exception.Message + ')') }
        } else { $notes += 'VC++ Redistributable yok' }
    }
    if ($notes) { $notes -join ', ' } else { 'mevcut' }
}

# 2. Profil raporu
[void](Invoke-Step 'Profil raporu' {
    & (Join-Path $Source 'scripts\profile-report.ps1') -Root $Root -OutFile (Join-Path $logs 'profil-raporu.txt') -RecommendFile (Join-Path $logs 'profil-onerisi.txt')
    'öneri: ' + (Get-Content -LiteralPath (Join-Path $logs 'profil-onerisi.txt') -Raw).Trim()
})

# 3. Altyapi
if ($prereqOk) {
    $infraOk = Invoke-Step 'Altyapı (PowerShell 7, llama.cpp, Python, ComfyUI)' {
        # Alt betik kendi ciktisini yazar; hata firlatirsa adim basarisiz olur.
        & (Join-Path $Source 'scripts\install-mamidlabs.ps1') -Profile $installProfile -Root $Root -Source $Source -NoUninstallEntry:$FromWizard | Out-Host
        if (!(Test-Path -LiteralPath $pwsh -PathType Leaf)) { throw 'Gömülü PowerShell 7 kurulmadı.' }
        'kuruldu'
    }
} else {
    Set-InstallProgress 'Altyapı (PowerShell 7, llama.cpp, Python, ComfyUI)'
    Add-Step 'Altyapı (PowerShell 7, llama.cpp, Python, ComfyUI)' 'atlandı' 'ön koşullar eksik' ([TimeSpan]::Zero)
}

# 4. Modeller
if ($Profile -eq 'none') {
    Set-InstallProgress 'Model dosyaları'
    Add-Step 'Model dosyaları' 'atlandı' 'profil daha sonra Profil yöneticisinden kurulacak' ([TimeSpan]::Zero)
} elseif (!$DownloadModels) {
    Set-InstallProgress 'Model dosyaları'
    Add-Step 'Model dosyaları' 'atlandı' "daha sonra: download-profile.ps1 -Profile $Profile" ([TimeSpan]::Zero)
} elseif (!$infraOk) {
    Set-InstallProgress 'Model dosyaları'
    Add-Step 'Model dosyaları' 'atlandı' 'altyapı kurulamadı' ([TimeSpan]::Zero)
} else {
    $modelsReady = Invoke-Step "Model dosyaları ($Profile)" {
        & $pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'scripts\download-profile.ps1') -Profile $Profile -Root $Root | Out-Host
        if ($LASTEXITCODE -ne 0) { throw 'Bazı dosyalar indirilemedi; Profil yöneticisinden yeniden dene.' }
        'indirildi ve boyutları doğrulandı'
    }
}

# 5. Model secimleri
if ($infraOk) {
    [void](Invoke-Step 'Model seçimleri' {
        $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Root 'scripts\configure-models.ps1'), '-Root', $Root)
        if ($Profile -ne 'none') { $arguments += @('-DefaultProfile', $Profile) } else { $arguments += '-NoLocalModel' }
        if ($LlmPath) { $arguments += @('-LlmPath', $LlmPath) }
        if ($ImageModelPath) { $arguments += @('-ImageModelPath', $ImageModelPath) }
        if ($VideoModelPath) { $arguments += @('-VideoModelPath', $VideoModelPath) }
        if ($OpenApiSettings) { $arguments += '-OpenApiSettings' }
        & $pwsh @arguments | Out-Host
        if ($LASTEXITCODE -ne 0) { throw 'Ayarlar yazılamadı.' }
        'settings\api.json güncellendi'
    })
}

# 6. OCR
if ($Ocr -and $infraOk) {
    [void](Invoke-Step 'OCR bileşenleri' {
        & $pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'scripts\install-ocr.ps1') -Warmup | Out-Host
        if ($LASTEXITCODE -ne 0) { throw 'OCR kurulamadı.' }
        'kuruldu'
    })
}

# 7. Smoke testi
$smokeReport = Join-Path $logs 'smoke-test-son.json'
if (!$SmokeTest) {
    Set-InstallProgress 'Smoke testi'
    Add-Step 'Smoke testi' 'atlandı' 'istenmedi' ([TimeSpan]::Zero)
} elseif (!$modelsReady) {
    Set-InstallProgress 'Smoke testi'
    Add-Step 'Smoke testi' 'atlandı' 'profil dosyaları hazır değil' ([TimeSpan]::Zero)
} else {
    [void](Invoke-Step 'Smoke testi' {
        # Video birkac dakika surer; kurulum sonunda sohbet, belge, cevrimdisi araclar, gorsel,
        # duzenleme ve medya sonrasi model gecisi dogrulanir. Video: smoke-test.ps1 elle calistirilir.
        $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Root 'scripts\smoke-test.ps1'),
                       '-Profile', $Profile, '-Root', $Root, '-SkipVideo', '-ReportPath', $smokeReport)
        if (!$Ocr) { $arguments += '-SkipOcr' }
        & $pwsh @arguments | Out-Host
        if ($LASTEXITCODE -ne 0) { throw 'En az bir bileşen doğrulanamadı; ayrıntı özetin sonunda.' }
        'tüm bileşenler doğrulandı'
    })
}

# 8. Ozet
$failed = @($steps | Where-Object { $_.state -eq 'hata' })
$lines = [Collections.Generic.List[string]]::new()
$lines.Add('MamidLabs kurulum özeti')
$lines.Add(('Tarih: {0:yyyy-MM-dd HH:mm}   Süre: {1:N0} dk   Hedef: {2}' -f $started, ((Get-Date) - $started).TotalMinutes, $Root))
$lines.Add("Profil: $Profile")
$lines.Add('')
foreach ($step in $steps) {
    $lines.Add(('[{0}] {1}{2}' -f $step.state.ToUpper(), $step.name, $(if ($step.detail) { ' - ' + $step.detail } else { '' })))
}
if (Test-Path -LiteralPath $smokeReport -PathType Leaf) {
    try {
        $smoke = Get-Content -LiteralPath $smokeReport -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([datetime]$smoke.time -ge $started) {
            $lines.Add('')
            $lines.Add('Smoke testi ayrıntısı:')
            foreach ($property in $smoke.results.PSObject.Properties) {
                $entry = $property.Value
                $mark = if ($entry.skipped) { 'ATLA ' } elseif ($entry.ok) { 'GEÇTİ' } else { 'HATA ' }
                $lines.Add(("  [{0}] {1} - {2}" -f $mark, $property.Name, $entry.detail))
            }
        }
    } catch { }
}
$reportFile = Join-Path $logs 'profil-raporu.txt'
if (Test-Path -LiteralPath $reportFile -PathType Leaf) {
    $lines.Add('')
    foreach ($line in (Get-Content -LiteralPath $reportFile -Encoding UTF8)) { $lines.Add($line) }
}
$lines.Add('')
if ($failed.Count) {
    $lines.Add("$($failed.Count) adım tamamlanamadı. Günlük: $(Join-Path $logs 'kurulum.log')")
} else {
    $lines.Add('Kurulum tamamlandı. MamidLabs masaüstü kısayolundan açılabilir.')
}
if ($Profile -eq 'none' -or !$DownloadModels) {
    $lines.Add('Profil dosyaları: uygulamada Profiller → Profil yöneticisi → Eksikleri indir.')
}
if ($OpenApiSettings) { $lines.Add('API anahtarı: uygulama ilk açılışta API bağlantıları penceresini açar.') }
$summary = $lines -join "`r`n"
[IO.File]::WriteAllText($SummaryPath, $summary, [Text.UTF8Encoding]::new($true))
Write-Host ''
Write-Host $summary
try { Stop-Transcript | Out-Null } catch { }

# Sihirbaz bu bitis bayragini bekler. Tek denemelik yazma (olasi AV/dosya kilidi)
# sessizce basarisiz olabildigi icin birkac kez denenir; sihirbaz ayrica surecin
# yasayip yasamadigini denetler (mamidlabs.iss ProcessIsRunning).
$doneState = if ($failed.Count) { 'hata' } else { 'tamam' }
$doneWritten = $false
$doneError = $null
for ($i = 0; $i -lt 5 -and !$doneWritten; $i++) {
    try {
        [IO.File]::WriteAllText($doneFlag, $doneState, [Text.UTF8Encoding]::new($false))
        $doneWritten = $true
    } catch {
        $doneError = $_.Exception.Message
        Start-Sleep -Milliseconds 300
    }
}
if (!$doneWritten) {
    try { [IO.File]::WriteAllText($doneFlag, "hata: bayrak yazilamadi - $doneError") } catch { }
}
if ($failed.Count) { exit 1 }
exit 0
