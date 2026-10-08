# MamidLabs yerel web yonetimi penceresi: sifre belirle, yerel ag secenegi, baslat/durdur.
# Sunucu (agent\web-server.ps1) sifreyi settings\api.json -> web.password alanindan (DPAPI)
# kendisi okur; boylece sifre komut satirinda/process listesinde gorunmez.
function Get-WebServerProcess {
    @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" -ErrorAction SilentlyContinue | Where-Object {
        $_.CommandLine -and $_.CommandLine -like '*web-server.ps1*' })
}

function Get-WebSettingsValues {
    $web = if ($script:apiSettings) { $script:apiSettings.web } else { $null }
    $port = 8917
    $lan = $false
    $hasPassword = $false
    if ($web) {
        if ($web.port) { $port = [int]$web.port }
        if ($null -ne $web.lan) { $lan = [bool]$web.lan }
        if ($web.password) { $hasPassword = $true }
    }
    return @{ port = $port; lan = $lan; hasPassword = $hasPassword }
}

function Start-MamidWebServer([int]$Port, [bool]$Lan) {
    $manage = Join-Path $root 'agent\web-server.ps1'
    if (!(Test-Path -LiteralPath $manage -PathType Leaf)) { throw "web-server.ps1 bulunamadi: $manage" }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    foreach ($argument in @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $manage, '-Root', $root, '-Port', [string]$Port)) {
        $psi.ArgumentList.Add($argument)
    }
    if ($Lan) { $psi.ArgumentList.Add('-Lan') }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    return [System.Diagnostics.Process]::Start($psi)
}

function Stop-MamidWebServer {
    foreach ($proc in Get-WebServerProcess) {
        Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
    }
}

function Show-WebSettings {
    if ($script:busy -or $script:imageBusy) { $metric.Text = 'Web yonetimi icin mevcut islemin bitmesini bekle.'; return }
    $values = Get-WebSettingsValues
    $dlg = [Windows.Forms.Form]::new()
    $dlg.Text = 'MamidLabs · Web yonetimi'
    $dlg.Size = [Drawing.Size]::new(620, 430)
    $dlg.StartPosition = 'CenterParent'
    $dlg.BackColor = $colPanel; $dlg.ForeColor = $colText
    $dlg.FormBorderStyle = 'FixedDialog'; $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false

    $pwLabel = [Windows.Forms.Label]::new(); $pwLabel.Text = if ($values.hasPassword) { 'Sifre (kayitli; degistirmek icin yaz)' } else { 'Sifre (zorunlu)' }
    $pwLabel.SetBounds(20, 16, 560, 22)
    $pw = [Windows.Forms.TextBox]::new(); $pw.SetBounds(20, 40, 560, 26); $pw.UseSystemPasswordChar = $true

    $portLabel = [Windows.Forms.Label]::new(); $portLabel.Text = 'Port'; $portLabel.SetBounds(20, 76, 120, 22)
    $portBox = [Windows.Forms.TextBox]::new(); $portBox.SetBounds(20, 100, 120, 26); $portBox.Text = [string]$values.port
    $lan = [Windows.Forms.CheckBox]::new(); $lan.Text = 'Yerel aga ac (0.0.0.0 - yonetici hakki gerekir)'; $lan.SetBounds(160, 100, 420, 26)
    $lan.Checked = $values.lan

    $note = [Windows.Forms.Label]::new()
    $note.SetBounds(20, 132, 560, 70)
    $note.Text = 'Sunucu varsayilan olarak yalnizca bu bilgisayardan (127.0.0.1) erisilir. Sifre Windows hesabina bagli olarak sifreli saklanir. Sifre degistirilince acik oturumlar gecersiz olur. Yerel aga acmak Windows yonetici hakki / URL ACL ister; agdaki herkes portu gorebilir (sifre korumali olsa da risk artar).'
    $link = [Windows.Forms.LinkLabel]::new(); $link.SetBounds(20, 200, 560, 22)
    $link.Text = 'Tarayicida ac: http://127.0.0.1:' + [string]$values.port + '/'
    $link.Tag = $values.port
    $link.Add_Click({ try { Start-Process -FilePath ('http://127.0.0.1:' + [string]$this.Tag + '/') } catch { } })

    $status = [Windows.Forms.Label]::new(); $status.SetBounds(20, 226, 560, 44)

    $buttons = @(
        @{ text = 'Kaydet'; x = 20; action = 'save' },
        @{ text = 'Baslat'; x = 155; action = 'start' },
        @{ text = 'Durdur'; x = 290; action = 'stop' },
        @{ text = 'Kapat'; x = 425; action = 'close' }
    )
    foreach ($b in $buttons) {
        $btn = [Windows.Forms.Button]::new(); $btn.Text = $b.text; $btn.SetBounds([int]$b.x, 280, 125, 34)
        $btn.Tag = @{ action = $b.action }
        $btn.Add_Click({
            $action = $this.Tag.action
            try {
                if ($action -eq 'close') { $this.Parent.Close(); return }
                if ($pw.Text.Trim()) {
                    if (!$script:apiSettings.web) { $script:apiSettings.web = @{} }
                    $script:apiSettings.web.password = (ConvertFrom-SecureString (ConvertTo-SecureString $pw.Text.Trim() -AsPlainText -Force))
                    $pw.Text = ''
                }
                if (!$script:apiSettings.web) { $script:apiSettings.web = @{} }
                $script:apiSettings.web.port = [int]$portBox.Text
                $script:apiSettings.web.lan = [bool]$lan.Checked
                Save-ApiSettings
                if ($action -eq 'save') { $status.Text = 'Kaydedildi.'; return }
                if ($action -eq 'stop') { Stop-MamidWebServer; $status.Text = 'Web yonetimi durduruldu.'; return }
                # start
                if (!$script:apiSettings.web.password) { $status.Text = 'Once bir sifre gir ve kaydet.'; return }
                $existing = @(Get-WebServerProcess)
                if ($existing.Count -gt 0) { Stop-MamidWebServer; Start-Sleep -Seconds 1 }
                [void](Start-MamidWebServer ([int]$portBox.Text) ([bool]$lan.Checked))
                $link.Text = 'Tarayicida ac: http://127.0.0.1:' + $portBox.Text + '/'
                $link.Tag = [int]$portBox.Text
                $status.Text = 'Web yonetimi baslatildi. Tarayicida linke tiklayip sifreyi gir.'
            } catch { $status.Text = $_.Exception.Message }
        })
        $dlg.Controls.Add($btn)
    }
    $dlg.Controls.AddRange(@($pwLabel, $pw, $portLabel, $portBox, $lan, $note, $link, $status))
    [void]$dlg.ShowDialog($form)
    $dlg.Dispose()
}
