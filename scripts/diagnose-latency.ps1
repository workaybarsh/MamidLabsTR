<#
.SYNOPSIS
    "Mesaji gonderdim, cok uzun bekletiyor" sikayetinin nedenini olcer.

.DESCRIPTION
    Uc soruyu veriyle yanitlar:
      1) Bekleme onek (prompt) islemeden mi geliyor, uretimden mi?
      2) Sunucu KV onbellegini kullaniyor mu, yoksa her turda tum baglami bastan mi isliyor?
      3) Model VRAM'e sigiyor mu, yoksa paylasilan sistem bellegine tasiyor mu?

    Ayni sohbeti iki tur halinde gonderir: ikinci turda yalnizca son mesaj eklenir.
    Onbellek calisiyorsa ikinci turda "yeniden islenen token" sayisi kucuk kalir.

.EXAMPLE
    pwsh -File scripts\diagnose-latency.ps1
    pwsh -File scripts\diagnose-latency.ps1 -FillTokens 8000
#>
param(
    [string]$Endpoint = 'http://127.0.0.1:8080',
    # Sohbeti suni olarak buyuterek uzun baglam davranisini olcer.
    [int]$FillTokens = 4000,
    [ValidateSet('low', 'medium', 'xhigh')][string]$Effort = 'low',
    [string]$LogDir = (Join-Path (Split-Path -Parent $PSScriptRoot) 'logs')
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Write-Head([string]$text) {
    Write-Host ''
    Write-Host $text -ForegroundColor Cyan
    Write-Host ('-' * $text.Length) -ForegroundColor DarkCyan
}

# ---------------------------------------------------------------- 1. GPU / VRAM
Write-Head '1) GPU ve VRAM'
$smi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
if ($smi) {
    $row = (& nvidia-smi --query-gpu=name,memory.used,memory.total,utilization.gpu --format=csv,noheader,nounits) -split '\s*,\s*'
    $used = [int]$row[1]; $total = [int]$row[2]
    Write-Host ("GPU        : {0}" -f $row[0])
    Write-Host ("VRAM       : {0} / {1} MiB  (%{2:0})" -f $used, $total, (100.0 * $used / [math]::Max(1, $total)))
    if ($used -gt ($total * 0.95)) {
        Write-Host 'UYARI: VRAM dolu. Windows surucusu tasan kismi sistem RAM''ine (shared memory) alir;' -ForegroundColor Yellow
        Write-Host '       bu durumda hem onek isleme hem uretim kat kat yavaslar.' -ForegroundColor Yellow
    }
} else {
    Write-Host 'nvidia-smi bulunamadi; VRAM olcumu atlandi.' -ForegroundColor DarkYellow
}
# Paylasilan bellek kullanimi: llama-server surecinin commit ettigi bellek VRAM'den
# buyukse tasma kuvvetle muhtemeldir.
$server = Get-Process -Name 'llama-server' -ErrorAction SilentlyContinue
if ($server) {
    Write-Host ("llama-server: PID {0}, calisma kumesi {1:0} MiB" -f $server.Id, ($server.WorkingSet64 / 1MB))
} else {
    Write-Host 'llama-server calismiyor.' -ForegroundColor Yellow
    return
}

# ---------------------------------------------------------------- 2. istek olcumu
function Measure-Turn([object[]]$messages, [string]$label) {
    $body = @{
        messages = $messages
        max_tokens = 48
        stream = $true
        cache_prompt = $true
        timings_per_token = $true
        stream_options = @{ include_usage = $true }
        temperature = 0.2
        reasoning_effort = $Effort
        chat_template_kwargs = @{ reasoning_effort = $Effort }
    } | ConvertTo-Json -Depth 20 -Compress

    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.UseProxy = $false
    $http = [Net.Http.HttpClient]::new($handler)
    $http.Timeout = [TimeSpan]::FromMinutes(10)
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $ttft = $null
    $timings = $null
    try {
        $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Post, "$Endpoint/v1/chat/completions")
        $request.Content = [Net.Http.StringContent]::new($body, [Text.Encoding]::UTF8, 'application/json')
        $response = $http.SendAsync($request, [Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        if (!$response.IsSuccessStatusCode) {
            throw ("Sunucu hatasi {0}: {1}" -f [int]$response.StatusCode, $response.Content.ReadAsStringAsync().GetAwaiter().GetResult())
        }
        $reader = [IO.StreamReader]::new($response.Content.ReadAsStreamAsync().GetAwaiter().GetResult(), [Text.Encoding]::UTF8)
        while ($null -ne ($line = $reader.ReadLine())) {
            if (!$line.StartsWith('data:')) { continue }
            $data = $line.Substring(5).Trim()
            if ($data -eq '[DONE]') { break }
            try { $chunk = $data | ConvertFrom-Json -ErrorAction Stop } catch { continue }
            if ($chunk.timings) { $timings = $chunk.timings }
            $delta = $chunk.choices[0].delta
            if (!$ttft -and ($delta.content -or $delta.reasoning_content)) { $ttft = $clock.ElapsedMilliseconds }
        }
        $reader.Dispose(); $response.Dispose(); $request.Dispose()
    } finally { $http.Dispose() }

    $cached = [int]$timings.cache_n
    $processed = [int]$timings.prompt_n
    Write-Host ''
    Write-Host $label -ForegroundColor White
    Write-Host ("  ilk token          : {0:0.0} sn" -f (([double]$ttft) / 1000.0))
    Write-Host ("  onek islenen token : {0}" -f $processed)
    Write-Host ("  onbellekten gelen  : {0}" -f $cached)
    if ($timings.prompt_ms) {
        Write-Host ("  onek isleme suresi : {0:0.0} sn  ({1:0} token/s)" -f ([double]$timings.prompt_ms / 1000.0), [double]$timings.prompt_per_second)
    }
    if ($timings.predicted_per_second) {
        Write-Host ("  uretim hizi        : {0:0.0} token/s" -f [double]$timings.predicted_per_second)
    }
    return @{ ttft = [double]$ttft; processed = $processed; cached = $cached; timings = $timings }
}

Write-Head "2) Onek isleme ve KV onbellegi (~$FillTokens token dolgu)"
# Dolgu metni: her calistirmada ayni olsun ki iki tur ayni oneki paylassin.
$filler = (1..([math]::Max(1, [int]($FillTokens / 12)))) | ForEach-Object {
    "Satir $_ : bu metin baglami doldurmak icin kullanilan sabit bir olcum metnidir."
}
$base = @(
    @{ role = 'system'; content = 'Kisa yanit ver.' }
    @{ role = 'user'; content = ($filler -join "`n") }
    @{ role = 'assistant'; content = 'Metni aldim.' }
)
$first = Measure-Turn ($base + @(@{ role = 'user'; content = 'Tek kelimeyle yanitla: hazir misin?' })) 'Tur 1 (onbellek sogukken)'
$second = Measure-Turn ($base + @(
    @{ role = 'user'; content = 'Tek kelimeyle yanitla: hazir misin?' }
    @{ role = 'assistant'; content = 'Hazirim.' }
    @{ role = 'user'; content = 'Simdi tek kelimeyle tekrar yanitla.' }
)) 'Tur 2 (yalnizca son mesaj eklendi)'

# ---------------------------------------------------------------- 3. yorum
Write-Head '3) Sonuc'
$reuse = $second.cached -gt ($first.processed * 0.5)
if ($reuse) {
    Write-Host 'KV onbellegi CALISIYOR: ikinci turda eski baglam yeniden islenmedi.' -ForegroundColor Green
} else {
    Write-Host 'KV onbellegi KULLANILMIYOR: ikinci turda tum baglam bastan islendi.' -ForegroundColor Red
    Write-Host 'Neden genelde promptun BASINDAKI bir degisikliktir: sistem istemi, arac tanimlari' -ForegroundColor Yellow
    Write-Host '(cipler acilip kapandiginda) veya gecmisin yeniden yazilmasi (sikistirma).' -ForegroundColor Yellow
}
$prefillShare = if ($second.ttft -gt 0 -and $second.timings.prompt_ms) { [double]$second.timings.prompt_ms / $second.ttft } else { 0 }
if ($prefillShare -gt 0.6) {
    Write-Host ("Bekleme sureci agirlikli olarak onek islemeden geliyor (ilk tokenin %{0:0}'i)." -f ($prefillShare * 100)) -ForegroundColor Yellow
}
if ($second.timings.prompt_per_second -and [double]$second.timings.prompt_per_second -lt 200) {
    Write-Host ("Onek isleme hizi dusuk ({0:0} token/s). GPU'ya sigmayan katmanlar veya VRAM tasmasi tipik nedendir." -f [double]$second.timings.prompt_per_second) -ForegroundColor Yellow
}
if ($second.timings.predicted_per_second -and [double]$second.timings.predicted_per_second -lt 12) {
    Write-Host ("Uretim hizi da dusuk ({0:0.0} token/s). Bu, VRAM tasmasi/paylasilan bellek isaretidir." -f [double]$second.timings.predicted_per_second) -ForegroundColor Red
}

# ---------------------------------------------------------------- 4. sunucu logu
Write-Head '4) Sunucu logunda yeniden isleme izleri'
$logs = @(Get-ChildItem -LiteralPath $LogDir -Filter 'qwen-*.std*.log' -File -ErrorAction SilentlyContinue)
if (!$logs) { Write-Host "Log bulunamadi: $LogDir" -ForegroundColor DarkYellow }
foreach ($log in $logs) {
    $hits = @(Select-String -LiteralPath $log.FullName -Pattern 'forcing full prompt re-processing|n_past|prompt processing progress|cache_n|slot released' -ErrorAction SilentlyContinue | Select-Object -Last 8)
    if ($hits) {
        Write-Host $log.Name -ForegroundColor White
        foreach ($hit in $hits) { Write-Host ('  ' + $hit.Line.Trim()) }
    }
}
