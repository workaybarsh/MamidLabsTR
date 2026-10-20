param([hashtable]$JobData, [hashtable]$Shared)

# Gorsel uretim akisi:
#   1) Dil modeli VRAM'den bosaltilir (model dosyasi Windows dosya onbelleginde kalir)
#   2) ComfyUI + Krea-2 Turbo yuklenir ve gorsel uretilir
#   3) Gorsel modeli kapatilir, dil modeli geri yuklenir
#
# Modlar:
#   yeni            : metinden gorsel
#   yeniden_uret    : klasik img2img, kaynak gorselin kompozisyonu korunur (denoise = strength)
#   stil_referansi  : Krea-2 stil referansi LoRA'si, kaynak gorsel Qwen3-VL'e kosullama olarak girer
#   kimlik_duzenle  : Krea 2 Identity Edit v1.2 (fotografi talimatla duzenle). Kaynak hem VAE
#                     latent'i (gorunus) hem Qwen3-VL'e (anlam) verilir; yuz/kimlik korunur.
#                     Istege bagli ikinci gorsel: sahne = 1. gorsel, kisi = 2. gorsel.
#                     Sablon: agent\workflows\krea2_identity_edit.json (ComfyUI arayuz bicimi).
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Add-Type -AssemblyName System.Drawing

# Kurulum kokunu kendi konumundan turet. ONEMLI: bu dosya Start-ThreadJob -FilePath
# ile baslatilir; bu, hedef dosyayi METIN olarak okuyup yeni bir runspace'te
# calistirir - $PSScriptRoot o baglamda HEP BOSTUR (gercek makinede dogrulandi).
# Asil kaynak mamidlabs-desktop.ps1'in JobData.root ile acikca gecirdigi degerdir;
# $PSScriptRoot yalnizca bu dosya '&' veya '-File' ile dogrudan calistirildiginda
# (elle test/hata ayiklama) devreye girer.
$root = if ($JobData.root) { [string]$JobData.root } elseif ($PSScriptRoot) { Split-Path -Parent $PSScriptRoot } else { (Get-Location).Path }
$manage = Join-Path $root 'scripts\manage-mamidlabs.ps1'
# Dil modeli durdur/geri-yukle akisi videogen-run.ps1 ile paylasilir (Amp #17).
. (Join-Path $root 'agent\media-model-swap.ps1')
$comfyDir = Join-Path $root 'ComfyUI'
$python = Join-Path $root 'venv\imagegen\Scripts\python.exe'
$comfyOut = Join-Path $root 'outputs\comfy'
$comfyIn = Join-Path $root 'outputs\input'
$imageOut = Join-Path $root 'outputs\images'
$logs = Join-Path $root 'logs'
$comfyUrl = 'http://127.0.0.1:8188'
$styleLora = Join-Path $comfyDir 'models\loras\krea2_style_reference.safetensors'
$identityLoraName = 'krea2_identity_edit_v1_2.safetensors'
$identityLora = Join-Path $comfyDir ('models\loras\' + $identityLoraName)
$identityNode = Join-Path $comfyDir 'custom_nodes\comfyui-krea2edit\__init__.py'

function Emit([string]$kind, [string]$text, $data = $null) {
    [pscustomobject]@{ kind = $kind; text = $text; usage = $null; data = $data }
}

function Get-Resolution([string]$aspect) {
    switch ($aspect) {
        '16:9' { return @(1344, 768) }
        '9:16' { return @(768, 1344) }
        '4:3'  { return @(1152, 896) }
        '3:4'  { return @(896, 1152) }
        default { return @(1024, 1024) }
    }
}

# Kaynak gorseli ~1 MP'ye olcekleyip ComfyUI input klasorune yazar; (dosyaAdi, genislik, yukseklik) doner.
function Write-SourceImage([string]$path) {
    $img = [System.Drawing.Image]::FromFile($path)
    try {
        $scale = [math]::Sqrt(1048576.0 / ($img.Width * $img.Height))
        $w = [int]([math]::Round($img.Width * $scale / 8.0) * 8)
        $h = [int]([math]::Round($img.Height * $scale / 8.0) * 8)
        if ($w -lt 256) { $w = 256 }
        if ($h -lt 256) { $h = 256 }
        $bmp = New-Object System.Drawing.Bitmap($w, $h)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        try {
            $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $g.DrawImage($img, 0, 0, $w, $h)
        } finally { $g.Dispose() }
        $name = 'ref-' + (Get-Date -Format 'yyyyMMddHHmmss') + '.png'
        $bmp.Save((Join-Path $comfyIn $name), [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        return @($name, $w, $h)
    } finally { $img.Dispose() }
}

function Stop-Comfy($process) {
    if ($process -and !$process.HasExited) {
        try { $process.Kill($true) } catch { try { $process.Kill() } catch { } }
        try { $process.WaitForExit(20000) | Out-Null } catch { }
    }
}

# fal'in krea-2 egitim araciyla kaydedilen LoRA'lar PEFT onekini (base_model.model.)
# kullanir; ComfyUI diffusion_model. bekler ve eslesmeyen her anahtari atlar - LoRA
# hic uygulanmaz (528/528 anahtar "lora key not loaded" olarak olculdu). Yalnizca
# baslik yeniden yazilir; tensor verisi ve sekilleri aynen kalir.
function Repair-LoraKeyPrefix([string]$path) {
    $tmp = $null
    $fs = [IO.File]::OpenRead($path)
    try {
        $reader = New-Object IO.BinaryReader($fs)
        $headerLength = $reader.ReadUInt64()
        if ($headerLength -eq 0 -or $headerLength -gt 100MB) { return }
        $header = [Text.Encoding]::UTF8.GetString($reader.ReadBytes([int]$headerLength))
        if (!$header.Contains('"base_model.model.')) { return }
        $fixed = [Text.Encoding]::UTF8.GetBytes($header.Replace('"base_model.model.', '"diffusion_model.'))
        $pad = (8 - ($fixed.Length % 8)) % 8
        $tmp = "$path.tmp"
        $out = [IO.File]::Create($tmp)
        try {
            $out.Write([BitConverter]::GetBytes([uint64]($fixed.Length + $pad)), 0, 8)
            $out.Write($fixed, 0, $fixed.Length)
            for ($i = 0; $i -lt $pad; $i++) { $out.WriteByte(0x20) }
            $fs.CopyTo($out)
        } finally { $out.Dispose() }
    } finally { $fs.Dispose() }
    Move-Item -LiteralPath $tmp -Destination $path -Force
}

function Resolve-ComfyOutput([string]$filename, [string]$subfolder, [string]$root, [string[]]$extensions) {
    if (!$filename -or $filename.IndexOf([char]0) -ge 0) { throw 'ComfyUI gecersiz cikti adi dondurdu.' }
    $relative = if ($subfolder) { Join-Path $subfolder $filename } else { $filename }
    try { $candidate = [IO.Path]::GetFullPath((Join-Path $root $relative)) } catch { throw 'ComfyUI gecersiz cikti yolu dondurdu.' }
    if (!(Inside $candidate $root)) { throw 'ComfyUI cikti klasoru disina tasan bir yol dondurdu.' }
    if ([IO.Path]::GetExtension($candidate).ToLowerInvariant() -notin $extensions) { throw 'ComfyUI beklenmeyen gorsel dosyasi dondurdu.' }
    if (!(Test-Path -LiteralPath $candidate -PathType Leaf)) { throw 'ComfyUI cikti dosyasi bulunamadi.' }
    return $candidate
}

function Inside([string]$path, [string]$folder) {
    $full = [IO.Path]::GetFullPath($path).TrimEnd('\')
    $root = [IO.Path]::GetFullPath($folder).TrimEnd('\')
    return $full.Equals($root, [StringComparison]::OrdinalIgnoreCase) -or
        $full.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Resolve-LocalModelName([string]$name, [string]$subfolder = 'models\diffusion_models') {
    if (!$name) { return $null }
    # Lite'in GGUF kuantize modelleri models\unet altindadir (.gguf); MAX/FLASH'in
    # tam hassasiyetli modelleri models\diffusion_models altindadir (.safetensors).
    $allowedExt = if ($subfolder -eq 'models\unet') { '.gguf' } else { '.safetensors' }
    $modelRoot = Join-Path $comfyDir $subfolder
    try { $candidate = [IO.Path]::GetFullPath((Join-Path $modelRoot $name)) } catch { throw 'Yerel gorsel modeli yolu gecersiz.' }
    if (!(Inside $candidate $modelRoot) -or [IO.Path]::GetExtension($candidate).ToLowerInvariant() -ne $allowedExt) { throw "Yerel gorsel modeli yalnizca $subfolder altinda bir $allowedExt dosyasi olabilir." }
    if (!(Test-Path -LiteralPath $candidate -PathType Leaf)) {
        # Kopyalanmadan eklenen harici dosya (settings\comfy-extra-models.yaml ile ComfyUI'ye tanitilir).
        $external = Resolve-ExternalMediaModel $root $name (Split-Path -Leaf $subfolder)
        if ($external) { return $external }
        throw 'Secilen yerel gorsel modeli bulunamadi.'
    }
    return $candidate.Substring($modelRoot.Length + 1).Replace('\', '/')
}

# Kimlik duzenleme cozunurlugu: kaynagin en-boy orani korunur, ~1 MP'ye olceklenir ve
# 16'nin katina yuvarlanir (VAE /8, DiT yama boyutu /2). Sablon notu: 1 MP en iyi
# denge; iki kisilik gorsellerde ~1,5 MP'yi asma.
function Get-EditResolution([int]$sourceWidth, [int]$sourceHeight) {
    $scale = [math]::Sqrt(1048576.0 / ([double]$sourceWidth * $sourceHeight))
    $w = [int]([math]::Round($sourceWidth * $scale / 16.0) * 16)
    $h = [int]([math]::Round($sourceHeight * $scale / 16.0) * 16)
    return @([math]::Max(512, $w), [math]::Max(512, $h))
}

# agent\workflows\krea2_identity_edit.json'un API bicimindeki karsiligi. Arayuz
# sablonundan tek fark: target_latent baglidir (dugum paketi README'si: kaynak
# ornekleme baslamadan kodlanir, VRAM'i dar kartlarda model bolunmez).
function New-IdentityEditWorkflow([hashtable]$wf, [string]$prompt, [int]$width, [int]$height, [long]$seed, [int]$steps,
                                  [string]$refName, [string]$refNameB, [double]$refBoost, [int]$groundingPx) {
    $wf['71'] = @{ class_type = 'LoraLoaderModelOnly'; inputs = @{ model = @('10', 0); lora_name = $identityLoraName; strength_model = 1.0 } }
    $wf['72'] = @{ class_type = 'LoadImage'; inputs = @{ image = $refName } }
    $wf['73'] = @{ class_type = 'VAEEncode'; inputs = @{ pixels = @('72', 0); vae = @('12', 0) } }
    $wf['82'] = @{ class_type = 'EmptySD3LatentImage'; inputs = @{ width = $width; height = $height; batch_size = 1 } }
    $patch = @{ model = @('71', 0); source_latent = @('73', 0); vae = @('12', 0); source_image = @('72', 0)
                target_latent = @('82', 0); ref_boost = $refBoost; ref_boost_a = 1.0; fit_mode = 'fit' }
    $positive = @{ clip = @('11', 0); prompt = $prompt; image = @('72', 0); grounding_px = $groundingPx; system_prompt = '' }
    # Negatif: bos talimat + ayni gorsel (egitimdeki kosulsuz hal); CFG 1'de etkisizdir.
    $negative = @{ clip = @('11', 0); prompt = ''; image = @('72', 0); grounding_px = $groundingPx; system_prompt = '' }
    if ($refNameB) {
        # Iki gorsel: sahne 1. kaynak, kisi 2. kaynak. ref_boost son kaynaga (kisiye) uygulanir.
        $wf['90'] = @{ class_type = 'LoadImage'; inputs = @{ image = $refNameB } }
        $wf['92'] = @{ class_type = 'VAEEncode'; inputs = @{ pixels = @('90', 0); vae = @('12', 0) } }
        $patch.source_latent_b = @('92', 0); $patch.source_image_b = @('90', 0)
        $positive.image_b = @('90', 0); $negative.image_b = @('90', 0)
    }
    $wf['79'] = @{ class_type = 'Krea2EditModelPatch'; inputs = $patch }
    $wf['84'] = @{ class_type = 'Krea2EditGroundedEncode'; inputs = $positive }
    $wf['85'] = @{ class_type = 'Krea2EditGroundedEncode'; inputs = $negative }
    $wf['3'] = @{ class_type = 'KSampler'; inputs = @{
        model = @('79', 0); positive = @('84', 0); negative = @('85', 0); latent_image = @('82', 0)
        seed = $seed; steps = $steps; cfg = 1; sampler_name = 'euler'; scheduler = 'simple'; denoise = 1.0 } }
    return $wf
}

function New-Workflow([string]$mode, [string]$prompt, [int]$width, [int]$height, [long]$seed, [int]$steps, [string]$refName, [double]$strength, [bool]$realism, [double]$realismStrength, [bool]$lite, [string]$refNameB = '', [double]$refBoost = 4.0, [int]$groundingPx = 768) {
    # Lite (8 GB VRAM): MAX/FLASH'in krea2_turbo_fp8_scaled.safetensors (~13,1 GB) dosyasi
    # tek basina karta sigmaz. Bunun yerine GGUF ile kuantize edilmis bir surum
    # (Q4_K_M, ~7,49 GB) 'UnetLoaderGGUF' dugumuyle yuklenir (ComfyUI-GGUF custom
    # node'u gerektirir); metin kodlayici/VAE/LoRA'lar MAX/FLASH ile ayni kalir -
    # yalnizca diffusion model yukleyici ve dosyasi degisir.
    $unetNode = if ($lite) {
        @{ class_type = 'UnetLoaderGGUF'; inputs = @{ unet_name = $(if($JobData.localModel){[string]$JobData.localModel}else{'krea2_turbo-Q4_K_M.gguf'}) } }
    } else {
        @{ class_type = 'UNETLoader'; inputs = @{ unet_name = $(if($JobData.localModel){[string]$JobData.localModel}else{'krea2_turbo_fp8_scaled.safetensors'}); weight_dtype = 'default' } }
    }
    $wf = @{
        '10' = $unetNode
        '11' = @{ class_type = 'CLIPLoader'; inputs = @{ clip_name = 'qwen3vl_4b_fp8_scaled.safetensors'; type = 'krea2'; device = 'default' } }
        '12' = @{ class_type = 'VAELoader'; inputs = @{ vae_name = 'qwen_image_vae.safetensors' } }
        '8'  = @{ class_type = 'VAEDecode'; inputs = @{ samples = @('3', 0); vae = @('12', 0) } }
        '9'  = @{ class_type = 'SaveImage'; inputs = @{ images = @('8', 0); filename_prefix = 'mamidlabs-local' } }
    }

    if ($mode -eq 'kimlik_duzenle') {
        $wf['9'].inputs.filename_prefix = 'mamidlabs-edit'
        return (New-IdentityEditWorkflow $wf $prompt $width $height $seed $steps $refName $refNameB $refBoost $groundingPx)
    }

    # Gercekci isik/golge/yansima LoRA'si; model zincirinin basina takilir.
    $modelSource = @('10', 0)
    if ($realism) {
        $wf['70'] = @{ class_type = 'LoraLoaderModelOnly'; inputs = @{ model = @('10', 0); lora_name = 'krea2_realism_lora.safetensors'; strength_model = $realismStrength } }
        $modelSource = @('70', 0)
    }

    if ($mode -eq 'stil_referansi') {
        # Sablon: Image Style Reference (Krea-2 Turbo)
        $wf['15'] = @{ class_type = 'LoraLoaderModelOnly'; inputs = @{ model = $modelSource; lora_name = 'krea2_style_reference.safetensors'; strength_model = 1.0 } }
        $wf['64'] = @{ class_type = 'ModelSamplingFlux'; inputs = @{ model = @('15', 0); max_shift = 1.15; base_shift = 0.5; width = $width; height = $height } }
        $wf['20'] = @{ class_type = 'LoadImage'; inputs = @{ image = $refName } }
        $wf['52'] = @{ class_type = 'TextEncodeQwenImageEditPlus'; inputs = @{ clip = @('11', 0); prompt = $prompt; vae = @('12', 0); image1 = @('20', 0) } }
        $wf['53'] = @{ class_type = 'FluxKontextMultiReferenceLatentMethod'; inputs = @{ conditioning = @('52', 0); reference_latents_method = 'index_timestep_zero' } }
        $wf['13'] = @{ class_type = 'ConditioningZeroOut'; inputs = @{ conditioning = @('52', 0) } }
        $wf['57'] = @{ class_type = 'CFGGuider'; inputs = @{ model = @('64', 0); positive = @('53', 0); negative = @('13', 0); cfg = 1.0 } }
        $wf['59'] = @{ class_type = 'KSamplerSelect'; inputs = @{ sampler_name = 'euler' } }
        $wf['60'] = @{ class_type = 'BasicScheduler'; inputs = @{ model = @('64', 0); scheduler = 'simple'; steps = $steps; denoise = 1.0 } }
        $wf['63'] = @{ class_type = 'RandomNoise'; inputs = @{ noise_seed = $seed } }
        $wf['61'] = @{ class_type = 'EmptyLatentImage'; inputs = @{ width = $width; height = $height; batch_size = 1 } }
        $wf['3']  = @{ class_type = 'SamplerCustomAdvanced'; inputs = @{ noise = @('63', 0); guider = @('57', 0); sampler = @('59', 0); sigmas = @('60', 0); latent_image = @('61', 0) } }
        return $wf
    }

    $wf['6'] = @{ class_type = 'CLIPTextEncode'; inputs = @{ clip = @('11', 0); text = $prompt } }
    $wf['13'] = @{ class_type = 'ConditioningZeroOut'; inputs = @{ conditioning = @('6', 0) } }
    if ($mode -eq 'yeniden_uret') {
        $wf['20'] = @{ class_type = 'LoadImage'; inputs = @{ image = $refName } }
        $wf['21'] = @{ class_type = 'VAEEncode'; inputs = @{ pixels = @('20', 0); vae = @('12', 0) } }
        $latent = @('21', 0)
        $denoise = $strength
    } else {
        $wf['5'] = @{ class_type = 'EmptyLatentImage'; inputs = @{ width = $width; height = $height; batch_size = 1 } }
        $latent = @('5', 0)
        $denoise = 1.0
    }
    $wf['3'] = @{ class_type = 'KSampler'; inputs = @{
        model = $modelSource; positive = @('6', 0); negative = @('13', 0); latent_image = $latent
        seed = $seed; steps = $steps; cfg = 1; sampler_name = 'euler'; scheduler = 'simple'; denoise = $denoise } }
    return $wf
}

$comfy = $null
try {
    foreach ($dir in @($comfyOut, $comfyIn, $imageOut, $logs)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if (!(Test-Path -LiteralPath $python -PathType Leaf)) { throw "Gorsel uretim ortami bulunamadi: $python" }
    $lite = [bool]$JobData.lite
    # Krea-2'nin ayrik UNET'i diffusion_models altindadir; Lite'in GGUF kuantize
    # surumu ComfyUI-GGUF custom node'unun aradigi models\unet altindadir.
    $modelFolder = if ($lite) { 'models\unet' } else { 'models\diffusion_models' }
    if ($JobData.localModel) { $JobData.localModel = Resolve-LocalModelName ([string]$JobData.localModel) $modelFolder }

    $mode = [string]$JobData.mode
    if (!$mode) { $mode = 'yeni' }
    $source = [string]$JobData.sourceImage
    if ($mode -ne 'yeni' -and (!$source -or !(Test-Path -LiteralPath $source -PathType Leaf))) {
        throw 'Bu mod icin kaynak gorsel gerekli; once sohbete bir gorsel ekle.'
    }
    if ($mode -eq 'stil_referansi' -and !(Test-Path -LiteralPath $styleLora -PathType Leaf)) {
        throw 'Stil referansi LoRA dosyasi bulunamadi: krea2_style_reference.safetensors'
    }
    $sourceB = [string]$JobData.sourceImageB
    if ($mode -eq 'kimlik_duzenle') {
        # LITE'ta (8 GB VRAM) sunulmaz (mamidlabs-inference.ps1 aracin enum'undan cikarir); model
        # yine de eski/onbellek bir arac cagrisiyla isterse burada acikca reddedilir. Sebep:
        # GGUF difuzyon modeli + metin/gorsel kodlayici ayni anda VRAM'e sigmayip 10-15 dk'ya
        # cikiyor (bkz. AGENTS.md donanim tablosu; r64/r128 kucuk LoRA da cozmuyor).
        if ($lite) { throw 'Fotograf duzenleme (kimlik korumali) LITE profilinde desteklenmiyor; 8 GB VRAM kartta asiri yavas. yeniden_uret modunu kullan.' }
        if (!(Test-Path -LiteralPath $identityNode -PathType Leaf)) {
            throw 'Fotograf duzenleme icin comfyui-krea2edit dugum paketi kurulu degil. Kurulumu guncelle: install-mamidlabs.ps1 -Stage comfyui'
        }
        if (!(Test-Path -LiteralPath $identityLora -PathType Leaf)) {
            throw "Fotograf duzenleme LoRA'si bulunamadi: $identityLoraName. Profiller -> Profil yoneticisi -> Eksikleri indir."
        }
        if ($sourceB -and !(Test-Path -LiteralPath $sourceB -PathType Leaf)) { $sourceB = '' }
    } else { $sourceB = '' }

    $size = Get-Resolution ([string]$JobData.aspect)
    $width = $size[0]; $height = $size[1]
    $refName = $null
    $refNameB = ''
    if ($mode -ne 'yeni') {
        $written = Write-SourceImage $source
        $refName = $written[0]
        if ($mode -eq 'yeniden_uret') { $width = $written[1]; $height = $written[2] }
        if ($mode -eq 'kimlik_duzenle') {
            # Cikti sahnenin (1. gorsel) en-boy oranini izler; fit_mode='fit' kisiyi ona yerlestirir.
            $size = Get-EditResolution $written[1] $written[2]
            $width = $size[0]; $height = $size[1]
            if ($sourceB) { $refNameB = (Write-SourceImage $sourceB)[0] }
        }
    }

    $seed = if ($JobData.seed) { [long]$JobData.seed } else { [long](Get-Random -Minimum 1 -Maximum 2147483646) }
    # Turbo + Identity Edit sablonu 10 adimi dengeli bulur (8 = talimata daha sadik, 12 = daha cok yuz ayrintisi).
    $steps = if ($JobData.steps) { [int]$JobData.steps } elseif ($mode -eq 'kimlik_duzenle') { 10 } else { 8 }
    # Sadakat ayari (ref_boost): 4 onerilen, >10 kaldirma/degistirme duzenlemelerini bozar.
    $refBoost = if ($JobData.refBoost) { [math]::Min(10.0, [math]::Max(0.5, [double]$JobData.refBoost)) } else { 4.0 }
    $strength = if ($JobData.strength) { [double]$JobData.strength } else { 0.6 }
    if ($strength -lt 0.2) { $strength = 0.2 }
    if ($strength -gt 0.95) { $strength = 0.95 }

    Stop-LocalModelForMedia $manage

    Emit 'status' $(if ($lite) { 'Krea-2 Turbo (GGUF, dusuk VRAM modu) yukleniyor...' } else { 'Krea-2 Turbo yukleniyor...' })
    # Ilk acilis ComfyUI'nin asset DB'sini kurar; yavas diskte/Defender altinda
    # 297 sn olculdu. 180 sn, kurulum smoke testini yanlis basarisiz gosteriyordu.
    $comfy = Start-OrReuseComfy $python $comfyDir $comfyOut $comfyIn $logs $comfyUrl $lite 600 $Shared

    # Yalnizca kullanici acikca gercekci gorsel istediginde acik gelir (mamidlabs-inference.ps1 Test-RealismIntent).
    $realism = [bool]$JobData.realism
    # Kimlik duzenlemede gercekcilik LoRA'si zincire eklenmez; kaynak fotograf zaten gercekci.
    if ($mode -eq 'kimlik_duzenle') { $realism = $false }
    $realismStrength = if ($JobData.realismStrength) { [double]$JobData.realismStrength } else { 0.8 }
    $realismLora = Join-Path $comfyDir 'models\loras\krea2_realism_lora.safetensors'
    if (!(Test-Path -LiteralPath $realismLora -PathType Leaf)) { $realism = $false }
    if ($realism) {
        try { Repair-LoraKeyPrefix $realismLora }
        catch { Emit 'status' ("Gercekcilik LoRA'si ComfyUI bicimine donusturulemedi: " + $_.Exception.Message) }
    }

    $modeLabel = switch ($mode) {
        'yeniden_uret' { "gorselden yeniden uretim (guc $strength)" }
        'stil_referansi' { 'stil referansi' }
        'kimlik_duzenle' { if ($refNameB) { 'fotograf duzenleme (sahne + kisi)' } else { 'fotograf duzenleme (kimlik korunur)' } }
        default { 'metinden gorsel' }
    }
    if ($realism) { $modeLabel += ' + gercekcilik' }
    Emit 'status' "Gorsel uretiliyor - $modeLabel ($width x $height, $steps adim)..."

    $workflow = New-Workflow $mode $JobData.prompt $width $height $seed $steps $refName $strength $realism $realismStrength $lite $refNameB $refBoost
    $body = @{ prompt = $workflow; client_id = [guid]::NewGuid().ToString() } | ConvertTo-Json -Depth 20 -Compress
    $queued = Invoke-RestMethod "$comfyUrl/prompt" -Method Post -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 60
    $promptId = [string]$queued.prompt_id
    if (!$promptId) { throw 'ComfyUI istegi kuyruga alinamadi.' }

    $produced = $null
    $deadline = [DateTime]::UtcNow.AddSeconds(900)
    while ([DateTime]::UtcNow -lt $deadline) {
        if ($Shared.Cancel) { throw 'İşlem durduruldu.' }
        if ($comfy.HasExited) { throw 'ComfyUI uretim sirasinda kapandi (muhtemelen VRAM yetersiz).' }
        Start-Sleep -Milliseconds 800
        $history = $null
        try { $history = Invoke-RestMethod "$comfyUrl/history/$promptId" -TimeoutSec 10 -ErrorAction Stop } catch { continue }
        $entry = $history.$promptId
        if (!$entry) { continue }
        if ($entry.status -and $entry.status.status_str -eq 'error') { throw 'ComfyUI uretim hatasi; logs\comfyui.stderr.log dosyasina bak.' }
        foreach ($nodeOutput in $entry.outputs.PSObject.Properties) {
            foreach ($image in @($nodeOutput.Value.images)) {
                if ($image.filename) { $produced = $image; break }
            }
            if ($produced) { break }
        }
        if ($produced) { break }
    }
    if (!$produced) { throw 'Gorsel uretimi zaman asimina ugradi.' }

    $sourcePath = Resolve-ComfyOutput ([string]$produced.filename) ([string]$produced.subfolder) $comfyOut @('.png', '.jpg', '.jpeg', '.webp')
    $finalPath = Join-Path $imageOut ('mamidlabs-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.png')
    Copy-Item -LiteralPath $sourcePath -Destination $finalPath -Force
    # Ara dosyalar birikmesin: ComfyUI ciktisi kopyalandiktan sonra, referanslarin son 20'si kalsin.
    Remove-Item -LiteralPath $sourcePath -Force -ErrorAction SilentlyContinue
    Get-ChildItem -LiteralPath $comfyIn -Filter 'ref-*.png' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -Skip 20 |
        Remove-Item -Force -ErrorAction SilentlyContinue

    Emit 'status' 'Gorsel modeli bellekten bosaltiliyor...'
    # Geri yuklenecek dil modelinin tam sigmasi icin gereken asgari bos VRAM
    # (MAX/FLASH ~14.6 GB; LITE ~6.2 GB + projektor). Yetmezse ComfyUI kapatilir.
    Release-Comfy $comfy $comfyUrl $(if ($lite) { 6000 } else { 14000 })
    $comfy = $null
    $Shared.Process = $null

    Emit 'image' $finalPath @{ prompt = [string]$JobData.prompt; seed = $seed; width = $width; height = $height; steps = $steps; mode = $mode }

    Restore-LocalModelForMedia $manage ([string]$JobData.restoreProfile) $false | Out-Null
    Emit 'done' 'Gorsel hazir.'
} catch {
    # Acilis sirasinda hata olursa $comfy atanmamistir; yari acik surec $Shared'dadir.
    Stop-Comfy $(if ($comfy) { $comfy } else { $Shared.Process })
    # Restore denemesinin KENDISI basarisiz olursa (ikinci parametre $true),
    # hata yutulup asagida orijinal hatayla birlikte gosterilir (#16) -
    # kullaniciya yalnizca gorsel hatasi gosterip dil modelinin de hazir
    # olmadigini gizlemek yanlis olur.
    $restoreFailure = Restore-LocalModelForMedia $manage ([string]$JobData.restoreProfile) $true
    $originalMessage = if ($Shared.Cancel) { 'İşlem durduruldu.' } else { $_.Exception.Message }
    if ($restoreFailure) {
        # Geri yukleme de basarisizsa kullaniciyi bundan haberdar etmeden yalnizca
        # orijinal hatayi gostermek, dil modelinin hazir sanilmasina yol acar.
        Emit 'error' "$originalMessage Ayrica dil modeli geri yuklenemedi: $restoreFailure Modeli elle yeniden baslat."
    } elseif ($Shared.Cancel) { Emit 'cancelled' 'İşlem durduruldu.' } else { Emit 'error' $originalMessage }
} finally {
    $Shared.Process = $null
}
