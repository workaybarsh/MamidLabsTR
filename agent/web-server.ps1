# MamidLabs yerel web yonetimi (HTTP sunucusu).
#
# Uygulama arayuzunu yerel agdan (ya da kurulumda yalnizca bu bilgisayardan) bir
# tarayiciyla yonetmeyi saglar. Tasarim OpenCode'un sunucu modelini ornek alir:
#   * Varsayilan olarak YALNIZCA localhost'a baglanir (127.0.0.1); yerel aga acmak
#     icin acik bir ayar gerekir (web.lan = true) ve Windows'ta http://+:port/ icin
#     yonetici hakki / URL ACL ister.
#   * Sifre korumalidir; dogru sifre HttpOnly + SameSite=Strict oturum cerezi verir.
#   * Sifre degistirilince tum oturumlar gecersiz olur.
#   * Basarisiz girislerde kisa bir kilit uygulanir (kaba kuvvet korumasi).
#   * Dosya erisimi yalnizca outputs\ agaciyla sinirlidir (yol dolanmasi engellenir).
#
# Bu betik hem uygulamadan (arka planda) hem de dogrudan calistirilabilir:
#   pwsh -File agent\web-server.ps1 -Root <kok> -Port 8917 -Password <sifre>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Root,
    [int]$Port = 8917,
    [string]$Password = '',
    [switch]$Lan,
    # Sifreyi settings\api.json -> web.password alanindan (DPAPI) okumak yerine
    # dogrudan parametreyle vermek icin -Password kullanilir.
    [string]$SettingsPasswordField = 'web.password'
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

function Write-Log([string]$text) {
    Write-Host ('[{0:HH:mm:ss}] {1}' -f (Get-Date), $text)
}

# --- sifre cozumleme -------------------------------------------------------
function Get-WebPassword([string]$root, [string]$plain, [string]$field) {
    if ($plain) { return $plain }
    $settingsPath = Join-Path $root 'settings\api.json'
    if (!(Test-Path -LiteralPath $settingsPath -PathType Leaf)) { return '' }
    try {
        $settings = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $parts = $field.Split('.')
        $node = $settings
        foreach ($part in $parts) { if ($null -eq $node) { return '' }; $node = $node.$part }
        if (!$node) { return '' }
        $secure = ConvertTo-SecureString ([string]$node)
        return [Net.NetworkCredential]::new('', $secure).Password
    } catch { return '' }
}

# --- oturum deposu (bellekte) ---------------------------------------------
$script:sessions = @{}           # token -> son gecerlilik (DateTime UTC)
$script:pairs = @{}              # tek kullanimlik baglanti tokeni -> son gecerlilik (DateTime UTC)
$script:sessionDays = 30         # OpenCode ile ayni: oturum 30 gun surer
$script:pairMinutes = 5          # OpenCode ile ayni: baglanti linki 5 dakikada dolar
$script:failedLogins = 0
$script:lockUntil = [DateTime]::MinValue

function New-Session {
    $bytes = [byte[]]::new(32)
    [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    $token = (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
    $days = if ($script:sessionDays) { [int]$script:sessionDays } else { 30 }
    $script:sessions[$token] = [DateTime]::UtcNow.AddDays($days)
    return $token
}

# Tek kullanimlik, kisa omurlu baglanti tokeni (OpenCode 'pair' ile ayni mantik).
function New-PairToken {
    $bytes = [byte[]]::new(24)
    [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    $token = (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
    $mins = if ($script:pairMinutes) { [int]$script:pairMinutes } else { 5 }
    $script:pairs[$token] = [DateTime]::UtcNow.AddMinutes($mins)
    return $token
}

function Consume-PairToken([string]$token) {
    if (!$token -or !$script:pairs.ContainsKey($token)) { return $false }
    $ok = ($script:pairs[$token] -ge [DateTime]::UtcNow)
    $script:pairs.Remove($token)  # tek kullanimlik: basarili da olsa tuketilir
    return $ok
}

function Test-Session([string]$token) {
    if (!$token -or !$script:sessions.ContainsKey($token)) { return $false }
    if ($script:sessions[$token] -lt [DateTime]::UtcNow) { $script:sessions.Remove($token); return $false }
    return $true
}

function Get-CookieToken($request) {
    $cookie = $request.Cookies['mamid']
    if ($cookie) { return [string]$cookie.Value }
    return ''
}

# Sabit zamanli karsilastirmaya yakin bir sifre kontrolu.
function Test-Password([string]$given, [string]$expected) {
    if (!$expected) { return $false }
    $a = [Text.Encoding]::UTF8.GetBytes([string]$given)
    $b = [Text.Encoding]::UTF8.GetBytes($expected)
    if ($a.Length -ne $b.Length) { return $false }
    $diff = 0
    for ($i = 0; $i -lt $a.Length; $i++) { $diff = $diff -bor ($a[$i] -bxor $b[$i]) }
    return ($diff -eq 0)
}

$script:password = Get-WebPassword $Root $Password $SettingsPasswordField
if (!$script:password) {
    throw 'Web yonetimi icin sifre ayarlanmamis. Uygulamada Web yonetimi penceresinden bir sifre belirle.'
}

# --- llama-server koptugu adresi -------------------------------------------
$script:llamaUrl = 'http://127.0.0.1:8080'

# --- yardimcilar -----------------------------------------------------------
function Send-Bytes($response, [int]$status, [string]$contentType, [byte[]]$body) {
    $response.StatusCode = $status
    $response.ContentType = $contentType
    $response.ContentLength64 = $body.Length
    $response.OutputStream.Write($body, 0, $body.Length)
    $response.OutputStream.Close()
}

function Send-Json($response, $obj, [int]$status = 200) {
    $json = ($obj | ConvertTo-Json -Depth 8 -Compress)
    Send-Bytes $response $status 'application/json; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes($json))
}

function Send-Text($response, [string]$text, [int]$status = 200, [string]$contentType = 'text/plain; charset=utf-8') {
    Send-Bytes $response $status $contentType ([Text.Encoding]::UTF8.GetBytes($text))
}

function Send-Unauthorized($response, [string]$message = 'Sifre gerekli.') {
    $response.AddHeader('WWW-Authenticate', 'Cookie')
    Send-Json $response @{ error = $message } 401
}

function Read-JsonBody($request) {
    $reader = New-Object IO.StreamReader($request.InputStream, [Text.Encoding]::UTF8)
    $text = $reader.ReadToEnd()
    $reader.Dispose()
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return ($text | ConvertFrom-Json)
}

# outputs\ icindeki bir dosya adini guvenli mutlak yola cevirir (yol dolanmasi yok).
function Resolve-OutputPath([string]$name) {
    $outputs = Join-Path $Root 'outputs'
    if ([string]::IsNullOrWhiteSpace($name)) { return $null }
    $safe = $name -replace '/', '\'
    if ($safe -match '\.\.' -or [IO.Path]::IsPathRooted($safe) -or $safe -match ':') { return $null }
    $full = [IO.Path]::GetFullPath((Join-Path $outputs $safe))
    $rootFull = [IO.Path]::GetFullPath($outputs)
    if (!$full.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) { return $null }
    if (!(Test-Path -LiteralPath $full -PathType Leaf)) { return $null }
    return $full
}

# --- HTTP API -----------------------------------------------------------------
function Invoke-Api($request, $response) {
    $path = $request.Url.AbsolutePath.TrimEnd('/')
    if ($path -eq '') { $path = '/' }
    $method = $request.HttpMethod

    # Giris, tek kullanimlik baglanti linki ve arayuz disinda her sey oturum ister.
    if ($path -eq '/' -and $method -eq 'GET') { Send-Text $response (Get-WebUiHtml) 200 'text/html; charset=utf-8'; return }
    if ($path -eq '/api/login' -and $method -eq 'POST') { Handle-Login $request $response; return }
    if ($path -eq '/auth/connect' -and $method -eq 'GET') { Handle-Connect $request $response; return }
    if ($path -eq '/favicon.ico') { Send-Bytes $response 204 'image/x-icon' ([byte[]]@()); return }

    if (!(Test-Session (Get-CookieToken $request))) { Send-Unauthorized $response; return }

    switch ("$method $path") {
        'POST /api/logout'   { Handle-Logout $request $response; return }
        'GET /api/status'    { Handle-Status $response; return }
        'GET /api/models'    { Handle-Models $response; return }
        'POST /api/model'    { Handle-ModelSwitch $request $response; return }
        'GET /api/outputs'   { Handle-Outputs $response; return }
        'GET /api/file'      { Handle-File $request $response; return }
        'POST /api/chat'     { Handle-Chat $request $response; return }
        'POST /api/pair'     { Handle-Pair $request $response; return }
        default              { Send-Json $response @{ error = 'Bilinmeyen uc nokta.' } 404; return }
    }
}

# Tek kullanimlik baglanti linki uretir (oturum gerekir). Link 5 dakika gecerli,
# tarayicida acilinca oturum cerezi verip arayuze yonlendirir (OpenCode 'pair').
function Handle-Pair($request, $response) {
    $token = New-PairToken
    $hostHeader = [string]$request.Headers['Host']
    if (!$hostHeader) { $hostHeader = "127.0.0.1:$Port" }
    $url = "http://$hostHeader/auth/connect?t=$token"
    Send-Json $response @{ url = $url; expiresIn = ($script:pairMinutes * 60) }
}

function Handle-Login($request, $response) {
    if ([DateTime]::UtcNow -lt $script:lockUntil) {
        Send-Json $response @{ error = 'Cok fazla hatali deneme; birkac saniye bekleyin.' } 429; return
    }
    $body = Read-JsonBody $request
    $given = if ($body) { [string]$body.password } else { '' }
    if (!(Test-Password $given $script:password)) {
        $script:failedLogins++
        if ($script:failedLogins -ge 5) { $script:lockUntil = [DateTime]::UtcNow.AddSeconds(30); $script:failedLogins = 0 }
        Send-Json $response @{ error = 'Sifre yanlis.' } 401; return
    }
    $script:failedLogins = 0
    $token = New-Session
    # HttpOnly + SameSite=Strict; XSS ve CSRF yuzeyini daraltir. Oturum 30 gun (OpenCode gibi).
    $response.AppendHeader('Set-Cookie', "mamid=$token; HttpOnly; SameSite=Strict; Path=/; Max-Age=$($script:sessionDays * 24 * 3600)")
    Send-Json $response @{ ok = $true }
}

function Handle-Logout($request, $response) {
    $token = Get-CookieToken $request
    if ($token) { $script:sessions.Remove($token) | Out-Null }
    $response.AppendHeader('Set-Cookie', 'mamid=; HttpOnly; SameSite=Strict; Path=/; Max-Age=0')
    Send-Json $response @{ ok = $true }
}

# Tek kullanimlik link: token gecerliyse oturum ac, arayuze yonlendir (OpenCode 'pair').
function Handle-Connect($request, $response) {
    $token = [string]$request.QueryString['t']
    if (!(Consume-PairToken $token)) {
        Send-Text $response '<!doctype html><meta charset="utf-8"><p>Baglanti gecersiz ya da suresi doldu. Yeni bir baglanti linki olustur.</p>' 401 'text/html; charset=utf-8'
        return
    }
    $session = New-Session
    $response.AppendHeader('Set-Cookie', "mamid=$session; HttpOnly; SameSite=Strict; Path=/; Max-Age=$($script:sessionDays * 24 * 3600)")
    $response.StatusCode = 302
    $response.RedirectLocation = '/'
    $response.OutputStream.Close()
}

function Handle-Status($response) {
    $health = $null
    try { $health = Invoke-RestMethod "$($script:llamaUrl)/health" -TimeoutSec 3 } catch { }
    $props = $null
    try { $props = Invoke-RestMethod "$($script:llamaUrl)/props" -TimeoutSec 3 } catch { }
    Send-Json $response @{
        ok = $true
        server = ($null -ne $health -and $health.status -eq 'ok')
        alias = if ($props) { [string]$props.model_path | Split-Path -Leaf } else { '' }
        model = if ($props) { [string]$props.model_path } else { '' }
        nCtx = if ($props -and $props.default_generation_settings) { [int]$props.default_generation_settings.n_ctx } else { 0 }
    }
}

function Handle-Models($response) {
    # Yerlesik profiller + kayitli yerel modeller (settings\api.json).
    $models = @()
    foreach ($p in @('max', 'flash', 'lite')) { $models += @{ id = "builtin-$p"; label = "Yerlesik $($p.ToUpper())" } }
    $settingsPath = Join-Path $Root 'settings\api.json'
    if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
        try {
            $settings = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($m in @($settings.localModels)) { if ($m -and $m.id) { $models += @{ id = [string]$m.id; label = [string]$m.name } } }
        } catch { }
    }
    Send-Json $response @{ models = @($models) }
}

function Handle-ModelSwitch($request, $response) {
    $body = Read-JsonBody $request
    $id = if ($body) { [string]$body.id } else { '' }
    if (!$id) { Send-Json $response @{ error = 'Model kimligi gerekli.' } 400; return }
    # Yalnizca yerlesik profiller ya da kayitli yerel model kimlikleri kabul edilir.
    $allowed = @('builtin-max', 'builtin-flash', 'builtin-lite')
    $settingsPath = Join-Path $Root 'settings\api.json'
    if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
        try { $settings = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json; foreach ($m in @($settings.localModels)) { if ($m -and $m.id) { $allowed += [string]$m.id } } } catch { }
    }
    if ($id -notin $allowed) { Send-Json $response @{ error = 'Gecersiz model.' } 400; return }
    $profile = 'max'
    $modelId = ''
    if ($id -like 'builtin-*') { $profile = $id.Substring('builtin-'.Length) } else { $modelId = $id }
    $manage = Join-Path $Root 'scripts\manage-qwen.ps1'
    try {
        $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $manage, '-Action', 'switch', '-Profile', $profile)
        if ($modelId) { $args += @('-ModelId', $modelId) }
        Start-Process -FilePath ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) -ArgumentList $args -WindowStyle Hidden
        Send-Json $response @{ ok = $true; switching = $id }
    } catch { Send-Json $response @{ error = $_.Exception.Message } 500 }
}

function Handle-Outputs($response) {
    $outputs = Join-Path $Root 'outputs'
    $items = @()
    if (Test-Path -LiteralPath $outputs) {
        Get-ChildItem -LiteralPath $outputs -Recurse -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 200 | ForEach-Object {
            $rel = $_.FullName.Substring($outputs.Length).TrimStart('\')
            $items += @{ name = $rel; size = $_.Length; modified = $_.LastWriteTime.ToString('s') }
        }
    }
    Send-Json $response @{ files = @($items) }
}

function Handle-File($request, $response) {
    $name = [string]$request.QueryString['name']
    $full = Resolve-OutputPath $name
    if (!$full) { Send-Json $response @{ error = 'Dosya bulunamadi.' } 404; return }
    $bytes = [IO.File]::ReadAllBytes($full)
    $type = switch ([IO.Path]::GetExtension($full).ToLowerInvariant()) {
        '.png' { 'image/png' } '.jpg' { 'image/jpeg' } '.jpeg' { 'image/jpeg' } '.webp' { 'image/webp' }
        '.gif' { 'image/gif' } '.mp4' { 'video/mp4' } '.webm' { 'video/webm' } '.pdf' { 'application/pdf' }
        default { 'application/octet-stream' }
    }
    $response.AddHeader('Content-Disposition', ('inline; filename="{0}"' -f [IO.Path]::GetFileName($full)))
    Send-Bytes $response 200 $type $bytes
}

# Sohbet: llama-server'in OpenAI uyumlu uc noktasina koprulenir; akis (SSE) dogrudan
# tarayiciya aktarilir.
function Handle-Chat($request, $response) {
    $body = Read-JsonBody $request
    if (!$body -or !$body.messages) { Send-Json $response @{ error = 'messages gerekli.' } 400; return }
    $payload = @{
        model = 'mamid-web'
        messages = $body.messages
        stream = $true
        # Uretim istegiyle ayni sekil (bkz. smoke-test/Set-LowEffortRequest).
        reasoning_effort = 'low'
        chat_template_kwargs = @{ reasoning_effort = 'low' }
    }
    if ($null -ne $body.temperature) { $payload.temperature = [double]$body.temperature }
    $json = $payload | ConvertTo-Json -Depth 10 -Compress

    $response.StatusCode = 200
    $response.ContentType = 'text/event-stream; charset=utf-8'
    $response.Headers['Cache-Control'] = 'no-cache'
    $response.SendChunked = $true
    $writer = New-Object IO.StreamWriter($response.OutputStream, [Text.UTF8Encoding]::new($false))
    $writer.AutoFlush = $true
    try {
        $req = [Net.HttpWebRequest]::Create("$($script:llamaUrl)/v1/chat/completions")
        $req.Method = 'POST'
        $req.ContentType = 'application/json; charset=utf-8'
        $req.Timeout = 600000
        $req.ReadWriteTimeout = 600000
        $reqBody = [Text.Encoding]::UTF8.GetBytes($json)
        $req.ContentLength = $reqBody.Length
        $rs = $req.GetRequestStream(); $rs.Write($reqBody, 0, $reqBody.Length); $rs.Close()
        $resp = $req.GetResponse()
        $reader = New-Object IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8)
        while (($line = $reader.ReadLine()) -ne $null) {
            $writer.Write($line + "`n")
        }
        $reader.Dispose(); $resp.Close()
    } catch {
        $writer.Write("data: {""error"":""$($_.Exception.Message -replace '"','\"')""}`n`n")
    } finally {
        $writer.Flush(); $writer.Dispose()
        try { $response.OutputStream.Close() } catch { }
    }
}

# --- ara yuz (tek dosya HTML) -------------------------------------------------
function Get-WebUiHtml {
    return @'
<!doctype html><html lang="tr"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>MamidLabs Web</title>
<style>
:root{color-scheme:dark}
body{margin:0;font:15px/1.5 system-ui,Segoe UI,sans-serif;background:#12151c;color:#d7deea}
header{display:flex;gap:12px;align-items:center;padding:10px 16px;background:#1a1f29;border-bottom:1px solid #263041;position:sticky;top:0}
header h1{font-size:16px;margin:0}
#status{font-size:13px;color:#8fa2bd;margin-left:auto}
#chat{max-width:900px;margin:0 auto;padding:16px;display:flex;flex-direction:column;gap:10px;min-height:60vh}
.msg{padding:10px 14px;border-radius:12px;white-space:pre-wrap;word-wrap:break-word}
.user{align-self:flex-end;background:#1f6feb33;border:1px solid #1f6feb66;max-width:80%}
.bot{align-self:flex-start;background:#1a1f29;border:1px solid #263041;max-width:90%}
.think{color:#7f8ea8;font-size:13px;font-style:italic}
footer{position:sticky;bottom:0;background:#12151c;border-top:1px solid #263041;padding:12px;display:flex;gap:8px;max-width:900px;margin:0 auto}
textarea{flex:1;resize:none;height:52px;background:#1a1f29;color:#d7deea;border:1px solid #263041;border-radius:10px;padding:8px}
button{background:#1f6feb;color:#fff;border:0;border-radius:10px;padding:0 18px;font-weight:600;cursor:pointer}
button:disabled{opacity:.5}
#login{max-width:360px;margin:12vh auto;background:#1a1f29;border:1px solid #263041;border-radius:14px;padding:22px;display:flex;flex-direction:column;gap:10px}
input{background:#12151c;color:#d7deea;border:1px solid #263041;border-radius:10px;padding:10px}
a{color:#5aa2ff}
.small{font-size:12px;color:#8fa2bd}
</style></head><body>
<div id="login">
  <h1 style="margin:0">MamidLabs Web</h1>
  <div class="small">Yerel yonetim. Sifreyi gir.</div>
  <input id="pw" type="password" placeholder="Sifre" autofocus>
  <button id="loginBtn">Giris</button>
  <div id="loginErr" class="small" style="color:#ff7b72"></div>
</div>
<div id="app" style="display:none">
  <header>
    <h1>MamidLabs</h1>
    <select id="model" style="background:#1a1f29;color:#d7deea;border:1px solid #263041;border-radius:8px;padding:6px"></select>
    <span id="status">durum…</span>
    <button id="pair" style="background:#30363d" title="Tek kullanimlik baglanti linki (5 dk)">Baglanti linki</button>
    <button id="logout" style="background:#30363d">Cikis</button>
  </header>
  <div id="chat"></div>
  <footer>
    <textarea id="box" placeholder="Mesaj yaz… (Enter = gonder, Shift+Enter = yeni satir)"></textarea>
    <button id="send">Gonder</button>
  </footer>
</div>
<script>
const $ = s => document.querySelector(s);
let busy = false;
async function api(path, opts){
  opts = opts || {}; opts.credentials = 'same-origin';
  if(opts.body && typeof opts.body !== 'string'){ opts.headers = {'Content-Type':'application/json'}; opts.body = JSON.stringify(opts.body); }
  const r = await fetch(path, opts);
  if(r.status === 401){ showLogin(); throw new Error('unauthorized'); }
  return r;
}
function showLogin(){ $('#login').style.display='flex'; $('#app').style.display='none'; $('#pw').focus(); }
function showApp(){ $('#login').style.display='none'; $('#app').style.display='block'; }
async function refresh(){
  try{
    const s = await (await api('/api/status')).json();
    $('#status').textContent = (s.server?'model hazir':'model kapali') + (s.alias?(' · '+s.alias):'') + (s.nCtx?(' · '+s.nCtx+' baglam'):'');
  }catch(e){}
  try{
    const m = await (await api('/api/models')).json();
    const sel = $('#model'); if(!sel.options.length){ m.models.forEach(x=>{const o=document.createElement('option');o.value=x.id;o.textContent=x.label;sel.appendChild(o);}); }
  }catch(e){}
}
function bubble(role, text){
  const d = document.createElement('div'); d.className = 'msg ' + (role==='user'?'user':'bot'); d.textContent = text;
  $('#chat').appendChild(d); d.scrollIntoView({behavior:'smooth', block:'end'}); return d;
}
async function send(){
  const text = $('#box').value.trim(); if(!text || busy) return;
  $('#box').value=''; busy=true; $('#send').disabled=true;
  bubble('user', text);
  const bot = bubble('assistant','');
  const history = [{role:'user', content:text}];
  try{
    const r = await api('/api/chat', {method:'POST', body:{messages:history}});
    const reader = r.body.getReader(); const dec = new TextDecoder(); let buf='';
    while(true){
      const {value, done} = await reader.read(); if(done) break;
      buf += dec.decode(value, {stream:true});
      let i;
      while((i = buf.indexOf('\n')) >= 0){
        const line = buf.slice(0,i).trim(); buf = buf.slice(i+1);
        if(!line.startsWith('data:')) continue;
        const data = line.slice(5).trim(); if(data === '[DONE]') continue;
        try{
          const j = JSON.parse(data);
          const delta = j.choices && j.choices[0] && j.choices[0].delta;
          if(delta && delta.reasoning_content) bot.textContent += '';
          if(delta && delta.content){ if(bot.dataset.thinking){ bot.textContent=''; delete bot.dataset.thinking; } bot.textContent += delta.content; }
          if(delta && delta.reasoning_content && !bot.textContent && !bot.dataset.thinking){ bot.dataset.thinking='1'; bot.textContent='(dusunuyor…)'; }
          bot.scrollIntoView({behavior:'smooth', block:'end'});
        }catch(e){}
      }
    }
  }catch(e){ bot.textContent = '[hata] ' + e.message; }
  busy=false; $('#send').disabled=false; refresh();
}
$('#loginBtn').onclick = async ()=>{
  try{ const r = await fetch('/api/login',{method:'POST',credentials:'same-origin',headers:{'Content-Type':'application/json'},body:JSON.stringify({password:$('#pw').value})});
    if(r.ok){ showApp(); refresh(); } else { $('#loginErr').textContent = 'Sifre yanlis.'; }
  }catch(e){ $('#loginErr').textContent = e.message; }
};
$('#pw').addEventListener('keydown', e=>{ if(e.key==='Enter') $('#loginBtn').click(); });
$('#send').onclick = send;
$('#box').addEventListener('keydown', e=>{ if(e.key==='Enter' && !e.shiftKey){ e.preventDefault(); send(); } });
$('#logout').onclick = async ()=>{ await api('/api/logout',{method:'POST'}); showLogin(); };
$('#pair').onclick = async ()=>{
  try{
    const j = await (await api('/api/pair',{method:'POST'})).json();
    if(navigator.clipboard) navigator.clipboard.writeText(j.url);
    alert('Tek kullanimlik baglanti linki (5 dk, kopyalandi):\n\n' + j.url + '\n\nBu linki ayni agdaki baska bir cihazin tarayicisina yapistir.');
  }catch(e){ alert('Link olusturulamadi: ' + e.message); }
};
$('#model').onchange = async ()=>{ const id = $('#model').value; await api('/api/model',{method:'POST',body:{id}}); setTimeout(refresh, 3000); };
refresh(); setInterval(refresh, 5000);
</script></body></html>
'@
}

# --- sunucu dongusu --------------------------------------------------------
$prefixHost = if ($Lan) { '+' } else { '127.0.0.1' }
$prefix = "http://${prefixHost}:$Port/"
$listener = [Net.HttpListener]::new()
$listener.Prefixes.Add($prefix)
try {
    $listener.Start()
} catch {
    throw ("Web sunucusu baslatilamadi ($prefix): " + $_.Exception.Message +
        $(if ($Lan) { ' - Yerel ag icin http://+:port/ Windows yonetici hakki / URL ACL ister.' } else { '' }))
}
$bindNote = if ($Lan) { 'yerel ag (0.0.0.0)' } else { 'yalnizca localhost' }
Write-Log "MamidLabs web yonetimi hazir: $prefix ($bindNote)"
Write-Host "URL: http://127.0.0.1:$Port/"
Write-Host "MAMIDWEB_READY"

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        try { Invoke-Api $context.Request $context.Response }
        catch {
            try { Send-Json $context.Response @{ error = $_.Exception.Message } 500 } catch { }
        }
    }
} finally {
    try { $listener.Stop(); $listener.Close() } catch { }
    Write-Log 'Web yonetimi durduruldu.'
}
