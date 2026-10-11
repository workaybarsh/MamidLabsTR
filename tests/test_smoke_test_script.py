"""scripts/smoke-test.ps1 sozlesmeleri.

Smoke testi kurulumdan sonra gercek modellerle sohbet, belge, OCR, gorsel, fotograf
duzenleme, medya sonrasi model gecisi ve video adimlarini dogrular. Bu dosya betigin
statik sozlesmelerini denetler; gercek calisma kurulu bir makinede yapilir.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read_text(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8-sig")


def test_every_component_can_be_skipped_independently():
    script = read_text("scripts/smoke-test.ps1")
    for flag in ("SkipChat", "SkipDocument", "SkipImage", "SkipVideo", "SkipUi"):
        assert f"[switch]${flag}" in script


def test_ui_step_launches_real_app_and_checks_mtp_and_no_connection_error():
    """Arayüz adımı: gerçek uygulamayı başlatır, pencere + model hazır olmasını
    doğrular, arayüzün kullandığı gerçek işçiyle bir tur atar ve 'sunucu kapatıldı'
    / watchdog metni olmadığını ve MTP'nin çalıştığını kanıtlar."""
    script = read_text("scripts/smoke-test.ps1")

    # Gerçek uygulama (masaüstü) başlatılır.
    assert "Join-Path $Root 'qwen-desktop.ps1'" in script
    assert "'-STA'" in script
    # Arayüz turu gerçek işçiyle (arayüzün kullandığı kod) çalışır.
    assert "agent\\qwen-inference.ps1" in script
    # MTP bayrağı ve gerçek draft kabulü doğrulanır.
    assert "--spec-type\\s+draft-mtp" in script
    assert "draft_n_accepted" in script
    # İstenmeyen bağlantı/kapanma metinleri LITERAL aranır (.Contains); -like "*[Hata]*"
    # PowerShell'de karakter sınıfı olur ve yanlış pozitif verir.
    assert "$joined.Contains($marker)" in script
    assert '-like "*$marker*"' not in script
    for marker in ("zorla kapat", "baglanti kesildi", "WSAECONNRESET", "[Hata]"):
        assert marker in script
    # Adım mutlaka raporlanır.
    assert "Report 'arayuz'" in script


def test_ui_step_restores_settings_and_stops_the_server():
    """Uygulama kapanışta ayarları ezer ve kendi sunucusunu durdurur; adım
    ayarları yedekleyip geri yüklemeli ve sunucuyu kapatmalı."""
    script = read_text("scripts/smoke-test.ps1")
    assert "mamidlabs-smoke-settings-backup" in script
    assert "Copy-Item -LiteralPath $settingsDir -Destination $settingsBackup" in script
    assert "Copy-Item -LiteralPath $settingsBackup -Destination $settingsDir" in script
    # finally bloğunda sunucu durdurulur.
    assert "& $manage -Action stop" in script


def test_smoke_test_has_ui_chat_step():
    """Arayuzu KULLANICI gibi suren adim: yazi kutusuna yazar, Gonder'e basar ve yanit
    geldigini dogrular (Gonder->Durdur->Gonder gecisi). Mevcut 'arayuz' adimi isciyi
    dogrudan cagirir; bu adim arayuzun gercek kullanici yolunu sinar."""
    script = read_text("scripts/smoke-test.ps1")
    assert "Write-Section 'Arayuz sohbet" in script
    assert "Report 'arayuz_sohbet'" in script
    assert "ValuePattern" in script  # yazi kutusuna yazar
    assert "0x00F5" in script        # BM_CLICK (Gonder)


def test_smoke_test_closes_leftover_comfyui():
    """Gorsel/video adimlari ComfyUI'yi acik birakir; arayuz adimi uygulamayi Force ile
    oldurdugu icin Shutdown-All calismaz. Test sonunda (ve arayuz adiminin finally'sinde)
    bosta kalan ComfyUI kapatilir; yoksa dil modeli onun uzerine yuklenip VRAM tasar
    (gercek makinede olculdu: 0,89 tok/s)."""
    script = read_text("scripts/smoke-test.ps1")
    assert "& $manage -Action closecomfy" in script
    # Belt-and-suspenders: kalan python ComfyUI sureci de oldurulur.
    assert "ComfyUI\\main.py" in script


def test_each_component_reports_pass_or_fail_independently():
    """Bir bilesen basarisiz olursa digerleri yine de denenmeli; erken cikis olmamali."""
    script = read_text("scripts/smoke-test.ps1")

    # Her blok kendi try/catch'i icinde, ust seviyede $ErrorActionPreference='Stop'
    # olsa bile bir adimin hatasi digerini engellememeli.
    assert script.count("} catch {") >= 4
    assert script.count("Report '") >= 4


def test_exit_code_reflects_overall_result():
    script = read_text("scripts/smoke-test.ps1")

    assert "exit 1" in script
    assert "exit 0" in script


def test_image_and_video_checks_require_the_model_file_first():
    """Model dosyasi yoksa ComfyUI'yi bos yere baslatmadan acik hata vermeli."""
    script = read_text("scripts/smoke-test.ps1")

    assert "Once Profiller menusunden indir" in script
    # Lite'ta unet (GGUF), diger profillerde diffusion_models altinda aranir.
    assert "models\\unet" in script
    assert "models\\diffusion_models" in script


def test_document_check_uses_a_real_docx_round_trip():
    """Mock degil: python-docx ile gercek dosya olusturulup office-tools.py ile
    geri okunmali; isaret metni ciktida aranmali."""
    script = read_text("scripts/smoke-test.ps1")

    assert "from docx import Document" in script
    assert "office-tools.py" in script
    assert "marker" in script.lower()


def test_ocr_check_covers_both_gpu_and_cpu_engines():
    """RTX 4060 Laptop uzerinde olculdu: dev-branch RTX-50 wheel'i Ada mimarisinde
    de gercekten calisiyor (guven 0.999), sadece 'ready:true' donup bos sonuc
    vermiyor. GPU icin duz gorsel, CPU icin taranmis PDF yolu ayri ayri test
    edilir; bunlar farkli kod yollaridir (ocr_image vs ocr_pdf)."""
    script = read_text("scripts/smoke-test.ps1")

    assert "[switch]$SkipOcr" in script
    assert "action = 'ocr_image'" in script
    assert "action = 'ocr_pdf'" in script
    assert r"venv\ocr\Scripts\python.exe" in script
    assert r"venv\ocr-cpu\Scripts\python.exe" in script


def test_readme_documents_the_smoke_test():
    readme = read_text("README.md")
    assert "smoke-test.ps1" in readme


def test_image_and_video_jobdata_pass_root():
    """Gorsel/video jobData'si 'root' alanini tasimalidir. imagegen-run.ps1/videogen-run.ps1
    Start-ThreadJob -FilePath ile calistigi icin $PSScriptRoot bostur (bkz.
    test_install_root_portability.py); JobData.root olmadan (Get-Location).Path'e
    dusup smoke-test.ps1'in CALISTIRILDIGI klasoru (kaynak agac) kok saniyordu,
    "Gorsel/video ortami bulunamadi: ...kaynak-agac\\venv\\imagegen\\..." hatasi
    veriyordu - -Root parametresi tamamen yok sayiliyordu."""
    script = read_text("scripts/smoke-test.ps1")
    image_block = script.split("Write-Section 'Gorsel uretimi'")[1].split("Write-Section 'Video uretimi'")[0]
    video_block = script.split("Write-Section 'Video uretimi'")[1]
    assert "root = $Root" in image_block
    assert "root = $Root" in video_block


def test_chat_check_matches_production_request_shape():
    """Gercek makinede yakalandi: chat testi ham /v1/chat/completions'i
    reasoning_effort='low' olmadan ve max_tokens=200 ile cagiriyordu. Lite'in
    sunucu tarafinda zorlanan dusunme butcesi (300 token, bkz. manage-qwen.ps1
    $liteThinkBudget) bu limiti tek basina tuketip gercek icerik uretmeden
    kesiyordu - "Model bos yanit dondurdu" hatasi. Gercek uretim istegi
    (qwen-inference.ps1 icindeki Set-LowEffortRequest) reasoning_effort'u
    her zaman gonderir; smoke test de ayni sekli kullanmali."""
    script = read_text("scripts/smoke-test.ps1")
    # Istek Invoke-ChatProbe'dadir; sohbet adimi ve medya sonrasi gecis adimi ayni sekli kullanir.
    assert "$probe = Invoke-ChatProbe" in script.split("Write-Section 'Sohbet modeli'")[1].split("Write-Section 'Belge okuma")[0]
    chat_block = script.split("function Invoke-ChatProbe")[1].split("\n}\n")[0]
    assert "reasoning_effort = 'low'" in chat_block
    assert "chat_template_kwargs = @{ reasoning_effort = 'low' }" in chat_block
    # 200 token dusunme butcesinin (300) tamamini tuketebilir; gercekci bir pay birakilmali.
    assert "max_tokens = 200" not in chat_block


def test_document_check_uses_a_valid_office_tools_action():
    """Gercek makinede yakalandi: office-tools.py'nin ACTIONS tablosunda
    'read_document' diye bir islem yok (yalnizca read_docx/read_pdf/... var;
    'read_document' yalnizca qwen-inference.ps1 icindeki arac ADI, uzantiya
    gore dogru action'a orada cevrilir). Smoke test office-tools.py'yi
    dogrudan cagirdigi icin gercek action adini kullanmali - yanlis olursa
    "bilinmeyen islem" hatasi verir, testin kendisi hep basarisiz olur."""
    script = read_text("scripts/smoke-test.ps1")
    doc_block = script.split("Write-Section 'Belge okuma")[1].split("Write-Section 'OCR")[0]
    assert "action = 'read_docx'" in doc_block
    assert "action = 'read_document'" not in doc_block


def test_media_swap_check_measures_speed_after_image_generation():
    """Gorsel sonrasi model gecisi (8 GB LITE): gorsel adimi dil modelini gercek
    uygulamadaki gibi bosaltip geri yukler, sonraki adim hizi ilk olcumle karsilastirir."""
    script = read_text("scripts/smoke-test.ps1")
    image_block = script.split("Write-Section 'Gorsel uretimi'")[1].split("Write-Section 'Fotograf duzenleme")[0]
    assert "restoreProfile = $(if ($script:chatBaseline) { $Profile } else { '' })" in image_block
    swap_block = script.split("Write-Section 'Medya sonrasi model gecisi'")[1].split("Write-Section 'Video uretimi'")[0]
    assert "Wait-ForHealth 180" in swap_block
    assert "$ratio -lt $MinSpeedRatio" in swap_block
    assert "Get-FreeVramMiB" in swap_block
    assert "[double]$MinSpeedRatio = 0.7" in script


def test_smoke_test_writes_a_machine_readable_report():
    script = read_text("scripts/smoke-test.ps1")
    assert "smoke-test-son.json" in script
    assert "ConvertTo-Json -Depth 6" in script
    # Atlanan adim basarisiz sayilmaz ama ozette gorunur.
    assert "skipped = $true" in script


def test_history_resume_step_guards_empty_tool_exchange():
    """Arac cagrilmadiysa $done.data BOS dizi olur ve Start-ThreadJob sinirindan $null doner;
    @($done.data) bunu @($null) yapip listeye bos mesaj ekler ve sunucu 400 verir
    ("All non-assistant messages must contain 'content'"). Adim gercek arayuz gibi
    `if ($done.data)` ile korumali ve yuklenen gecmis icin >=1 mesaj yeterli olmali."""
    script = read_text("scripts/smoke-test.ps1")
    assert "if ($done.data) { $chatMessages += @($done.data) }" in script
    # Model arac cagirmadan yanitlarsa yalnizca kullanici mesaji kaydedilir; >=1 yeterli.
    assert "$reloaded.Count -lt 1" in script
