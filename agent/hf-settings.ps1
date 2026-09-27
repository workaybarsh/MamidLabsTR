function Show-HuggingFaceSettings {
    if($script:busy -or $script:imageBusy){$metric.Text='Önce mevcut işlemin bitmesini bekle.';return}
    $dlg=[Windows.Forms.Form]::new();$dlg.Text='MamidLabs · Hugging Face';$dlg.Size=[Drawing.Size]::new(620,470)
    $dlg.StartPosition='CenterParent';$dlg.BackColor=$colPanel;$dlg.ForeColor=$colText;$dlg.FormBorderStyle='FixedDialog';$dlg.MaximizeBox=$false
    $fields=@{}
    $rows=@(@('token','Token (boş bırakılırsa kayıtlı token korunur)'),@('repo','Model deposu (kurum/model)'),@('filename','Depo içindeki dosya yolu'),@('destination','İndirilecek klasör'))
    $y=16
    foreach($row in $rows){
        $label=[Windows.Forms.Label]::new();$label.Text=$row[1];$label.SetBounds(20,$y,560,22)
        $box=[Windows.Forms.TextBox]::new();$box.SetBounds(20,($y+24),560,26);$fields[$row[0]]=$box
        $dlg.Controls.AddRange(@($label,$box));$y+=65
    }
    $fields.token.UseSystemPasswordChar=$true;$fields.destination.Text=Join-Path $root 'models\huggingface'
    $note=[Windows.Forms.Label]::new();$note.SetBounds(20,280,560,48);$note.Text='Okuma yetkili token yeterlidir. Kısıtlı modeller için Hugging Face üzerinde erişim izni gerekir. Token yalnızca bu Windows hesabında şifreli saklanır; indirilen dosya otomatik çalıştırılmaz.'
    $status=[Windows.Forms.Label]::new();$status.SetBounds(20,382,560,40)
    $dlg.Controls.AddRange(@($note,$status))
    foreach($action in @(@('save','Kaydet',20),@('test','Bağlantıyı test et',155),@('download','Dosyayı indir',300),@('remove','Tokenı kaldır',445))){
        $btn=[Windows.Forms.Button]::new();$btn.Text=$action[1];$btn.SetBounds([int]$action[2],338,130,32)
        $btn.Tag=@{action=$action[0];fields=$fields;status=$status;dialog=$dlg}
        $btn.Add_Click({
            try{
                $f=$this.Tag.fields;$action=$this.Tag.action
                if($action -eq 'remove'){$script:apiSettings.providers.Remove('huggingface');Save-ApiSettings;$f.token.Text='';$this.Tag.status.Text='Kayıtlı token kaldırıldı. HF_TOKEN ortam değişkeni varsa kullanılabilir.';return}
                if($f.token.Text.Trim()){
                    $script:apiSettings.providers.huggingface=@{key=(ConvertFrom-SecureString (ConvertTo-SecureString $f.token.Text.Trim() -AsPlainText -Force))}
                    Save-ApiSettings;$f.token.Text=''
                }
                $token=Get-ProviderKey 'huggingface'
                if(!$token){throw 'Token gir.'}
                if($action -eq 'save'){$this.Tag.status.Text='Token şifreli kaydedildi.';return}
                if($action -eq 'download' -and (!$f.repo.Text.Trim() -or !$f.filename.Text.Trim() -or !$f.destination.Text.Trim())){throw 'Depo, dosya yolu ve hedef klasörü doldur.'}
                $data=@{kind='huggingface';apiKey=$token;action=$action;repo=$f.repo.Text.Trim();filename=$f.filename.Text.Trim();destination=$f.destination.Text.Trim();root=$root}
                $script:activeBubble=New-Bubble 'assistant';$script:activeBubble.body.Text='Hugging Face işlemi…'
                $script:sharedMedia=[hashtable]::Synchronized(@{Cancel=$false;Process=$null})
                $script:imageJob=Start-ThreadJob -FilePath (Join-Path $root 'agent\api-media-run.ps1') -ArgumentList $data,$script:sharedMedia
                $script:imageBusy=$true;$send.Enabled=$true;$send.Text='Durdur';Relayout-Chat
                $this.Tag.dialog.Close()
            }catch{$this.Tag.status.Text=$_.Exception.Message}
        });$dlg.Controls.Add($btn)
    }
    [void]$dlg.ShowDialog($form);$dlg.Dispose()
}
