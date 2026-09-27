#Requires -Version 7.0
<#
.SYNOPSIS
    Kurulum sonrasi model secimlerini settings\api.json dosyasina yazar.

.DESCRIPTION
    Kurulum sihirbazi bu betigi gomulu PowerShell 7 ile cagirir. Uygulamadaki
    pencerelerle ayni ayar anahtarlarini kullanir:

      -DefaultProfile       acilista yuklenecek yerlesik profil (max/flash/lite)
      -NoLocalModel         acilista yerel model yuklenmez (API ya da sonra kurulacak profil)
      -LlmPath              kendi GGUF dil modelin; listeye eklenir ve secilir
      -ImageModelPath       kendi Krea 2 Turbo dosyan; kopyalanmadan yerinde kullanilir
      -VideoModelPath       kendi Wan 2.2 TI2V 5B dosyan; kopyalanmadan yerinde kullanilir
      -OpenApiSettings      uygulama ilk acilista API baglantilari penceresini acar

    API anahtarlari bilerek burada alinmaz: anahtar komut satirindan gecerse surec
    listesinde gorunur. Anahtar uygulamada girilir ve Windows DPAPI ile saklanir.

.EXAMPLE
    pwsh -File scripts\configure-models.ps1 -LlmPath D:\modeller\qwen.gguf -OpenApiSettings
#>
param(
    [string]$Root,
    [ValidateSet('', 'max', 'flash', 'lite')][string]$DefaultProfile = '',
    [switch]$NoLocalModel,
    [string]$LlmPath,
    [string]$ImageModelPath,
    [string]$VideoModelPath,
    [switch]$OpenApiSettings
)

$ErrorActionPreference = 'Stop'
if (!$Root) { $Root = Split-Path -Parent $PSScriptRoot }
. (Join-Path $Root 'agent\media-paths.ps1')

$settingsDir = Join-Path $Root 'settings'
$settingsPath = Join-Path $settingsDir 'api.json'
$settings = @{ selected = 'local'; providers = @{} }
if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
    $settings = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
    if (!$settings.providers) { $settings.providers = @{} }
}
$changes = [Collections.Generic.List[string]]::new()

if ($DefaultProfile) {
    $settings.selected = 'local'; $settings.selectedModel = "builtin-$DefaultProfile"
    $settings.localProfile = $DefaultProfile; $settings.selectedLocalModel = ''
    $changes.Add("Açılış profili: $DefaultProfile")
}
if ($NoLocalModel -and !$LlmPath) {
    $settings.selected = 'local'; $settings.selectedModel = 'off'; $settings.selectedLocalModel = ''
    $changes.Add('Açılışta yerel model yüklenmeyecek')
}

if ($LlmPath) {
    if (!(Test-Path -LiteralPath $LlmPath -PathType Leaf) -or [IO.Path]::GetExtension($LlmPath).ToLowerInvariant() -ne '.gguf') {
        throw "GGUF dil modeli bulunamadı: $LlmPath"
    }
    if ([IO.Path]::GetFileName($LlmPath) -match '(?i)mmproj|projector') { throw 'Görsel projektörü (mmproj) tek başına dil modeli olarak eklenemez.' }
    $full = [IO.Path]::GetFullPath($LlmPath)
    $models = @($settings.localModels | Where-Object { $_ })
    $existing = @($models | Where-Object { $_.path -eq $full })[0]
    if (!$existing) {
        $existing = @{ id = ('local-' + [guid]::NewGuid().ToString('N')); name = [IO.Path]::GetFileNameWithoutExtension($full); path = $full }
        $models += $existing
    }
    $settings.localModels = $models
    $settings.selected = 'local'; $settings.selectedModel = $existing.id; $settings.selectedLocalModel = $existing.id
    $changes.Add("Dil modeli: $full")
}

$external = @($settings.externalMediaModels | Where-Object { $_ })
foreach ($item in @(@{ kind = 'image'; path = $ImageModelPath }, @{ kind = 'video'; path = $VideoModelPath })) {
    if (!$item.path) { continue }
    $external = @(Add-ExternalMediaModel $external $item.path $item.kind)
    $settings[($item.kind + 'LocalModel')] = [IO.Path]::GetFileName($item.path)
    $settings[($item.kind + 'Provider')] = 'local'
    $changes.Add(($(if ($item.kind -eq 'image') { 'Görsel modeli: ' } else { 'Video modeli: ' }) + [IO.Path]::GetFullPath($item.path)))
}
if ($ImageModelPath -or $VideoModelPath) {
    $settings.externalMediaModels = $external
    [void](Write-ComfyExtraModelPaths $Root $external)
}

if ($OpenApiSettings) {
    $settings.firstRunApiSettings = $true
    $changes.Add('İlk açılışta API bağlantıları penceresi açılacak')
}

if (!$changes.Count) { Write-Host 'Değişiklik yok.'; exit 0 }
[void][IO.Directory]::CreateDirectory($settingsDir)
$temp = $settingsPath + '.tmp'
[IO.File]::WriteAllText($temp, ($settings | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
Move-Item -LiteralPath $temp -Destination $settingsPath -Force
foreach ($change in $changes) { Write-Host ('   [ok]   ' + $change) -ForegroundColor Green }
exit 0
