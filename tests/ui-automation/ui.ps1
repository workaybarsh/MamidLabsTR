# UI Automation yardimcilari (Windows PowerShell 5.1). Masaustu testleri icin.
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Windows.Forms, System.Drawing
$ErrorActionPreference = 'Stop'
$AE = [Windows.Automation.AutomationElement]
$TS = [Windows.Automation.TreeScope]
$shotDir = Join-Path $env:TEMP 'claude\ui\shots'
New-Item -ItemType Directory -Force -Path $shotDir | Out-Null

Add-Type @'
using System; using System.Runtime.InteropServices;
public static class Win {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
}
'@

function Get-Window([int]$procId, [string]$titleLike = '*', [int]$timeoutSec = 60) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $cond = New-Object Windows.Automation.PropertyCondition($AE::ProcessIdProperty, $procId)
        $wins = $AE::RootElement.FindAll($TS::Children, $cond)
        foreach ($w in $wins) { if ($w.Current.Name -like $titleLike) { return $w } }
        Start-Sleep -Milliseconds 500
    }
    throw "Pencere bulunamadi (pid $procId, $titleLike)"
}

function Get-WindowByTitle([string]$titleLike, [int]$timeoutSec = 60) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        foreach ($w in $AE::RootElement.FindAll($TS::Children, [Windows.Automation.Condition]::TrueCondition)) {
            if ($w.Current.Name -like $titleLike) { return $w }
        }
        Start-Sleep -Milliseconds 500
    }
    throw "Pencere bulunamadi: $titleLike"
}

function Show-Tree($el, [int]$max = 200) {
    $all = $el.FindAll($TS::Descendants, [Windows.Automation.Condition]::TrueCondition)
    $i = 0
    foreach ($e in $all) {
        if ($i++ -ge $max) { break }
        $c = $e.Current
        if (!$c.IsOffscreen) { '{0,-14} [{1}] en={2} {3}' -f $c.ControlType.ProgrammaticName.Replace('ControlType.', ''), $c.Name, $c.IsEnabled, $c.AutomationId }
    }
}

function Find-El($root, [string]$name, [string]$type = $null) {
    foreach ($e in $root.FindAll($TS::Descendants, [Windows.Automation.Condition]::TrueCondition)) {
        $c = $e.Current
        if ($c.IsOffscreen) { continue }
        if ($type -and $c.ControlType.ProgrammaticName -ne "ControlType.$type") { continue }
        if ($c.Name -like $name) { return $e }
    }
    return $null
}

function Invoke-El($el) {
    $p = $null
    if ($el.TryGetCurrentPattern([Windows.Automation.InvokePattern]::Pattern, [ref]$p)) { $p.Invoke(); return }
    if ($el.TryGetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern, [ref]$p)) { $p.Select(); return }
    if ($el.TryGetCurrentPattern([Windows.Automation.TogglePattern]::Pattern, [ref]$p)) { $p.Toggle(); return }
    throw "Tiklanamiyor: $($el.Current.Name)"
}

function Click-Name($root, [string]$name, [string]$type = $null, [int]$timeoutSec = 30) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $el = Find-El $root $name $type
        if ($el -and $el.Current.IsEnabled) { Invoke-El $el; Start-Sleep -Milliseconds 700; return }
        Start-Sleep -Milliseconds 500
    }
    throw "Bulunamadi ya da pasif: $name"
}

function Set-Text($el, [string]$text) {
    $p = $el.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern)
    $p.SetValue($text)
}

function Save-Shot($win, [string]$name) {
    $h = [IntPtr]$win.Current.NativeWindowHandle
    if ($h -ne [IntPtr]::Zero) { [Win]::ShowWindow($h, 9) | Out-Null; [Win]::SetForegroundWindow($h) | Out-Null; Start-Sleep -Milliseconds 400 }
    $r = $win.Current.BoundingRectangle
    $bmp = New-Object Drawing.Bitmap ([int]$r.Width), ([int]$r.Height)
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen([int]$r.X, [int]$r.Y, 0, 0, $bmp.Size)
    $g.Dispose()
    $path = Join-Path $shotDir ($name + '.png')
    $bmp.Save($path, [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
    return $path
}

Add-Type @'
using System; using System.Runtime.InteropServices; using System.Text;
public static class Msg {
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr h, int m, IntPtr w, IntPtr l);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr h, int m, IntPtr w, string l);
}
'@

# Inno Setup dugmeleri UIA'da Pane gorunur; gercek HWND'ye BM_CLICK gonderilir.
function Click-Hwnd($el) {
    $h = [IntPtr]$el.Current.NativeWindowHandle
    if ($h -eq [IntPtr]::Zero) { Invoke-El $el; return }
    [void][Msg]::SendMessage($h, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 800
}
function Click-Pane($root, [string]$name, [int]$timeoutSec = 30) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        $el = Find-El $root $name
        if ($el -and $el.Current.IsEnabled) { Click-Hwnd $el; return }
        Start-Sleep -Milliseconds 500
    }
    throw "Bulunamadi ya da pasif: $name"
}
function Set-HwndText($el, [string]$text) {
    [void][Msg]::SendMessage([IntPtr]$el.Current.NativeWindowHandle, 0x000C, [IntPtr]::Zero, $text)
}

# ---------------------------------------------------------------- dosya secme diyalogu
# TUZAK: Vista+ ortak "Ac/Kaydet" diyalogunda dosya-adi kutusuna TAM YOL yazmak
# Windows 11'de "Dosya adinda asagidaki karakterler bulunamaz: \ / : * ? \" < > |"
# hatasina yol acar (Windows bunu "Ada Degistir/Sakla" sanir). Dogru sira:
#   1) diyalogu hedef KLASORE yonlendir (adres cubugu Edit'i; olmazsa dosya-adi
#      kutusuna KLASOR yolunu yaz + Enter),
#   2) dosya-adi kutusunu temizle ve YALNIZCA dosya adini (Split-Path -Leaf) yaz,
#   3) kabul et (Ac/Kaydet = kontrol kimligi 1),
#   4) hata penceresi (#32770, "karakterler bulunamaz") cikarsa OK'a bas, kapat ve
#      yalnizca-dosya-adi ile yeniden dene. Hata kullaniciya/teste yansimaz.
# Win32 alt yapisi: win32.ps1'deki [FileDlg] sinifi.

# Diyalogun adres cubugundaki guncel klasor adini doner (gezinme dogrulamasi icin).
function Get-FileDialogAddressName {
    param([IntPtr]$dialog)
    $d = [Windows.Automation.AutomationElement]::FromHandle($dialog)
    foreach ($e in $d.FindAll($TS::Descendants, [Windows.Automation.Condition]::TrueCondition)) {
        $c = $e.Current
        if ($c.AutomationId -eq '1001' -and -not $c.IsOffscreen -and $c.Name) { return $c.Name }
    }
    return ''
}

# Diyalogu hedef klasore yonlendirir. Once adres cubugu Edit'i (varsa), olmazsa
# dosya-adi kutusuna KLASOR yolunu yazip Enter ile gider. Gezinme dogrulanirsa $true.
function Move-FileDialogToFolder {
    param([IntPtr]$dialog, [string]$folder)
    if (-not $folder) { return $true }
    $folder = [FileDlg]::LongPath(([IO.Path]::GetFullPath($folder)))
    $leafName = Split-Path -Leaf $folder
    $targets = @([FileDlg]::AddressEdit($dialog), [FileDlg]::FileNameEdit($dialog))
    foreach ($ctl in $targets) {
        if ($ctl -eq [IntPtr]::Zero) { continue }
        [FileDlg]::FocusIn($dialog, $ctl)
        Start-Sleep -Milliseconds 150
        [FileDlg]::SetTextValue($ctl, '')
        Start-Sleep -Milliseconds 120
        [FileDlg]::SetTextValue($ctl, $folder)
        Start-Sleep -Milliseconds 200
        [FileDlg]::PressEnter($ctl)
        Start-Sleep -Milliseconds 1400
        if ((Get-FileDialogAddressName $dialog) -like "*$leafName*") { return $true }
    }
    return $false
}

# Dosya-adi kutusunu temizleyip YALNIZCA verilen adi yazar (tam yol yazmaz).
function Set-FileDialogNameOnly {
    param([IntPtr]$dialog, [string]$name)
    $edit = [FileDlg]::FileNameEdit($dialog)
    if ($edit -eq [IntPtr]::Zero) { throw 'Dosya adi kutusu bulunamadi.' }
    [FileDlg]::FocusIn($dialog, $edit)
    Start-Sleep -Milliseconds 120
    [FileDlg]::SetTextValue($edit, '')
    Start-Sleep -Milliseconds 120
    [FileDlg]::SetTextValue($edit, $name)
    Start-Sleep -Milliseconds 200
}

# Diyalogu kabul eder (Ac/Kaydet = kontrol kimligi 1).
function Accept-FileDialog {
    param([IntPtr]$dialog)
    [FileDlg]::ClickButton($dialog, 1)
}

# Popup (#32770) metnini UIA'dan toplar (GetWindowText capraz surecte bos donebilir).
function Get-FileDialogPopupText {
    param([IntPtr]$h)
    $parts = @()
    try {
        $d = [Windows.Automation.AutomationElement]::FromHandle($h)
        if ($d.Current.Name) { $parts += $d.Current.Name }
        foreach ($e in $d.FindAll($TS::Descendants, [Windows.Automation.Condition]::TrueCondition)) {
            $c = $e.Current
            if (-not $c.IsOffscreen -and $c.Name) { $parts += $c.Name }
        }
    } catch {}
    return ($parts -join ' ')
}

# Aciklama hata penceresini (#32770) bulup OK'a basar ve kapatir. Kapattiysa $true.
function Dismiss-FileDialogError {
    param([IntPtr]$dialog, [int]$appPid = 0, [string]$Pattern = 'karakterler bulunamaz|following characters|belirtilen karakter|cannot contain')
    foreach ($h in [FileDlg]::Tops()) {
        if ($h -eq $dialog) { continue }
        if ([FileDlg]::Cls($h) -notmatch '32770') { continue }
        if ($appPid -gt 0) { $p = 0; [void][W32]::GetWindowThreadProcessId($h, [ref]$p); if ($p -ne $appPid) { continue } }
        if ((Get-FileDialogPopupText $h) -match $Pattern) {
            [FileDlg]::ClickButton($h, 1)
            Start-Sleep -Milliseconds 200
            [FileDlg]::PressEnter($h)
            Start-Sleep -Milliseconds 400
            return $true
        }
    }
    return $false
}

# Acik bir HWND'nin hala yasadigini gosterir.
function Test-WindowExists {
    param([IntPtr]$h)
    return ([FileDlg]::Tops() -contains $h)
}

# ANA AKIS: diyalogu hedef dosyaya yonlendir ve sec. Hata penceresi cikarsa kapatip
# yalnizca dosya adi ile yeniden dener. Diyalog kapanirsa $true.
function Set-FileDialogTarget {
    param([IntPtr]$dialog, [string]$path, [int]$appPid = 0)
    if ($dialog -eq [IntPtr]::Zero) { throw 'Set-FileDialogTarget: gecersiz diyalog.' }
    $full = [FileDlg]::LongPath(([IO.Path]::GetFullPath($path)))
    $folder = Split-Path -Parent $full
    $leaf = Split-Path -Leaf $full
    [void](Move-FileDialogToFolder $dialog $folder)
    for ($i = 0; $i -lt 2; $i++) {
        Set-FileDialogNameOnly $dialog $leaf
        Accept-FileDialog $dialog
        Start-Sleep -Milliseconds 900
        if (-not (Test-WindowExists $dialog)) { return $true }
        if (Dismiss-FileDialogError $dialog $appPid) {
            Start-Sleep -Milliseconds 400
            [void](Move-FileDialogToFolder $dialog $folder)
        } else { break }
    }
    return $false
}
function Get-Wizard { Get-Window ([int](Get-Content (Join-Path $env:TEMP 'claude\ui\wizard-pid.txt'))) '*' 10 }
