"""Bagli klasor yollari ve run_command kacislari.

1) Kucuk modeller relative_path'e bazen bagli klasoru de iceren tam (rooted) bir yol
   yazar. Join-Path bunu klasorun onune ekleyip ikilenmis, gecersiz bir yol uretirdi.
   Resolve-BoundTarget rooted yolu dogrudan kullanir; klasor disindaki yol reddedilir.
2) Ic ice tirnakli komutlar (powershell -Command "if (...) { ... }") /c argumani
   olarak verilince .NET'in \\" kacisi cmd.exe ile uyusmaz. Komut gecici bir .cmd
   dosyasina yazilip calistirilir.
3) .cmd dosyasinda eslesmeyen "%" sessizce silinir ("42 % 2" -> "42  2"). Eslesen
   "%VAR%" ciftleri korunur, tek basina "%" "%%" olarak kacislanir.
"""
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]

PRELUDE = r"""
$ErrorActionPreference = 'Stop'
# Python ciktiyi UTF-8 cozer; konsol kod sayfasi farkliysa (or. Turkce Windows'ta
# cp1254) Turkce karakterler bozulup testi ortama gore kararsiz yapiyordu. Cikti
# kodlamasini sabitleyerek testi deterministik hale getir.
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
function Get-Functions([string]$path) {
    $tokens=$null; $errs=$null
    $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errs)
    if ($errs.Count) { throw ($errs | Out-String) }
    return (($ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.FunctionDefinitionAst] } | ForEach-Object { $_.Extent.Text }) -join "`n")
}
"""


def run_pwsh_functions(script: str) -> str:
    pwsh = "pwsh"
    try:
        proc = subprocess.run(
            [pwsh, "-NoProfile", "-Command", PRELUDE + script],
            capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=30,
        )
    except FileNotFoundError:
        pytest.skip("PowerShell 7 is unavailable")
    if proc.returncode != 0:
        raise AssertionError(f"pwsh basarisiz oldu: {proc.stderr}")
    return proc.stdout


def test_rooted_relative_path_inside_bound_folder_resolves_without_doubling(tmp_path):
    inference_path = str(ROOT / "agent" / "mamidlabs-inference.ps1").replace("\\", "\\\\")
    folder = str(tmp_path).replace("\\", "\\\\")
    rooted = str(tmp_path / "fibonacci.py").replace("\\", "\\\\")
    out = run_pwsh_functions(rf"""
$JobData = @{{ root = '{tmp_path}' }}
$Shared = [hashtable]::Synchronized(@{{ AccessMode = 'full'; Cancel = $false }})
Invoke-Expression (Get-Functions '{inference_path}')
$folder = '{folder}'
$a = [pscustomobject]@{{ relative_path = '{rooted}'; content = 'print(1)' }}
Write-Output ('r:' + (Invoke-Tool 'write_bound_file' $a $folder))
""")
    line = next(ln for ln in out.splitlines() if ln.startswith("r:"))
    assert line.startswith("r:Yazildi"), line
    assert (tmp_path / "fibonacci.py").read_text(encoding="utf-8") == "print(1)"


def test_rooted_relative_path_outside_bound_folder_is_still_rejected(tmp_path):
    """Guvenlik siniri korunmali: rooted bir yol bagli klasorun disindaysa yine reddedilir."""
    inference_path = str(ROOT / "agent" / "mamidlabs-inference.ps1").replace("\\", "\\\\")
    bound = tmp_path / "bound"
    bound.mkdir()
    outside = tmp_path / "outside.py"
    folder = str(bound).replace("\\", "\\\\")
    outside_arg = str(outside).replace("\\", "\\\\")
    out = run_pwsh_functions(rf"""
$JobData = @{{ root = '{tmp_path}' }}
$Shared = [hashtable]::Synchronized(@{{ AccessMode = 'full'; Cancel = $false }})
Invoke-Expression (Get-Functions '{inference_path}')
$folder = '{folder}'
$a = [pscustomobject]@{{ relative_path = '{outside_arg}'; content = 'print(2)' }}
Write-Output ('r:' + (Invoke-Tool 'write_bound_file' $a $folder))
""")
    line = next(ln for ln in out.splitlines() if ln.startswith("r:"))
    assert "disina cikilamaz" in line
    assert not outside.exists()


def test_normal_relative_path_is_unaffected(tmp_path):
    inference_path = str(ROOT / "agent" / "mamidlabs-inference.ps1").replace("\\", "\\\\")
    folder = str(tmp_path).replace("\\", "\\\\")
    out = run_pwsh_functions(rf"""
$JobData = @{{ root = '{tmp_path}' }}
$Shared = [hashtable]::Synchronized(@{{ AccessMode = 'full'; Cancel = $false }})
Invoke-Expression (Get-Functions '{inference_path}')
$folder = '{folder}'
$a = [pscustomobject]@{{ relative_path = 'normal.py'; content = 'print(3)' }}
Write-Output ('r:' + (Invoke-Tool 'write_bound_file' $a $folder))
""")
    line = next(ln for ln in out.splitlines() if ln.startswith("r:"))
    assert line == "r:Yazildi: normal.py (8 karakter)"


def test_run_command_survives_nested_quoted_powershell_command(tmp_path):
    """Eskiden bu tam sekilde 'if' satirini calistirmadan oldugu gibi yazdiriyordu
    (cmd.exe /c'ye dogrudan argument olarak verilen komutun ic ice tirnaklari
    bozuluyordu). Artik komut gecici bir .cmd dosyasina yazilip calistiriliyor."""
    inference_path = str(ROOT / "agent" / "mamidlabs-inference.ps1").replace("\\", "\\\\")
    folder = str(tmp_path).replace("\\", "\\\\")
    out = run_pwsh_functions(rf"""
$JobData = @{{ root = '{tmp_path}' }}
$Shared = [hashtable]::Synchronized(@{{ AccessMode = 'full'; Cancel = $false }})
Invoke-Expression (Get-Functions '{inference_path}')
$folder = '{folder}'
$a = [pscustomobject]@{{ command = 'powershell -NoProfile -Command "if (1 -eq 1) {{ Write-Host yes }} else {{ Write-Host no }}"' }}
Write-Output ('r:' + (Invoke-Tool 'run_command' $a $folder))
""")
    result = out.split("r:", 1)[1]
    assert "Cikis kodu: 0" in result
    assert "yes" in result
    assert "not recognized" not in result


def test_run_command_percent_sign_is_not_swallowed_by_cmd(tmp_path):
    """.cmd dosyasina yazilan komuttaki tek "%" cmd.exe tarafindan parametre
    referansi sanilip sessizce yutulmamali (orn. mod alma "42 % 2 -eq 0")."""
    inference_path = str(ROOT / "agent" / "mamidlabs-inference.ps1").replace("\\", "\\\\")
    folder = str(tmp_path).replace("\\", "\\\\")
    out = run_pwsh_functions(rf"""
$JobData = @{{ root = '{tmp_path}' }}
$Shared = [hashtable]::Synchronized(@{{ AccessMode = 'full'; Cancel = $false }})
Invoke-Expression (Get-Functions '{inference_path}')
$folder = '{folder}'
$a = [pscustomobject]@{{ command = 'powershell -NoProfile -Command "if (42 % 2 -eq 0) {{ Write-Output cift }} else {{ Write-Output tek }}"' }}
Write-Output ('r:' + (Invoke-Tool 'run_command' $a $folder))
""")
    result = out.split("r:", 1)[1]
    assert "Cikis kodu: 0" in result
    assert "cift" in result


def test_run_command_percent_env_var_reference_still_expands(tmp_path, monkeypatch):
    """"%FOO%" gibi gercek (satirda esleseni olan) bir ortam degiskeni referansi
    normal sekilde genisletilmeli; yalnizca eslesmeyen/tek basina kalan "%"
    kacislanir (bkz. mamidlabs-inference.ps1'deki run_command yorumu ve
    tests/test_run_command_percent_sign_is_not_swallowed_by_cmd)."""
    monkeypatch.setenv("MAMIDLABS_TEST_VAR", "merhaba-dunya")
    inference_path = str(ROOT / "agent" / "mamidlabs-inference.ps1").replace("\\", "\\\\")
    folder = str(tmp_path).replace("\\", "\\\\")
    out = run_pwsh_functions(rf"""
$JobData = @{{ root = '{tmp_path}' }}
$Shared = [hashtable]::Synchronized(@{{ AccessMode = 'full'; Cancel = $false }})
Invoke-Expression (Get-Functions '{inference_path}')
$folder = '{folder}'
$a = [pscustomobject]@{{ command = 'echo %MAMIDLABS_TEST_VAR%' }}
Write-Output ('r:' + (Invoke-Tool 'run_command' $a $folder))
""")
    result = out.split("r:", 1)[1]
    assert "Cikis kodu: 0" in result
    assert "merhaba-dunya" in result


def test_run_command_turkish_characters_survive_temp_script_roundtrip(tmp_path):
    """UTF-8 BOM'suz yazma + "chcp 65001" sayesinde komuttaki/ciktidaki Turkce
    karakterler bozulmadan gitmeli (eskiden [Text.Encoding]::Default pwsh 7'de
    ANSI degil BOM'suz UTF-8 uretiyordu ama cmd.exe dosyayi kendi OEM kod
    sayfasiyla okudugu icin Turkce karakterler bozulabiliyordu)."""
    inference_path = str(ROOT / "agent" / "mamidlabs-inference.ps1").replace("\\", "\\\\")
    folder = str(tmp_path).replace("\\", "\\\\")
    out = run_pwsh_functions(rf"""
$JobData = @{{ root = '{tmp_path}' }}
$Shared = [hashtable]::Synchronized(@{{ AccessMode = 'full'; Cancel = $false }})
Invoke-Expression (Get-Functions '{inference_path}')
$folder = '{folder}'
$a = [pscustomobject]@{{ command = 'powershell -NoProfile -Command "Write-Output çöğüşıİ"' }}
Write-Output ('r:' + (Invoke-Tool 'run_command' $a $folder))
""")
    result = out.split("r:", 1)[1]
    assert "Cikis kodu: 0" in result
    assert "çöğüşıİ" in result


def test_run_command_temp_script_is_cleaned_up(tmp_path):
    inference_path = str(ROOT / "agent" / "mamidlabs-inference.ps1").replace("\\", "\\\\")
    folder = str(tmp_path).replace("\\", "\\\\")
    temp_before = set(Path(__import__("tempfile").gettempdir()).glob("mamidlabs-cmd-*.cmd"))
    run_pwsh_functions(rf"""
$JobData = @{{ root = '{tmp_path}' }}
$Shared = [hashtable]::Synchronized(@{{ AccessMode = 'full'; Cancel = $false }})
Invoke-Expression (Get-Functions '{inference_path}')
$folder = '{folder}'
$a = [pscustomobject]@{{ command = 'echo test' }}
Invoke-Tool 'run_command' $a $folder | Out-Null
""")
    temp_after = set(Path(__import__("tempfile").gettempdir()).glob("mamidlabs-cmd-*.cmd"))
    assert temp_after - temp_before == set(), "gecici .cmd dosyasi calistirmadan sonra silinmeli"
