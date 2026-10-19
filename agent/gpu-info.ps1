# NVIDIA bos VRAM olcumu - TEK kaynak (manage / medya / smoke ayni kurali kullanir).
#
# Neden siki ayristirma: eski kod `-replace '\D', ''` ile TUM rakamlari birlestiriyordu.
# Bu, surucu hatasi metnindeki surum numaralarini (or. "580.88") dev bir "bos VRAM" degerine
# cevirebiliyor, `-5` gibi degerlerde isareti atiyor ve `[N/A]`/bos ciktida 0 uretiyordu.
# 0 "gercek olcum" gibi kullanildiginda ComfyUI gereksiz kapatiliyor; sahte BUYUK deger ise
# bellek kapisini atlatip modelin paylasilan bellege tasmasina (sohbet ~40 -> ~27 tok/s) yol
# acabiliyordu. Bu yuzden yalnizca tam sayi (istege bagli "MiB") kabul edilir; geri kalan her
# sey "olculemedi" = $null.

# "12345" / "12345 MiB" -> 12345 ; [N/A], bos, hata metni, negatif -> $null
function ConvertFrom-MiBText([string]$text) {
    if ($null -eq $text) { return $null }
    $line = @([string]$text -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
    if ($line.Count -eq 0) { return $null }
    if ($line[0] -notmatch '^\s*(\d{1,9})\s*(?:MiB)?\s*$') { return $null }
    return [int]$Matches[1]
}

# Kartin anlik bos VRAM'i (MiB). Coklu GPU'da ILK kart (uygulama tek karta yukler).
# nvidia-smi yok/okunamaz/hata -> $null. Cagiranlar $null'i "olcum yok" saymali, 0 saymamali.
function Get-NvidiaFreeVramMiB {
    $smi = (Get-Command nvidia-smi -ErrorAction SilentlyContinue).Source
    if (!$smi) { return $null }
    $raw = $null
    try { $raw = & $smi --query-gpu=memory.free --format=csv,noheader,nounits 2>$null } catch { return $null }
    if ($null -eq $raw) { return $null }
    $first = @($raw | Select-Object -First 1)
    if ($first.Count -eq 0) { return $null }
    return (ConvertFrom-MiBText ([string]$first[0]))
}
