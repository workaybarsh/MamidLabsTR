"""Kurulumun iptali ve geri alinmasi.

Sihirbaz setup-run.ps1'i ewNoWait ile baslatir ve kendi mesaj kuyrugunu elle pompalar
(mamidlabs.iss PumpMessages); boylece kurulum surerken pencere yanit vermeye devam eder.
Iptal onaylanirsa taskkill /T ile alt surecler durdurulur, uninstall-mamidlabs.ps1 o ana
kadar kurulanlari kaldirir ve sihirbaz kapanir. Ayrintilar: AGENTS.md, tuzaklar.
"""
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
ISS = ROOT / "packaging" / "windows" / "mamidlabs.iss"


def read_text(path) -> str:
    return Path(path).read_text(encoding="utf-8-sig")


def pwsh_or_skip():
    pwsh = shutil.which("pwsh")
    if not pwsh:
        pytest.skip("PowerShell 7 is unavailable")
    return pwsh


# ------------------------------------------------------------------ iptal + geri alma

def test_installer_does_not_block_the_ui_thread_while_running_setup():
    iss = read_text(ISS)
    block = iss[iss.index("procedure CurStepChanged"):]
    assert "ewNoWait" in block
    # Tamamen bekleyen Exec mesaj dongusunu durdurur ve Iptal dugmesini kilitler.
    assert "ewWaitUntilTerminated, SetupExitCode" not in block


def test_installer_pumps_messages_so_the_cancel_button_stays_responsive():
    iss = read_text(ISS)
    assert "PeekMessageW" in iss and "TranslateMessage" in iss and "DispatchMessageW" in iss
    assert "procedure PumpMessages" in iss
    assert "PumpMessages;" in iss[iss.index("procedure CurStepChanged"):]


def test_installer_confirms_cancel_and_rolls_back_via_the_uninstaller():
    iss = read_text(ISS)
    assert "procedure CancelButtonClick" in iss
    cancel_block = iss[iss.index("procedure CancelButtonClick"):iss.index("procedure CurStepChanged")]
    assert "InstallRunning" in cancel_block
    assert "MsgBox(" in cancel_block and "MB_YESNO" in cancel_block

    step_block = iss[iss.index("procedure CurStepChanged"):]
    # Alt surecleri de (winget, pip, hf indirme) birlikte oldurur.
    assert "taskkill.exe" in step_block and "/T /F" in step_block
    # Ayni geri alma yolunu (Yes + FromWizard) CurUninstallStepChanged de kullanir.
    assert "uninstall-mamidlabs.ps1" in step_block
    assert "-Yes -FromWizard" in step_block or "' -Yes -FromWizard'" in step_block.replace('"', "'")
    # Abort tek basina yetmez: Inno'nun adim makinesi ssPostInstall'dan sonra Ozet/Bitis
    # sayfalarina gecer. Iptalde surec ExitProcess ile dogrudan sonlandirilir.
    assert "ExitProcess(1)" in step_block


def test_setup_run_writes_a_pid_file_and_a_completion_flag_for_the_wizard_to_poll():
    setup_run = read_text(ROOT / "scripts/setup-run.ps1")
    assert "kurulum.pid" in setup_run
    assert "kurulum-tamam.flag" in setup_run
    # Basarili/basarisiz/beklenmeyen istisna - hepsinde bayrak yazilmali, yoksa sihirbaz
    # sonsuza kadar bekler.
    assert setup_run.count("$doneFlag") >= 3
    assert "trap {" in setup_run


def test_setup_run_pid_and_done_flag_actually_get_written(tmp_path):
    """Betigin en basindaki PID/bayrak yazma kismini gercekten calistirip dogrular
    (tum betigi calistirmiyoruz - Windows'a ve gercek indirmelere ihtiyac duyar)."""
    pwsh = pwsh_or_skip()
    setup_run = read_text(ROOT / "scripts/setup-run.ps1")
    start = setup_run.index("$pidFile = Join-Path")
    end = setup_run.index("$steps = [Collections.Generic.List[object]]::new()")
    snippet = setup_run[start:end]
    logs = tmp_path / "logs"
    logs.mkdir()
    runner = tmp_path / "run.ps1"
    runner.write_text(
        f"$logs = '{logs}'\n" + snippet + "\nWrite-Output ('pid:' + (Get-Content -LiteralPath $pidFile))\n",
        encoding="utf-8-sig",
    )
    result = subprocess.run([pwsh, "-NoProfile", "-NonInteractive", "-File", str(runner)],
                            capture_output=True, text=True, timeout=30, encoding="utf-8", errors="replace")
    assert result.returncode == 0, result.stdout + result.stderr
    assert "pid:" in result.stdout
    assert not (logs / "kurulum-tamam.flag").exists()  # basta silinir, betik henuz bitmedi
