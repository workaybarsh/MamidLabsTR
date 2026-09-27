param([hashtable]$JobData, [hashtable]$Shared)

# Video uretim akisi (gorsel uretimiyle ayni VRAM takasi):
#   1) Dil modeli VRAM'den bosaltilir
#   2) ComfyUI + Wan 2.2 TI2V-5B yuklenir, video uretilir
#   3) Video modeli kapatilir, dil modeli geri yuklenir
#
# Modlar:
#   metin   : sifirdan video (text-to-video)
#   gorsel  : eklenen gorselden video (image-to-video)
#   video   : eklenen videonun son karesinden devam (video continuation)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Add-Type -AssemblyName System.Drawing

# Kurulum kokunu kendi konumundan turet. ONEMLI: bu dosya Start-ThreadJob -FilePath
# ile baslatilir; bu, hedef dosyayi METIN olarak okuyup yeni bir runspace'te
# calistirir - $PSScriptRoot o baglamda HEP BOSTUR (gercek makinede dogrulandi).
# Asil kaynak qwen-desktop.ps1'in JobData.root ile acikca gecirdigi degerdir;
# $PSScriptRoot yalnizca bu dosya '&' veya '-File' ile dogrudan calistirildiginda
# (elle test/hata ayiklama) devreye girer.
$root = if ($JobData.root) { [string]$JobData.root } elseif ($PSScriptRoot) { Split-Path -Parent $PSScriptRoot } else { (Get-Location).Path }
$manage = Join-Path $root 'scripts\manage-qwen.ps1'
# Dil modeli durdur/geri-yukle akisi imagegen-run.ps1 ile paylasilir (Amp #17).
. (Join-Path $root 'agent\media-model-swap.ps1')
$comfyDir = Join-Path $root 'ComfyUI'
$python = Join-Path $root 'venv\imagegen\Scripts\python.exe'
$mediaPy = Join-Path $root 'agent\media-tools.py'
$comfyOut = Join-Path $root 'outputs\comfy'
$comfyIn = Join-Path $root 'outputs\input'
$videoOut = Join-Path $root 'outputs\videolar'
$logs = Join-Path $root 'logs'
$comfyUrl = 'http://127.0.0.1:8188'

$negativeDefault = 'blurry, low quality, low resolution, distorted, deformed, extra limbs, watermark, text, logo, jpeg artifacts, overexposed, static image, flickering, duplicated frames'

function Emit([string]$kind, [string]$text, $data = $null) {
    [pscustomobject]@{ kind = $kind; text = $text; usage = $null; data = $data }
}

# Lite profilinde 8 GB VRAM'i asmamak icin cozunurluk 480p bandina cekilir.
# Kaynak gorselden gelen olculer de bu siniri asamaz.
function Limit-LiteResolution([int]$width, [int]$height) {
    $maxLong = 832; $maxShort = 480
    $long = [math]::Max($width, $height); $short = [math]::Min($width, $height)
    if ($long -le $maxLong -and $short -le $maxShort) { return @($width, $height) }
    $scale = [math]::Min($maxLong / [double]$long, $maxShort / [double]$short)
    $w = [int]([math]::Round($width * $scale / 16.0) * 16)
    $h = [int]([math]::Round($height * $scale / 16.0) * 16)
    if ($w -lt 16) { $w = 16 }
    if ($h -lt 16) { $h = 16 }
    return @($w, $h)
}

function Get-Resolution([string]$aspect, [string]$quality) {
    # 16 GB VRAM icin olcekli varsayilanlar; yuksek kalite daha uzun surer.
    if ($quality -eq 'yuksek') {
        switch ($aspect) {
            '16:9' { return @(1280, 704) }
            '9:16' { return @(704, 1280) }
            '1:1'  { return @(960, 960) }
            default { return @(1280, 704) }
        }
    }
    switch ($aspect) {
        '16:9' { return @(832, 480) }
        '9:16' { return @(480, 832) }
        '1:1'  { return @(640, 640) }
        '4:3'  { return @(768, 576) }
        default { return @(832, 480) }
    }
}

function Invoke-MediaTool([hashtable]$payload) {
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $python
    $psi.ArgumentList.Add($mediaPy)
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $p = [Diagnostics.Process]::Start($psi)
    try {
        $p.StandardInput.Write(($payload | ConvertTo-Json -Compress))
        $p.StandardInput.Close()
        $out = $p.StandardOutput.ReadToEnd()
        $p.WaitForExit()
        return ($out | ConvertFrom-Json)
    } finally { $p.Dispose() }
}

function Write-SourceImage([string]$path) {
    $img = [System.Drawing.Image]::FromFile($path)
    try {
        $scale = [math]::Min(1.0, 1280.0 / [double][math]::Max($img.Width, $img.Height))
        $w = [int]([math]::Round($img.Width * $scale / 32.0) * 32)
        $h = [int]([math]::Round($img.Height * $scale / 32.0) * 32)
        if ($w -lt 128) { $w = 128 }
        if ($h -lt 128) { $h = 128 }
        $bmp = New-Object System.Drawing.Bitmap($w, $h)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        try {
            $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $g.DrawImage($img, 0, 0, $w, $h)
        } finally { $g.Dispose() }
        $name = 'vref-' + (Get-Date -Format 'yyyyMMddHHmmss') + '.png'
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

function Resolve-ComfyOutput([string]$filename, [string]$subfolder, [string]$root, [string[]]$extensions) {
    if (!$filename -or $filename.IndexOf([char]0) -ge 0) { throw 'ComfyUI gecersiz cikti adi dondurdu.' }
    $relative = if ($subfolder) { Join-Path $subfolder $filename } else { $filename }
    try { $candidate = [IO.Path]::GetFullPath((Join-Path $root $relative)) } catch { throw 'ComfyUI gecersiz cikti yolu dondurdu.' }
    if (!(Inside $candidate $root)) { throw 'ComfyUI cikti klasoru disina tasan bir yol dondurdu.' }
    if ([IO.Path]::GetExtension($candidate).ToLowerInvariant() -notin $extensions) { throw 'ComfyUI beklenmeyen video dosyasi dondurdu.' }
    if (!(Test-Path -LiteralPath $candidate -PathType Leaf)) { throw 'ComfyUI cikti dosyasi bulunamadi.' }
    return $candidate
}

function Inside([string]$path, [string]$folder) {
    $full = [IO.Path]::GetFullPath($path).TrimEnd('\')
    $root = [IO.Path]::GetFullPath($folder).TrimEnd('\')
    return $full.Equals($root, [StringComparison]::OrdinalIgnoreCase) -or
        $full.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Resolve-LocalModelName([string]$name) {
    if (!$name) { return $null }
    $modelRoot = Join-Path $comfyDir 'models\diffusion_models'
    try { $candidate = [IO.Path]::GetFullPath((Join-Path $modelRoot $name)) } catch { throw 'Yerel video modeli yolu gecersiz.' }
    if (!(Inside $candidate $modelRoot) -or [IO.Path]::GetExtension($candidate).ToLowerInvariant() -ne '.safetensors') { throw 'Yerel video modeli yalnizca diffusion_models altinda bir safetensors dosyasi olabilir.' }
    if (!(Test-Path -LiteralPath $candidate -PathType Leaf)) {
        # Kopyalanmadan eklenen harici dosya (settings\comfy-extra-models.yaml ile ComfyUI'ye tanitilir).
        $external = Resolve-ExternalMediaModel $root $name 'diffusion_models'
        if ($external) { return $external }
        throw 'Secilen yerel video modeli bulunamadi.'
    }
    return $candidate.Substring($modelRoot.Length + 1).Replace('\', '/')
}

$comfy = $null
try {
    foreach ($dir in @($comfyOut, $comfyIn, $videoOut, $logs)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if (!(Test-Path -LiteralPath $python -PathType Leaf)) { throw "Gorsel/video ortami bulunamadi: $python" }
    if ($JobData.localModel) { $JobData.localModel = Resolve-LocalModelName ([string]$JobData.localModel) }

    $mode = [string]$JobData.mode
    if (!$mode) { $mode = 'metin' }
    $source = [string]$JobData.sourceFile

    $startImage = $null
    if ($mode -eq 'gorsel') {
        if (!$source -or !(Test-Path -LiteralPath $source -PathType Leaf)) { throw 'Bu mod icin bir gorsel gerekli; once sohbete gorsel ekle.' }
        $startImage = $source
    } elseif ($mode -eq 'video') {
        if (!$source -or !(Test-Path -LiteralPath $source -PathType Leaf)) { throw 'Bu mod icin bir video gerekli; once sohbete video ekle.' }
        Emit 'status' 'Kaynak videonun son karesi aliniyor...'
        $framePath = Join-Path $comfyIn ('vframe-' + (Get-Date -Format 'yyyyMMddHHmmss') + '.png')
        $frame = Invoke-MediaTool @{ action = 'video_frame'; path = $source; which = 'last'; out = $framePath; max_side = 1280 }
        if (!$frame -or $frame.error) { throw "Videodan kare alinamadi: $($frame.error)" }
        $startImage = $framePath
    }

    $lite = [bool]$JobData.lite
    $quality = [string]$JobData.quality
    if ($lite -and $quality -eq 'yuksek') {
        Emit 'status' 'Lite profilinde yuksek kalite video kapalidir; 480p ile devam ediliyor.'
        $quality = ''
    }
    $size = Get-Resolution ([string]$JobData.aspect) $quality
    $width = $size[0]; $height = $size[1]
    $refName = $null
    if ($startImage) {
        $written = Write-SourceImage $startImage
        $refName = $written[0]
        $width = $written[1]; $height = $written[2]
    }
    if ($lite) {
        $capped = Limit-LiteResolution $width $height
        $width = $capped[0]; $height = $capped[1]
    }

    $seed = if ($JobData.seed) { [long]$JobData.seed } else { [long](Get-Random -Minimum 1 -Maximum 2147483646) }
    $steps = if ($JobData.steps) { [int]$JobData.steps } else { 20 }
    $fps = if ($JobData.fps) { [int]$JobData.fps } else { 24 }
    $seconds = if ($JobData.seconds) { [double]$JobData.seconds } else { 2.0 }
    if ($seconds -lt 1) { $seconds = 1 }
    # 8 GB VRAM'de 3 saniyenin uzeri VAE cozumunde tasiyor.
    $maxSeconds = if ($lite) { 3 } else { 5 }
    if ($seconds -gt $maxSeconds) { $seconds = $maxSeconds }
    # Comfy-Org deposunda ti2v_5B'nin fp8 surumu yoktur; Lite de ayni fp16 dosyasini
    # kullanir ve VRAM'e --lowvram ile katman katman sigar. Kijai'nin fp8 agirligi
    # kendi wrapper node'lari icindir; istenirse Gorsel ve video API penceresinden secilir.
    $videoModel = if ($JobData.localModel) { [string]$JobData.localModel } else { 'wan2.2_ti2v_5B_fp16.safetensors' }
    # Lite'ta karo kuculur: tepe VRAM duser, karsiliginda parca sinirlarinda hafif
    # leke gorulebilir. 16 GB profilde genis ortusme oldugu gibi korunur.
    $tile = if ($lite) { @{ size = 256; overlap = 64; temporal = 12; temporalOverlap = 4 } }
            else { @{ size = 320; overlap = 80; temporal = 16; temporalOverlap = 8 } }
    # length 4n+1 olmali
    $length = [int]([math]::Round(($seconds * $fps - 1) / 4.0) * 4 + 1)
    if ($length -lt 5) { $length = 5 }
    $negative = [string]$JobData.negative
    if (!$negative) { $negative = $negativeDefault }

    Stop-LocalModelForMedia $manage

    Emit 'status' 'Wan 2.2 5B yukleniyor...'
    $comfy = Start-OrReuseComfy $python $comfyDir $comfyOut $comfyIn $logs $comfyUrl $lite 240 $Shared

    $workflow = @{
        '37' = @{ class_type = 'UNETLoader'; inputs = @{ unet_name = $videoModel; weight_dtype = 'default' } }
        '48' = @{ class_type = 'ModelSamplingSD3'; inputs = @{ model = @('37', 0); shift = 8 } }
        '38' = @{ class_type = 'CLIPLoader'; inputs = @{ clip_name = 'umt5_xxl_fp8_e4m3fn_scaled.safetensors'; type = 'wan'; device = 'default' } }
        '39' = @{ class_type = 'VAELoader'; inputs = @{ vae_name = 'wan2.2_vae.safetensors' } }
        '6'  = @{ class_type = 'CLIPTextEncode'; inputs = @{ clip = @('38', 0); text = [string]$JobData.prompt } }
        '7'  = @{ class_type = 'CLIPTextEncode'; inputs = @{ clip = @('38', 0); text = $negative } }
        '55' = @{ class_type = 'Wan22ImageToVideoLatent'; inputs = @{ vae = @('39', 0); width = $width; height = $height; length = $length; batch_size = 1 } }
        '3'  = @{ class_type = 'KSampler'; inputs = @{
                model = @('48', 0); positive = @('6', 0); negative = @('7', 0); latent_image = @('55', 0)
                seed = $seed; steps = $steps; cfg = 5; sampler_name = 'uni_pc'; scheduler = 'simple'; denoise = 1 } }
        # Video VAE'si tum kareleri birden cozerken 16 GB VRAM'i tasiriyor; parcali cozum sart.
        '8'  = @{ class_type = 'VAEDecodeTiled'; inputs = @{
                samples = @('3', 0); vae = @('39', 0)
                tile_size = $tile.size; overlap = $tile.overlap
                temporal_size = $tile.temporal; temporal_overlap = $tile.temporalOverlap } }
        '57' = @{ class_type = 'CreateVideo'; inputs = @{ images = @('8', 0); fps = $fps } }
        '58' = @{ class_type = 'SaveVideo'; inputs = @{ video = @('57', 0); filename_prefix = 'mamidlabs-local'; format = 'mp4'; codec = 'h264' } }
    }
    if ($refName) {
        $workflow['56'] = @{ class_type = 'LoadImage'; inputs = @{ image = $refName } }
        $workflow['55'].inputs.start_image = @('56', 0)
    }

    $modeLabel = switch ($mode) {
        'gorsel' { 'gorselden video' }
        'video'  { 'videodan devam' }
        default  { 'metinden video' }
    }
    $sn = [math]::Round($length / [double]$fps, 1)
    Emit 'status' "Video uretiliyor - $modeLabel ($width x $height, $length kare / $sn sn, $steps adim). Bu islem dakikalar surebilir..."

    $body = @{ prompt = $workflow; client_id = [guid]::NewGuid().ToString() } | ConvertTo-Json -Depth 20 -Compress
    $queued = Invoke-RestMethod "$comfyUrl/prompt" -Method Post -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 60
    $promptId = [string]$queued.prompt_id
    if (!$promptId) { throw 'ComfyUI istegi kuyruga alinamadi.' }

    $produced = $null
    $lastNote = [DateTime]::UtcNow
    $deadline = [DateTime]::UtcNow.AddMinutes(45)
    while ([DateTime]::UtcNow -lt $deadline) {
        if($Shared.Cancel){throw 'İşlem durduruldu.'}
        if ($comfy.HasExited) { throw 'ComfyUI uretim sirasinda kapandi (muhtemelen VRAM yetersiz).' }
        Start-Sleep -Milliseconds 1000
        if (([DateTime]::UtcNow - $lastNote).TotalSeconds -ge 30) {
            $lastNote = [DateTime]::UtcNow
            try {
                $progress = Invoke-RestMethod "$comfyUrl/prompt" -TimeoutSec 5
                Emit 'status' "Video uretiliyor... (kuyrukta $($progress.exec_info.queue_remaining) is)"
            } catch { }
        }
        $history = $null
        try { $history = Invoke-RestMethod "$comfyUrl/history/$promptId" -TimeoutSec 10 -ErrorAction Stop } catch { continue }
        $entry = $history.$promptId
        if (!$entry) { continue }
        if ($entry.status -and $entry.status.status_str -eq 'error') { throw 'ComfyUI uretim hatasi; logs\comfyui.stderr.log dosyasina bak.' }
        $saveNode = $entry.outputs.'58'
        if ($saveNode) {
            foreach ($item in @($saveNode.images) + @($saveNode.videos) + @($saveNode.gifs)) {
                if ($item -and $item.filename) { $produced = $item; break }
            }
        }
        if ($produced) { break }
    }
    if (!$produced) { throw 'Video uretimi zaman asimina ugradi.' }

    $sourcePath = Resolve-ComfyOutput ([string]$produced.filename) ([string]$produced.subfolder) $comfyOut @('.mp4', '.webm', '.mkv', '.mov', '.gif')
    $ext = [IO.Path]::GetExtension($produced.filename)
    if (!$ext) { $ext = '.mp4' }
    $finalPath = Join-Path $videoOut ('mamidlabs-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + $ext)
    Copy-Item -LiteralPath $sourcePath -Destination $finalPath -Force
    Remove-Item -LiteralPath $sourcePath -Force -ErrorAction SilentlyContinue

    Emit 'status' 'Video modeli bellekten bosaltiliyor...'
    Release-Comfy $comfy $comfyUrl
    $comfy = $null
    $Shared.Process=$null

    # Sohbette gosterilecek kucuk resim
    $thumb = Join-Path $videoOut ([IO.Path]::GetFileNameWithoutExtension($finalPath) + '.png')
    try { Invoke-MediaTool @{ action = 'video_frame'; path = $finalPath; which = 'first'; out = $thumb; max_side = 720 } | Out-Null } catch { $thumb = $null }

    Emit 'video' $finalPath @{
        prompt = [string]$JobData.prompt; seed = $seed; width = $width; height = $height
        frames = $length; fps = $fps; seconds = $sn; steps = $steps; mode = $mode
        thumbnail = $(if ($thumb -and (Test-Path -LiteralPath $thumb)) { $thumb } else { '' })
    }

    Restore-LocalModelForMedia $manage ([string]$JobData.restoreProfile) $false | Out-Null
    Emit 'status' 'Video hazır.'
} catch {
    # Acilis sirasinda hata olursa $comfy atanmamistir; yari acik surec $Shared'dadir.
    Stop-Comfy $(if ($comfy) { $comfy } else { $Shared.Process })
    # Restore denemesinin KENDISI basarisiz olursa (ikinci parametre $true),
    # hata yutulup asagida orijinal hatayla birlikte gosterilir (#16) -
    # kullaniciya yalnizca video hatasi gosterip dil modelinin de hazir
    # olmadigini gizlemek yanlis olur.
    $restoreFailure = Restore-LocalModelForMedia $manage ([string]$JobData.restoreProfile) $true
    $originalMessage = if ($Shared.Cancel) { 'İşlem durduruldu.' } else { $_.Exception.Message }
    if ($restoreFailure) {
        # Geri yukleme de basarisizsa kullaniciyi bundan haberdar etmeden yalnizca
        # orijinal hatayi gostermek, dil modelinin hazir sanilmasina yol acar.
        Emit 'error' "$originalMessage Ayrica dil modeli geri yuklenemedi: $restoreFailure Modeli elle yeniden baslat."
    } elseif ($Shared.Cancel) { Emit 'cancelled' 'İşlem durduruldu.' } else { Emit 'error' $originalMessage }
} finally {
    $Shared.Process=$null
}
