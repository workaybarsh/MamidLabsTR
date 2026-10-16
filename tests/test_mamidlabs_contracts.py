import json
import shutil
import socket
import struct
import subprocess
import tempfile
import threading
import time
import importlib.util
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[1]


def read_text(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8-sig")


def test_custom_provider_base_url_is_passed_to_the_worker():
    """'custom' taban adresi yalnizca ayar penceresinde (apiSettings) yasar; isci
    (Start-ThreadJob) ayarlari okumaz ve $PSScriptRoot bostur. Bu yuzden masaustu
    jobData'ya apiSettings + baseUrl gecirmeli, isci de gercek istekte bunlari
    kullanmali; aksi halde custom saglayici sohbette 'taban adresi gir' hatasi verir
    (yalnizca dogrulama calisir). Gercek uctan uca testte bulundu."""
    desktop = read_text("mamidlabs-desktop.ps1")
    worker = read_text("agent/mamidlabs-inference.ps1")
    # Masaustu iki jobData blogunda (sohbet + sikistirma) gecirir.
    assert desktop.count("apiSettings = $script:apiSettings") >= 2
    assert desktop.count("baseUrl = (Get-CustomBaseUrl)") >= 2
    # Isci ayarlari ve taban adresini uygular; ucu bundan sonra hesaplar.
    assert "$script:apiSettings = if ($JobData.apiSettings)" in worker
    assert "$JobData.baseUrl" in worker
    idx_apply = worker.index("$script:apiSettings.providers['custom'] = @{ baseUrl")
    idx_endpoint = worker.index("$endpoint = Get-ProviderEndpoint $provider")
    assert idx_apply < idx_endpoint


def test_model_profiles_use_max_flash_and_lite_names():
    registry = read_text("agent/model-registry.ps1")
    manager = read_text("scripts/manage-mamidlabs.ps1")

    assert "builtin-max" in registry
    assert "builtin-flash" in registry
    assert "builtin-xhigh" not in registry
    assert "builtin-low" not in registry
    assert "builtin-lite" in registry
    assert "ValidateSet('max', 'flash', 'lite')" in manager
    assert "--reasoning-effort', $reasoningEffort" in manager


def test_ocr_only_returns_text_without_explanation_request():
    inference = read_text("agent/mamidlabs-inference.ps1")

    assert "function Test-OcrExplainIntent" in inference
    assert "$ocrDirect = !(Test-OcrExplainIntent $userText)" in inference
    assert "if ($ocrDirect)" in inference
    assert "Emit 'done' ([string]$ocrResult.text)" in inference
    assert "Emit 'done' $directPdfText" in inference


def test_image_ocr_swaps_local_model_and_command_tool_uses_approval():
    inference = read_text("agent/mamidlabs-inference.ps1")
    ocr = read_text("agent/ocr-tools.py")
    desktop = read_text("mamidlabs-desktop.ps1")

    assert "function Invoke-ImageOcrWithModelSwap" in inference
    assert "action = 'ocr_image'; path = [string]$paths[0]; device = 'gpu'" in inference
    assert "& (Get-ManageMamidLabsPath) -Action stop" in inference
    assert "Start-LocalModelRestore ([string]$JobData.profile)" in inference
    assert "function Request-Approval([string]$toolName" in inference
    assert "Request-Approval 'run_command'" in inference
    assert "name = 'run_command'" in inference
    assert "profile = $profile" in desktop
    assert "engine=\"paddleocr-gpu\"" in ocr
    assert "engine = _new_engine(\"cpu\")" in ocr
    assert "GPU OCR metin bulamadı; OCR başarısız oldu, görsel Qwen mmproj'e yönlendiriliyor" in inference
    assert "action = 'ocr_images'; paths = @($paths); device = 'gpu'" in inference
    assert "name = 'read_images_ocr'" in inference
    assert "tool_choice = @{ type = 'function'; function = @{ name = 'read_images_ocr' } }" in inference
    assert "Çoklu görsel okuma aktif — birden fazla görsel yükleyebilirsiniz." in inference
    assert "function Get-OcrCpuPythonExe { Join-Path (Get-InstallRoot) 'venv\\ocr-cpu\\Scripts\\python.exe' }" in inference
    assert "action = 'ocr_pdf'; path = $full; max_pages = 50 } (Get-OcrPyPath) (Get-OcrCpuPythonExe)" in inference
    assert "function Start-LocalModelRestore([string]$profile)" in inference
    assert "Start-Process -FilePath $powershell -ArgumentList $arguments" in inference
    assert "currentImagePaths = @($script:currentTurnImagePaths)" in desktop
    assert "multiImageOcr = [bool]($script:currentTurnMultiImageOcr -and $hasOcr)" in desktop
    assert "$dlg.Multiselect = [bool]$script:multiImageOcrMode" in desktop
    assert "Önce \"çoklu görsel okuma modunu aç\" mesajını gönderin" in desktop


def test_generation_tools_are_gated_by_installed_components():
    """Görsel/video ve çoklu-görsel OCR yalnızca ilgili bileşen kuruluysa (ya da API) sunulur;
    aksi halde model var olmayan aracı çağırıp sapıtıyordu."""
    desktop = read_text("mamidlabs-desktop.ps1")
    assert "imagegen = ($hasMedia -or $imageApiOk)" in desktop
    assert "videogen = ($hasMedia -or $videoApiOk)" in desktop
    assert "$hasMedia = Test-Path -LiteralPath (Join-Path $root 'ComfyUI\\main.py')" in desktop
    assert "$hasOcr = (Test-Path -LiteralPath (Join-Path $root 'venv\\ocr\\Scripts\\python.exe'))" in desktop


def test_multi_image_selection_is_preserved_until_send_validation():
    desktop = read_text("mamidlabs-desktop.ps1")

    add_image_start = desktop.index("function Add-SelectedImage")
    add_image_end = desktop.index("function Add-SelectedVideo", add_image_start)
    add_image = desktop[add_image_start:add_image_end]
    assert "$script:selectedImages.Clear()" not in add_image
    assert "acik mod etkinse" in add_image


def test_provider_adapters_preserve_forced_tool_choice():
    """OpenAI uyumlu saglayicilar zorunlu arac secimini aynen alir. Claude'da dusunme
    acikken zorunlu secim 400 verdigi icin 'auto'ya cevrilir (test_api_providers)."""
    providers = read_text("agent/api-providers.ps1")

    assert "if ($body.tool_choice) { $request.tool_choice=$body.tool_choice }" in providers


def test_api_video_tools_do_not_advertise_unsupported_video_continuation():
    inference = read_text("agent/mamidlabs-inference.ps1")

    assert "$videoModes = @('metin', 'gorsel')" in inference
    assert "$videoModes += 'video'" in inference
    assert "mode=video kullanma." in inference


def test_web_tool_failure_is_detected_and_discourages_workarounds():
    """Web aramasi/sayfa indirme ag hatasiyla basarisiz olunca modelin run_command
    (ping/curl...) gibi araclarla etrafindan dolasmasini onleyen bir sistem notu
    eklenir; arac basarisizligi guvenilir sekilde tespit edilir."""
    inference = read_text("agent/mamidlabs-inference.ps1")
    desktop = read_text("mamidlabs-desktop.ps1")

    assert "function Test-WebToolFailure" in inference
    assert "$script:webToolFailCount" in inference
    assert "Test-WebToolFailure $name $result" in inference
    # Istek-kopyasina eklenen not (kalici gecmise yazilmaz); iki kademeli.
    assert "etrafindan dolasmaya" in inference
    assert "run_command ile ping/curl" in inference
    assert "ACIKCA KURULAMIYOR" in inference
    # Ag-probe komutlarina karsi sert koruma (kucuk model nota uymayabiliyor).
    assert "$script:webToolFailCount -gt 0 -and" in inference
    assert "ag komutu calistirilmadi" in inference
    # 2. web hatasindan sonra web araclari modele artik sunulmaz (arama dongusunu engeller).
    # (F1 baglam korumasi birinci kosul oldu; web-hatasi dali elseif olarak korunur.)
    assert "$offeredTools = if ($forceFinalAnswer)" in inference
    assert "elseif ($script:webToolFailCount -ge 2 -and !$script:webToolSuccess)" in inference
    # Kullanici dosya sormadiysa dosya araclari da sunulmaz (cevabi dosyalarda aramasin).
    assert "function Test-FileIntent" in inference
    assert "$blocked += @('list_bound_files', 'read_bound_file')" in inference
    assert "Test-FileIntent $userText" in inference
    # Sistem isteminde de onleyici kural.
    assert "etrafindan dolasmaya calisma" in desktop


def test_run_command_is_only_offered_on_explicit_command_intent():
    """Kullanici acikca komut/terminal istemedikce run_command modele SUNULMAZ; boylece
    kucuk model web/arama hatasinda absurt komut denemelerine giremez."""
    inference = read_text("agent/mamidlabs-inference.ps1")

    assert "function Test-CommandIntent" in inference
    # run_command tanimi niyet kosuluna bagli.
    assert "if (Test-CommandIntent $userText) {" in inference
    idx = inference.index("name = 'run_command'")
    block = inference[idx - 400:idx]
    assert "Test-CommandIntent $userText" in block


def test_command_intent_detection_matrix():
    """Test-CommandIntent: yalnizca acik komut/terminal niyetinde true doner."""
    pwsh = shutil.which("pwsh")
    if not pwsh:
        pytest.skip("PowerShell 7 is unavailable")
    script = r"""
$job = @{ messages = @(@{ role = 'user'; content = 'x' }); compactOnly = $true; provider = 'local'; model = 'test'; contextLimit = 32768; maxTokens = 100; agent = $false; internet = $false; office = $false; documentCreate = $false }
$shared = @{ Cancel = $false }
. '__ROOT__\agent\mamidlabs-inference.ps1' $job $shared | Out-Null
$cases = @(
  @{ t = 'su komutu calistir: ipconfig'; e = $true }
  @{ t = 'terminali ac ve dir yaz'; e = $true }
  @{ t = 'powershell scripti calistir'; e = $true }
  @{ t = 'ping google.com'; e = $true }
  @{ t = 'einstein bilmecesi nedir'; e = $false }
  @{ t = 'istanbulda hava nasil'; e = $false }
  @{ t = 'bunu bir cumlede ozetle'; e = $false }
  @{ t = 'fotografi duzenle'; e = $false }
)
$fail = 0
foreach ($c in $cases) {
  $got = [bool](Test-CommandIntent $c.t)
  if ($got -ne [bool]$c.e) { $fail++; Write-Output ("FAIL: '{0}' got={1} beklenen={2}" -f $c.t, $got, $c.e) }
}
Write-Output ("FAILCOUNT=" + $fail)
""".replace("__ROOT__", str(ROOT))
    with tempfile.NamedTemporaryFile(mode="w", suffix=".ps1", encoding="utf-8-sig", delete=False) as handle:
        handle.write(script)
        script_path = Path(handle.name)
    try:
        result = subprocess.run(
            [str(pwsh), "-NoProfile", "-NonInteractive", "-File", str(script_path)],
            capture_output=True, encoding="utf-8", errors="replace", check=False,
        )
    finally:
        script_path.unlink(missing_ok=True)
    assert result.returncode == 0, result.stderr or result.stdout
    assert "FAILCOUNT=0" in result.stdout, result.stdout


def test_web_tool_failure_detection_matrix():
    """Test-WebToolFailure: yalnizca web araclari ve hata durumunda true doner."""
    pwsh = shutil.which("pwsh")
    if not pwsh:
        pytest.skip("PowerShell 7 is unavailable")
    script = r"""
$job = @{ messages = @(@{ role = 'user'; content = 'x' }); compactOnly = $true; provider = 'local'; model = 'test'; contextLimit = 32768; maxTokens = 100; agent = $false; internet = $false; office = $false; documentCreate = $false }
$shared = @{ Cancel = $false }
. '__ROOT__\agent\mamidlabs-inference.ps1' $job $shared | Out-Null
$cases = @(
  @{ n = 'search_web'; r = '{"error":"Web aramasi basarisiz"}'; e = $true }
  @{ n = 'search_web'; r = '[{"title":"x","href":"u"}]'; e = $false }
  @{ n = 'fetch_page'; r = '{"error":"URL hostu cozumlenemedi."}'; e = $true }
  @{ n = 'find_reference_image'; r = '{"error":"gorsel aramasi basarisiz"}'; e = $true }
  @{ n = 'list_bound_files'; r = '{"error":"ilgisiz"}'; e = $false }
  @{ n = 'search_web'; r = ''; e = $true }
)
$fail = 0
foreach ($c in $cases) {
  $got = [bool](Test-WebToolFailure $c.n $c.r)
  if ($got -ne [bool]$c.e) { $fail++; Write-Output ("HATA: $($c.n) got=$got beklenen=$($c.e)") }
}
Write-Output ("FAILCOUNT=" + $fail)
""".replace("__ROOT__", str(ROOT))
    with tempfile.NamedTemporaryFile(mode="w", suffix=".ps1", encoding="utf-8-sig", delete=False) as handle:
        handle.write(script)
        script_path = Path(handle.name)
    try:
        result = subprocess.run(
            [str(pwsh), "-NoProfile", "-NonInteractive", "-File", str(script_path)],
            capture_output=True, encoding="utf-8", errors="replace", check=False,
        )
    finally:
        script_path.unlink(missing_ok=True)
    assert result.returncode == 0, result.stderr or result.stdout
    assert "FAILCOUNT=0" in result.stdout, result.stdout


def test_stream_watchdog_uses_fresh_connection_and_survives_dropped_stream():
    """Yerel sunucu, arac calisirken bos kalan keep-alive baglantisini kapatabiliyor;
    bayat baglanti tekrar kullanilinca akis ortasinda 'Varolan bir baglanti ... zorla
    kapatildi' (WSAECONNRESET) olusuyordu. Duzeltme: yerel istekler baglantiyi kapatir
    (her tur taze baglanti) ve yanit metni varken kopma hata sayilmaz."""
    inference = read_text("agent/mamidlabs-inference.ps1")

    assert "if ($provider -eq 'local') { $request.Headers.ConnectionClose = $true }" in inference
    assert "$result.finishReason = 'connection-closed'" in inference


# ---------------------------------------------------- D3: custom retry/tolerans
def test_custom_provider_retries_and_tolerates_partial_stream():
    """D3: 'custom' (OpenAI uyumlu ozel uc) icin gecici baglanti hatasinda sinirli
    yeniden deneme + kismi yanit toleransi. Uzak saglayicilar (openai/claude/gemini/
    deepseek) KORUNUR: yalnizca local + custom bu toleransi alir."""
    inference = read_text("agent/mamidlabs-inference.ps1")

    assert "$retryableProvider = $provider -eq 'local' -or $provider -eq 'custom'" in inference
    assert "if (!$retryableProvider -or $networkRetried" in inference
    assert "Ozel uc baglantisi kesildi; bir kez yeniden baglaniliyor..." in inference
    assert "($provider -eq 'local' -or $provider -eq 'custom') -and $isReset -and !$shared.Cancel -and $usable" in inference
    # Uzak saglayicilar toleransa EKLENMEZ (yan etki minimal kalsin): yeni retry
    # kosulu yalnizca local/custom icerir.
    retry_lines = [line for line in inference.splitlines() if "retryableProvider" in line]
    assert retry_lines
    for line in retry_lines:
        assert "openai" not in line and "claude" not in line and "gemini" not in line and "deepseek" not in line


class _DropMidStreamHandler(BaseHTTPRequestHandler):
    """Icerik parcasi gonderip [DONE] olmadan RST ile baglantiyi kapatir
    (gercek custom uc/kopma senaryosu)."""

    protocol_version = "HTTP/1.1"

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        self.wfile.write(
            b"data: "
            + json.dumps({"choices": [{"index": 0, "delta": {"content": "Merhaba"}}]}).encode()
            + b"\n\n"
        )
        self.wfile.flush()
        time.sleep(1.0)
        self.connection.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
        try:
            self.connection.close()
        except OSError:
            pass
        self.close_connection = True

    def log_message(self, *args):
        pass


def test_custom_provider_dropped_stream_is_not_an_error(tmp_path):
    """D3 davranis: custom saglayici yanit metni urettikten sonra baglantiyi koparirsa
    bu HATA sayilmaz (cevabin altina '[Hata]' eklenmez); finish_reason 'connection-closed'
    olur ve disari istisna sizmaz."""
    pwsh = shutil.which("pwsh")
    if not pwsh:
        pytest.skip("pwsh bulunamadi")
    server = ThreadingHTTPServer(("127.0.0.1", 0), _DropMidStreamHandler)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        script = tmp_path / "custom-drop.ps1"
        base = f"http://127.0.0.1:{server.server_port}"
        script.write_text(
            f"""
$job = @{{ messages = @(@{{ role = 'user'; content = 'selam' }}); compactOnly = $true; provider = 'custom'; baseUrl = '{base}'; model = 'test'; contextLimit = 32768; maxTokens = 100; agent = $false; internet = $false; office = $false; documentCreate = $false }}
$shared = @{{ Cancel = $false }}
. '{ROOT}\\agent\\mamidlabs-inference.ps1' $job $shared | Out-Null
# compactOnly cikisinda betik kendi HttpClient'ini kapatir.
$script:http = [Net.Http.HttpClient]::new(); $script:http.Timeout = [Threading.Timeout]::InfiniteTimeSpan
$turn = @{{ reasoning = ''; content = ''; usage = $null; toolParts = @{{}}; finishReason = $null }}
$threw = $false
try {{
    Invoke-ChatCompletion @{{ model = 'test'; max_tokens = 100; messages = @() }} $shared $false $turn | Out-Null
}} catch {{
    $threw = [string]$_.Exception.GetBaseException().Message
}}
@{{ content = $turn.content; finish = $turn.finishReason; threw = $threw }} | ConvertTo-Json -Compress
""",
            encoding="utf-8-sig",
        )
        result = subprocess.run(
            [pwsh, "-NoProfile", "-NonInteractive", "-File", str(script)],
            capture_output=True, encoding="utf-8", errors="replace", check=False, timeout=60,
        )
    finally:
        server.shutdown()
    assert result.returncode == 0, result.stderr or result.stdout
    got = json.loads(result.stdout.strip().splitlines()[-1])
    assert got["content"] == "Merhaba", got
    assert got["finish"] == "connection-closed", got
    assert got["threw"] is False, got


def test_ocr_model_swap_keeps_json_response_separate_from_status_events():
    inference = read_text("agent/mamidlabs-inference.ps1")
    start = inference.index("function Invoke-ImageOcrWithModelSwap")
    end = inference.index("function Invoke-Tool", start)
    ocr_swap = inference[start:end]

    status_lines = [line for line in ocr_swap.splitlines() if "Emit 'status'" in line]
    assert status_lines
    assert all("| Out-Null" in line for line in status_lines)


def test_security_contracts_cover_ssrf_archive_and_local_output_paths():
    tools = read_text("agent/mamidlabs-agent-tools.py")
    office = read_text("agent/office-tools.py")
    media = read_text("agent/api-media.py")
    video_tools = read_text("agent/media-tools.py")
    ocr = read_text("agent/ocr-tools.py")
    imagegen = read_text("agent/imagegen-run.ps1")
    videogen = read_text("agent/videogen-run.ps1")

    assert "def _validate_remote_url" in tools
    assert "any(not address.is_global for address in addresses)" in tools
    assert "class _SafeRedirectHandler" in tools
    assert "_read_limited(response, MAX_PAGE_BYTES)" in tools
    assert "_read_limited(response, MAX_REFERENCE_BYTES)" in tools
    assert "request.get('out_dir')" not in tools
    assert "MAX_ARCHIVE_ENTRY_BYTES" in office
    assert "_read_archive_entry(stream" in office
    assert "zf.read(entry)" not in office
    assert "rf.read(entry)" not in office
    assert "decode_image_payload" in media
    assert "MAX_VIDEO_BYTES" in media
    assert "MAX_VIDEO_FILE_BYTES" in video_tools
    assert "candidate.relative_to(OUTPUT_ROOT)" in video_tools
    assert "MAX_RENDER_PIXELS" in ocr
    assert "Resolve-ComfyOutput" in imagegen
    assert "Resolve-ComfyOutput" in videogen
    assert "Remove-Item -LiteralPath $sourcePath" in imagegen
    assert "Remove-Item -LiteralPath $sourcePath" in videogen


def test_chat_history_remains_account_encrypted():
    desktop = read_text("mamidlabs-desktop.ps1")

    assert "MAMIDLABS-CHAT-DPAPI-V1" in desktop
    assert "Protect-ChatText $json" in desktop
    assert "Read-ChatData $file.FullName" in desktop
    assert "$loadedChatId -match '^[0-9a-fA-F]{32}$'" in desktop


def test_single_instance_check_verifies_the_window_class():
    """'MamidLabs' basligini tasiyan baska bir pencere (orn. Explorer'in
    TabProxyWindow'i ya da bir video/medya penceresi) yuzunden uygulama kendini
    'zaten acik' sanip HIC acilmiyordu (gercek makinede goruldu; arayuz smoke
    adimi 'pencere acilmadan kapandi' verdi). Tek-ornek denetimi artik yalnizca
    gercek WinForms penceresini (sinif adi WindowsForms10.*) kabul eder."""
    desktop = read_text("mamidlabs-desktop.ps1")
    assert "GetClassName" in desktop
    assert "WindowsForms10.*" in desktop
    # Sinif denetimi FindWindow sonucundan sonra ve erken return'den once olmali.
    idx_find = desktop.index("[MamidLabsWindow]::FindWindow([NullString]::Value, $appTitle)")
    idx_class = desktop.index("WindowsForms10.*", idx_find)
    idx_return = desktop.index("return", idx_find)
    assert idx_find < idx_class < idx_return


def test_remote_url_validation_blocks_local_and_non_http_targets():
    path = ROOT / "agent" / "mamidlabs-agent-tools.py"
    spec = importlib.util.spec_from_file_location("mamidlabs_agent_tools", path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)

    for url in ("http://127.0.0.1/", "http://169.254.169.254/", "file:///etc/passwd", "http://localhost/"):
        with pytest.raises(ValueError):
            module._validate_remote_url(url)


def test_archive_reader_stops_before_unbounded_memory_growth():
    path = ROOT / "agent" / "office-tools.py"
    spec = importlib.util.spec_from_file_location("office_tools", path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)

    class OversizedStream:
        def read(self, size):
            return b"x" * size

    with pytest.raises(ValueError):
        module._read_archive_entry(OversizedStream(), module.MAX_ARCHIVE_ENTRY_BYTES)


def test_previous_image_payload_is_not_kept_for_follow_up_messages():
    desktop = read_text("mamidlabs-desktop.ps1")
    inference = read_text("agent/mamidlabs-inference.ps1")

    assert "$turnHasImage = [bool]$script:currentTurnHasImage" in desktop
    assert "$script:currentTurnHasImage -and" in desktop
    assert "$script:currentTurnHasImage = $false" in desktop
    assert "Remove-PreviousImagePayload $history[$i]" in desktop
    assert "if ($jobEvent.data -and $jobEvent.data.direct)" in desktop
    assert "Sohbete eklenmis bir gorsel var." not in desktop
    assert "Sohbete bir gorsel eklendi;" not in inference


def test_powershell_scripts_parse():
    powershell = shutil.which("powershell") or shutil.which("pwsh")
    if not powershell:
        pytest.skip("PowerShell is unavailable")
    scripts = sorted(path.relative_to(ROOT)
                     for directory in (ROOT, ROOT / "agent", ROOT / "scripts")
                     for path in directory.glob("*.ps1"))
    with tempfile.TemporaryDirectory() as temp_dir:
        parse_paths = []
        for script in scripts:
            path = Path(temp_dir) / Path(script).name
            path.write_bytes((ROOT / script).read_bytes())
            parse_paths.append(path)

        for path in parse_paths:
            command = (
                "$tokens = $null; $parseErrors = $null; "
                "$source = [System.IO.File]::ReadAllText("
                + "'"
                + str(path).replace("'", "''")
                + "'); "
                + "$null = [System.Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$parseErrors); "
                + "if ($parseErrors.Count) { throw ($parseErrors | Out-String) }; "
            )
            result = subprocess.run(
                [powershell, "-NoProfile", "-NonInteractive", "-Command", command],
                capture_output=True,
                # PowerShell parse hatalari OS arayuz diline gore lokalize edilir (bu
                # oturumda Turkce Windows'ta gercek bir mojibake ile karsilasildi);
                # encoding verilmezse sistem kod sayfasi kullanilir ve hata metni
                # cozulemeyip stdout/stderr'i None birakabilir.
                encoding="utf-8", errors="replace",
                check=False,
            )
            assert result.returncode == 0, f"{path}: {result.stderr or result.stdout}"


def test_runtime_ocr_intent_matrix():
    # PowerShell 7 gerekir; conftest kurulu runtime\pwsh'u PATH'e ekler.
    pwsh = shutil.which("pwsh")
    if not pwsh:
        pytest.skip("PowerShell 7 is unavailable")

    # mamidlabs-inference.ps1 $root'u kendi konumundan turetir; ROOT uzerinden dot-source edilir.
    script = r"""
$job = @{ messages = @(@{ role = 'user'; content = 'Gorseldeki metni oku' }); compactOnly = $true; provider = 'local'; model = 'test'; contextLimit = 32768; maxTokens = 1200; agent = $false; internet = $false; office = $false; documentCreate = $false }
$shared = @{ Cancel = $false }
. '__ROOT__\agent\mamidlabs-inference.ps1' $job $shared | Out-Null
foreach ($text in @('Gorseldeki metni oku', 'Bu görselde okuduklarını açıkla', 'Gorseldeki metni acikla', 'Gorselde ne var', 'Gorseldeki metni oku, guven skorunu belirt')) {
    Write-Output (('OCR=' + [bool](Test-OcrIntent $text)) + '|EXPLAIN=' + [bool](Test-OcrExplainIntent $text))
}
""".replace("__ROOT__", str(ROOT))

    with tempfile.NamedTemporaryFile(
        mode="w", suffix=".ps1", encoding="utf-8-sig", delete=False
    ) as handle:
        handle.write(script)
        script_path = Path(handle.name)
    try:
        result = subprocess.run(
            [str(pwsh), "-NoProfile", "-NonInteractive", "-File", str(script_path)],
            capture_output=True,
            # pwsh UTF-8 yazar; kodlama verilmezse Windows sistem kod sayfasi kullanilir
            # ve Turkce kurulumda (cp1254) cozumleme hatasi stdout'u None birakir
            # (bkz. tests/test_desktop_behavior.py -> run_ps ile ayni duzeltme).
            encoding="utf-8", errors="replace",
            check=False,
        )
    finally:
        script_path.unlink(missing_ok=True)
    assert result.returncode == 0, result.stderr or result.stdout
    lines = [line.strip() for line in result.stdout.splitlines() if line.strip()]
    assert lines == [
        "OCR=True|EXPLAIN=False",
        "OCR=True|EXPLAIN=True",
        "OCR=True|EXPLAIN=True",
        "OCR=False|EXPLAIN=False",
        "OCR=True|EXPLAIN=True",
    ]


def test_multi_image_ocr_is_an_explicit_one_turn_mode():
    desktop = read_text("mamidlabs-desktop.ps1")
    inference = read_text("agent/mamidlabs-inference.ps1")

    assert "$script:multiImageOcrMode = $false" in desktop
    assert "function Test-MultiImageOcrActivationIntent" in desktop
    assert "if ($activationIntent -and $allPaths.Count -eq 0)" in desktop
    assert "$multiImageRequested = $script:multiImageOcrMode -and $script:selectedImages.Count -gt 1" in desktop
    assert "Önce \"çoklu görsel okuma modunu aç\" mesajını gönderin" in desktop
    assert "multiImageOcrMode = [bool]$script:multiImageOcrMode" in desktop
    assert "$script:multiImageOcrMode = $false" in desktop[desktop.index("'done'"):]
    assert "Çoklu görsel okuma aktif — birden fazla görsel yükleyebilirsiniz." in desktop
    assert "$multiImageOcrRequested = [bool]$JobData.multiImageOcrMode" in inference
    assert "function Invoke-ImageOcrWithModelSwap([string[]]$paths, [bool]$waitForRestore = $true)" in inference
    assert "Yerel model yükleniyor; hazır olduğunda görsel/sohbet devam edecek" in inference
    assert "if (!$script:multiImageOcrMode -and $script:selectedImages.Count -ge 1)" in desktop


def test_generated_artifacts_can_be_opened_directly():
    """Uretilen dosya (gorsel/video/belge) sohbet balonundan tek tikla acilabilmeli."""
    desktop = read_text("mamidlabs-desktop.ps1")
    assert "function Open-BubbleArtifact" in desktop
    assert "Open-BubbleArtifact $this.Tag" in desktop
    assert "Start-Process -FilePath $path" in desktop
    assert "openFile = $null" in desktop
    assert "$openFile.Text" in desktop


def test_update_check_uses_a_github_token_for_the_private_repo():
    """Private depoda releases/latest 404 doner; guncelleme denetimi/indirmesi bir GitHub
    tokeni kullanmali (GITHUB_TOKEN/GH_TOKEN ortam degiskeni ya da kayitli 'github' anahtari)."""
    catalog = read_text("agent/profile-catalog.ps1")
    assert "function Get-UpdateToken" in catalog
    assert "GITHUB_TOKEN" in catalog and "GH_TOKEN" in catalog
    assert "Authorization" in catalog
    assert "Bearer $token" in catalog


def test_system_prompt_requires_verification_and_forbids_fabrication():
    """Sabit sistem istemi (Get-SystemPrompt) modele kanitli/dogru cevap vermesini ve cok
    adimli islerde kritik adimlari/ara sonuclari tekrar gozden gecirmesini soyler; var
    oldugundan emin olmadigi test/teorem/kaynak adini uydurmasini yasaklar. Dogrulama
    talimati YUMUSATILDI: "IKI KEZ kontrol et" dusunmeyi sinirsizca uzatmayi tesvik edip
    LITE'ta cikti butcesini tuketerek gorunur yaniti engelleyebiliyordu; artik model
    YANITINI DE MUTLAKA YAZMAYA cagrilir. Talimat sabit oldugu icin onek degismez ve KV
    onbellegi bozulmaz."""
    desktop = read_text("mamidlabs-desktop.ps1")
    assert "Kanitli ve dogru cevap ver" in desktop
    assert "tekrar gozden gecir" in desktop
    assert "YANITINI DA MUTLAKA YAZ" in desktop
    assert "yanitsiz kalma" in desktop
    # Eski, dusunmeyi sinirsizca uzatan ifade kalmamali (regresyonun tetikleyicisi).
    assert "en az IKI KEZ kontrol et" not in desktop
    assert "test, teorem, ozdeslik veya kaynak adi KULLANMA" in desktop
    # Talimat sabit sistem isteminde olmali (tura ozel ipuclarinda degil).
    prompt = desktop[desktop.index("function Get-SystemPrompt"):desktop.index("function Get-TurnHints")]
    assert "YANITINI DA MUTLAKA YAZ" in prompt