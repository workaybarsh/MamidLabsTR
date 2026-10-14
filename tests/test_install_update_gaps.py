"""Kurulum/guncelleme dogruluk bosluklari icin regresyon testleri.

Altı duzeltmeyi kapsar:
1. Betik kurulumu ile uygulama ici guncelleme denetimi uyumu (DisplayVersion,
   Get-ScriptUninstallVersion yedegi).
2. Guncellemede bayat dosya temizligi (program klasorleri kopyalamadan once bosaltilir).
3. requirements\\ kokte (belgelenen -Stage layout komutu -Source verilmeden calisir).
4. .iss ile ayni dislama (agent\\__pycache__\\*, *.pyc; assets\\installer artik dahil).
5. Sihirbaz kaydi varken mukerrer betik kaydi acilmaz.
6. Kaldiricinin EULA.txt/requirements girdileri (test_uninstall.py'de ayrica).
"""
import shutil
import subprocess
import sys
import uuid
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]

pytestmark = pytest.mark.skipif(sys.platform != "win32", reason="Windows kurulum/kayit defteri")


def read_text(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8-sig")


def ps_body(body: str, script_path: str = "scripts/install-mamidlabs.ps1", extra: str = "", timeout: int = 60) -> str:
    pwsh = shutil.which("pwsh")
    if not pwsh:
        pytest.skip("PowerShell 7 is unavailable")
    path = str(ROOT / script_path).replace("\\", "\\\\")
    script = rf"""
$ErrorActionPreference = 'Stop'
function Get-Functions([string]$path) {{
    $tokens=$null; $errs=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errs)
    if ($errs.Count) {{ throw ($errs | Out-String) }}
    return (($ast.EndBlock.Statements | Where-Object {{ $_ -is [Management.Automation.Language.FunctionDefinitionAst] }} | ForEach-Object {{ $_.Extent.Text }}) -join "`n")
}}
Invoke-Expression (Get-Functions '{path}')
{extra}
{body}
"""
    proc = subprocess.run([pwsh, "-NoProfile", "-Command", script], capture_output=True, text=True,
                          timeout=timeout, encoding="utf-8", errors="replace")
    assert proc.returncode == 0, proc.stdout + proc.stderr
    return proc.stdout


# ------------------------------------------------------- statik: kopyalama/kok listeleri

def test_layout_root_creates_and_copies_requirements():
    """Belgelenen guncelleme komutu (install-mamidlabs.ps1 -Stage layout, -Source yok)
    bagimliliklari <root>\\requirements'tan okur; klasor kokte olusturulmali ve kopyalanmali."""
    script = read_text("scripts/install-mamidlabs.ps1")
    folders = script.split("$folders = @(")[1].split(")")[0]
    assert "'requirements'" in folders
    assert "$requirements = Join-Path $Source 'requirements'" in script
    assert "Copy-Item -LiteralPath $requirements -Destination $Root -Recurse -Force" in script


def test_layout_prunes_owned_program_dirs_before_copying():
    """Repodan silinen dosyalar guncellemede geride kalmamali: Inno ignoreversion ve
    Copy-Item -Force eski dosyayi silmez; program klasorleri once bosaltilir (ENG'deki
    gibi dordu de: agent, scripts, assets, requirements)."""
    script = read_text("scripts/install-mamidlabs.ps1")
    assert "function Remove-ProgramDir" in script
    assert "foreach ($folder in @('agent', 'scripts', 'assets', 'requirements')) {" in script
    assert "Remove-ProgramDir (Join-Path $Root $folder)" in script
    # Kaynagin kokun KENDISI oldugu durumda (kurulu kopyadan -Source'suz) kaynagi silmemek
    # ve kendi uzerine kopyalamamak icin atlanir.
    assert "if ($sourceInsideRoot) {" in script
    assert "$sourceInsideRoot = ($sourceFull -ieq $rootFull)" in script
    # Kaynagin kokun yalnizca ICINDE olmasi (sihirbazin kurulum-kaynak paketi) atlama nedeni DEGILDIR.
    assert "$sourceFull.StartsWith($rootFull" not in script
    # Kaynak paket tazelemesi de bosaltilir.
    assert "Remove-ProgramDir (Join-Path $kaynak $folder)" in script


def test_layout_applies_the_same_excludes_as_the_iss():
    script = read_text("scripts/install-mamidlabs.ps1")
    assert "function Remove-ProgramExcludes" in script
    assert "Remove-ProgramExcludes (Join-Path $Root 'agent')" in script
    assert "Remove-ProgramExcludes (Join-Path $kaynak 'agent')" in script


def test_layout_writes_display_version_and_accepts_app_version_override():
    script = read_text("scripts/install-mamidlabs.ps1")
    assert "[string]$AppVersion," in script
    assert "function Get-SourceAppVersion" in script
    assert "Get-SourceAppVersion" in script
    assert "$values['DisplayVersion'] = $version" in script
    # Surum tek kaynaktan: .iss MyAppVersion (MAJOR.MINOR.PATCH).
    assert "MyAppVersion\\s+\"(\\d+\\.\\d+\\.\\d+)\"" in script


def test_layout_skips_script_key_when_a_wizard_entry_owns_this_root():
    script = read_text("scripts/install-mamidlabs.ps1")
    assert "wizardOwnsThisRoot" in script
    assert "'*_is1'" in script
    assert "Windows kaldirma kaydi sihirbaz tarafindan zaten yazilmis" in script


def test_layout_from_install_root_without_source_does_not_self_copy(tmp_path):
    """Belgelenen komut kurulu kopyadan (-Source verilmeden) calistirilirsa kaynak=kok olur;
    program dosyalarini kendi uzerine kopyalamaya calismak 'kendi uzerine yazilamaz' hatasi
    verirdi. Artik bu durum atlanir ve komut basariyla doner (requirements kokte oldugu
    icin Read-Requirements onceki gibi erken durmaz)."""
    pwsh = shutil.which("pwsh")
    if not pwsh:
        pytest.skip("PowerShell 7 is unavailable")
    root = tmp_path / "MamidLabsKur"
    req = root / "requirements"
    req.mkdir(parents=True)
    (req / "app.txt").write_text("pytest", encoding="utf-8")
    (req / "imagegen.txt").write_text("", encoding="utf-8")
    (req / "asr.txt").write_text("", encoding="utf-8")
    proc = subprocess.run(
        [pwsh, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
         str(ROOT / "scripts/install-mamidlabs.ps1"),
         "-Root", str(root), "-Source", str(root), "-Stage", "layout", "-NoUninstallEntry"],
        capture_output=True, text=True, timeout=180, encoding="utf-8", errors="replace")
    assert proc.returncode == 0, proc.stdout + proc.stderr
    assert "Kaynak kurulum kokunun kendisi" in proc.stdout
    assert (req / "app.txt").exists()


def test_layout_from_wizard_nested_source_copies_program_files(tmp_path):
    """Sihirbaz kaynak paketi {kok}\\kurulum-kaynak altina acar ve installer'i
    `-Root {kok} -Source {kok}\\kurulum-kaynak` ile cagirir; kaynak kokun ICINDE olmasina
    ragmen program dosyalari koke kopyalanmalidir. Eski prefix kontrolu yuzunden kaynak
    'zaten yerinde' sanilip atlaniyor, taze kurulum bos kaliyordu (ayrica kaynak paketi
    kendi uzerine kopyalanip betik duruyordu)."""
    pwsh = shutil.which("pwsh")
    if not pwsh:
        pytest.skip("PowerShell 7 is unavailable")
    root = tmp_path / "MamidLabsWiz"
    kaynak = root / "kurulum-kaynak"
    # Read-Requirements betik yuklenirken $Source\requirements'dan okur.
    req = kaynak / "requirements"
    req.mkdir(parents=True)
    for name in ("app.txt", "imagegen.txt", "asr.txt"):
        (req / name).write_text("", encoding="utf-8")
    # Her program klasorune bir olcu (probe) dosyasi koy.
    for folder in ("agent", "scripts", "assets", "requirements"):
        (kaynak / folder).mkdir(parents=True, exist_ok=True)
        (kaynak / folder / "probe-marker.txt").write_text("probe", encoding="utf-8")
    proc = subprocess.run(
        [pwsh, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
         str(ROOT / "scripts/install-mamidlabs.ps1"),
         "-Root", str(root), "-Source", str(kaynak), "-Stage", "layout", "-NoUninstallEntry"],
        capture_output=True, text=True, timeout=180, encoding="utf-8", errors="replace")
    assert proc.returncode == 0, proc.stdout + proc.stderr
    # Kaynak kokun icinde olmasina ragmen "zaten yerinde" denip atlanmamali.
    assert "Kaynak kurulum kokunun kendisi" not in proc.stdout
    assert "Program dosyalari kopyalandi" in proc.stdout
    # Sihirbazin kullandigi bu yolda dort program klasoru de koke kopyalanmali.
    for folder in ("agent", "scripts", "assets", "requirements"):
        assert (root / folder / "probe-marker.txt").exists(), proc.stdout + proc.stderr
    # Kaynak paket kendi uzerine kopyalanip bosaltilmamali.
    assert (kaynak / "agent" / "probe-marker.txt").exists(), proc.stdout + proc.stderr


# ------------------------------------------------ islevsel: Get-SourceAppVersion

def test_get_source_app_version_reads_iss_and_ignores_non_semver(tmp_path):
    src = tmp_path / "src"
    (src / "packaging/windows").mkdir(parents=True)
    iss = src / "packaging/windows/mamidlabs.iss"
    iss.write_text('; surum\n#define MyAppVersion "2.3.4"\n', encoding="utf-8")
    out = ps_body(f"$Source = '{src}'\nWrite-Output ('v:' + (Get-SourceAppVersion))")
    assert "v:2.3.4" in out
    # x.y.z disi deger kabul edilmez (sessizce bozuk surum yazilmaz).
    iss.write_text('#define MyAppVersion "1.2"\n', encoding="utf-8")
    out = ps_body(f"$Source = '{src}'\nWrite-Output ('v:' + (Get-SourceAppVersion))")
    assert "v:1.2" not in out


# ------------------------------------- islevsel: Remove-ProgramDir / Excludes

def test_remove_program_dir_removes_a_whole_tree(tmp_path):
    owned = tmp_path / "assets"
    (owned / "icons").mkdir(parents=True)
    (owned / "icons/a.ico").write_bytes(b"x")
    out = ps_body(f"Remove-ProgramDir '{owned}'\nWrite-Output ('gone:' + (!(Test-Path -LiteralPath '{owned}')))")
    assert "gone:True" in out


def test_remove_program_excludes_leaves_real_files(tmp_path):
    agent = tmp_path / "agent"
    (agent / "transcriber/__pycache__").mkdir(parents=True)
    (agent / "transcriber/__pycache__/x.pyc").write_bytes(b"x")
    (agent / "transcriber/keep.py").write_text("x", encoding="utf-8")
    (agent / "old.pyc").write_bytes(b"x")
    assets = tmp_path / "assets"
    (assets / "installer").mkdir(parents=True)
    (assets / "installer/side.bmp").write_bytes(b"x")
    (assets / "icons").mkdir()
    (assets / "icons/a.ico").write_bytes(b"x")
    body = f"""
Remove-ProgramExcludes '{agent}'
Write-Output ('pycache:' + (Test-Path -LiteralPath '{agent}\\transcriber\\__pycache__'))
Write-Output ('oldpyc:' + (Test-Path -LiteralPath '{agent}\\old.pyc'))
Write-Output ('keep:' + (Test-Path -LiteralPath '{agent}\\transcriber\\keep.py'))
Write-Output ('installer:' + (Test-Path -LiteralPath '{assets}\\installer'))
Write-Output ('icons:' + (Test-Path -LiteralPath '{assets}\\icons\\a.ico'))
"""
    out = ps_body(body)
    assert "pycache:False" in out
    assert "oldpyc:False" in out
    assert "keep:True" in out
    assert "installer:True" in out
    assert "icons:True" in out


# ------------------------------- islevsel: Get-ScriptUninstallVersion (guncelleme)

def test_updater_reads_version_from_the_script_uninstall_key(tmp_path):
    base = f"HKCU:\\Software\\MamidLabsGapTest-{uuid.uuid4().hex[:8]}"
    root = tmp_path / "MamidLabsKur"
    root.mkdir()
    body = f"""
New-Item -Path '{base}\\MamidLabs-abcd1234' -Force | Out-Null
Set-ItemProperty -Path '{base}\\MamidLabs-abcd1234' -Name DisplayName -Value 'MamidLabs ({root})'
Set-ItemProperty -Path '{base}\\MamidLabs-abcd1234' -Name InstallLocation -Value '{root}'
Set-ItemProperty -Path '{base}\\MamidLabs-abcd1234' -Name DisplayVersion -Value '2.5.0'
Write-Output ('v:' + (Get-ScriptUninstallVersion -InstallRoot '{root}' -RegistryPaths @('{base}')))
"""
    try:
        out = ps_body(body, script_path="agent/profile-catalog.ps1")
        assert "v:2.5.0" in out
    finally:
        subprocess.run([shutil.which("powershell") or shutil.which("pwsh"), "-NoProfile", "-Command",
                        f"Remove-Item -LiteralPath '{base}' -Recurse -Force -ErrorAction SilentlyContinue"],
                       capture_output=True)


def test_script_key_version_must_match_this_install_root(tmp_path):
    """Baska bir koke kurulu kopyanin surumu yanlislikla okunmamali."""
    base = f"HKCU:\\Software\\MamidLabsGapTest-{uuid.uuid4().hex[:8]}"
    root = tmp_path / "MamidLabsKur"
    root.mkdir()
    body = f"""
New-Item -Path '{base}\\MamidLabs-baska' -Force | Out-Null
Set-ItemProperty -Path '{base}\\MamidLabs-baska' -Name DisplayName -Value 'MamidLabs (D:\\Baska)'
Set-ItemProperty -Path '{base}\\MamidLabs-baska' -Name InstallLocation -Value 'D:\\Baska'
Set-ItemProperty -Path '{base}\\MamidLabs-baska' -Name DisplayVersion -Value '9.9.9'
Write-Output ('v:' + (Get-ScriptUninstallVersion -InstallRoot '{root}' -RegistryPaths @('{base}')))
"""
    try:
        out = ps_body(body, script_path="agent/profile-catalog.ps1")
        assert "9.9.9" not in out
    finally:
        subprocess.run([shutil.which("powershell") or shutil.which("pwsh"), "-NoProfile", "-Command",
                        f"Remove-Item -LiteralPath '{base}' -Recurse -Force -ErrorAction SilentlyContinue"],
                       capture_output=True)
