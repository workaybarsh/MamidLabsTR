import subprocess
import shutil
import tempfile
import importlib.util
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[1]


def read_text(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8-sig")


def test_model_profiles_use_max_flash_and_lite_names():
    registry = read_text("agent/model-registry.ps1")
    manager = read_text("scripts/manage-qwen.ps1")

    assert "builtin-max" in registry
    assert "builtin-flash" in registry
    assert "builtin-xhigh" not in registry
    assert "builtin-low" not in registry
    assert "builtin-lite" in registry
    assert "ValidateSet('max', 'flash', 'lite')" in manager
    assert "--reasoning-effort', $reasoningEffort" in manager


def test_ocr_only_returns_text_without_explanation_request():
    inference = read_text("agent/qwen-inference.ps1")

    assert "function Test-OcrExplainIntent" in inference
    assert "$ocrDirect = !(Test-OcrExplainIntent $userText)" in inference
    assert "if ($ocrDirect)" in inference
    assert "Emit 'done' ([string]$ocrResult.text)" in inference
    assert "Emit 'done' $directPdfText" in inference


def test_image_ocr_swaps_local_model_and_command_tool_uses_approval():
    inference = read_text("agent/qwen-inference.ps1")
    ocr = read_text("agent/ocr-tools.py")
    desktop = read_text("qwen-desktop.ps1")

    assert "function Invoke-ImageOcrWithModelSwap" in inference
    assert "action = 'ocr_image'; path = [string]$paths[0]; device = 'gpu'" in inference
    assert "& (Get-ManageQwenPath) -Action stop" in inference
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
    assert "multiImageOcr = [bool]$script:currentTurnMultiImageOcr" in desktop
    assert "$dlg.Multiselect = [bool]$script:multiImageOcrMode" in desktop
    assert "Önce \"çoklu görsel okuma modunu aç\" mesajını gönderin" in desktop


def test_multi_image_selection_is_preserved_until_send_validation():
    desktop = read_text("qwen-desktop.ps1")

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
    inference = read_text("agent/qwen-inference.ps1")

    assert "$videoModes = @('metin', 'gorsel')" in inference
    assert "$videoModes += 'video'" in inference
    assert "mode=video kullanma." in inference


def test_ocr_model_swap_keeps_json_response_separate_from_status_events():
    inference = read_text("agent/qwen-inference.ps1")
    start = inference.index("function Invoke-ImageOcrWithModelSwap")
    end = inference.index("function Invoke-Tool", start)
    ocr_swap = inference[start:end]

    status_lines = [line for line in ocr_swap.splitlines() if "Emit 'status'" in line]
    assert status_lines
    assert all("| Out-Null" in line for line in status_lines)


def test_security_contracts_cover_ssrf_archive_and_local_output_paths():
    tools = read_text("agent/qwen-agent-tools.py")
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
    desktop = read_text("qwen-desktop.ps1")

    assert "MAMIDLABS-CHAT-DPAPI-V1" in desktop
    assert "Protect-ChatText $json" in desktop
    assert "Read-ChatData $file.FullName" in desktop
    assert "$loadedChatId -match '^[0-9a-fA-F]{32}$'" in desktop


def test_remote_url_validation_blocks_local_and_non_http_targets():
    path = ROOT / "agent" / "qwen-agent-tools.py"
    spec = importlib.util.spec_from_file_location("qwen_agent_tools", path)
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
    desktop = read_text("qwen-desktop.ps1")
    inference = read_text("agent/qwen-inference.ps1")

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

    # qwen-inference.ps1 $root'u kendi konumundan turetir; ROOT uzerinden dot-source edilir.
    script = r"""
$job = @{ messages = @(@{ role = 'user'; content = 'Gorseldeki metni oku' }); compactOnly = $true; provider = 'local'; model = 'test'; contextLimit = 32768; maxTokens = 1200; agent = $false; internet = $false; office = $false; documentCreate = $false }
$shared = @{ Cancel = $false }
. '__ROOT__\agent\qwen-inference.ps1' $job $shared | Out-Null
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
    desktop = read_text("qwen-desktop.ps1")
    inference = read_text("agent/qwen-inference.ps1")

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
