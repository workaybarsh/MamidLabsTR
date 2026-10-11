# API keys are encrypted by Windows DPAPI for the current Windows account.
function Read-ApiSettings {
    $path = Join-Path $root 'settings\api.json'
    if (Test-Path -LiteralPath $path) {
        try { return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable) } catch { }
    }
    return @{selected='local';providers=@{}}
}
function Save-ApiSettings {
    $dir = Join-Path $root 'settings'
    [void][IO.Directory]::CreateDirectory($dir)
    $path = Join-Path $dir 'api.json'
    $temp = $path + '.tmp'
    try {
        [IO.File]::WriteAllText($temp, ($script:apiSettings | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
        if ([IO.File]::Exists($path)) { [IO.File]::Replace($temp, $path, [NullString]::Value) }
        else { [IO.File]::Move($temp, $path) }
    } finally {
        if ([IO.File]::Exists($temp)) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
    }
}
function Get-ProviderKey([string]$provider) {
    $profile = $script:apiSettings.providers[$provider]
    if ($profile -and $profile.key) {
        try {
            $secure = ConvertTo-SecureString ([string]$profile.key)
            return [Net.NetworkCredential]::new('', $secure).Password
        } catch { throw 'API anahtarı bu Windows hesabında çözülemedi. Ayarlardan yeniden gir.' }
    }
    $envName = if ($provider -eq 'huggingface') { 'HF_TOKEN' } else { [string](Get-ChatProvider $provider).env }
    if ($envName) { return [Environment]::GetEnvironmentVariable($envName) }
    return ''
}
function Show-ApiSettings {
    if ($script:busy -or $script:imageBusy) { $metric.Text='Bağlantı ayarları için mevcut işlemin bitmesini bekle.'; return }
    $providers = @(Get-ChatProviders)
    $dlg = [Windows.Forms.Form]::new()
    $dlg.Text='MamidLabs · API bağlantıları'
    $dlg.Size=[Drawing.Size]::new(570,520)
    $dlg.StartPosition='CenterParent'; $dlg.FormBorderStyle='FixedDialog'; $dlg.MaximizeBox=$false; $dlg.MinimizeBox=$false
    $dlg.BackColor=$colPanel; $dlg.ForeColor=$colText
    $provider=[Windows.Forms.ComboBox]::new();$provider.DropDownStyle='DropDownList';$provider.SetBounds(20,42,510,28)
    [void]$provider.Items.AddRange(@($providers | ForEach-Object { [string]$_.label }))
    # Hesap baglama: anahtar sayfasi tarayicida acilir, yapistirilan anahtar saglayicinin
    # model listesiyle dogrulanir ve hesabin erisebildigi modeller listeye dolar.
    $openPage=[Windows.Forms.Button]::new();$openPage.Text='1. Hesabına gir, anahtar al';$openPage.SetBounds(20,108,250,30)
    # 'custom' (Özel) icin ayri bir hesap sayfasi yok; ayni satirda taban adres
    # kutusu gosterilir (bkz. $hesapLabel.Text degisimi asagida).
    $baseUrl=[Windows.Forms.TextBox]::new();$baseUrl.SetBounds(20,108,510,28);$baseUrl.Visible=$false
    $key=[Windows.Forms.TextBox]::new();$key.SetBounds(20,174,510,28);$key.UseSystemPasswordChar=$true
    $verify=[Windows.Forms.Button]::new();$verify.Text='2. Doğrula ve modelleri getir';$verify.SetBounds(20,208,250,30)
    $model=[Windows.Forms.ComboBox]::new();$model.DropDownStyle='DropDown';$model.SetBounds(20,274,510,28)
    $context=[Windows.Forms.NumericUpDown]::new();$context.SetBounds(20,340,190,28);$context.Minimum=4096;$context.Maximum=2000000;$context.Increment=1024
    $hesapLabel=$null;$keyLabel=$null
    foreach ($item in @(@('Sağlayıcı',20),@('Hesap bağlantısı',86),@('API anahtarı — boş bırakırsan kayıtlı anahtar korunur',152),@('Model kimliği (listeden seç ya da tam API model adını yaz)',252),@('Kullanılacak bağlam sınırı (token — anahtar doğrulanınca otomatik algılanır)',318))) {
        $label=[Windows.Forms.Label]::new();$label.Text=$item[0];$label.SetBounds(20,[int]$item[1],510,22);$dlg.Controls.Add($label)
        if ([int]$item[1] -eq 86) { $hesapLabel = $label }
        if ([int]$item[1] -eq 152) { $keyLabel = $label }
    }
    $note=[Windows.Forms.Label]::new();$note.SetBounds(20,374,510,46)
    $note.Text='API seçiliyken gönderdiğin mesajlar, ekler ve araç sonuçları seçilen sağlayıcıya iletilir. API ücretleri kendi hesabına aittir. Anahtar Windows hesabına bağlı şifreli saklanır.'
    $save=[Windows.Forms.Button]::new();$save.Text='Kaydet';$save.SetBounds(420,430,110,32)
    $status=[Windows.Forms.Label]::new();$status.SetBounds(20,430,390,40)
    $dlg.Controls.AddRange(@($provider,$openPage,$baseUrl,$key,$verify,$model,$context,$note,$save,$status))
    $fields=@{provider=$provider;model=$model;key=$key;baseUrl=$baseUrl;context=$context;status=$status;providers=$providers;dialog=$dlg;openPage=$openPage;hesapLabel=$hesapLabel;keyLabel=$keyLabel;contexts=@{}}
    $provider.Tag=$fields;$save.Tag=$fields;$openPage.Tag=$fields;$verify.Tag=$fields;$model.Tag=$fields
    # Model secildiginde/yazildiginda baglam pencereyi uctan algilanan degerden uygula
    # (anahtar dogrulaninca $f.contexts dolar).
    $model.Add_TextChanged({
        $f=$this.Tag;$name=$this.Text.Trim()
        if($f.contexts -and $f.contexts.ContainsKey($name)){$f.context.Value=[Math]::Min([int]$f.contexts[$name],[int]$f.context.Maximum)}
    })
    $provider.Add_SelectedIndexChanged({
        $f=$this.Tag;$id=[string]$f.providers[$this.SelectedIndex].id;$p=$script:apiSettings.providers[$id]
        $f.model.Items.Clear()
        foreach($name in @(@($p.models)+@($p.model) | Where-Object {$_} | Select-Object -Unique)){[void]$f.model.Items.Add($name)}
        $f.model.Text=if($p){[string]$p.model}else{''}
        $f.key.Text=''
        $f.context.Value=if($p.contextLimit){[int]$p.contextLimit}else{32768}
        $f.status.Text=if($p.key){'Kayıtlı anahtar var.'}else{'Anahtar henüz kaydedilmedi.'}
        # 'custom' (Özel) hazır bir hesap sayfası sunmaz; onun yerine kendi API
        # adresini yazacağı bir kutu gösterilir. Anahtar da onda isteğe bağlıdır
        # (çoğu yerel sunucu - Ollama, LM Studio, vLLM vb. - kimlik doğrulama istemez).
        if ($id -eq 'custom') {
            $f.openPage.Visible=$false;$f.baseUrl.Visible=$true
            $f.baseUrl.Text=if($p.baseUrl){[string]$p.baseUrl}else{''}
            $f.hesapLabel.Text='Taban adres (ör. http://127.0.0.1:1234/v1 — sonunda /chat/completions OLMADAN)'
            $f.keyLabel.Text='API anahtarı — isteğe bağlı, çoğu yerel/kendi sunucu (Ollama, LM Studio, vLLM vb.) gerektirmez'
        } else {
            $f.openPage.Visible=$true;$f.baseUrl.Visible=$false
            $f.hesapLabel.Text='Hesap bağlantısı'
            $f.keyLabel.Text='API anahtarı — boş bırakırsan kayıtlı anahtar korunur'
        }
    })
    $openPage.Add_Click({
        $f=$this.Tag;$entry=$f.providers[$f.provider.SelectedIndex]
        try { Start-Process ([string]$entry.keyPage); $f.status.Text="$($entry.label) anahtar sayfası tarayıcıda açıldı. Oluşturduğun anahtarı aşağıya yapıştır." }
        catch { $f.status.Text='Tarayıcı açılamadı: '+[string]$entry.keyPage }
    })
    $verify.Add_Click({
        $f=$this.Tag;$entry=$f.providers[$f.provider.SelectedIndex];$id=[string]$entry.id
        $candidate=$f.key.Text.Trim()
        $f.status.Text='Doğrulanıyor…';$f.dialog.Cursor=[Windows.Forms.Cursors]::WaitCursor;$f.dialog.Refresh()
        try {
            if(!$candidate){$candidate=Get-ProviderKey $id}
            # 'custom' icin henuz kaydedilmemis ekrandaki taban adresi dener (bkz.
            # Get-ProviderModels'in $baseUrlOverride parametresi); digerlerinde ayni.
            $names=if($id -eq 'custom'){@(Get-ProviderModels $id $candidate $f.baseUrl.Text.Trim())}else{@(Get-ProviderModels $id $candidate)}
            $current=$f.model.Text
            $f.model.Items.Clear();foreach($name in $names){[void]$f.model.Items.Add($name)}
            $f.model.Text=if($current -and $names -contains $current){$current}elseif($names){$names[0]}else{$current}
            # Baglam penceresini uctan otomatik algila (anahtar girildiginde). Uc
            # context_length dondurmuyorsa mevcut deger korunur.
            $f.contexts = if($id -eq 'custom'){ Get-ProviderModelContexts $id $candidate $f.baseUrl.Text.Trim() } else { Get-ProviderModelContexts $id $candidate }
            if(@($f.contexts.Keys).Count){
                $sel=$f.model.Text.Trim()
                $val = if($f.contexts.ContainsKey($sel)){[int]$f.contexts[$sel]}else{([int[]]@($f.contexts.Values)|Measure-Object -Maximum).Maximum}
                if($val -gt 0){ $f.context.Value=[Math]::Min($val,[int]$f.context.Maximum) }
                $f.status.Text="Bağlantı doğrulandı: $($names.Count) model. Bağlam otomatik algılandı: $([int]$f.context.Value) token."
            } else {
                $f.status.Text="Bağlantı doğrulandı: $($names.Count) model bulundu. Model seçip Kaydet'e bas."
            }
        } catch { $f.status.Text=$_.Exception.Message }
        finally { $f.dialog.Cursor=[Windows.Forms.Cursors]::Default }
    })
    $save.Add_Click({
        $fields=$this.Tag;$id=[string]$fields.providers[$fields.provider.SelectedIndex].id
        try {
            $p=$script:apiSettings.providers[$id]
            if (!$p) {$p=@{}}
            $updated=$p.Clone()
            $updated.model=$fields.model.Text.Trim();$updated.contextLimit=[int]$fields.context.Value
            $updated.models=@(@($p.models)+@($updated.model) | Where-Object {$_} | Select-Object -Unique)
            if ($id -eq 'custom') {
                $trimmed=$fields.baseUrl.Text.Trim().TrimEnd('/')
                if (!$trimmed) { throw 'Önce taban adresi gir (ör. http://127.0.0.1:1234/v1).' }
                $updated.baseUrl=$trimmed
            }
            if ($fields.key.Text.Trim()) { $updated.key=ConvertFrom-SecureString (ConvertTo-SecureString $fields.key.Text.Trim() -AsPlainText -Force) }
            $script:apiSettings.providers[$id]=$updated
            Save-ApiSettings
            $fields.key.Text='';$fields.status.Text='Kaydedildi.'
            Update-ProviderSelection
        } catch { $fields.status.Text='Kaydedilemedi: '+$_.Exception.Message }
    })
    $provider.SelectedIndex=0
    [void]$dlg.ShowDialog($form)
    $dlg.Dispose()
}
