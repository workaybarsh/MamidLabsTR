"""8 GB VRAM / 16 GB RAM Lite profili ve profil kataloğu sözleşmeleri."""
import json
import re
import shutil
import subprocess
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[1]


def read_text(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8-sig")


def parse_alias_table(text: str, variable: str) -> dict:
    """@{ max = 'a'; flash = 'b'; lite = 'c' } biçimindeki tabloyu sözlüğe çevirir."""
    match = re.search(re.escape(variable) + r"\s*=\s*@\{([^}]*)\}", text)
    assert match, f"{variable} tablosu bulunamadı"
    return dict(re.findall(r"(\w+)\s*=\s*'([^']+)'", match.group(1)))


# --------------------------------------------------------------- profil tanımı

def test_manager_accepts_lite_profile():
    manager = read_text("scripts/manage-qwen.ps1")

    assert "ValidateSet('max', 'flash', 'lite')" in manager
    # Lite ayrı bir 9B modeli kullanır; 27B dosyasına düşmemeli.
    assert "Huihui-Qwen3.5-9B-abliterated.i1-Q5_K_M.gguf" in manager
    assert "$desiredAlias = $profileAliases[$Profile]" in manager


def test_alias_tables_agree_between_manager_and_registry():
    """İki dosyadaki alias tablosu ayrışırsa model geri yükleme yanlış profile döner."""
    manager = parse_alias_table(read_text("scripts/manage-qwen.ps1"), "$profileAliases")
    registry = parse_alias_table(read_text("agent/model-registry.ps1"), "$script:localProfileAliases")

    assert manager == registry
    assert set(manager) == {"max", "flash", "lite"}
    assert len(set(manager.values())) == 3


def test_alias_table_is_reachable_when_only_functions_are_loaded():
    """Tablo dosya seviyesinde kalirsa, sadece fonksiyonlari yukleyen cagrilarda
    (davranis testleri, kismi dot-source) null uzerinde metot cagrilir."""
    registry = read_text("agent/model-registry.ps1")

    assert "function Get-LocalProfileAliases" in registry
    assert registry.index("function Get-LocalProfileAliases") < registry.index("$script:localProfileAliases = @{")
    # Tabloya dogrudan erisim kalmamali; hepsi erisimci uzerinden gecmeli.
    assert "$script:localProfileAliases[" not in registry
    assert "$script:localProfileAliases.ContainsKey" not in registry


def test_lite_stays_within_eight_gigabyte_budget():
    """32K baglam gercek donanimda (RTX 4060 Laptop) olculdu. Q4_K_M ile VRAM
    kullanimi 6198 MiB (1759 MiB bos kalir, rahat pay). Kullanici Q5_K_M'i
    varsayilan yapmayi tercih etti: 7500 MiB (~450-500 MiB bos kalir, dar ama
    kabul edilen bir pay - llama.cpp kendi otomatik sigdirma kontrolu bunu
    "tam sigmiyor" diye isaretler ama --gpu-layers 99 elle zorlandigi icin
    yine de yukler; performans dusmez (~35 tok/s, Q4'ten yalnizca ~%13 yavas)."""
    manager = read_text("scripts/manage-qwen.ps1")
    lite_block = manager.split("if ($Profile -eq 'lite') {", 1)[1]

    assert "$liteFile = 'Huihui-Qwen3.5-9B-abliterated.i1-Q5_K_M.gguf'" in lite_block
    assert "$liteCtx = '32768'" in lite_block
    assert "'--ctx-size', $liteCtx" in manager
    assert "'--batch-size', '256', '--ubatch-size', '128'" in manager
    # Projektör yoksa Lite metin-only çalışmalı, hata vermemeli.
    assert "$Profile -ne 'lite' -and !(Test-Path -LiteralPath $projector" in manager
    assert "if ($projector) { $serverArgs += @('--mmproj', $projector" in manager


def test_settings_are_loaded_before_the_profile_reads_them():
    """$settings profil blokundan sonra atanirsa liteModel/liteContext sessizce yok sayilir."""
    manager = read_text("scripts/manage-qwen.ps1")

    assigned = manager.index("$settings = Get-Content -LiteralPath $settingsPath")
    used = manager.index("$settings.liteModel")
    assert assigned < used, "ayarlar kullanildiktan sonra okunuyor"


def test_registry_exposes_lite_entry_matching_server_context():
    """32K baglam gercek makinede olculdu (bkz. test_lite_stays_within_eight_gigabyte_budget);
    UI'nin contextLimit'i (baglam sikistirma esigini belirler) sunucunun gercek
    --ctx-size'iyla eslesmeli, aksi halde sikistirma gereginden erken/gec tetiklenir."""
    registry = read_text("agent/model-registry.ps1")

    assert "id = 'builtin-lite'; label = 'Qwen3.5 9B LITE'; profile = 'lite'" in registry
    assert "contextLimit = 32768" in registry
    assert "function Get-ProfileFromAlias" in registry


def test_model_bar_only_lists_profiles_with_chat_files_present():
    """MAX kurulu bir PC'de LITE de (ya da tersi) alt barda seçilebilir görünüyordu;
    seçilince manage-qwen.ps1 dosya bulunamadı hatası veriyordu. Artık yalnızca dil
    modeli dosyaları diskte olan profiller listelenir."""
    registry = read_text("agent/model-registry.ps1")
    catalog = read_text("agent/profile-catalog.ps1")

    assert "function Get-BuiltinProfileDefinitions" in registry
    assert "if (Test-LocalProfileChatFilesPresent $def.profile)" in registry
    assert "function Test-LocalProfileChatFilesPresent" in catalog
    # ComfyUI medya modelleri sohbet icin gerekmez, denetim disi tutulmali.
    assert "-notmatch '^ComfyUI" in catalog


def test_chat_files_present_ignores_missing_comfyui_media_but_requires_llm_files(tmp_path):
    """MAX kurulu bir PC'de LITE (ya da tersi) alt barda görünmemeli. Dil modeli
    dosyaları eksikse profil "hazır değil" sayılmalı; ComfyUI medya dosyaları eksik
    olsa bile (-SkipMedia ile kurulmuş olabilir) sohbet için "hazır" sayılmalı."""
    pwsh = shutil.which("pwsh")
    if not pwsh:
        pytest.skip("PowerShell 7 is unavailable")

    (tmp_path / "models" / "max").mkdir(parents=True)
    (tmp_path / "models" / "max" / "model.gguf").write_bytes(b"x")
    (tmp_path / "models" / "max" / "mmproj.gguf").write_bytes(b"x")
    catalog_json = {
        "profiles": [
            {"id": "max", "files": [
                {"target": "models/max/model.gguf"},
                {"target": "models/max/mmproj.gguf"},
                {"target": "ComfyUI/models/diffusion_models/missing.safetensors"},
            ]},
            {"id": "lite", "files": [
                {"target": "models/lite/model.gguf"},
                {"target": "models/lite/mmproj.gguf"},
            ]},
        ]
    }
    (tmp_path / "agent").mkdir()
    (tmp_path / "agent" / "profiles.json").write_text(json.dumps(catalog_json), encoding="utf-8")

    catalog_path = str(ROOT / "agent" / "profile-catalog.ps1").replace("\\", "\\\\")
    root_arg = str(tmp_path).replace("\\", "\\\\")
    script = rf"""
$ErrorActionPreference = 'Stop'
function Get-Functions([string]$path) {{
    $tokens=$null; $errs=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errs)
    if ($errs.Count) {{ throw ($errs | Out-String) }}
    return (($ast.EndBlock.Statements | Where-Object {{ $_ -is [Management.Automation.Language.FunctionDefinitionAst] }} | ForEach-Object {{ $_.Extent.Text }}) -join "`n")
}}
$root = '{root_arg}'
Invoke-Expression (Get-Functions '{catalog_path}')
Write-Output ('max:' + (Test-LocalProfileChatFilesPresent 'max'))
Write-Output ('lite:' + (Test-LocalProfileChatFilesPresent 'lite'))
"""
    proc = subprocess.run([pwsh, "-NoProfile", "-Command", script], capture_output=True, text=True, timeout=30)
    assert proc.returncode == 0, proc.stderr
    assert "max:True" in proc.stdout, proc.stdout
    assert "lite:False" in proc.stdout, proc.stdout


def test_desktop_resolves_profile_through_alias_helper():
    desktop = read_text("qwen-desktop.ps1")

    # Eski "-like '*-flash'" türetmesi üç yerde vardı; lite'ı max sanıyordu.
    assert "-like '*-flash'" not in desktop
    assert desktop.count("Get-ProfileFromAlias") == 3
    # Model yuklenirken (ornek: ses turu yuklemeyi gecersiz kildiginda) aktif alias henuz
    # yok olabilir; o durumda SECILI profile dusulur (yanlis profil baslatilmaz).
    assert "else { Get-SelectedLocalAlias }" in desktop
    assert "'builtin-lite' { 'lite'; break }" in desktop


def test_lite_thinks_without_a_reasoning_budget():
    """Qwen3.5 sablonu --reasoning-effort'u yok sayar; LITE'a artik dusunme BUTCESI konmaz
    (kullanici istegi): sunucuya `--reasoning-budget` verilmez, model lazim oldugu kadar
    (gerektigi kadar uzun) dusunur. Dusunme acik kalir (--reasoning on, deepseek formati) ve
    sistem istemi modele derin dusunmesini, suresini kisitlamamasini soyler."""
    manager = read_text("scripts/manage-qwen.ps1")
    desktop = read_text("qwen-desktop.ps1")

    assert "--reasoning-budget" not in manager
    assert "$liteThinkBudget" not in manager
    assert "$settings.liteReasoningBudget" not in manager
    # Dusunme yine acik ve deepseek formatiyla.
    assert "'--reasoning', 'on'" in manager
    assert "'--reasoning-format', 'deepseek'" in manager
    # Derin dusunme talimati ve sureyi kisitlamama vurgusu.
    assert "Düşünme suresini KISITLAMA" in desktop


def test_mtp_speculative_decoding_is_enabled_when_model_has_mtp_layers():
    """Qwen3.8 27B GGUF'u gomulu bir MTP/nextn draft basligi tasir (nextn_predict_layers=1,
    blk.64.nextn.*); LITE'in 9B GGUF'una da indirme sirasinda ayni baslik eklenir
    (agent/mtp_inject.py). --spec-type draft-mtp AYRI draft model gerektirmez ve cikti
    kayipsizdir. Bayrak yalnizca model gercekten MTP katmani tasiyorsa eklenir; tasimayan
    modele verilirse llama.cpp "model doesn't contain MTP layers" ile acilmaz."""
    manager = read_text("scripts/manage-qwen.ps1")

    assert "'--spec-type', 'draft-mtp'" in manager
    # MTP katmani olan her profil (max/flash/lite) icin; custom haric, GGUF kontroluyle.
    assert "if (!$custom -and $mtpEnabled -and (Test-GgufHasMtp $model))" in manager
    # settings.mtp ile kapatilabilmeli.
    assert "$settings.mtp" in manager
    assert "$mtpEnabled = $true" in manager
    # GGUF basliginda MTP tensoru arayan guvenlik kontrolu.
    assert "function Test-GgufHasMtp" in manager
    assert "nextn" in manager


def test_thinking_is_never_switched_off_in_requests():
    """Dusunme urun kararidir: istekler yalnizca cabayi ayarlar (reasoning_effort), ozelligi kapatmaz."""
    inference = read_text("agent/qwen-inference.ps1")

    assert "enable_thinking" not in inference
    assert "function Set-LowEffortRequest" in inference
    # Tanim + baglam sikistirma + ana istek + bos yanit tekrari.
    assert inference.count("Set-LowEffortRequest") == 4
    assert "$body.reasoning_effort = 'low'" in inference


def test_lite_system_prompt_encourages_deep_reasoning():
    """LITE icin sistem istemine derin/adim adim akil yurutme talimati eklenir; bu
    satir yalnizca lite profilinde bulunur (onek profile gore sabit oldugu icin KV
    onbellegi bozulmaz) ve sinirsiz dusunme suresinde daha dogru sonuca yonlendirir."""
    desktop = read_text("qwen-desktop.ps1")

    assert "Derin ve dikkatli dusun" in desktop
    # Yalnizca LITE profilinde eklenir.
    idx = desktop.index("Derin ve dikkatli dusun")
    block = desktop[max(0, idx - 700):idx]
    assert "$script:apiSettings.localProfile -eq 'lite'" in block
    # Dusunme ozelligini kapatmaz; yalnizca yonlendirir.
    assert "enable_thinking" not in desktop


# ------------------------------------------------------------------ medya yolu

def test_lite_image_uses_krea2_gguf_via_shared_workflow():
    """Kullanici istegiyle: Z-Image kalitesi yetersiz bulundu, Lite de MAX/FLASH
    ile ayni Krea-2 Turbo'yu kullanacak sekilde degistirildi - yalnizca tam
    hassasiyetli (.safetensors, ~13,1 GB, 8 GB karta sigmaz) yerine GGUF
    kuantize (Q4_K_M, ~7,5 GB) surumu ve ComfyUI-GGUF custom node'unun
    'UnetLoaderGGUF' dugumu kullanilir. Ayri bir New-LiteWorkflow artik yok -
    tek New-Workflow fonksiyonu $lite parametresine gore dallanır (kod
    tekrarini onlemek icin, #17'deki media-model-swap.ps1 deseniyle ayni ruh)."""
    imagegen = read_text("agent/imagegen-run.ps1")

    assert "function New-LiteWorkflow" not in imagegen
    assert "class_type = 'UnetLoaderGGUF'" in imagegen
    assert "krea2_turbo-Q4_K_M.gguf" in imagegen
    assert "$workflow = New-Workflow $mode $JobData.prompt $width $height $seed $steps $refName $strength $realism $realismStrength $lite" in imagegen
    # GGUF dosyalari ComfyUI-GGUF custom node'unun aradigi models\unet altinda.
    assert "$modelFolder = if ($lite) { 'models\\unet' }" in imagegen
    assert "Start-OrReuseComfy $python $comfyDir $comfyOut $comfyIn $logs $comfyUrl $lite" in imagegen


def test_lite_image_supports_style_reference_and_realism_like_max_flash():
    """Kullanici istegiyle: gercekcilik/stil referansi LoRA'lari artik Lite'ta
    da MAX/FLASH ile ayni sekilde calisir - sessizce baska moda dusme veya
    devre disi birakma yok (Z-Image AIO mimarisinde bu LoRA'lar hic yoktu,
    simdi hepsi ayni Krea-2 mimarisini paylasiyor)."""
    imagegen = read_text("agent/imagegen-run.ps1")

    assert "if ($lite -and $mode -eq 'stil_referansi')" not in imagegen
    assert "if ($lite) { $realism = $false }" not in imagegen
    # Stil referansi LoRA dosyasi eksikse (lite dahil) acik hata verilmeli.
    assert "if ($mode -eq 'stil_referansi' -and !(Test-Path -LiteralPath $styleLora -PathType Leaf))" in imagegen


def test_lite_video_caps_resolution_and_duration():
    videogen = read_text("agent/videogen-run.ps1")

    assert "function Limit-LiteResolution" in videogen
    assert "$maxSeconds = if ($lite) { 3 } else { 5 }" in videogen
    assert "$capped = Limit-LiteResolution $width $height" in videogen
    assert "Start-OrReuseComfy $python $comfyDir $comfyOut $comfyIn $logs $comfyUrl $lite" in videogen
    # Comfy-Org deposunda ti2v_5B'nin fp8'i yok; Lite de fp16 dosyasını kullanır.
    assert "wan2.2_ti2v_5B_fp8_scaled" not in videogen
    assert "tile_size = $tile.size" in videogen


# ------------------------------------------------------------- profil kataloğu

def load_catalog() -> dict:
    return json.loads(read_text("agent/profiles.json"))


def test_catalog_lists_every_profile_the_manager_accepts():
    catalog = load_catalog()
    ids = [profile["id"] for profile in catalog["profiles"]]

    assert ids == ["max", "flash", "lite"]
    for profile in catalog["profiles"]:
        assert profile["label"] and profile["hardware"] and profile["summary"]
        assert profile["files"], f"{profile['id']} dosyasız"


@pytest.mark.parametrize("field", ["label", "target"])
def test_catalog_files_carry_required_fields(field):
    for profile in load_catalog()["profiles"]:
        for entry in profile["files"]:
            assert entry.get(field), f"{profile['id']}: {field} boş"


def test_catalog_targets_stay_inside_the_install_root():
    for profile in load_catalog()["profiles"]:
        for entry in profile["files"]:
            target = entry["target"]
            assert not target.startswith("/"), target
            assert ":" not in target, target
            assert ".." not in target.split("/"), target
            assert "\\" not in target, target


def test_catalog_download_entries_are_complete():
    """repo dolu olan her satır indirilebilir olmalı: dosya yolu ve boyut şart."""
    for profile in load_catalog()["profiles"]:
        for entry in profile["files"]:
            if not entry["repo"]:
                # Kaynağı tanımlanmamış satırlar elle kurulur; boyut beklenmez.
                assert not entry["filename"]
                continue
            assert "/" in entry["repo"], entry["repo"]
            assert entry["filename"], entry["target"]
            assert entry["bytes"] > 0, entry["target"]


def test_every_profile_is_fully_downloadable():
    """Sihirbazda profil secip Ileri'ye basmak her seyi indirmeli: MAX/FLASH'in 27B
    dil modeli ve Identity Edit LoRA'si dahil hicbir satir elle kurulum gerektirmez."""
    for profile in load_catalog()["profiles"]:
        manual = [e["target"] for e in profile["files"] if not e["repo"]]
        assert not manual, f"{profile['id']} elle kurulum gerektiriyor: {manual}"

    lite = next(p for p in load_catalog()["profiles"] if p["id"] == "lite")
    names = [entry["target"].rsplit("/", 1)[-1] for entry in lite["files"]]
    assert "Huihui-Qwen3.5-9B-abliterated.i1-Q5_K_M.gguf" in names
    assert "krea2_turbo-Q4_K_M.gguf" in names
    assert "qwen3vl_4b_fp8_scaled.safetensors" in names
    assert "qwen_image_vae.safetensors" in names


def test_lite_language_model_matches_manager_default():
    """Katalogdaki GGUF ile manage-qwen.ps1'in açtığı dosya aynı olmalı."""
    lite = next(p for p in load_catalog()["profiles"] if p["id"] == "lite")
    gguf = [
        e
        for e in lite["files"]
        if e["target"].endswith(".gguf")
        and e["target"].startswith("models/Huihui-Qwen3.5-9B-abliterated-i1-GGUF/")
        and "mmproj" not in e["target"]
    ]

    assert len(gguf) == 1
    name = gguf[0]["target"].rsplit("/", 1)[-1]
    assert name in read_text("scripts/manage-qwen.ps1")
    # manage-qwen.ps1 dosyayı bu klasörde arar.
    assert gguf[0]["target"].startswith("models/Huihui-Qwen3.5-9B-abliterated-i1-GGUF/")


def test_pinned_revision_is_used_for_repackaged_wan_files():
    """Sürümü sabitlenmemiş indirme, depo güncellenince sessizce başka dosya getirir."""
    for profile in load_catalog()["profiles"]:
        for entry in profile["files"]:
            if entry["repo"] in (
                "Comfy-Org/Wan_2.2_ComfyUI_Repackaged",
                "Comfy-Org/Krea-2",
                "vantagewithai/Krea-2-Turbo-GGUF",
            ):
                assert re.fullmatch(r"[0-9a-f]{40}", entry.get("revision", "")), entry["target"]


# -------------------------------------------------------------- indirme akışı

def test_downloader_supports_multiple_files_without_token():
    hub = read_text("agent/hf-hub.py")

    assert "files = job.get('files')" in hub
    assert "def fetch(" in hub
    # Katalog depoları herkese açık; token zorunlu olmamalı.
    assert "raise ValueError('Önce Hugging Face tokenını kaydet.')" not in hub
    assert "yalnızca herkese açık depolar" in hub
    # Var olan dosya yeniden indirilmemeli.
    assert "if target.exists() and not item.get('force')" in hub


def test_downloader_rejects_paths_outside_the_repository():
    hub = read_text("agent/hf-hub.py")

    assert "def safe_repo_path" in hub
    assert "'..' in parts" in hub
    assert "safe_repo_path(item['filename'])" in hub


def test_profile_menu_is_wired_into_the_desktop():
    desktop = read_text("qwen-desktop.ps1")
    catalog = read_text("agent/profile-catalog.ps1")

    assert "profile-catalog.ps1')" in desktop
    assert "ToolStripMenuItem('Profiller')" in desktop
    # Menu sirasi: Dosya en solda, Görünüm ortada, Profiller en sagda.
    assert desktop.index("$menu.Items.Add($fileMenu)") < desktop.index("$menu.Items.Add($viewMenu)")
    assert desktop.index("$menu.Items.Add($viewMenu)") < desktop.index("$menu.Items.Add($profileMenu)")
    assert "$profileMenu.Add_DropDownOpening" in desktop

    for name in ("Get-ProfileCatalog", "Get-ProfileState", "Show-ProfileManager",
                 "Switch-ToProfile", "Start-ProfileDownload"):
        assert f"function {name}" in catalog


def test_profile_switch_blocks_while_busy():
    catalog = read_text("agent/profile-catalog.ps1")

    assert "if ($script:busy -or $script:imageBusy -or $script:pendingSend)" in catalog
    assert "if ($script:busy -or $script:imageBusy) { return 'Önce mevcut işlemin bitmesini bekle.' }" in catalog


def test_imagegen_and_videogen_share_a_single_model_swap_module():
    """Durdur/uret/geri yukle akisinin tek sahibi vardir: imagegen-run.ps1 ve
    videogen-run.ps1 agent/media-model-swap.ps1'i dot-source edip ayni
    Stop-LocalModelForMedia / Restore-LocalModelForMedia fonksiyonlarini
    kullanir - eski kopyalanmis "& $manage -Action stop" bekleme dongusu
    kalmamali."""
    for path in ("agent/imagegen-run.ps1", "agent/videogen-run.ps1"):
        text = read_text(path)
        assert ". (Join-Path $root 'agent\\media-model-swap.ps1')" in text
        assert "Stop-LocalModelForMedia $manage" in text
        assert "Restore-LocalModelForMedia $manage ([string]$JobData.restoreProfile) $false" in text
        assert "Restore-LocalModelForMedia $manage ([string]$JobData.restoreProfile) $true" in text
        # Eski kopyalanmis bekleme dongusu ve restore bloklari kalmamali.
        assert "@(Get-Process -Name 'llama-server' -ErrorAction SilentlyContinue).Count -gt 0) {" not in text


def test_restore_status_is_visible_on_cancel_and_error_too():
    """Olculdu: iptal sonrasi restoreProfile calisiyordu ama basari yolundaki
    'Dil modeli geri yukleniyor' durum mesaji catch bloginda yoktu; kullanici
    modelin neden geri geldigini gormeden sessiz bir bekleme yasiyordu. Artik
    tek yerde (media-model-swap.ps1) uygulanip her iki cagiri yolunda da
    (basari: $swallowError=$false, hata: $swallowError=$true) kullanilir."""
    swap = read_text("agent/media-model-swap.ps1")
    assert "function Restore-LocalModelForMedia" in swap
    assert 'Emit \'status\' "Dil modeli geri yukleniyor ($restoreProfile)..."' in swap


def test_restore_failure_inside_catch_block_is_surfaced_not_swallowed():
    """Hata/iptal sonrasi geri yukleme de basarisiz olursa (orn. model dosyasi
    tasindi, GPU mesgul) bu sessizce yutulmaz: media-model-swap.ps1
    $swallowError=$true iken hatayi metin olarak dondurur, cagiran bunu
    orijinal gorsel/video hatasiyla birlikte gosterir."""
    swap = read_text("agent/media-model-swap.ps1")
    assert "if ($swallowError) {" in swap
    assert "catch { return $_.Exception.Message }" in swap

    for path in ("agent/imagegen-run.ps1", "agent/videogen-run.ps1"):
        text = read_text(path)
        assert "Ayrica dil modeli geri yuklenemedi" in text
        # Eski sessiz yutma deseni ("try { ... } catch { }") artik kalmamali.
        assert "-Profile ([string]$JobData.restoreProfile) | Out-Null } catch { }" not in text
