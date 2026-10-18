#Requires -Version 5.1
<#
.SYNOPSIS
    Bir profilin eksik model dosyalarini uygulamayi acmadan indirir.

.DESCRIPTION
    Uygulamadaki "Profiller -> Profil yoneticisi -> Eksikleri indir" ile ayni isi
    yapar: agent\profiles.json katalogunu okur, diskte olmayan ve indirilebilir
    (repo alani dolu) dosyalari agent\hf-hub.py ile sabit commit'ten indirir ve
    boyutlarini dogrular. Kurulum sihirbazi bu betigi kurulum sonunda cagirir;
    "daha sonra kur" diyen kullanici ayni komutu istedigi zaman calistirabilir.

    Kisitli depolar icin HF_TOKEN ortam degiskeni kullanilir; katalogdaki depolar
    herkese aciktir.

.EXAMPLE
    runtime\pwsh\pwsh.exe -File scripts\download-profile.ps1 -Profile lite
#>
param(
    [Parameter(Mandatory = $true)][ValidateSet('max', 'flash', 'lite')][string]$Profile,
    [string]$Root
)

$ErrorActionPreference = 'Stop'
if (!$Root) { $Root = Split-Path -Parent $PSScriptRoot }
# Windows PowerShell 5.1 native programa varsayilan olarak ASCII yazar; Turkce
# etiketler bozulmasin diye her iki yon UTF-8'e alinir.
$OutputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

$catalogPath = Join-Path $Root 'agent\profiles.json'
$python = Join-Path $Root 'venv\app\Scripts\python.exe'
$hub = Join-Path $Root 'agent\hf-hub.py'
foreach ($required in @($catalogPath, $python, $hub)) {
    if (!(Test-Path -LiteralPath $required -PathType Leaf)) { throw "Bulunamadi: $required. Once install-mamidlabs.ps1 calistir." }
}

# GGUF basliginda MTP/nextn blogu var mi? Var olan (MTP'siz) modele yeniden indirmeden
# MTP eklenmesi gerektigini anlamak icin kullanilir (bkz. agent/mtp_inject.py).
function Test-GgufHasNextn([string]$Path) {
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

$entry = @((Get-Content -LiteralPath $catalogPath -Raw -Encoding UTF8 | ConvertFrom-Json).profiles | Where-Object { $_.id -eq $Profile })[0]
if (!$entry) { throw "Katalogda profil yok: $Profile" }

$files = [Collections.Generic.List[object]]::new()
$manual = [Collections.Generic.List[string]]::new()
foreach ($file in @($entry.files)) {
    $target = Join-Path $Root ([string]$file.target)
    if (Test-Path -LiteralPath $target -PathType Leaf) {
        # MTP yapilandirmasi olan ama basligi eksik bir dosya yine islenir (yeniden indirmeden eklenir).
        if (!($file.mtp -and !(Test-GgufHasNextn $target))) { continue }
    }
    if (![string]$file.repo) {
        $hint = if ([string]$file.source) { " (kaynak: $($file.source))" } else { '' }
        $manual.Add("$($file.label) -> $($file.target)$hint")
        continue
    }
    $files.Add([ordered]@{
        repo = [string]$file.repo; filename = [string]$file.filename; revision = [string]$file.revision
        target = $target; label = [string]$file.label; bytes = [long]$file.bytes; sha256 = [string]$file.sha256; mtp = $file.mtp
    })
}

$totalGB = [math]::Round((($files | ForEach-Object { $_.bytes }) | Measure-Object -Sum).Sum / 1GB, 1)
Write-Host "Profil $($entry.label): $($files.Count) dosya indirilecek (~$totalGB GB)."
$failed = $false
if ($files.Count) {
    $job = @{ action = 'download'; files = @($files.ToArray()); apiKey = $env:HF_TOKEN } | ConvertTo-Json -Depth 6 -Compress
    $job | & $python $hub | ForEach-Object {
        $message = $null
        try { $message = $_ | ConvertFrom-Json } catch { Write-Host $_; return }
        switch ([string]$message.kind) {
            'error' { $failed = $true; Write-Host ('   [hata] ' + $message.text) -ForegroundColor Red }
            'status' { Write-Host ('   ' + $message.text) }
        }
    }
    if ($LASTEXITCODE -ne 0) { $failed = $true }
}
if ($manual.Count) {
    Write-Host ''
    Write-Host 'Elle kurulacak dosyalar (katalogda indirme kaynagi sabitlenmemis):' -ForegroundColor Yellow
    foreach ($line in $manual) { Write-Host ('   - ' + $line) -ForegroundColor Yellow }
}
if ($failed) { exit 1 }
Write-Host 'Indirme tamam.' -ForegroundColor Green
exit 0
