"""7-Zip (RAR açma) ve Visual C++ Redistributable ön koşulları.

Bulgu: `rarfile` paketi kurulu olsa da gerçek RAR açma işini yapan `7z`/`unrar`
hiçbir yerde kurulmuyordu; office-tools.py yalnızca var olmayan bir
`tools\\7zip\\7z.exe` yoluna bakıyordu. Aynı şekilde native derlemelerin (ör.
`llama-server.exe`) genelde ihtiyaç duyduğu Visual C++ Redistributable hiç
kontrol edilmiyordu. Çözüm: ikisi de winget ile diğer ön koşullar (Python, Git)
gibi otomatik kuruluyor; office-tools.py standart Program Files konumlarına
bakıyor.
"""
import re
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]


def read_text(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8-sig")


def run_pwsh_functions(script: str) -> str:
    pwsh = shutil.which("pwsh")
    if not pwsh:
        pytest.skip("PowerShell 7 is unavailable")
    prelude = r"""
$ErrorActionPreference = 'Stop'
function Get-Functions([string]$path) {
    $tokens=$null; $errs=$null
    $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errs)
    if ($errs.Count) { throw ($errs | Out-String) }
    return (($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.FunctionDefinitionAst] } | ForEach-Object { $_.Extent.Text }) -join "`n")
}
"""
    proc = subprocess.run(
        [pwsh, "-NoProfile", "-Command", prelude + script],
        capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=30,
    )
    if proc.returncode != 0:
        raise AssertionError(f"pwsh basarisiz oldu: {proc.stderr}")
    return proc.stdout


def test_setup_run_installs_7zip_and_vcredist_via_winget():
    setup_run = read_text("scripts/setup-run.ps1")
    assert "Install-WithWinget '7zip.7zip' '7-Zip'" in setup_run
    assert "Install-WithWinget 'Microsoft.VCRedist.2015+.x64' 'Visual C++ Redistributable'" in setup_run
    # Eksikse kurulumu tumden durdurmamali (RAR/VC++ Redistributable eksikligi
    # sohbeti/gorsel uretimini engellemez) - yalnizca not dusulur.
    assert "7-Zip yok; RAR açma çalışmayabilir" in setup_run


def test_office_tools_checks_standard_program_files_locations_for_sevenzip():
    office_tools = read_text("agent/office-tools.py")
    assert "ProgramFiles" in office_tools
    assert "ProgramFiles(x86)" in office_tools
    assert "7-Zip" in office_tools


def test_install_ocr_falls_back_to_official_paddle_channel_and_checks_exit_codes():
    """paddle-qa.bj.bcebos.com bir QA/nightly sunucusudur, PyPI gibi kalicilik
    garantisi vermez; kaldirilirsa resmi kararli kanala (paddlepaddle.org.cn)
    dusulmeli. Ayrica pip cagrilarinin $LASTEXITCODE'u kontrol edilmeli - eskiden
    kontrol edilmiyordu, basarisiz bir kurulum sessizce "basarili" sayilabiliyordu."""
    install_ocr = read_text("scripts/install-ocr.ps1")
    assert "paddlepaddle.org.cn/packages/stable" in install_ocr
    assert install_ocr.count("if ($LASTEXITCODE -ne 0)") >= 3


def test_vcredist_check_is_false_and_does_not_throw_when_windir_is_missing():
    """Linux/kisitli ortamlarda WINDIR tanimsiz olabilir; Join-Path'e dogrudan null
    vermek terminating error firlatir (gercek CI'da bulundu ve duzeltildi).
    Test-VCRedistReady WINDIR'a bakar; onsuz sonuc deterministik olarak False'tur."""
    out = run_pwsh_functions(rf"""
Invoke-Expression (Get-Functions '{ROOT / "scripts" / "setup-run.ps1"}')
Remove-Item Env:\WINDIR -ErrorAction SilentlyContinue
Write-Output ('vc:' + (Test-VCRedistReady))
""")
    assert "vc:False" in out


def test_seven_zip_check_does_not_throw_when_program_files_env_vars_are_missing():
    """Test-SevenZipReady ProgramFiles/ProgramFiles(x86)'a bakar; onlar tanimsizken
    Join-Path'e null vermek terminating error firlatiyordu (gercek CI'da bulundu ve
    duzeltildi). Sonucun kendisi (True/False) makineye gore degisir - ornegin
    GitHub'in windows-latest calistiricisinda 7-Zip zaten kurulu geliyor - o yuzden
    yalnizca cokmedigi denetleniyor, belirli bir deger degil."""
    out = run_pwsh_functions(rf"""
Invoke-Expression (Get-Functions '{ROOT / "scripts" / "setup-run.ps1"}')
Remove-Item Env:\ProgramFiles -ErrorAction SilentlyContinue
Remove-Item 'Env:\ProgramFiles(x86)' -ErrorAction SilentlyContinue
Write-Output ('7zip:' + (Test-SevenZipReady))
""")
    assert re.search(r"7zip:(True|False)", out)
