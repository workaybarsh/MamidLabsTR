# Profil kataloğu: hangi profilin hangi dosyalara ihtiyacı olduğu, dosyaların
# kurulu olup olmadığı ve eksiklerin Hugging Face üzerinden indirilmesi.
# Katalog verisi agent/profiles.json dosyasındadır; repo alanı boş olan satırlar
# elle kurulur, dolu olanlar uygulamadan indirilebilir.

function Get-ProfileCatalog {
    if ($script:profileCatalog) { return $script:profileCatalog }
    $path = Join-Path $root 'agent/profiles.json'
    if (!(Test-Path -LiteralPath $path -PathType Leaf)) { $script:profileCatalog = @(); return $script:profileCatalog }
    try {
        $script:profileCatalog = @((Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json).profiles)
    } catch {
        $script:profileCatalog = @()
    }
    return $script:profileCatalog
}

# MAX ve FLASH tamamen ayni dosyalari indirir (ayni "target" yollari); kullaniciya gorunen
# katalogda (Profiller menusu + Profil yoneticisi penceresi) FLASH tek temsilci olarak
# kalir (agent/profiles.json'da etiketi "Qwen3.8 27B"). Calisma zamaninda MAX/FLASH gecisi
# alt bardan yapilir (model-registry.ps1'in builtin-max/builtin-flash tanimlari). Bu filtre
# YALNIZCA GORUNUM icindir: belirli bir id ile yapilan aramalar (Get-ProfileEntry,
# Get-ProfileState, Test-LocalProfileChatFilesPresent) tam katalogu gormelidir, cunku alt
# bar 'max' icin de bunlari cagirir.
function Get-ProfileCatalogForDisplay {
    return @(Get-ProfileCatalog | Where-Object { $_.id -ne 'max' })
}

function Get-ProfileEntry([string]$id) {
    return @(Get-ProfileCatalog | Where-Object { $_.id -eq $id })[0]
}

function Format-ByteSize([long]$bytes) {
    if ($bytes -le 0) { return '—' }
    if ($bytes -ge 1073741824) { return ('{0:N1} GB' -f ($bytes / 1073741824)) }
    return ('{0:N0} MB' -f ($bytes / 1048576))
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

# Bir profilin dosyalarını diskte arar; eksikleri indirilebilir ve elle kurulacak
# diye ayırır. Boyut karşılaştırması yapılmaz: yarım kalmış bir indirme varsa
# Hugging Face istemcisi kaldığı yerden devam eder.
function Get-ProfileState([string]$id) {
    $entry = Get-ProfileEntry $id
    $state = @{ present = @(); missingDownloadable = @(); missingManual = @() }
    if (!$entry) { return $state }
    foreach ($file in @($entry.files)) {
        $full = Join-Path $root ([string]$file.target)
        if (Test-Path -LiteralPath $full -PathType Leaf) {
            # Var olan ama MTP basligi eksik bir model yeniden islenmeli (yeniden indirmeden eklenir).
            if ($file.mtp -and !(Test-GgufHasNextn $full)) { $state.missingDownloadable += $file }
            else { $state.present += $file }
        }
        elseif ([string]$file.repo) { $state.missingDownloadable += $file }
        else { $state.missingManual += $file }
    }
    return $state
}

# Bir profile ait HEDEFLERDEN baska profillerle paylasilanlari cikarir; profil silme
# yalnizca bu benzersiz dosyalari kaldirir ki diger profilin kurulumu bozulmasin.
# Ornek: MAX ve FLASH birebir ayni dosya kumesini kullanir (takma ad sayilir, paylasim
# degil); LITE ise medya dosyalarinin bir kismini MAX/FLASH ile paylasir.
function Get-ProfileUniqueTargets([string]$id) {
    $catalog = @(Get-ProfileCatalog)
    $entry = @($catalog | Where-Object { $_.id -eq $id })[0]
    if (!$entry) { return @() }
    $myTargets = @($entry.files | ForEach-Object { [string]$_.target })
    $mySignature = ($myTargets | Sort-Object -Unique) -join '|'
    $shared = @{}
    foreach ($profile in $catalog) {
        if ($profile.id -eq $id) { continue }
        $otherTargets = @($profile.files | ForEach-Object { [string]$_.target })
        # Ayni dosya kumesi = ayni profilin takma adi (MAX/FLASH); paylasim sayilmaz.
        if ((($otherTargets | Sort-Object -Unique) -join '|') -eq $mySignature) { continue }
        foreach ($target in $otherTargets) { $shared[$target] = $true }
    }
    $unique = [Collections.Generic.List[string]]::new()
    $seen = @{}
    foreach ($target in $myTargets) {
        if ($seen.ContainsKey($target)) { continue }
        $seen[$target] = $true
        if (!$shared.ContainsKey($target)) { [void]$unique.Add($target) }
    }
    return $unique.ToArray()
}

# Profili sil: yalnizca benzersiz dosyalari kaldirir, bosalan klasorleri temizler ve
# silinen dosya sayisini/hatayi dondurur. Cagiran (Profil yoneticisi) onay alir.
function Remove-ProfileFiles([string]$id) {
    $result = @{ removed = 0; failed = 0; totalBytes = 0L }
    foreach ($target in (Get-ProfileUniqueTargets $id)) {
        $full = Join-Path $root $target
        if (!(Test-Path -LiteralPath $full -PathType Leaf)) { continue }
        try { $result.totalBytes += [long](Get-Item -LiteralPath $full).Length } catch { }
        try { Remove-Item -LiteralPath $full -Force -ErrorAction Stop; $result.removed++ }
        catch { $result.failed++ }
    }
    # Geride bos kalan klasorleri kaldir (yalnizca bu profilin hedeflerinin klasorleri).
    foreach ($target in (Get-ProfileUniqueTargets $id)) {
        $dir = Split-Path -Parent (Join-Path $root $target)
        try {
            if ((Test-Path -LiteralPath $dir -PathType Container) -and
                !(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue)) {
                Remove-Item -LiteralPath $dir -Force -ErrorAction SilentlyContinue
            }
        } catch { }
    }
    return $result
}

# Bilesen siniflandirmasi: medya (gorsel/video) ComfyUI altinda, ses ise venv\asr ve
# whisper model dosyalari altindadir; geri kalan (dil modeli/mmproj) cekirdektir.
function Get-ProfileFileComponent([string]$target) {
    $t = ([string]$target) -replace '\\', '/'
    if ($t -like 'ComfyUI/*') { return 'media' }
    if ($t -like 'venv/asr/*' -or $t -like 'models/whisper*') { return 'audio' }
    return 'core'
}

# Secili bilesenlerin (media/audio) profildeki dosyalarini siler; yalnizca bu profile
# ozel (paylasilmayan) dosyalara dokunur. Silinen dosya sayisi ve toplam bayt doner.
function Remove-ProfileComponents([string]$id, [string[]]$components) {
    $result = @{ removed = 0; failed = 0; totalBytes = 0L }
    foreach ($target in (Get-ProfileUniqueTargets $id)) {
        if ($components -notcontains (Get-ProfileFileComponent $target)) { continue }
        $full = Join-Path $root $target
        if (!(Test-Path -LiteralPath $full -PathType Leaf)) { continue }
        try { $result.totalBytes += [long](Get-Item -LiteralPath $full).Length } catch { }
        try { Remove-Item -LiteralPath $full -Force -ErrorAction Stop; $result.removed++ }
        catch { $result.failed++ }
    }
    return $result
}

# Bir profilin SOHBET icin gerekli dosyalarinin (dil modeli + mmproj) diskte
# olup olmadigini kontrol eder. ComfyUI altindaki medya (gorsel/video) modelleri
# kasten disaridadir: -SkipMedia ile kurulmus olabilirler ve sohbetin calismasi
# icin gerekmezler. Alt bardaki model kutusunun yalnizca gercekten
# yuklenebilecek profilleri gostermesi icin kullanilir (bkz. model-registry.ps1
# Update-ProviderSelection).
function Test-LocalProfileChatFilesPresent([string]$id) {
    $entry = Get-ProfileEntry $id
    if (!$entry) { return $false }
    $chatFiles = @($entry.files | Where-Object { [string]$_.target -notmatch '^ComfyUI[\\/]' })
    if (!$chatFiles.Count) { return $false }
    foreach ($file in $chatFiles) {
        $full = Join-Path $root ([string]$file.target)
        if (!(Test-Path -LiteralPath $full -PathType Leaf)) { return $false }
    }
    return $true
}

# Guncelleme kontrolu, Inno Setup'in yazdigi kaldirma kaydindan ({AppId}_is1) yerel
# surumu okur. AppId packaging/windows/mamidlabs.iss ile ayni olmalidir; TR ve ENG
# surumleri ayri AppId ve ayri GitHub deposu tasir (bkz. AGENTS.md, tuzaklar).
$script:MamidLabsAppId = '{56CF14A8-57AF-4EEB-A520-937212F0B365}'
$script:MamidLabsRepo = 'workaybarsh/MamidLabsTR'
# Bu sürümün arayüz dili ve "dil profili" (diğer dil sürümü) deposu. Profiller penceresindeki
# dil seçimi, diğer dil sürümünün kurulum paketini indirip kurar (kurulum aynı klasöre yapılır).
$script:MamidLabsEditionLang = 'tr'
$script:OtherEditionRepo = 'workaybarsh/MamidLabsENG'

# Ozel (private) depo icin guncelleme denetimi ve indirmesi bir GitHub tokeni gerektirir;
# aksi halde GitHub 404 doner. Token su sirayla aranir: GITHUB_TOKEN / GH_TOKEN ortam
# degiskeni, sonra kayitli 'github' saglayici anahtari (Windows DPAPI, API ayarlariyla ayni).
function Get-UpdateToken {
    foreach ($envName in @('GITHUB_TOKEN', 'GH_TOKEN')) {
        $value = [Environment]::GetEnvironmentVariable($envName)
        if ($value) { return $value }
    }
    $profile = $null
    if ($script:apiSettings -and $script:apiSettings.providers) {
        $profile = $script:apiSettings.providers['github']
    }
    if ($profile -and $profile.key) {
        try {
            $secure = ConvertTo-SecureString ([string]$profile.key)
            return [Net.NetworkCredential]::new('', $secure).Password
        } catch { }
    }
    return ''
}

function Get-GitHubHeaders([string]$token) {
    $headers = @{ 'User-Agent' = 'MamidLabs-Updater'; 'Accept' = 'application/vnd.github+json' }
    if ($token) { $headers['Authorization'] = "Bearer $token" }
    return $headers
}

function Get-InstalledMamidLabsVersion {
    foreach ($hive in @('HKCU:', 'HKLM:')) {
        $key = "$hive\Software\Microsoft\Windows\CurrentVersion\Uninstall\$($script:MamidLabsAppId)_is1"
        if (Test-Path -LiteralPath $key) {
            try {
                $v = (Get-ItemProperty -LiteralPath $key -Name DisplayVersion -ErrorAction Stop).DisplayVersion
                if ($v) { return $v }
            } catch { }
        }
    }
    # Sihirbazsiz (betik tabanli) kurulumda Inno'nun {AppId}_is1 kaydi yoktur; betik kendi
    # MamidLabs-<hash8> kaydina DisplayVersion yazar (scripts/install-mamidlabs.ps1
    # Invoke-Layout). Inno kaydi bulunamazsa bu yedege dusulur.
    return (Get-ScriptUninstallVersion -InstallRoot $root)
}

# Inno disinda (betik tabanli) kurulumun yazdigi MamidLabs-<hash8> kaldirma kaydindan
# surumu okur. Girdi bu kuruluma ait mi diye InstallLocation/DisplayName ile eslesir;
# boylece baska bir koke kurulu kopyanin surumu yanlislikla okunmaz.
function Get-ScriptUninstallVersion {
    param(
        [string]$InstallRoot,
        [string[]]$RegistryPaths = @(
            'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
            'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall'
        )
    )
    $expected = $null
    if ($InstallRoot) { $expected = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\') }
    foreach ($base in $RegistryPaths) {
        if (!(Test-Path -LiteralPath $base)) { continue }
        foreach ($item in @(Get-ChildItem -LiteralPath $base -ErrorAction SilentlyContinue)) {
            if ($item.PSChildName -notlike 'MamidLabs-*') { continue }
            $props = Get-ItemProperty -LiteralPath $item.PSPath -ErrorAction SilentlyContinue
            if (!$props -or [string]$props.DisplayName -notlike 'MamidLabs*') { continue }
            if ($expected) {
                $location = ([string]$props.InstallLocation).TrimEnd('\')
                $isThis = ($location -ieq $expected) -or
                          (([string]$props.DisplayName).IndexOf($expected, [StringComparison]::OrdinalIgnoreCase) -ge 0)
                if (!$isThis) { continue }
            }
            $v = [string]$props.DisplayVersion
            if ($v) { return $v }
        }
    }
    return $null
}

# GitHub'daki en son sürümü yerel sürümle (Inno'nun kendi kaldırma kaydı) karşılaştırır.
# Sonuç: @{ available; version; downloadUrl; size; localVersion; error }. Ağ hatasında
# 'error' dolu döner, istisna fırlatmaz — Profiller penceresindeki buton kullanıcıya
# ham hata metni yerine kısa bir durum göstersin diye.
function Test-MamidLabsUpdateAvailable {
    $local = Get-InstalledMamidLabsVersion
    $token = Get-UpdateToken
    try {
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$($script:MamidLabsRepo)/releases/latest" `
            -Headers (Get-GitHubHeaders $token) -TimeoutSec 20 -ErrorAction Stop
    } catch {
        $reason = if (!$token) { 'özel depo için güncelleme tokenı gerekli' } else { 'internet yok?' }
        return @{ available = $false; error = "Denetlenemedi ($reason)"; localVersion = $local }
    }
    $remoteTag = [string]$release.tag_name
    $remoteVersion = $remoteTag.TrimStart('v', 'V')
    $asset = @($release.assets | Where-Object { $_.name -like '*Setup*.exe' }) | Select-Object -First 1
    if (!$asset) { return @{ available = $false; error = 'Kurulum dosyası bulunamadı'; localVersion = $local } }
    $isNewer = $true
    if ($local) {
        try { $isNewer = ([version]$remoteVersion) -gt ([version]$local) }
        catch { $isNewer = ($remoteVersion -ne $local) }
    }
    return @{ available = $isNewer; version = $remoteVersion; downloadUrl = [string]$asset.browser_download_url
              apiUrl = [string]$asset.url; size = [long]$asset.size; localVersion = $local }
}

# Diğer dil sürümünün en son kurulum paketini bulur (dil profili indirme). Sonuç:
# @{ version; downloadUrl; apiUrl; size } ya da @{ error }. Ağ hatasında istisna fırlatmaz.
function Get-EditionRelease([string]$repo) {
    $token = Get-UpdateToken
    try {
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/latest" `
            -Headers (Get-GitHubHeaders $token) -TimeoutSec 20 -ErrorAction Stop
    } catch {
        $reason = if (!$token) { 'özel depo için güncelleme tokenı gerekli' } else { 'internet yok?' }
        return @{ error = "Denetlenemedi ($reason)" }
    }
    $asset = @($release.assets | Where-Object { $_.name -like '*Setup*.exe' }) | Select-Object -First 1
    if (!$asset) { return @{ error = 'Kurulum dosyası bulunamadı' } }
    return @{ version = ([string]$release.tag_name).TrimStart('v', 'V')
              downloadUrl = [string]$asset.browser_download_url
              apiUrl = [string]$asset.url; size = [long]$asset.size }
}

# Indirilen dil profili (diger dil surumu) paketinin kalici yolu ve kaydi. "Sil" icin izlenir;
# boylece kullanici daha sonra kaldirabilir. Indirilen paket burada tutulur (gecici %TEMP% degil).
function Get-EditionDownloadDir { return (Join-Path $root 'tools\editions') }
function Get-EditionRecordPath { return (Join-Path (Get-EditionDownloadDir) 'edition.json') }

function Get-EditionRecord {
    $path = Get-EditionRecordPath
    if (!(Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try { return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

# Profiller penceresindeki kapanışlar (GetNewClosure) `$script:` değişkenlerini GÖREMEZ
# ($script: kapanışın kendi modül kapsamına bakar, boş döner). "Meşgul" bayrakları anlık
# olduğundan yerel değişkene kopyalanamaz (bayat kalır); bu yüzden canlı değer bu fonksiyon
# üzerinden okunur (fonksiyon içinde $script: gerçek script kapsamına bakar).
function Test-ProfileManagerBusy { return [bool]($script:busy -or $script:imageBusy) }

function Get-ProfileStatusLabel([string]$id) {
    $state = Get-ProfileState $id
    $downloadable = @($state.missingDownloadable).Count
    $manual = @($state.missingManual).Count
    if ($downloadable + $manual -eq 0) { return 'kurulu' }
    if ($manual -eq 0) { return "$downloadable dosya indirilmeli" }
    return "$($downloadable + $manual) dosya eksik"
}

# Seçimi alt sağdaki model kutusuna yansıtır; kutunun kendi olayı modeli yükler.
function Switch-ToProfile([string]$id) {
    if ($script:busy -or $script:imageBusy -or $script:pendingSend) { $metric.Text = 'Önce mevcut işlemin bitmesini bekle.'; return $false }
    $index = -1
    for ($i = 0; $i -lt $script:modelEntries.Count; $i++) {
        if ($script:modelEntries[$i].id -eq "builtin-$id") { $index = $i; break }
    }
    if ($index -lt 0) {
        # Dosyalari eksik oldugu icin alt barda hic gorunmuyor olabilir (bkz.
        # Update-ProviderSelection); kullanici burada "Bu profile geç" ile eksik
        # dosya uyarisini gorup yine de gecmeyi secti, o yuzden gecici olarak
        # listeye eklenip seciliyor.
        $def = @(Get-BuiltinProfileDefinitions | Where-Object { $_.profile -eq $id })[0]
        if (!$def) { $metric.Text = 'Profil model listesinde bulunamadı.'; return $false }
        $script:modelEntries += @{ id = $def.id; provider = 'local'; label = $def.label; profile = $def.profile; contextLimit = 32768 }
        [void]$modelChoice.Items.Add($def.label)
        $index = $script:modelEntries.Count - 1
    }
    if ($modelChoice.SelectedIndex -eq $index) { $metric.Text = "$($script:modelEntries[$index].label) zaten seçili."; return $true }
    $modelChoice.SelectedIndex = $index
    return $true
}

function Start-ProfileDownload([string]$id, [string[]]$components = @('core', 'media', 'audio')) {
    if ($script:busy -or $script:imageBusy) { return 'Önce mevcut işlemin bitmesini bekle.' }
    $state = Get-ProfileState $id
    $missing = @($state.missingDownloadable | Where-Object { $components -contains (Get-ProfileFileComponent ([string]$_.target)) })
    if (!$missing.Count) { return 'Seçili bileşenler için indirilecek dosya yok.' }
    $files = @()
    foreach ($file in $missing) {
        $files += @{
            repo = [string]$file.repo
            filename = [string]$file.filename
            revision = [string]$file.revision
            target = (Join-Path $root ([string]$file.target))
            label = [string]$file.label
            bytes = [long]$file.bytes
            mtp = $file.mtp
        }
    }
    $total = ($missing | Measure-Object -Property bytes -Sum).Sum
    $data = @{ kind = 'huggingface'; action = 'download'; files = $files; apiKey = (Get-ProviderKey 'huggingface'); root = $root }
    $script:activeBubble = New-Bubble 'assistant'
    $script:activeBubble.body.Text = "Profil dosyaları indiriliyor: $($files.Count) dosya, yaklaşık $(Format-ByteSize $total)."
    $script:sharedMedia = [hashtable]::Synchronized(@{ Cancel = $false; Process = $null })
    $script:imageJob = Start-ThreadJob -FilePath (Join-Path $root 'agent/api-media-run.ps1') -ArgumentList $data, $script:sharedMedia
    $script:imageBusy = $true
    $send.Enabled = $true
    $send.Text = 'Durdur'
    Relayout-Chat
    return $null
}

function Show-ProfileManager([string]$focusId) {
    $catalog = @(Get-ProfileCatalogForDisplay)
    if (!$catalog.Count) { $metric.Text = 'Profil kataloğu okunamadı: agent/profiles.json'; return }

    $dlg = [Windows.Forms.Form]::new()
    $dlg.Text = 'MamidLabs · Profiller'
    $dlg.Size = [Drawing.Size]::new(790, 660)
    $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.BackColor = $colPanel
    $dlg.ForeColor = $colText

    $list = [Windows.Forms.ListBox]::new()
    $list.SetBounds(16, 16, 230, 300)
    $list.BackColor = [Drawing.Color]::FromArgb(35, 39, 49)
    $list.ForeColor = $colText
    $list.BorderStyle = 'FixedSingle'

    $detail = [Windows.Forms.TextBox]::new()
    $detail.SetBounds(262, 16, 500, 300)
    $detail.Multiline = $true
    $detail.ReadOnly = $true
    $detail.ScrollBars = 'Vertical'
    $detail.WordWrap = $false
    $detail.BackColor = [Drawing.Color]::FromArgb(35, 39, 49)
    $detail.ForeColor = $colText
    $detail.BorderStyle = 'FixedSingle'

    $status = [Windows.Forms.Label]::new()
    $status.SetBounds(16, 326, 746, 40)

    $downloadBtn = [Windows.Forms.Button]::new()
    $downloadBtn.Text = 'Eksikleri indir'
    $downloadBtn.SetBounds(16, 376, 180, 34)
    $switchBtn = [Windows.Forms.Button]::new()
    $switchBtn.Text = 'Bu profile geç'
    $switchBtn.SetBounds(202, 376, 150, 34)
    $deleteBtn = [Windows.Forms.Button]::new()
    $deleteBtn.Text = 'Profili sil'
    $deleteBtn.SetBounds(358, 376, 120, 34)
    $updateBtn = [Windows.Forms.Button]::new()
    $updateBtn.Text = 'Güncellemeleri denetle'
    $updateBtn.SetBounds(484, 376, 180, 34)
    $updateBtn.Tag = @{ state = 'idle' }
    $closeBtn = [Windows.Forms.Button]::new()
    $closeBtn.Text = 'Kapat'
    $closeBtn.SetBounds(670, 376, 104, 34)

    # Ozel (private) depo icin guncelleme denetimi/indirmesi token ister (bkz. Get-UpdateToken).
    $tokenLabel = [Windows.Forms.Label]::new()
    $tokenLabel.Text = 'Güncelleme tokenı (özel depo için GitHub tokenı):'
    $tokenLabel.SetBounds(16, 418, 420, 20)
    $tokenBox = [Windows.Forms.TextBox]::new()
    $tokenBox.SetBounds(16, 440, 430, 26)
    $tokenBox.UseSystemPasswordChar = $true
    $tokenSave = [Windows.Forms.Button]::new()
    $tokenSave.Text = 'Tokenı kaydet'
    $tokenSave.SetBounds(456, 439, 130, 28)
    $tokenClear = [Windows.Forms.Button]::new()
    $tokenClear.Text = 'Sil'
    $tokenClear.SetBounds(592, 439, 60, 28)
    # Bilesen secimi: indirilecek/silinecek istege bagli bilesenler (dil modeli cekirdektir).
    $mediaChk = [Windows.Forms.CheckBox]::new()
    $mediaChk.Text = 'Görsel/video üretimi'
    $mediaChk.SetBounds(16, 478, 200, 24)
    $mediaChk.Checked = $true
    $mediaChk.ForeColor = $colText
    $audioChk = [Windows.Forms.CheckBox]::new()
    $audioChk.Text = 'Ses yakalama'
    $audioChk.SetBounds(224, 478, 200, 24)
    $audioChk.Checked = $true
    $audioChk.ForeColor = $colText
    $delCompBtn = [Windows.Forms.Button]::new()
    $delCompBtn.Text = 'Seçili bileşenleri sil'
    $delCompBtn.SetBounds(16, 508, 200, 34)
    # Dil profili değerleri GetNewClosure() içinde $script: ile GÖRÜNMEZ (kapanış kendi modül
    # kapsamına bakar, $script: boş döner); bu yüzden yerel değişkene alınır. Aksi halde
    # "zaten kurulu" denetimi ve diğer sürüm deposu boş kalır (bkz. $mainForm = $form, tuzak 21).
    $editionLang = $script:MamidLabsEditionLang
    $otherEditionRepo = $script:OtherEditionRepo
    # Dil profili: bu sürümün dili varsayılan seçilidir; kullanıcı diğer dil sürümünü
    # (İngilizce/Türkçe) buradan indirip kurabilir. Aynı klasöre kurulur.
    $langLabel = [Windows.Forms.Label]::new()
    $langLabel.Text = 'Arayüz dili / dil profili:'
    $langLabel.SetBounds(16, 552, 210, 20)
    $langLabel.ForeColor = $colText
    $langCombo = [Windows.Forms.ComboBox]::new()
    $langCombo.DropDownStyle = 'DropDownList'
    [void]$langCombo.Items.Add('Türkçe')
    [void]$langCombo.Items.Add('English')
    $langCombo.SetBounds(232, 550, 140, 26)
    $langCombo.SelectedIndex = if ($editionLang -eq 'en') { 1 } else { 0 }
    $langBtn = [Windows.Forms.Button]::new()
    $langBtn.Text = 'Seçili dil sürümünü indir'
    $langBtn.SetBounds(380, 549, 200, 28)
    $langDeleteBtn = [Windows.Forms.Button]::new()
    $langDeleteBtn.Text = 'Dil sürümünü sil'
    $langDeleteBtn.SetBounds(586, 549, 176, 28)
    if ($script:apiSettings.providers -and $script:apiSettings.providers['github']) {
        $tokenLabel.Text = 'Güncelleme tokenı kayıtlı (boş bırakırsan korunur; değiştirmek için yaz):'
    }

    foreach ($profile in $catalog) { [void]$list.Items.Add("$($profile.label) — $(Get-ProfileStatusLabel $profile.id)") }

    $refresh = {
        $index = $list.SelectedIndex
        if ($index -lt 0) { return }
        $profile = $catalog[$index]
        $state = Get-ProfileState $profile.id
        $lines = [Collections.Generic.List[string]]::new()
        $lines.Add([string]$profile.label)
        $lines.Add('Donanım: ' + [string]$profile.hardware)
        $lines.Add('')
        $lines.Add([string]$profile.summary)
        $lines.Add('')
        foreach ($file in @($profile.files)) {
            $full = Join-Path $root ([string]$file.target)
            $mark = if (Test-Path -LiteralPath $full -PathType Leaf) { '[kurulu]' }
                    elseif ([string]$file.repo) { '[indirilecek]' }
                    else { '[elle kurulmalı]' }
            $lines.Add(('{0,-17}{1} ({2})' -f $mark, [string]$file.label, (Format-ByteSize ([long]$file.bytes))))
            $lines.Add('                 ' + [string]$file.target)
            if (!([string]$file.repo) -and [string]$file.source -and !(Test-Path -LiteralPath $full -PathType Leaf)) {
                $lines.Add('                 kaynak: ' + [string]$file.source)
            }
        }
        if (@($state.missingManual).Count) {
            $lines.Add('')
            $lines.Add('[elle kurulmalı] satırları için agent/profiles.json içinde depo adı yoktur;')
            $lines.Add('mevcut kurulumdan kopyalanmaları, kaynak adresinden indirilip gösterilen')
            $lines.Add('konuma konması veya katalogda kaynak tanımlanması gerekir.')
        }
        $detail.Lines = $lines.ToArray()
        $downloadable = @($state.missingDownloadable)
        if ($downloadable.Count) {
            $downloadBtn.Enabled = $true
            $downloadBtn.Text = "Eksikleri indir ($(Format-ByteSize (($downloadable | Measure-Object -Property bytes -Sum).Sum)))"
        } else {
            $downloadBtn.Enabled = $false
            $downloadBtn.Text = 'Eksik indirme yok'
        }
    }
    $list.Add_SelectedIndexChanged($refresh)

    $downloadBtn.Add_Click({
        $index = $list.SelectedIndex
        if ($index -lt 0) { return }
        $components = @('core')
        if ($mediaChk.Checked) { $components += 'media' }
        if ($audioChk.Checked) { $components += 'audio' }
        $failure = Start-ProfileDownload $catalog[$index].id $components
        if ($failure) { $status.Text = $failure; return }
        $dlg.Close()
    }.GetNewClosure())

    # Secili bilesenleri (gorsel/video, ses) bu profilden sil: yalnizca bu profile ozel
    # dosyalar kaldirilir; cekirdek (dil modeli) ve paylasilan dosyalar korunur.
    $delCompBtn.Add_Click({
        $index = $list.SelectedIndex
        if ($index -lt 0) { return }
        if (Test-ProfileManagerBusy) { $status.Text = 'Önce mevcut işlemin bitmesini bekle.'; return }
        $components = @()
        if ($mediaChk.Checked) { $components += 'media' }
        if ($audioChk.Checked) { $components += 'audio' }
        if (!$components.Count) { $status.Text = 'Silinecek bileşen seçilmedi (Görsel/video veya Ses).'; return }
        $profile = $catalog[$index]
        $answer = [Windows.Forms.MessageBox]::Show(
            ($profile.label + ' için seçili bileşenler silinecek (yalnızca bu profile özel dosyalar).' + "`r`n`r`nSilinsin mi?"),
            'Bileşenleri sil', 'YesNo', 'Warning')
        if ($answer -ne 'Yes') { return }
        $result = Remove-ProfileComponents $profile.id $components
        $list.Items[$index] = "$($profile.label) — $(Get-ProfileStatusLabel $profile.id)"
        & $refresh
        $status.Text = if ($result.removed) { "Seçili bileşenler silindi ($($result.removed) dosya, $(Format-ByteSize $result.totalBytes))." }
            else { 'Silinecek (bu profile özel) dosya bulunamadı.' }
        try { Update-ProviderSelection } catch { }
    }.GetNewClosure())

    $switchBtn.Add_Click({
        $index = $list.SelectedIndex
        if ($index -lt 0) { return }
        $profile = $catalog[$index]
        $state = Get-ProfileState $profile.id
        # Dil modeli dosyası yoksa llama-server açılışta hata verir; önce uyar.
        if (@($state.missingDownloadable).Count -or @($state.missingManual).Count) {
            $answer = [Windows.Forms.MessageBox]::Show(
                'Bu profilin bazı dosyaları eksik. Yine de geçilsin mi?',
                'Eksik dosya', 'YesNo', 'Warning')
            if ($answer -ne 'Yes') { return }
        }
        if (Switch-ToProfile $profile.id) { $dlg.Close() }
    }.GetNewClosure())

    $closeBtn.Add_Click({ $dlg.Close() }.GetNewClosure())

    # Profil silme: yalnizca bu profile OZEL dosyalar kaldirilir; baska profillerle
    # paylasilanlar (or. LITE'in MAX/FLASH ile ortak medya dosyalari) korunur. Aktif
    # profil siliniyorsa once model durdurulur.
    # $script:apiSettings bir KAPANIŞ içinde ($script: boş döner) görünmediğinden yerel
    # değişkene alınır; aynı nesne olduğu için token kaydetme/silme de gerçek ayarları değiştirir.
    $settings = $script:apiSettings
    $deleteBtn.Add_Click({
        $index = $list.SelectedIndex
        if ($index -lt 0) { return }
        if (Test-ProfileManagerBusy) { $status.Text = 'Önce mevcut işlemin bitmesini bekle.'; return }
        $profile = $catalog[$index]
        $present = @((Get-ProfileUniqueTargets $profile.id) | Where-Object {
            Test-Path -LiteralPath (Join-Path $root $_) -PathType Leaf })
        if (!$present.Count) {
            $status.Text = 'Silinecek dosya yok: profil kurulu değil ya da tüm dosyaları başka bir profille paylaşılıyor.'
            return
        }
        $bytes = 0L
        foreach ($rel in $present) { try { $bytes += [long](Get-Item -LiteralPath (Join-Path $root $rel)).Length } catch { } }
        $isActive = ([string]$settings.selectedModel -eq "builtin-$($profile.id)")
        $warn = if ($isActive) { "`r`n`r`nDIKKAT: Bu profil şu an seçili. Model çalışıyorsa önce durdurulur." } else { '' }
        $answer = [Windows.Forms.MessageBox]::Show(
            ($profile.label + ' profiline ait ' + $present.Count + ' dosya (' + (Format-ByteSize $bytes) + ') silinecek.' +
             "`r`nBaşka profillerle paylaşılan dosyalar korunur." + $warn + "`r`n`r`nSilinsin mi?"),
            'Profili sil', 'YesNo', 'Warning')
        if ($answer -ne 'Yes') { return }
        if ($isActive) { try { Stop-LocalMamidLabs } catch { } }
        $result = Remove-ProfileFiles $profile.id
        $list.Items[$index] = "$($profile.label) — $(Get-ProfileStatusLabel $profile.id)"
        & $refresh
        $status.Text = if ($result.failed) { "$($result.failed) dosya silinemedi (kullanımda olabilir)." }
            else { "Profil dosyaları silindi ($($result.removed) dosya, $(Format-ByteSize $result.totalBytes)); paylaşılan dosyalar korundu." }
        try { Update-ProviderSelection } catch { }
    }.GetNewClosure())

    # $settings yukarida yakalanan gerçek ayarlar nesnesidir; token kaydetme/silme kapanışları
    # (GetNewClosure) onu kullanır çünkü $script:apiSettings kapanış içinde boş döner.
    $tokenSave.Add_Click({
        if (!$settings.providers) { $settings.providers = @{} }
        $value = $tokenBox.Text.Trim()
        if ($value) {
            $settings.providers['github'] = @{ key = (ConvertFrom-SecureString (ConvertTo-SecureString $value -AsPlainText -Force)) }
            $status.Text = 'Güncelleme tokenı kaydedildi. "Güncellemeleri denetle" ile dene.'
        } else {
            $status.Text = 'Boş token kaydedilmedi.'
        }
        $tokenBox.Text = ''
        Save-ApiSettings
    }.GetNewClosure())
    $tokenClear.Add_Click({
        if ($settings.providers -and $settings.providers.ContainsKey('github')) {
            $settings.providers.Remove('github')
        }
        Save-ApiSettings
        $status.Text = 'Güncelleme tokenı silindi.'
    }.GetNewClosure())

    # Buton üç halli: boşta "Güncellemeleri denetle" → tıklanınca GitHub'ı sorar →
    # güncelleme varsa "Şimdi güncelle"ye döner (bir tıklama daha indirip kurulumu
    # başlatır), yoksa "Güncelsiniz" yazıp birkaç saniye sonra kendini sıfırlar
    # (Timer ile). Sonuç durum satırına da yazılır; pasif düğme metni koyu temada
    # zor okunur. Ağ çağrısı diğer pencerelerdeki (ör. api-settings.ps1 Doğrula)
    # senkron istekle aynı desende: kısa sürdüğü için ayrı iş parçacığına gerek yok.
    #
    # Kurulum sihirbazı başlatılınca uygulama kendini kapatır (ana pencerenin
    # FormClosing'i sohbeti kaydeder, llama-server ve ComfyUI'yi durdurur). Açık kalırsa
    # install-mamidlabs.ps1 'layout' aşamasında "MamidLabs acik" diye durur ve
    # güncelleme tamamlanamaz.
    $mainForm = $form
    $updateResetTimer = [Windows.Forms.Timer]::new()
    $updateResetTimer.Interval = 3000
    $updateResetTimer.Add_Tick({
        $updateResetTimer.Stop()
        $updateBtn.Tag = @{ state = 'idle' }
        $updateBtn.Text = 'Güncellemeleri denetle'
        $updateBtn.Enabled = $true
    }.GetNewClosure())
    $dlg.Add_FormClosed({ $updateResetTimer.Stop(); $updateResetTimer.Dispose() }.GetNewClosure())

    $updateBtn.Add_Click({
        $state = $updateBtn.Tag
        if ($state.state -eq 'available') {
            $updateBtn.Enabled = $false
            $updateBtn.Text = 'İndiriliyor…'
            $dlg.Refresh()
            try {
                $downloadPath = Join-Path $env:TEMP "MamidLabs_Setup_$($state.version).exe"
                $token = Get-UpdateToken
                $dlgUrl = if ($token -and $state.apiUrl) { $state.apiUrl } else { $state.downloadUrl }
                $dlgHeaders = if ($token -and $state.apiUrl) {
                    @{ 'User-Agent' = 'MamidLabs-Updater'; 'Accept' = 'application/octet-stream'; 'Authorization' = "Bearer $token" }
                } else { @{ 'User-Agent' = 'MamidLabs-Updater' } }
                Invoke-WebRequest -Uri $dlgUrl -Headers $dlgHeaders -OutFile $downloadPath -UseBasicParsing -ErrorAction Stop
                if ($state.size -and (Get-Item -LiteralPath $downloadPath).Length -ne $state.size) {
                    throw 'İndirilen dosya boyutu uyuşmuyor.'
                }
                Start-Process -FilePath $downloadPath
                $status.Text = "Kurulum sihirbazı açıldı; MamidLabs güncelleme için kapanıyor."
                $dlg.Close()
                if ($mainForm) { $mainForm.Close() }
            } catch {
                $updateBtn.Text = 'İndirilemedi'
                $status.Text = 'Güncelleme indirilemedi: ' + $_.Exception.Message
                $updateBtn.Tag = @{ state = 'idle' }
                $updateResetTimer.Start()
            }
            return
        }
        $updateResetTimer.Stop()
        $updateBtn.Enabled = $false
        $updateBtn.Text = 'Denetleniyor…'
        $dlg.Refresh()
        $result = Test-MamidLabsUpdateAvailable
        $localText = if ($result.localVersion) { $result.localVersion } else { 'bilinmiyor' }
        if ($result.available) {
            $updateBtn.Tag = @{ state = 'available'; downloadUrl = $result.downloadUrl; apiUrl = $result.apiUrl; version = $result.version; size = $result.size }
            $updateBtn.Text = 'Şimdi güncelle'
            $updateBtn.Enabled = $true
            $status.Text = "Yeni sürüm var: $($result.version) (kurulu: $localText). Şimdi güncelle, kurulum sihirbazını açar ve MamidLabs'i kapatır."
        } else {
            $updateBtn.Tag = @{ state = 'idle' }
            $updateBtn.Text = if ($result.error) { $result.error } else { 'Güncelsiniz' }
            $status.Text = if ($result.error) { 'Güncelleme denetlenemedi: ' + $result.error } else { "MamidLabs güncel (sürüm $localText)." }
            $updateBtn.Enabled = $false
            $updateResetTimer.Start()
        }
    }.GetNewClosure())

    $langBtn.Add_Click({
        $chosen = if ($langCombo.SelectedIndex -eq 1) { 'en' } else { 'tr' }
        if ($chosen -eq $editionLang) {
            $status.Text = 'Seçilen dil sürümü zaten kurulu.'
            return
        }
        $langBtn.Enabled = $false
        $langBtn.Text = 'İndiriliyor…'
        $dlg.Refresh()
        $release = Get-EditionRelease $otherEditionRepo
        if ($release.error) {
            $status.Text = 'Dil sürümü indirilemedi: ' + $release.error
            $langBtn.Text = 'Seçili dil sürümünü indir'
            $langBtn.Enabled = $true
            return
        }
        try {
            # Paket kalici tutulur (tools\editions); "Sil" ile bu dosya + kayit kaldirilir.
            $dir = Get-EditionDownloadDir
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $downloadPath = Join-Path $dir ("MamidLabs_Setup_" + $chosen + ".exe")
            $token = Get-UpdateToken
            $url = if ($token -and $release.apiUrl) { $release.apiUrl } else { $release.downloadUrl }
            $headers = if ($token -and $release.apiUrl) {
                @{ 'User-Agent' = 'MamidLabs-Updater'; 'Accept' = 'application/octet-stream'; 'Authorization' = "Bearer $token" }
            } else { @{ 'User-Agent' = 'MamidLabs-Updater' } }
            Invoke-WebRequest -Uri $url -Headers $headers -OutFile $downloadPath -UseBasicParsing -ErrorAction Stop
            if ($release.size -and (Get-Item -LiteralPath $downloadPath).Length -ne $release.size) { throw 'İndirilen dosya boyutu uyuşmuyor.' }
            @{ lang = $chosen; version = [string]$release.version; path = $downloadPath; installedAt = (Get-Date).ToString('o') } |
                ConvertTo-Json | Set-Content -LiteralPath (Get-EditionRecordPath) -Encoding UTF8
            $langDeleteBtn.Enabled = $true
            Start-Process -FilePath $downloadPath
            $status.Text = 'Dil sürümünün kurulum sihirbazı açıldı; MamidLabs kapanıyor.'
            $dlg.Close()
            if ($mainForm) { $mainForm.Close() }
        } catch {
            $status.Text = 'Dil sürümü indirilemedi: ' + $_.Exception.Message
            $langBtn.Text = 'Seçili dil sürümünü indir'
            $langBtn.Enabled = $true
        }
    }.GetNewClosure())

    $langDeleteBtn.Add_Click({
        $record = Get-EditionRecord
        if (!$record) { $status.Text = 'Silinecek indirilmiş dil sürümü yok.'; return }
        try {
            if ($record.path -and (Test-Path -LiteralPath $record.path -PathType Leaf)) {
                Remove-Item -LiteralPath $record.path -Force
            }
            Remove-Item -LiteralPath (Get-EditionRecordPath) -Force -ErrorAction SilentlyContinue
            $langDeleteBtn.Enabled = $false
            $status.Text = 'İndirilen dil sürümü paketi silindi.'
        } catch {
            $status.Text = 'Dil sürümü paketi silinemedi: ' + $_.Exception.Message
        }
    }.GetNewClosure())

    # Baslangicta "Sil" dügmesi yalnizca indirilmis bir dil paketi varsa etkin olsun.
    $langDeleteBtn.Enabled = [bool](Get-EditionRecord)

    $dlg.Controls.AddRange(@($list, $detail, $status, $downloadBtn, $switchBtn, $deleteBtn, $updateBtn, $closeBtn, $tokenLabel, $tokenBox, $tokenSave, $tokenClear, $mediaChk, $audioChk, $delCompBtn, $langLabel, $langCombo, $langBtn, $langDeleteBtn))
    $wanted = 0
    if ($focusId) {
        for ($i = 0; $i -lt $catalog.Count; $i++) { if ($catalog[$i].id -eq $focusId) { $wanted = $i; break } }
    }
    $list.SelectedIndex = $wanted
    & $refresh
    [void]$dlg.ShowDialog($form)
    $dlg.Dispose()
}
