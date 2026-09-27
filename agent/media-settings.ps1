function Show-MediaSettings {
    if ($script:busy -or $script:imageBusy) { $metric.Text='Önce mevcut işlemin bitmesini bekle.'; return }
    $dlg=[Windows.Forms.Form]::new();$dlg.Text='MamidLabs · Görsel ve video modelleri';$dlg.Size=[Drawing.Size]::new(650,480)
    $dlg.StartPosition='CenterParent';$dlg.FormBorderStyle='FixedDialog';$dlg.MaximizeBox=$false;$dlg.MinimizeBox=$false
    $dlg.BackColor=$colPanel;$dlg.ForeColor=$colText
    $fields=@{}
    $y=20
    foreach($kind in @('image','video')) {
        $label=[Windows.Forms.Label]::new();$label.Text=if($kind -eq 'image'){'Görsel üretimi'}else{'Video üretimi'};$label.SetBounds(20,$y,520,24)
        $combo=[Windows.Forms.ComboBox]::new();$combo.DropDownStyle='DropDownList';$combo.SetBounds(20,($y+28),150,28)
        [void]$combo.Items.AddRange(@('Yerel','OpenAI','Gemini'))
        $model=[Windows.Forms.ComboBox]::new();$model.DropDownStyle='DropDown';$model.SetBounds(185,($y+28),425,28)
        $combo.Tag=@{kind=$kind;model=$model}
        $combo.Add_SelectedIndexChanged({
            if($this.SelectedIndex -lt 0){return}
            $id=@('local','openai','gemini')[$this.SelectedIndex]
            $this.Tag.model.Items.Clear()
            $p=$script:apiSettings.providers[$id]
            if($id -eq 'local'){
                # Krea-2'nin tam hassasiyetli agirligi diffusion_models altinda durur;
                # Lite'in GGUF kuantize surumu ComfyUI-GGUF custom node'unun aradigi
                # unet altindadir.
                $dirs=if($this.Tag.kind -eq 'image'){@('ComfyUI\models\diffusion_models','ComfyUI\models\unet')}else{@('ComfyUI\models\diffusion_models')}
                $rx=if($this.Tag.kind -eq 'image'){'(?i)krea2.*turbo'}else{'(?i)wan2[._]2.*ti2v.*5b'}
                $files=@()
                foreach($dir in $dirs){
                    $base=Join-Path $root $dir
                    if(!(Test-Path -LiteralPath $base)){continue}
                    $files+=@(Get-ChildItem -LiteralPath $base -Filter '*.safetensors' -File -Recurse | Where-Object {$_.Name -match $rx} | ForEach-Object {$_.FullName.Substring($base.Length+1).Replace('\','/')})
                    $files+=@(Get-ChildItem -LiteralPath $base -Filter '*.gguf' -File -Recurse | Where-Object {$_.Name -match $rx} | ForEach-Object {$_.FullName.Substring($base.Length+1).Replace('\','/')})
                }
                # Kopyalanmadan eklenen harici dosyalar da listelenir (media-paths.ps1).
                foreach($external in @($script:apiSettings.externalMediaModels | Where-Object {$_ -and [string]$_.kind -eq $this.Tag.kind})){
                    if(Test-Path -LiteralPath ([string]$external.path) -PathType Leaf){$files+=[IO.Path]::GetFileName([string]$external.path)}
                }
                $files=@($files | Select-Object -Unique)
                foreach($file in $files){[void]$this.Tag.model.Items.Add($file)}
                $saved=[string]$script:apiSettings[($this.Tag.kind+'LocalModel')]
                $this.Tag.model.Text=if($saved){$saved}elseif($files){$files[0]}else{''}
            }else{
                if($p){foreach($name in @($p[($this.Tag.kind+'Models')])){if($name){[void]$this.Tag.model.Items.Add($name)}}}
                $this.Tag.model.Text=if($p){[string]$p[($this.Tag.kind+'Model')]}else{''}
            }
        })
        $id=[string]$script:apiSettings[($kind+'Provider')];$index=[Array]::IndexOf(@('local','openai','gemini'),$id)
        $combo.SelectedIndex=[math]::Max(0,$index)
        $fields[$kind]=@{combo=$combo;model=$model}
        $dlg.Controls.AddRange(@($label,$combo,$model));$y+=85
    }
    $note=[Windows.Forms.Label]::new();$note.SetBounds(20,225,590,110)
    $note.Text="API için tam model kimliğini gir; anahtarları API bağlantıları bölümünde kaydet. Yerelde Krea 2 Turbo görsel, Wan 2.2 TI2V 5B video modelleri desteklenir; farklı mimariler ek işlem hattı gerektirir. Görselde MAX/FLASH Krea 2 Turbo'nun fp8_scaled (.safetensors), Lite ise GGUF kuantize (Q4_K_M, .gguf) sürümünü kullanır. Video tüm profillerde aynı Wan 2.2 TI2V 5B dosyasıyla üretilir; Lite 480p ile sınırlıdır.`r`nClaude sohbeti destekler. OpenAI Sora API 24 Eylül 2026'da kapandı; OpenAI video seçeneği artık yanıt vermeyebilir. Tüm seçimler program yeniden açıldığında korunur."
    $browse=[Windows.Forms.Button]::new();$browse.Text='Model dosyası seç (dosya yolu)…';$browse.SetBounds(20,188,340,30)
    $browse.Tag=$fields
    $browse.Add_Click({
        $pick=[Windows.Forms.OpenFileDialog]::new();$pick.Title='Krea 2 Turbo (.safetensors/.gguf) veya Wan 2.2 TI2V 5B model dosyası';$pick.Filter='Model|*.safetensors;*.gguf'
        try {
            if($pick.ShowDialog() -ne 'OK'){return}
            $kind=if(Test-MediaModelFile $pick.FileName 'image'){'image'}elseif(Test-MediaModelFile $pick.FileName 'video'){'video'}else{''}
            if(!$kind){[void][Windows.Forms.MessageBox]::Show('Bu pencere Krea 2 Turbo (.safetensors/.gguf) veya Wan 2.2 TI2V 5B (.safetensors) ağırlıklarını destekler.');return}
            # Varsayilan: dosya yerinde kullanilir (kopya yok). Hayir: eskisi gibi ComfyUI klasorune kopyalanir.
            $answer=[Windows.Forms.MessageBox]::Show("Dosya bulunduğu yerde kullanılsın mı?`r`n`r`nEvet: kopyalanmaz, yalnızca yolu kaydedilir (önerilir).`r`nHayır: MamidLabs ComfyUI klasörüne kopyalanır.",'Model dosyası','YesNoCancel','Question')
            if($answer -eq 'Cancel'){return}
            $name=[IO.Path]::GetFileName($pick.FileName)
            if($answer -eq 'Yes'){
                $script:apiSettings.externalMediaModels=@(Add-ExternalMediaModel $script:apiSettings.externalMediaModels $pick.FileName $kind)
                [void](Write-ComfyExtraModelPaths $root $script:apiSettings.externalMediaModels)
            } else {
                # GGUF (Lite) ComfyUI-GGUF custom node'u tarafindan unet altinda aranir.
                $folder='ComfyUI\models\'+(Get-ComfyModelFolder $pick.FileName)
                New-Item -ItemType Directory -Path (Join-Path $root $folder) -Force | Out-Null
                $target=Join-Path (Join-Path $root $folder) $name
                if(!(Test-Path -LiteralPath $target)){Copy-Item -LiteralPath $pick.FileName -Destination $target}
            }
            $script:apiSettings[($kind+'LocalModel')]=$name
            $script:apiSettings[($kind+'Provider')]='local'
            Save-ApiSettings
            # Ilgili satiri Yerel'e alip listeyi tazeler; yeni dosya secili gelir.
            $field=$this.Tag[$kind];$field.combo.SelectedIndex=-1;$field.combo.SelectedIndex=0
            $field.model.Text=$name
            # Secimden sonra pencerede gorunur bir onay yoktu; kullanici islemin olup olmadigini bilemiyordu.
            $label=if($kind -eq 'image'){'Görsel'}else{'Video'}
            $how=if($answer -eq 'Yes'){'bulunduğu yerde kullanılacak, kopyalanmadı'}else{'ComfyUI klasörüne kopyalandı'}
            $this.Tag['status'].Text="$label modeli eklendi: $name ($how)."
        } catch { [void][Windows.Forms.MessageBox]::Show('Model eklenemedi: '+$_.Exception.Message) }
        finally { $pick.Dispose() }
    });$dlg.Controls.Add($browse)
    $status=[Windows.Forms.Label]::new();$status.SetBounds(20,365,455,40)
    $fields['status']=$status
    $save=[Windows.Forms.Button]::new();$save.Text='Kaydet';$save.SetBounds(500,365,110,32);$save.Tag=@{fields=$fields;status=$status}
    $save.Add_Click({
        try {
            foreach($kind in @('image','video')) {
                $field=$this.Tag.fields[$kind];$id=@('local','openai','gemini')[$field.combo.SelectedIndex]
                if($id -ne 'local' -and !$field.model.Text.Trim()){throw 'Seçili API için model kimliğini gir.'}
            }
            foreach($kind in @('image','video')) {
                $field=$this.Tag.fields[$kind];$id=@('local','openai','gemini')[$field.combo.SelectedIndex]
                $script:apiSettings[($kind+'Provider')]=$id
                if($id -eq 'local'){$script:apiSettings[($kind+'LocalModel')]=$field.model.Text.Trim()}
                if($id -ne 'local') {
                    if(!$script:apiSettings.providers[$id]){$script:apiSettings.providers[$id]=@{}}
                    $script:apiSettings.providers[$id][($kind+'Model')]=$field.model.Text.Trim()
                    $p=$script:apiSettings.providers[$id]
                    $p[($kind+'Models')]=@(@($p[($kind+'Models')])+@($field.model.Text.Trim()) | Where-Object {$_} | Select-Object -Unique)
                }
            }
            Save-ApiSettings;$this.Tag.status.Text='Görsel ve video seçimleri kaydedildi.'
        }catch{$this.Tag.status.Text=$_.Exception.Message}
    })
    $dlg.Controls.AddRange(@($note,$status,$save));[void]$dlg.ShowDialog($form);$dlg.Dispose()
}

function Start-CloudMedia([string]$kind,[hashtable]$data) {
    $provider=[string]$script:apiSettings[($kind+'Provider')]
    if(!$provider -or $provider -eq 'local'){return $false}
    try {
        $data.kind=$kind;$data.provider=$provider;$data.root=$root
        $data.model=[string]$script:apiSettings.providers[$provider][($kind+'Model')]
        $data.apiKey=Get-ProviderKey $provider
        if(!$data.model -or !$data.apiKey){throw 'API bağlantıları bölümünde anahtarı, Görsel ve video API bölümünde model kimliğini gir.'}
        $script:sharedMedia=[hashtable]::Synchronized(@{Cancel=$false;Process=$null})
        $job=Start-ThreadJob -FilePath (Join-Path $root 'agent\api-media-run.ps1') -ArgumentList $data,$script:sharedMedia
        if($kind -eq 'image'){$script:imageJob=$job}else{$script:videoJob=$job}
        $script:imageBusy=$true;$send.Enabled=$true;$send.Text='Durdur'
        $metric.Text="$provider API: üretim isteği gönderiliyor…"
    }catch{Render-JobEvent ([pscustomobject]@{kind='error';text=$_.Exception.Message})}
    return $true
}
