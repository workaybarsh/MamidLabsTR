param([hashtable]$JobData, [hashtable]$Shared)
$ErrorActionPreference='Stop'
# Kurulum kokunu kendi konumundan turet. ONEMLI: bu dosya Start-ThreadJob -FilePath
# ile baslatilir; bu, hedef dosyayi METIN olarak okuyup yeni bir runspace'te
# calistirir - $PSScriptRoot o baglamda HEP BOSTUR (gercek makinede dogrulandi).
# Asil kaynak mamidlabs-desktop.ps1/media-settings.ps1/hf-settings.ps1/profile-catalog.ps1'in
# JobData.root ile acikca gecirdigi degerdir.
$root = if ($JobData.root) { [string]$JobData.root } elseif ($PSScriptRoot) { Split-Path -Parent $PSScriptRoot } else { (Get-Location).Path }
$process=$null
try {
    $psi=[Diagnostics.ProcessStartInfo]::new()
    $psi.FileName=Join-Path $root 'venv\app\Scripts\python.exe'
    $worker='api-media.py'
    if($JobData.kind -eq 'huggingface'){$worker='hf-hub.py'}
    $psi.ArgumentList.Add((Join-Path $root ('agent\' + $worker)))
    $psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
    $psi.RedirectStandardInput=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
    $psi.StandardInputEncoding=[Text.UTF8Encoding]::new($false)
    $psi.StandardOutputEncoding=[Text.Encoding]::UTF8
    $process=[Diagnostics.Process]::Start($psi)
    $Shared.Process=$process
    $errors=$process.StandardError.ReadToEndAsync()
    $process.StandardInput.Write(($JobData|ConvertTo-Json -Depth 10 -Compress));$process.StandardInput.Close()
    while (!$process.StandardOutput.EndOfStream) {
        $line=$process.StandardOutput.ReadLine()
        if ($line) { $line | ConvertFrom-Json }
    }
    $process.WaitForExit()
    if ($Shared.Cancel) { [pscustomobject]@{kind='cancelled';text='API takibi durduruldu. Sağlayıcıdaki iş devam edebilir.'} }
    elseif ($process.ExitCode -ne 0) { throw 'API üretim işlemi beklenmedik şekilde kapandı.' }
} catch {
    [pscustomobject]@{kind='error';text=$_.Exception.Message}
} finally {
    $Shared.Process=$null
    if ($process) { if(!$process.HasExited){$process.Kill($true)};$process.Dispose() }
}
