"""agent/qwen-inference.ps1 read_bound_file icin ikili dosya tespiti.

Bir .exe/.zip/gorsel metin olarak okunursa bozuk karakterler model baglamina gider
(token israfi, tanimsiz davranis). Ikili dosyalar tespit edilip reddedilir; UTF-8
metin (Turkce karakterler dahil) normal okunur. Fonksiyon gercek dosyalarla, inference
betigi yuklenmeden izole calistirilir.
"""
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]


def read_text(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8-sig")


def test_read_bound_file_checks_for_binary_before_reading_as_text():
    inference = read_text("agent/qwen-inference.ps1")

    assert "function Test-BinaryFile" in inference
    assert "if (Test-BinaryFile $target)" in inference
    # Kontrol dosya okumadan (ReadAllText'ten) once calismali.
    check_index = inference.index("if (Test-BinaryFile $target)")
    read_index = inference.index("[IO.File]::ReadAllText($target)")
    assert check_index < read_index


def _run_function_isolated(function_text: str, invocation: str, tmp_path: Path) -> str:
    """Fonksiyonu, tum qwen-inference.ps1'i (JobData/Shared bekleyen ust
    seviye kod dahil) dot-source etmeden, izole calistirir. -Command yerine
    -File kullanir: Turkce karakterler -Command argumaninda Python -> pwsh
    kodlama katmanlari arasinda bozulabilir, dosyaya UTF-8 BOM ile yazmak
    (test_desktop_behavior.py'deki run_ps ile ayni teknik) bunu onler."""
    pwsh = shutil.which("pwsh")
    if not pwsh:
        pytest.skip("PowerShell 7 is unavailable")
    script_path = tmp_path / "test.ps1"
    script_path.write_text(function_text + "\n" + invocation, encoding="utf-8-sig")
    result = subprocess.run(
        [pwsh, "-NoProfile", "-NonInteractive", "-File", str(script_path)],
        capture_output=True, text=True, timeout=30, encoding="utf-8", errors="replace",
    )
    assert result.returncode == 0, result.stdout + result.stderr
    return result.stdout


def _extract_function(name: str) -> str:
    inference = read_text("agent/qwen-inference.ps1")
    start = inference.index(f"function {name}(")
    # Basit brace sayaci: fonksiyon govdesinin kapanisini bulur.
    depth = 0
    started = False
    for index in range(start, len(inference)):
        char = inference[index]
        if char == "{":
            depth += 1
            started = True
        elif char == "}":
            depth -= 1
            if started and depth == 0:
                return inference[start:index + 1]
    raise AssertionError(f"{name} fonksiyonunun sonu bulunamadi")


@pytest.mark.parametrize("filename,expect_binary", [
    ("assets/icons/mamidlabs.ico", True),
    ("assets/icons/mamidlabs-64.png", True),
    ("README.md", False),
    ("scripts/manage-qwen.ps1", False),
])
def test_binary_detection_on_real_repository_files(filename, expect_binary, tmp_path):
    """Gercek repo dosyalari uzerinde calistirilir; mock veri degil."""
    function_text = _extract_function("Test-BinaryFile")
    target = ROOT / filename
    assert target.exists(), f"test dosyasi yok: {target}"

    output = _run_function_isolated(function_text, f"Test-BinaryFile '{target}'", tmp_path)
    assert output.strip() == str(expect_binary)


def test_binary_detection_handles_empty_file(tmp_path):
    function_text = _extract_function("Test-BinaryFile")
    output = _run_function_isolated(
        function_text,
        "$p = Join-Path $env:TEMP 'mamidlabs-empty-test.txt'; "
        "New-Item -ItemType File -Path $p -Force | Out-Null; "
        "try { Test-BinaryFile $p } finally { Remove-Item -LiteralPath $p -Force }",
        tmp_path,
    )
    assert output.strip() == "False"


def test_binary_detection_handles_turkish_utf8_text(tmp_path):
    """Turkce ozel karakterler (UTF-8 coklu bayt) yanlislikla ikili sayilmamali.
    Gercek makinede dogrulandi: 'ığüşöç İĞÜŞÖÇ' iceren bir dosya False donuyor."""
    function_text = _extract_function("Test-BinaryFile")
    sample_path = tmp_path / "sample.txt"
    sample_path.write_text("Türkçe karakterli bir örnek metin: ığüşöç İĞÜŞÖÇ", encoding="utf-8")
    output = _run_function_isolated(
        function_text,
        f"Test-BinaryFile '{sample_path}'",
        tmp_path,
    )
    assert output.strip() == "False"
