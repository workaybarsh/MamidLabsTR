# Uzun yasayan alt surecleri (llama-server, ComfyUI) cagiranin std tanitcilarini
# devretmeden baslatir.
#
# Start-Process -RedirectStandardOutput, CreateProcess'i bInheritHandles=TRUE ile
# cagirir: cocuk, cagiranin devredilebilir tum tanitcilarini, betigin kendi stdout
# borusu dahil, alir. Cocuk yasadikca boru kapanmaz; bu yuzden "manage-mamidlabs.ps1 |
# Out-String", smoke-test.ps1 ciktisini dosyaya yonlendirmek ya da Start-Process -Wait
# hic bitmiyordu (gercek makinede goruldu). Cozum: baslatma aninda std tanitcilarin
# devralma bayragini kapatip sonra eski haline getirmek.

function Start-DetachedProcess([string]$FilePath, [string[]]$ArgumentList, [string]$WorkingDirectory,
                               [string]$StdOutPath, [string]$StdErrPath) {
    if (-not ('MamidLabs.StdHandles' -as [type])) {
        Add-Type -Namespace MamidLabs -Name StdHandles -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int id);
[DllImport("kernel32.dll")] public static extern bool GetHandleInformation(IntPtr h, out int flags);
[DllImport("kernel32.dll")] public static extern bool SetHandleInformation(IntPtr h, int mask, int flags);
'@
    }
    $handleFlagInherit = 1
    $restore = [Collections.Generic.List[IntPtr]]::new()
    # STD_INPUT_HANDLE, STD_OUTPUT_HANDLE, STD_ERROR_HANDLE
    foreach ($id in @(-10, -11, -12)) {
        $handle = [MamidLabs.StdHandles]::GetStdHandle($id)
        if ($handle -eq [IntPtr]::Zero -or $handle -eq [IntPtr]::new(-1)) { continue }
        $flags = 0
        if ([MamidLabs.StdHandles]::GetHandleInformation($handle, [ref]$flags) -and ($flags -band $handleFlagInherit) -and
            [MamidLabs.StdHandles]::SetHandleInformation($handle, $handleFlagInherit, 0)) {
            $restore.Add($handle)
        }
    }
    try {
        return Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -WorkingDirectory $WorkingDirectory `
            -RedirectStandardOutput $StdOutPath -RedirectStandardError $StdErrPath -WindowStyle Hidden -PassThru
    } finally {
        foreach ($handle in $restore) { [MamidLabs.StdHandles]::SetHandleInformation($handle, $handleFlagInherit, $handleFlagInherit) | Out-Null }
    }
}
