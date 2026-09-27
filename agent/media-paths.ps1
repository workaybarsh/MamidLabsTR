# Harici (kopyalanmadan yerinde kullanilan) gorsel ve video model dosyalari.
#
# Eskiden "Yerel model ice aktar" secilen dosyayi ComfyUI\models altina kopyaliyordu;
# 13 GB'lik bir Krea-2 dosyasi icin bu hem dakikalar suruyor hem diskte ikinci kopya
# birakiyordu. Artik dosya yolu settings\api.json icindeki externalMediaModels
# listesine yazilir ve ComfyUI o klasorleri settings\comfy-extra-models.yaml
# uzerinden (--extra-model-paths-config) gorur. Model adi yalnizca dosya adidir.
#
# Bu dosya arayuz icermez: masaustu, kurulum betigi (configure-models.ps1) ve
# gorsel/video isleri ayni fonksiyonlari kullanir.

# Desteklenen mimariler: gorselde Krea 2 Turbo (.safetensors veya Lite icin .gguf),
# videoda Wan 2.2 TI2V 5B (.safetensors). Farkli mimariler farkli is akisi ister.
function Test-MediaModelFile([string]$path, [string]$kind) {
    $name = [IO.Path]::GetFileName($path)
    if ($kind -eq 'image') { return $name -match '(?i)krea2.*turbo.*\.(safetensors|gguf)$' }
    if ($kind -eq 'video') { return $name -match '(?i)wan2[._]2.*ti2v.*5b.*\.safetensors$' }
    return $false
}

# ComfyUI'nin modeli arayacagi klasor turu: GGUF'ler ComfyUI-GGUF'in baktigi unet,
# digerleri diffusion_models.
function Get-ComfyModelFolder([string]$path) {
    if ([IO.Path]::GetExtension($path).ToLowerInvariant() -eq '.gguf') { return 'unet' }
    return 'diffusion_models'
}

function Read-ExternalMediaModels([string]$root) {
    $path = Join-Path $root 'settings\api.json'
    if (!(Test-Path -LiteralPath $path -PathType Leaf)) { return @() }
    try { $settings = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return @() }
    return @($settings.externalMediaModels | Where-Object { $_ -and $_.path })
}

# Listeye yeni bir harici model ekler (ayni yol ikinci kez eklenmez) ve guncel
# listeyi dondurur. Dosya ve mimari burada dogrulanir.
function Add-ExternalMediaModel($models, [string]$path, [string]$kind) {
    if (!(Test-Path -LiteralPath $path -PathType Leaf)) { throw "Model dosyası bulunamadı: $path" }
    if (!(Test-MediaModelFile $path $kind)) {
        $expected = if ($kind -eq 'image') { 'Krea 2 Turbo (.safetensors veya .gguf)' } else { 'Wan 2.2 TI2V 5B (.safetensors)' }
        throw "Bu dosya desteklenmiyor. Beklenen: $expected."
    }
    $full = [IO.Path]::GetFullPath($path)
    $list = @($models | Where-Object { $_ -and [string]$_.path -ne $full })
    return @($list + @(@{ kind = $kind; path = $full }))
}

# settings\comfy-extra-models.yaml dosyasini listeden uretir. Icerik degismediyse
# dosyaya dokunulmaz: ComfyUI dosya yeniyse yeniden baslatilir, gereksiz yeniden
# baslatma ~20 sn kaybettirir. Liste bossa dosya silinir. Yazilan yolu dondurur.
function Write-ComfyExtraModelPaths([string]$root, $models) {
    $yaml = Join-Path $root 'settings\comfy-extra-models.yaml'
    $folders = [ordered]@{}
    foreach ($model in @($models)) {
        if (!$model -or !(Test-Path -LiteralPath ([string]$model.path) -PathType Leaf)) { continue }
        $key = Get-ComfyModelFolder ([string]$model.path)
        $dir = ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath([string]$model.path))).Replace('\', '/')
        if (!$folders.Contains($key)) { $folders[$key] = [Collections.Generic.List[string]]::new() }
        if (!$folders[$key].Contains($dir)) { $folders[$key].Add($dir) }
    }
    if (!$folders.Count) {
        if (Test-Path -LiteralPath $yaml) { Remove-Item -LiteralPath $yaml -Force }
        return $null
    }
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add('# MamidLabs tarafindan uretilir; Gorsel ve video modelleri penceresinden degistir.')
    $lines.Add('mamidlabs_harici:')
    foreach ($key in $folders.Keys) {
        $lines.Add("    ${key}: |")
        foreach ($dir in $folders[$key]) { $lines.Add("        $dir") }
    }
    $content = ($lines -join "`n") + "`n"
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $yaml))
    if ((Test-Path -LiteralPath $yaml) -and ([IO.File]::ReadAllText($yaml) -eq $content)) { return $yaml }
    [IO.File]::WriteAllText($yaml, $content, [Text.UTF8Encoding]::new($false))
    return $yaml
}

# Model adi ComfyUI\models altinda yoksa kayitli harici dosyalarda aranir. Bulunursa
# ComfyUI'ye verilecek ad (dosya adi) doner; bulunamazsa $null.
function Resolve-ExternalMediaModel([string]$root, [string]$name, [string]$comfyFolder) {
    if (!$name -or $name.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) { return $null }
    foreach ($model in @(Read-ExternalMediaModels $root)) {
        $path = [string]$model.path
        if ([IO.Path]::GetFileName($path) -ne $name) { continue }
        if ((Get-ComfyModelFolder $path) -ne $comfyFolder) { continue }
        if (Test-Path -LiteralPath $path -PathType Leaf) { return $name }
    }
    return $null
}
