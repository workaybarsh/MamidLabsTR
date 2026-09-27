"""Kopyalanmadan (dosya yoluyla) eklenen gorsel/video modelleri.

agent/media-paths.ps1 gercek fonksiyonlari calistirilir: ComfyUI'ye verilen
extra_model_paths YAML'i, degismeyen icerigin yeniden yazilmamasi ve model adinin
harici listeden cozulmesi.
"""
import json
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]


def run_ps(tmp_path, body):
    pwsh = shutil.which("pwsh")
    if not pwsh:
        pytest.skip("PowerShell 7 is unavailable")
    script = tmp_path / "test.ps1"
    script.write_text(
        "$ErrorActionPreference = 'Stop'\n"
        f". '{ROOT / 'agent' / 'media-paths.ps1'}'\n"
        "function Assert($condition, [string]$message) { if (!$condition) { throw $message } }\n"
        f"$root = '{tmp_path}'\n" + body,
        encoding="utf-8-sig",
    )
    result = subprocess.run([pwsh, "-NoProfile", "-NonInteractive", "-File", str(script)],
                            cwd=tmp_path, capture_output=True, text=True, timeout=60,
                            encoding="utf-8", errors="replace")
    assert result.returncode == 0, result.stdout + result.stderr
    return result.stdout


def make_models(tmp_path):
    ext = tmp_path / "harici disk"
    (ext / "krea").mkdir(parents=True)
    (ext / "wan").mkdir()
    (ext / "krea" / "krea2_turbo_fp8_scaled.safetensors").write_bytes(b"x")
    (ext / "krea" / "krea2_turbo-Q4_K_M.gguf").write_bytes(b"x")
    (ext / "wan" / "wan2.2_ti2v_5B_fp16.safetensors").write_bytes(b"x")
    (ext / "other.safetensors").write_bytes(b"x")
    return ext


def test_yaml_groups_folders_by_comfy_model_type(tmp_path):
    ext = make_models(tmp_path)
    run_ps(tmp_path, f"""
$models = @()
$models = Add-ExternalMediaModel $models '{ext / 'krea' / 'krea2_turbo_fp8_scaled.safetensors'}' 'image'
$models = Add-ExternalMediaModel $models '{ext / 'krea' / 'krea2_turbo-Q4_K_M.gguf'}' 'image'
$models = Add-ExternalMediaModel $models '{ext / 'wan' / 'wan2.2_ti2v_5B_fp16.safetensors'}' 'video'
$models = Add-ExternalMediaModel $models '{ext / 'wan' / 'wan2.2_ti2v_5B_fp16.safetensors'}' 'video'
Assert ($models.Count -eq 3) "ayni yol iki kez eklenmemeli: $($models.Count)"
[void](Write-ComfyExtraModelPaths $root $models)
""")
    yaml = (tmp_path / "settings" / "comfy-extra-models.yaml").read_text(encoding="utf-8")
    krea = str(ext / "krea").replace("\\", "/")
    wan = str(ext / "wan").replace("\\", "/")
    assert "mamidlabs_harici:" in yaml
    assert yaml.count(krea) == 2  # diffusion_models ve unet altinda
    assert yaml.count(wan) == 1
    assert "    unet: |\n        " + krea in yaml


def test_unsupported_architecture_is_rejected(tmp_path):
    ext = make_models(tmp_path)
    run_ps(tmp_path, f"""
try {{ Add-ExternalMediaModel @() '{ext / 'other.safetensors'}' 'image'; throw 'hata bekleniyordu' }}
catch {{ Assert ($_.Exception.Message -like '*desteklenmiyor*') $_.Exception.Message }}
try {{ Add-ExternalMediaModel @() '{ext / 'yok.safetensors'}' 'video'; throw 'hata bekleniyordu' }}
catch {{ Assert ($_.Exception.Message -like '*bulunamad*') $_.Exception.Message }}
""")


def test_unchanged_yaml_is_not_rewritten_and_empty_list_removes_it(tmp_path):
    ext = make_models(tmp_path)
    run_ps(tmp_path, f"""
$models = Add-ExternalMediaModel @() '{ext / 'wan' / 'wan2.2_ti2v_5B_fp16.safetensors'}' 'video'
$yaml = Write-ComfyExtraModelPaths $root $models
(Get-Item $yaml).LastWriteTime = [datetime]'2020-01-01'
[void](Write-ComfyExtraModelPaths $root $models)
Assert ((Get-Item $yaml).LastWriteTime -eq [datetime]'2020-01-01') 'degismeyen icerik ComfyUI yeniden baslatmasin'
Assert ($null -eq (Write-ComfyExtraModelPaths $root @())) 'bos liste null donmeli'
Assert (!(Test-Path $yaml)) 'bos liste dosyayi silmeli'
""")


def test_model_name_resolves_from_the_saved_external_list(tmp_path):
    ext = make_models(tmp_path)
    settings = tmp_path / "settings"
    settings.mkdir()
    (settings / "api.json").write_text(json.dumps({"externalMediaModels": [
        {"kind": "image", "path": str(ext / "krea" / "krea2_turbo-Q4_K_M.gguf")},
    ]}), encoding="utf-8")
    out = run_ps(tmp_path, """
@{
  unet = Resolve-ExternalMediaModel $root 'krea2_turbo-Q4_K_M.gguf' 'unet'
  wrongFolder = Resolve-ExternalMediaModel $root 'krea2_turbo-Q4_K_M.gguf' 'diffusion_models'
  traversal = Resolve-ExternalMediaModel $root '..\\krea2_turbo-Q4_K_M.gguf' 'unet'
} | ConvertTo-Json -Compress
""")
    result = json.loads(out)
    assert result["unet"] == "krea2_turbo-Q4_K_M.gguf"
    assert result["wrongFolder"] is None
    assert result["traversal"] is None


def test_comfy_receives_the_extra_paths_and_restarts_when_they_change():
    swap = (ROOT / "agent/media-model-swap.ps1").read_text(encoding="utf-8-sig")
    assert "'--extra-model-paths-config', $extraPaths" in swap
    assert "LastWriteTime -gt $existing.StartTime" in swap
    for path in ("agent/imagegen-run.ps1", "agent/videogen-run.ps1"):
        assert "Resolve-ExternalMediaModel $root $name" in (ROOT / path).read_text(encoding="utf-8-sig")


def test_media_dialog_offers_in_place_use_before_copying():
    dialog = (ROOT / "agent/media-settings.ps1").read_text(encoding="utf-8-sig")
    assert "Add-ExternalMediaModel" in dialog
    assert "Write-ComfyExtraModelPaths" in dialog
    registry = (ROOT / "agent/model-registry.ps1").read_text(encoding="utf-8-sig")
    assert "OpenFileDialog" in registry and "Multiselect=$true" in registry
