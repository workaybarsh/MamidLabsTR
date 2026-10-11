# Profil basina llama-server alias'i. scripts\manage-qwen.ps1 icindeki
# $profileAliases tablosuyla birebir ayni kalmalidir; test_qwen_contracts bunu denetler.
# Tablo bilerek fonksiyon icinde kurulur: dosya sadece fonksiyonlari alinarak
# yuklendiginde de tanimli olur, null uzerinde metot cagrilmaz.
function Get-LocalProfileAliases {
    if (!$script:localProfileAliases) {
        $script:localProfileAliases = @{ max = 'qwen3.8-27b-max'; flash = 'qwen3.8-27b-flash'; lite = 'qwen3.5-9b-lite' }
    }
    return $script:localProfileAliases
}

# Sunucunun bildirdigi alias'tan profili geri cozer. Saglik kontrolu ve medya
# islerinden sonraki geri yukleme bu fonksiyonu kullanir.
function Get-ProfileFromAlias([string]$alias) {
    $aliases = Get-LocalProfileAliases
    foreach ($name in @('max', 'flash', 'lite')) {
        if ($alias -eq $aliases[$name]) { return $name }
    }
    if ($alias -like '*-lite') { return 'lite' }
    if ($alias -like '*-flash') { return 'flash' }
    return 'max'
}

# Alt bardaki model kutusunda ve "Bu profile geç" akışında kullanılan sabit
# builtin profil tanımları; tek yerden gelsin diye burada toplandı.
function Get-BuiltinProfileDefinitions {
    return @(
        @{ id = 'builtin-max'; label = 'Qwen3.8 27B MAX'; profile = 'max' },
        @{ id = 'builtin-flash'; label = 'Qwen3.8 27B FLASH'; profile = 'flash' },
        @{ id = 'builtin-lite'; label = 'Qwen3.5 9B LITE'; profile = 'lite' }
    )
}

function Update-ProviderSelection {
    $script:suppressModelChoice=$true
    try {
        $modelChoice.Items.Clear()
        # Lite, 8 GB VRAM / 16 GB RAM makineler icin ayri 9B modeli kullanir. 32K baglam
        # gercek makinede olculdu: varsayilan Q5_K_M ile ~7500 MiB VRAM (8 GB kartta
        # ~450-500 MiB bos kalir - dar ama kullanilabilir).
        # Yalnizca dil modeli dosyalari diskte olan profiller listelenir (ComfyUI medya
        # modelleri haric - -SkipMedia ile kurulmus olabilir, sohbet icin gerekmezler);
        # aksi halde MAX kurulu bir PC'de LITE de (ya da tersi) secilebilir gorunuyordu,
        # secilince manage-qwen.ps1 dosya bulunamadi hatasi veriyordu.
        $script:modelEntries=@()
        foreach ($def in (Get-BuiltinProfileDefinitions)) {
            if (Test-LocalProfileChatFilesPresent $def.profile) {
                $script:modelEntries += @{ id = $def.id; provider = 'local'; label = $def.label; profile = $def.profile; contextLimit = 32768 }
            }
        }
        foreach($local in @($script:apiSettings.localModels)){if($local){$script:modelEntries+=@{id=$local.id;provider='local';label=$local.name;path=$local.path;profile='flash';contextLimit=8192}}}
        $script:modelEntries+=@{id='off';provider='local';label='Kapalı';profile='off';contextLimit=0}
        foreach($id in (Get-ChatProviderIds)){
            $p=$script:apiSettings.providers[$id]
            foreach($name in @(@($p.models)+@($p.model) | Where-Object {$_} | Select-Object -Unique)){
                $script:modelEntries+=@{id="$id|$name";provider=$id;label="$id · $name";model=$name;contextLimit=$(if($p.contextLimit){[int]$p.contextLimit}else{32768})}
            }
        }
        foreach($entry in $script:modelEntries){[void]$modelChoice.Items.Add($entry.label)}
        $wanted=[string]$script:apiSettings.selectedModel;$index=-1
        for($i=0;$i -lt $script:modelEntries.Count;$i++){if($script:modelEntries[$i].id -eq $wanted){$index=$i;break}}
        if($index -lt 0){$index=0}
        $modelChoice.SelectedIndex=$index
        $entry=$script:modelEntries[$index]
        $script:providerId=$entry.provider;$script:apiSettings.selected=$entry.provider
        $script:apiSettings.selectedModel=$entry.id;$script:ctxLimit=$entry.contextLimit
        if($entry.provider -eq 'local'){
            $script:apiSettings.selectedLocalModel=if($entry.path){$entry.id}else{''}
            if($entry.profile -ne 'off'){$script:apiSettings.localProfile=$entry.profile}
        }
        $script:compactAt=[int]($script:ctxLimit*.67)
    }finally{$script:suppressModelChoice=$false}
    $metric.Text="$($modelChoice.SelectedItem) seçildi."
    Update-LiveMetrics
}

function Get-SelectedLocalAlias {
    if ($script:providerId -ne 'local' -or $script:apiSettings.selectedModel -eq 'off') { return '' }
    if ($script:apiSettings.selectedLocalModel) { return [string]$script:apiSettings.selectedLocalModel }
    $aliases = Get-LocalProfileAliases
    $profile = [string]$script:apiSettings.localProfile
    if (!$profile -or !$aliases.ContainsKey($profile)) { $profile = 'max' }
    return [string]$aliases[$profile]
}

function Select-RegisteredModel {
    if($script:suppressModelChoice -or $modelChoice.SelectedIndex -lt 0){return}
    if($script:busy -or $script:imageBusy -or $script:pendingSend){Update-ProviderSelection;return}
    $entry=$script:modelEntries[$modelChoice.SelectedIndex]
    $script:apiSettings.selectedModel=$entry.id;$script:apiSettings.selected=$entry.provider
    if($entry.provider -eq 'local' -and $entry.profile -ne 'off'){
        $script:apiSettings.selectedLocalModel=if($entry.path){$entry.id}else{''}
        $script:apiSettings.localProfile=$entry.profile
    }
    $script:providerId=$entry.provider
    $script:ctxLimit=$entry.contextLimit;$script:compactAt=[int]($script:ctxLimit*.67)
    Save-ApiSettings;Update-LiveMetrics
    if($entry.profile -eq 'off'){Stop-LocalQwen}
    elseif($entry.provider -eq 'local'){Restart-LocalQwen $entry.profile}
    else{
        Stop-LocalQwen
        $metric.Text="$($entry.label) seçildi."
    }
}

# GGUF dil modeli dosyalarini listeye ekler. Parcali modellerde yalnizca ilk parca,
# gorsel projektorleri (mmproj) haric. Dosyalar yerinde kullanilir, kopyalanmaz.
function Register-LocalModelFiles($files) {
    $files=@($files | Where-Object {$_.Name -notmatch '(?i)mmproj|projector' -and ($_.Name -notmatch '-(\d{5})-of-\d{5}' -or [int]$Matches[1] -eq 1)})
    $registered=@($script:apiSettings.localModels | Where-Object {$_})
    foreach($file in $files){if(!@($registered | Where-Object {$_.path -eq $file.FullName}).Count){$registered+=@{id=('local-'+[guid]::NewGuid().ToString('N'));name=$file.BaseName;path=$file.FullName}}}
    $script:apiSettings.localModels=$registered
    return $files.Count
}

# Dosya yoluyla secim: bir ya da birden cok .gguf dosyasi. Iptal edilirse klasor
# taramasi teklif edilir (bir klasordeki tum modelleri tek seferde eklemek icin).
function Add-LocalModelFolder {
    if($script:busy -or $script:imageBusy){$metric.Text='Önce mevcut işlemin bitmesini bekle.';return}
    $pick=[Windows.Forms.OpenFileDialog]::new();$pick.Title='GGUF dil modeli dosyasını seç';$pick.Filter='GGUF dil modeli|*.gguf';$pick.Multiselect=$true
    try{
        if($pick.ShowDialog($form) -eq 'OK'){
            $files=@($pick.FileNames | ForEach-Object { Get-Item -LiteralPath $_ })
        } else {
            $folder=[Windows.Forms.FolderBrowserDialog]::new();$folder.Description='Ya da GGUF dil modeli klasörünü seç (tümü eklenir)'
            try{
                if($folder.ShowDialog($form) -ne 'OK'){return}
                $files=@(Get-ChildItem -LiteralPath $folder.SelectedPath -Filter '*.gguf' -File -Recurse)
            }finally{$folder.Dispose()}
        }
        $count=Register-LocalModelFiles $files
        if(!$count){$metric.Text='Desteklenen GGUF dil modeli bulunamadı (görsel projektörü tek başına eklenemez).';return}
        Save-ApiSettings;Update-ProviderSelection
        $metric.Text="$count GGUF modeli listede. Sağ alttan seçebilirsin."
    }finally{$pick.Dispose()}
}
