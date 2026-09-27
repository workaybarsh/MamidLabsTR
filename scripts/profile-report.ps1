#Requires -Version 5.1
<#
.SYNOPSIS
    Profil raporu: bu bilgisayarda hangi MamidLabs profilinin calisacagini soyler.

.DESCRIPTION
    Ekran karti (VRAM), RAM ve hedef diskteki bos alan olculur; her profil icin
    "uygun / sinirda / uygun degil" karari ve gerekcesi yazilir, bir profil onerilir.
    Kurulum sihirbazi bu betigi kurulumdan ONCE, Windows PowerShell 5.1 ile calistirir;
    bu yuzden yalnizca 5.1'de bulunan komutlar kullanilir. Hicbir sey kurmaz/indirmez.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\profile-report.ps1
#>
param(
    [string]$Root = (Join-Path $env:LOCALAPPDATA 'Programs\MamidLabs'),
    # Kurulum sihirbazi betigi gecici klasorden calistirdigi icin katalog yolu verilebilir.
    [string]$Catalog,
    [string]$OutFile,
    [string]$JsonFile,
    # Yalnizca onerilen profil kimligi (lite/flash/max/api); kurulum sihirbazi okur.
    [string]$RecommendFile
)

$ErrorActionPreference = 'Stop'

# install-mamidlabs.ps1 icindeki $script:Requirements ile ayni kalmalidir
# (test_setup_wizard.py denetler). Lite'ta Windows masaustunun tuttugu ~1 GB VRAM
# dusuldukten sonra kalan paya gore secilmistir.
$requirements = [ordered]@{
    lite  = @{ vramMiB = 7000;  ramGB = 14; diskGB = 58; label = 'LITE  (Qwen3.5 9B, 8 GB kart)' }
    flash = @{ vramMiB = 15000; ramGB = 30; diskGB = 75; label = 'FLASH (Qwen3.8 27B, kısa düşünme)' }
    max   = @{ vramMiB = 15000; ramGB = 30; diskGB = 75; label = 'MAX   (Qwen3.8 27B, derin düşünme)' }
}

function Get-GpuInfo {
    $smi = (Get-Command nvidia-smi -ErrorAction SilentlyContinue).Source
    if (!$smi -and $env:SystemRoot) {
        # Bazi surucu kurulumlari nvidia-smi'yi PATH'e eklemez.
        $default = Join-Path $env:SystemRoot 'System32\nvidia-smi.exe'
        if (Test-Path -LiteralPath $default) { $smi = $default }
    }
    if ($smi) {
        try {
            $line = (& $smi --query-gpu=name,memory.total,driver_version --format=csv,noheader,nounits | Select-Object -First 1)
            $parts = $line -split '\s*,\s*'
            return @{ name = $parts[0]; vramMiB = [int]$parts[1]; driver = $parts[2]; nvidia = $true }
        } catch { }
    }
    # NVIDIA disi kart ya da surucu yok: yalnizca ad raporlanir; VRAM bilinmez.
    $controller = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Select-Object -First 1
    $name = if ($controller) { [string]$controller.Name } else { 'bulunamadı' }
    return @{ name = $name; vramMiB = 0; driver = ''; nvidia = $false }
}

function Get-FreeDiskGB([string]$path) {
    try {
        $qualifier = Split-Path -Qualifier ([IO.Path]::GetFullPath($path))
        $drive = Get-PSDrive -Name $qualifier.TrimEnd(':') -ErrorAction Stop
        return [math]::Round($drive.Free / 1GB, 1)
    } catch { return 0 }
}

# Katalogdaki indirilebilir dosyalarin toplam boyutu (ayni hedef bir kez sayilir) ve
# indirme kaynagi olmayan, elle kurulacak dosyalarin adlari.
function Get-ProfileDownload([string]$id) {
    $result = @{ gb = 0; manual = @() }
    $catalog = if ($Catalog) { $Catalog } else { Join-Path (Split-Path -Parent $PSScriptRoot) 'agent\profiles.json' }
    if (!(Test-Path -LiteralPath $catalog -PathType Leaf)) { return $result }
    $profiles = (Get-Content -LiteralPath $catalog -Raw -Encoding UTF8 | ConvertFrom-Json).profiles
    $entry = @($profiles | Where-Object { $_.id -eq $id })[0]
    if (!$entry) { return $result }
    $bytes = 0
    $seen = @{}
    foreach ($file in @($entry.files)) {
        if ($seen.ContainsKey([string]$file.target)) { continue }
        $seen[[string]$file.target] = $true
        if ([string]$file.repo) { $bytes += [long]$file.bytes } else { $result.manual += [string]$file.label }
    }
    $result.gb = [math]::Round($bytes / 1GB, 1)
    return $result
}

$os = Get-CimInstance Win32_OperatingSystem
$cpu = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name
$ramGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
$gpu = Get-GpuInfo
$diskGB = Get-FreeDiskGB $Root

$verdicts = [ordered]@{}
foreach ($id in $requirements.Keys) {
    $need = $requirements[$id]
    $notes = [Collections.Generic.List[string]]::new()
    $status = 'uygun'
    if (!$gpu.nvidia) { $status = 'uygun değil'; $notes.Add('NVIDIA ekran kartı/sürücüsü bulunamadı') }
    elseif ($gpu.vramMiB -lt $need.vramMiB) { $status = 'uygun değil'; $notes.Add("VRAM $($gpu.vramMiB) MiB < $($need.vramMiB) MiB") }
    if ($ramGB -lt $need.ramGB) {
        # RAM azligi calismayi engellemez ama model gecislerini yavaslatir.
        if ($status -eq 'uygun') { $status = 'sınırda' }
        $notes.Add("RAM $ramGB GB < önerilen $($need.ramGB) GB")
    }
    if ($diskGB -lt $need.diskGB) {
        if ($status -eq 'uygun') { $status = 'sınırda' }
        $notes.Add("boş disk $diskGB GB < $($need.diskGB) GB")
    }
    $download = Get-ProfileDownload $id
    $verdicts[$id] = @{ status = $status; notes = @($notes); downloadGB = $download.gb; manualFiles = @($download.manual) }
}

# FLASH, MAX ile ayni dosyalari kullanir ama daha hizli yanit verir; gunluk kullanim
# icin o onerilir. Hicbir yerel profil uymuyorsa API ya da kendi modeli onerilir.
$recommended = 'api'
foreach ($id in @('flash', 'lite')) {
    if ($verdicts[$id].status -ne 'uygun değil') { $recommended = $id; break }
}

$lines = [Collections.Generic.List[string]]::new()
$lines.Add('MamidLabs profil raporu')
$lines.Add('')
$lines.Add("Sistem : $($os.Caption) ($($os.Version))")
$lines.Add("İşlemci: $cpu")
$lines.Add("RAM    : $ramGB GB")
$gpuText = if ($gpu.nvidia) { "$($gpu.name), $($gpu.vramMiB) MiB VRAM, sürücü $($gpu.driver)" } else { "$($gpu.name) (NVIDIA değil ya da sürücü yok)" }
$lines.Add("Ekran  : $gpuText")
$lines.Add("Disk   : $Root için $diskGB GB boş")
$lines.Add('')
foreach ($id in $verdicts.Keys) {
    $verdict = $verdicts[$id]
    $detail = if ($verdict.notes.Count) { ' - ' + ($verdict.notes -join '; ') } else { '' }
    $lines.Add(('{0}: {1}{2}' -f $requirements[$id].label, $verdict.status.ToUpper(), $detail))
    if ($verdict.downloadGB -gt 0) { $lines.Add("        indirilecek model dosyaları ~$($verdict.downloadGB) GB") }
    foreach ($manual in $verdict.manualFiles) { $lines.Add("        elle kurulacak: $manual") }
}
$lines.Add('')
$lines.Add($(switch ($recommended) {
    'flash' { 'Öneri: FLASH. 16 GB kartta en hızlı günlük kullanım; derin akıl yürütme için MAX de aynı dosyalarla çalışır.' }
    'lite'  { 'Öneri: LITE. 8 GB kart için hazırlanmış profil.' }
    default { 'Öneri: yerel profil bu donanıma sığmıyor. API (OpenAI, Claude, Gemini, DeepSeek) ya da kendi küçük modelini kullan.' }
}))
$text = $lines -join "`r`n"

if ($OutFile) { [IO.File]::WriteAllText($OutFile, $text, [Text.UTF8Encoding]::new($true)) }
if ($JsonFile) {
    $data = [ordered]@{
        recommended = $recommended; ramGB = $ramGB; diskGB = $diskGB
        gpu = $gpu.name; vramMiB = $gpu.vramMiB; nvidia = $gpu.nvidia; profiles = $verdicts
    }
    [IO.File]::WriteAllText($JsonFile, ($data | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
}
if ($RecommendFile) { [IO.File]::WriteAllText($RecommendFile, $recommended, [Text.Encoding]::ASCII) }
# -OutFile verilmediyse rapor ekrana basilir.
if (!$OutFile) { $text }
