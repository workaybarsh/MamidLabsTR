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

# Bir profilin dosyalarını diskte arar; eksikleri indirilebilir ve elle kurulacak
# diye ayırır. Boyut karşılaştırması yapılmaz: yarım kalmış bir indirme varsa
# Hugging Face istemcisi kaldığı yerden devam eder.
function Get-ProfileState([string]$id) {
    $entry = Get-ProfileEntry $id
    $state = @{ present = @(); missingDownloadable = @(); missingManual = @() }
    if (!$entry) { return $state }
    foreach ($file in @($entry.files)) {
        $full = Join-Path $root ([string]$file.target)
        if (Test-Path -LiteralPath $full -PathType Leaf) { $state.present += $file }
        elseif ([string]$file.repo) { $state.missingDownloadable += $file }
        else { $state.missingManual += $file }
    }
    return $state
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
    return $null
}

# GitHub'daki en son sürümü yerel sürümle (Inno'nun kendi kaldırma kaydı) karşılaştırır.
# Sonuç: @{ available; version; downloadUrl; size; localVersion; error }. Ağ hatasında
# 'error' dolu döner, istisna fırlatmaz — Profiller penceresindeki buton kullanıcıya
# ham hata metni yerine kısa bir durum göstersin diye.
function Test-MamidLabsUpdateAvailable {
    $local = Get-InstalledMamidLabsVersion
    try {
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$($script:MamidLabsRepo)/releases/latest" `
            -Headers @{ 'User-Agent' = 'MamidLabs-Updater'; 'Accept' = 'application/vnd.github+json' } -TimeoutSec 20 -ErrorAction Stop
    } catch {
        return @{ available = $false; error = 'Denetlenemedi (internet yok?)'; localVersion = $local }
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
    return @{ available = $isNewer; version = $remoteVersion; downloadUrl = [string]$asset.browser_download_url; size = [long]$asset.size; localVersion = $local }
}

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

function Start-ProfileDownload([string]$id) {
    if ($script:busy -or $script:imageBusy) { return 'Önce mevcut işlemin bitmesini bekle.' }
    $state = Get-ProfileState $id
    $missing = @($state.missingDownloadable)
    if (!$missing.Count) { return 'İndirilecek dosya yok.' }
    $files = @()
    foreach ($file in $missing) {
        $files += @{
            repo = [string]$file.repo
            filename = [string]$file.filename
            revision = [string]$file.revision
            target = (Join-Path $root ([string]$file.target))
            label = [string]$file.label
            bytes = [long]$file.bytes
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
    $dlg.Size = [Drawing.Size]::new(790, 500)
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
    $downloadBtn.SetBounds(16, 376, 210, 34)
    $switchBtn = [Windows.Forms.Button]::new()
    $switchBtn.Text = 'Bu profile geç'
    $switchBtn.SetBounds(240, 376, 170, 34)
    $updateBtn = [Windows.Forms.Button]::new()
    $updateBtn.Text = 'Güncellemeleri denetle'
    $updateBtn.SetBounds(416, 376, 214, 34)
    $updateBtn.Tag = @{ state = 'idle' }
    $closeBtn = [Windows.Forms.Button]::new()
    $closeBtn.Text = 'Kapat'
    $closeBtn.SetBounds(642, 376, 120, 34)

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
        $failure = Start-ProfileDownload $catalog[$index].id
        if ($failure) { $status.Text = $failure; return }
        $dlg.Close()
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
                Invoke-WebRequest -Uri $state.downloadUrl -OutFile $downloadPath -UseBasicParsing -ErrorAction Stop
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
            $updateBtn.Tag = @{ state = 'available'; downloadUrl = $result.downloadUrl; version = $result.version; size = $result.size }
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

    $dlg.Controls.AddRange(@($list, $detail, $status, $downloadBtn, $switchBtn, $updateBtn, $closeBtn))
    $wanted = 0
    if ($focusId) {
        for ($i = 0; $i -lt $catalog.Count; $i++) { if ($catalog[$i].id -eq $focusId) { $wanted = $i; break } }
    }
    $list.SelectedIndex = $wanted
    & $refresh
    [void]$dlg.ShowDialog($form)
    $dlg.Dispose()
}
