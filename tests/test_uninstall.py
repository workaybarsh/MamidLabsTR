"""uninstall-mamidlabs.ps1: sahte bir kurulum kokunde gercekten silerek dogrulanir.

Kaldirici Windows PowerShell 5.1 ile calisir (gomulu PowerShell 7 de silinecegi icin);
testler de onu kullanir. Gercek masaustu ve kayit defteri yerine gecici bir masaustu
klasoru ve HKCU altinda test anahtari kullanilir.
"""
import os
import shutil
import subprocess
import sys
import time
import uuid
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "uninstall-mamidlabs.ps1"

pytestmark = pytest.mark.skipif(sys.platform != "win32", reason="Windows kaldiricisi")


def powershell():
    exe = shutil.which("powershell")
    if not exe:
        pytest.skip("Windows PowerShell yok")
    return exe


def ps(command, timeout=60):
    return subprocess.run([powershell(), "-NoProfile", "-NonInteractive", "-Command", command],
                          capture_output=True, text=True, timeout=timeout, encoding="utf-8", errors="replace")


def make_install(base: Path) -> Path:
    root = base / "MamidLabsKur"
    for folder in ("agent", "scripts", "assets", "models", "logs", "llama.cpp", "ComfyUI/models/loras", "venv/imagegen/Lib",
                   "runtime/pwsh", "tools/pip-cache", "tools/hf-home", "chats", "outputs/images", "settings"):
        (root / folder).mkdir(parents=True, exist_ok=True)
    (root / "agent/profiles.json").write_text("{}", encoding="utf-8")
    (root / "qwen-desktop.ps1").write_text("# app", encoding="utf-8")
    (root / "launch-qwen-desktop.vbs").write_text("' launcher", encoding="utf-8")
    (root / "models/model.gguf").write_bytes(b"x" * 1024)
    (root / "chats/sohbet.json").write_text("{}", encoding="utf-8")
    (root / "outputs/images/a.png").write_bytes(b"png")
    (root / "settings/api.json").write_text("{}", encoding="utf-8")
    # 260 karakteri asan derin bir yol: venv/ComfyUI'de gercekten olur.
    deep = root / "venv/imagegen/Lib" / ("d" * 60) / ("e" * 60) / ("f" * 60) / ("g" * 60)
    os.makedirs("\\\\?\\" + str(deep), exist_ok=True)
    with open("\\\\?\\" + str(deep / "x.py"), "w") as handle:
        handle.write("x")
    return root


def make_shortcut(desktop: Path, target_root: Path, name: str = "MamidLabs.lnk"):
    desktop.mkdir(parents=True, exist_ok=True)
    link = desktop / name
    result = ps(
        f"$s = (New-Object -ComObject WScript.Shell).CreateShortcut('{link}'); "
        f"$s.TargetPath = 'C:\\Windows\\System32\\wscript.exe'; $s.Arguments = '\"{target_root}\\launch-qwen-desktop.vbs\"'; "
        f"$s.WorkingDirectory = '{target_root}'; $s.Save()")
    assert result.returncode == 0, result.stderr
    return link


def run_uninstall(root: Path, desktop: Path, *args, registry="HKCU:\\Software\\MamidLabsTest-none"):
    command = [powershell(), "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(SCRIPT),
               "-Root", str(root), "-DesktopPath", str(desktop), "-UninstallRegistryPaths", registry, *args]
    return subprocess.run(command, capture_output=True, text=True, timeout=180, encoding="utf-8", errors="replace")


def test_full_uninstall_removes_everything_and_only_this_installs_shortcut(tmp_path):
    root = make_install(tmp_path)
    desktop = tmp_path / "Desktop"
    link = make_shortcut(desktop, root)
    other_desktop = tmp_path / "Desktop2"
    other_link = make_shortcut(other_desktop, tmp_path / "BaskaKurulum")

    result = run_uninstall(root, desktop, "-Yes")
    assert result.returncode == 0, result.stdout + result.stderr
    assert not root.exists(), result.stdout
    assert not link.exists()

    # Baska bir kopyaya isaret eden kisayola dokunulmaz.
    result = run_uninstall(make_install(tmp_path / "ikinci"), other_desktop, "-Yes")
    assert result.returncode == 0, result.stdout + result.stderr
    assert other_link.exists()


def test_second_install_shortcut_is_removed_and_the_other_install_keeps_its_own(tmp_path):
    """Ikinci kurulum MamidLabs.lnk'yi ezmez, "MamidLabs (<klasor>).lnk" acar; kaldirici onu siler."""
    root = make_install(tmp_path)
    desktop = tmp_path / "Desktop"
    main_link = make_shortcut(desktop, tmp_path / "AnaKurulum")
    second_link = make_shortcut(desktop, root, f"MamidLabs ({root.name}).lnk")
    result = run_uninstall(root, desktop, "-Yes")
    assert result.returncode == 0, result.stdout + result.stderr
    assert not second_link.exists()
    assert main_link.exists()


def test_installer_opens_a_separate_shortcut_when_another_install_owns_the_default():
    install = (ROOT / "scripts/install-mamidlabs.ps1").read_text(encoding="utf-8-sig")
    assert "'MamidLabs (' + (Split-Path -Leaf $Root) + ').lnk'" in install
    assert "MamidLabs acik; program dosyalari kilitli" in install


def test_keep_user_data_leaves_chats_outputs_and_settings(tmp_path):
    root = make_install(tmp_path)
    result = run_uninstall(root, tmp_path / "Desktop", "-Yes", "-KeepUserData")
    assert result.returncode == 0, result.stdout + result.stderr
    assert sorted(p.name for p in root.iterdir()) == ["chats", "outputs", "settings"]
    assert (root / "chats/sohbet.json").exists()


def test_foreign_files_are_kept_without_confirmation(tmp_path):
    root = make_install(tmp_path)
    (root / "benim-notlarim.txt").write_text("kisisel", encoding="utf-8")
    result = run_uninstall(root, tmp_path / "Desktop", "-Yes")
    assert result.returncode == 0, result.stdout + result.stderr
    assert [p.name for p in root.iterdir()] == ["benim-notlarim.txt"]


def test_dry_run_deletes_nothing(tmp_path):
    root = make_install(tmp_path)
    before = sorted(p.name for p in root.iterdir())
    result = run_uninstall(root, tmp_path / "Desktop", "-DryRun")
    assert result.returncode == 0, result.stdout + result.stderr
    assert "hicbir sey silinmedi" in result.stdout
    assert sorted(p.name for p in root.iterdir()) == before


def test_refuses_folders_that_are_not_a_mamidlabs_install(tmp_path):
    folder = tmp_path / "Belgelerim"
    folder.mkdir()
    (folder / "tez.docx").write_text("x", encoding="utf-8")
    result = run_uninstall(folder, tmp_path / "Desktop", "-Yes")
    assert result.returncode == 1
    assert (folder / "tez.docx").exists()


def test_stops_processes_running_from_the_install(tmp_path):
    root = make_install(tmp_path)
    # Uygulama/ComfyUI gibi komut satirinda kok yolunu tasiyan bir surec.
    marker = root / "scripts" / "bekle.ps1"
    marker.write_text("Start-Sleep -Seconds 120", encoding="utf-8")
    proc = subprocess.Popen([powershell(), "-NoProfile", "-File", str(marker)], cwd=str(tmp_path))
    try:
        time.sleep(2)
        result = run_uninstall(root, tmp_path / "Desktop", "-Yes")
        assert result.returncode == 0, result.stdout + result.stderr
        assert proc.wait(timeout=10) is not None
        assert not root.exists()
    finally:
        if proc.poll() is None:
            proc.kill()


def test_removes_only_the_uninstall_entry_of_this_root(tmp_path):
    root = make_install(tmp_path)
    base = f"HKCU:\\Software\\MamidLabsTest-{uuid.uuid4().hex[:8]}"
    setup = ps(
        f"New-Item -Path '{base}\\MamidLabs-bu' -Force | Out-Null; "
        f"Set-ItemProperty -Path '{base}\\MamidLabs-bu' -Name DisplayName -Value 'MamidLabs ({root})'; "
        f"Set-ItemProperty -Path '{base}\\MamidLabs-bu' -Name InstallLocation -Value '{root}\\'; "
        f"New-Item -Path '{base}\\MamidLabs-baska' -Force | Out-Null; "
        f"Set-ItemProperty -Path '{base}\\MamidLabs-baska' -Name DisplayName -Value 'MamidLabs (D:\\Baska)'; "
        f"Set-ItemProperty -Path '{base}\\MamidLabs-baska' -Name InstallLocation -Value 'D:\\Baska'")
    assert setup.returncode == 0, setup.stderr
    try:
        result = run_uninstall(root, tmp_path / "Desktop", "-Yes", registry=base)
        assert result.returncode == 0, result.stdout + result.stderr
        left = ps(f"(Get-ChildItem '{base}').PSChildName")
        assert left.stdout.split() == ["MamidLabs-baska"]
    finally:
        ps(f"Remove-Item -LiteralPath '{base}' -Recurse -Force")


def test_installers_keep_caches_inside_the_install_root():
    install = (ROOT / "scripts/install-mamidlabs.ps1").read_text(encoding="utf-8-sig")
    ocr = (ROOT / "scripts/install-ocr.ps1").read_text(encoding="utf-8-sig")
    hub = (ROOT / "agent/hf-hub.py").read_text(encoding="utf-8")
    assert "$env:PIP_CACHE_DIR = Join-Path $Root 'tools\\pip-cache'" in install
    assert "$env:PIP_CACHE_DIR = Join-Path $Root 'tools\\pip-cache'" in ocr
    assert hub.index("HF_HOME") < hub.index("from huggingface_hub import")


def test_wizard_uninstaller_runs_the_script_and_no_longer_deletes_foreign_shortcuts():
    iss = (ROOT / "packaging/windows/mamidlabs.iss").read_text(encoding="utf-8-sig")
    assert "uninstall-mamidlabs.ps1" in iss and "-Yes -FromWizard" in iss
    assert "{userdesktop}\\MamidLabs.lnk" not in iss
    assert "-InstallPrereqs -FromWizard" in iss


def test_uninstaller_is_ascii_for_windows_powershell_51():
    # 5.1 BOM'suz dosyayi ANSI okur; Turkce karakter sessizce bozulurdu.
    SCRIPT.read_bytes().decode("ascii")
