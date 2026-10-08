#Requires -Version 5.1
<#
.SYNOPSIS
    MamidLabs yerel web yonetimini (tarayicidan erisim) baslatir/durdurur.

.DESCRIPTION
    Uygulamadaki "Web yonetimi" penceresiyle ayni isi yapar: agent\web-server.ps1'i
    arka planda baslatir. Sunucu sifreyi settings\api.json -> web.password alanindan
    (Windows DPAPI) okur; once uygulamadan bir sifre belirlenmis olmalidir.
    Varsayilan olarak yalnizca bu bilgisayardan erisilir; -Lan ile yerel aga acilir
    (Windows yonetici hakki / URL ACL gerekir).

.EXAMPLE
    runtime\pwsh\pwsh.exe -File scripts\web-serve.ps1 -Start
    runtime\pwsh\pwsh.exe -File scripts\web-serve.ps1 -Start -Port 8917 -Lan
    runtime\pwsh\pwsh.exe -File scripts\web-serve.ps1 -Stop
#>
param(
    [switch]$Start,
    [switch]$Stop,
    [int]$Port = 0,
    [switch]$Lan,
    [string]$Root
)

$ErrorActionPreference = 'Stop'
if (!$Root) { $Root = Split-Path -Parent $PSScriptRoot }

function Get-WebServerProcess {
    @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" -ErrorAction SilentlyContinue | Where-Object {
        $_.CommandLine -and $_.CommandLine -like '*web-server.ps1*' })
}

if ($Stop -or (!$Start -and $Stop)) {
    foreach ($proc in Get-WebServerProcess) { Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue }
    Write-Host 'Web yonetimi durduruldu.'
    exit 0
}

if (!$Start) { throw 'Bir islem sec: -Start ya da -Stop.' }

$server = Join-Path $Root 'agent\web-server.ps1'
if (!(Test-Path -LiteralPath $server -PathType Leaf)) { throw "Bulunamadi: $server" }

# Port/yerel ag ayarlari settings\api.json'dan okunur (uygulamada kaydedilen degerler).
$port = $Port
$lanFlag = [bool]$Lan
$settingsPath = Join-Path $Root 'settings\api.json'
if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
    try {
        $settings = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($settings.web) {
            if (!$port -and $settings.web.port) { $port = [int]$settings.web.port }
            if (!$Lan -and $null -ne $settings.web.lan) { $lanFlag = [bool]$settings.web.lan }
            if (!$settings.web.password) { throw 'Once uygulamadan bir web sifresi belirle.' }
        }
    } catch { Write-Host $_.Exception.Message }
}
if (!$port) { $port = 8917 }

foreach ($proc in Get-WebServerProcess) { Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Milliseconds 500

$pwsh = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $server, '-Root', $Root, '-Port', [string]$port)
if ($lanFlag) { $args += '-Lan' }
Start-Process -FilePath $pwsh -ArgumentList $args -WindowStyle Hidden
Start-Sleep -Seconds 2
Write-Host ("Web yonetimi baslatildi: http://127.0.0.1:{0}/" -f $port)
Write-Host 'Tarayicida ac ve sifreyi gir.'
exit 0
