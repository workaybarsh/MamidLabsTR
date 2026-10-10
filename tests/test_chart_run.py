"""Bagimsiz grafik ureticisi (agent\\chart-run.ps1) + arac kablolamasi.

Sohbet araci `generate_chart` bu betigi gomulu pwsh ile ayri bir surecte calistirir;
betik stdin'den JSON spec alir, stdout'a JSON sonuc yazar. Bu testler gercek pwsh'ta
tum grafik turlerini uretir ve guvenli ifade cozumleyicinin Invoke-Expression
kullanmadigini dogrular. PowerShell 7 yoksa atlanir (bkz. conftest.py).
"""
import json
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
CHART = ROOT / "agent" / "chart-run.ps1"
INFERENCE = ROOT / "agent" / "qwen-inference.ps1"
DESKTOP = ROOT / "qwen-desktop.ps1"


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8-sig")


def pwsh_exe():
    exe = shutil.which("pwsh")
    if not exe:
        pytest.skip("PowerShell 7 is unavailable")
    return exe


def run_chart(spec: dict) -> dict:
    """chart-run.ps1'i calistirir ve JSON sonucu sozluk olarak dondurur."""
    spec = dict(spec)
    if spec.get("out"):
        spec["out"] = str(spec["out"])
    proc = subprocess.run(
        [pwsh_exe(), "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(CHART)],
        input=json.dumps(spec),
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=120,
    )
    assert proc.stdout.strip(), f"cikti yok; stderr={proc.stderr!r}"
    return json.loads(proc.stdout)


def assert_png(result: dict, tmp_path: Path) -> None:
    assert "error" not in result, result
    out = Path(result["path"])
    assert out.is_file() and out.suffix == ".png", result
    assert out.stat().st_size > 0
    assert out.read_bytes()[:8] == b"\x89PNG\r\n\x1a\n", "gecerli PNG imzasi degil"


def test_bar_with_top_level_values(tmp_path):
    result = run_chart({
        "type": "bar",
        "labels": ["Ocak", "Subat", "Mart", "Nisan", "Mayis"],
        "values": [12, 19, 8, 15, 22],
        "title": "Aylik satis",
        "ylabel": "Adet",
        "out": tmp_path / "bar.png",
    })
    assert_png(result, tmp_path)
    assert result["type"] == "bar"


def test_line_with_multiple_series(tmp_path):
    result = run_chart({
        "type": "line",
        "labels": ["2020", "2021", "2022", "2023", "2024"],
        "series": [
            {"name": "TR", "values": [10, 14, 13, 18, 21]},
            {"name": "ENG", "values": [8, 9, 12, 14, 19]},
        ],
        "title": "Yillik artis",
        "out": tmp_path / "line.png",
    })
    assert_png(result, tmp_path)
    assert result["type"] == "line"


def test_pie_with_top_level_values(tmp_path):
    result = run_chart({
        "type": "pie",
        "labels": ["Elma", "Armut", "Muz", "Cilek"],
        "values": [35, 25, 20, 20],
        "title": "Meyve dagilimi",
        "out": tmp_path / "pie.png",
    })
    assert_png(result, tmp_path)
    assert result["type"] == "pie"


def test_pie_rejects_non_positive_values(tmp_path):
    result = run_chart({
        "type": "pie",
        "labels": ["A", "B"],
        "values": [0, 0],
        "out": tmp_path / "pie0.png",
    })
    assert "error" in result


def test_scatter_accepts_objects_and_arrays(tmp_path):
    obj = run_chart({
        "type": "scatter",
        "series": [{"name": "Grup A", "points": [{"x": 1, "y": 2}, {"x": 2, "y": 3.5}, {"x": 3, "y": 3}]}],
        "out": tmp_path / "scatter-obj.png",
    })
    assert_png(obj, tmp_path)
    arr = run_chart({
        "type": "scatter",
        "series": [{"name": "Grup A", "points": [[1, 2], [2, 3.5], [3, 3]]}],
        "out": tmp_path / "scatter-arr.png",
    })
    assert_png(arr, tmp_path)


def test_function_curves_sin_cos_and_power(tmp_path):
    result = run_chart({
        "type": "function",
        "functions": ["sin(x)", "cos(x)", "x^2"],
        "xmin": -6.283185307179586,
        "xmax": 6.283185307179586,
        "samples": 800,
        "title": "Fonksiyon egrisi",
        "out": tmp_path / "fn.png",
    })
    assert_png(result, tmp_path)
    assert result["type"] == "function"


def test_function_invalid_expression_reports_error(tmp_path):
    result = run_chart({
        "type": "function",
        "functions": ["bilinmeyen(x)"],
        "xmin": 0,
        "xmax": 1,
        "out": tmp_path / "bad-fn.png",
    })
    assert "error" in result


def test_function_rejects_arbitrary_code(tmp_path):
    # Guvenli cozumleyici yalnizca izinli simgeleri kabul eder; ornekleme sirasinda
    # ifade cozulemezse hata dondurur (Invoke-Expression yok).
    result = run_chart({
        "type": "function",
        "functions": ["x); Remove-Item C:\\ ; ("],
        "xmin": 0,
        "xmax": 1,
        "out": tmp_path / "evil.png",
    })
    assert "error" in result


def test_unknown_type_reports_error(tmp_path):
    result = run_chart({"type": "wat", "labels": ["A"], "values": [1], "out": tmp_path / "x.png"})
    assert "error" in result


def test_missing_out_reports_error(tmp_path):
    result = run_chart({"type": "bar", "labels": ["A"], "values": [1]})
    assert "error" in result


def test_source_uses_no_invoke_expression():
    import re
    src = read_text(CHART)
    # Yorum satirlarindaki ifadeyi degil, gercek cagriyi arar (satir basinda komut).
    assert not re.search(r"(?m)^\s*(Invoke-Expression|iex)\b", src), \
        "guvenli cozumleyici Invoke-Expression kullanmamali"


def test_inference_wires_generate_chart_tool():
    src = read_text(INFERENCE)
    assert "name = 'generate_chart'" in src, "arac tanimi yok"
    assert "$job.chartgen" in src, "arac chartgen bayragiyla sunulmuyor"
    assert "$name -eq 'generate_chart'" in src, "arac cagrisi islenmiyor"
    assert "chart-run.ps1" in src, "grafik betigi cagrilmiyor"
    assert "chartFile" in src, "chart olayi yayilmaz"


def test_desktop_handles_chart_event_and_flag():
    src = read_text(DESKTOP)
    assert "chartgen = $true" in src, "jobData chartgen gonderilmiyor"
    assert "'chart'" in src, "arayuz chart olayini islemiyor"
    assert "generate_chart" in src, "arac etiketi/sistem istemi eksik"


def test_smoke_test_has_chart_step():
    src = read_text(ROOT / "scripts" / "smoke-test.ps1")
    assert "[switch]$SkipChart" in src, "grafik adimi atlanabilir olmali"
    assert "Write-Section 'Grafik uretimi" in src, "grafik adimi yok"
    assert "Report 'grafik'" in src, "grafik adimi raporlanmiyor"
    assert "chart-run.ps1" in src, "grafik betigi smoke testinde cagrilmiyor"


def _extract_function(source: str, name: str) -> str:
    import re
    m = re.search(r"function " + re.escape(name) + r"\b[\s\S]*?\n\}", source)
    assert m, f"{name} bulunamadi"
    return m.group(0)


def test_invoke_chart_tool_creates_png(tmp_path):
    """Isci icindeki Invoke-ChartTool gercek chart-run.ps1 ile PNG uretmeli."""
    pwsh = pwsh_exe()
    src = read_text(INFERENCE)
    fns = _extract_function(src, "Get-InstallRoot") + "\n" + _extract_function(src, "Invoke-ChartTool")
    (tmp_path / "agent").mkdir()
    shutil.copy(CHART, tmp_path / "agent" / "chart-run.ps1")

    template = """
$JobData = @{ root = '__ROOT__' }
$o = '{"type":"bar","labels":["A","B","C"],"values":[3,7,4],"title":"Test grafigi"}' | ConvertFrom-Json
$r = Invoke-ChartTool $o
Write-Output $r
Write-Output ('ARTIFACT=' + [string]$script:createdArtifact)
"""
    script = fns + "\n" + template.replace("__ROOT__", str(tmp_path))
    proc = subprocess.run(
        [pwsh, "-NoProfile", "-NonInteractive", "-Command", script],
        capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=120,
    )
    assert proc.returncode == 0, proc.stdout + proc.stderr
    assert "Grafik olusturuldu" in proc.stdout, proc.stdout + proc.stderr
    pngs = list((tmp_path / "outputs" / "grafikler").glob("*.png"))
    assert pngs and pngs[0].stat().st_size > 0


def test_invoke_chart_tool_rejects_bad_type(tmp_path):
    pwsh = pwsh_exe()
    src = read_text(INFERENCE)
    fns = _extract_function(src, "Get-InstallRoot") + "\n" + _extract_function(src, "Invoke-ChartTool")
    (tmp_path / "agent").mkdir()
    shutil.copy(CHART, tmp_path / "agent" / "chart-run.ps1")
    template = """
$JobData = @{ root = '__ROOT__' }
$o = '{"type":"wat","values":[1]}' | ConvertFrom-Json
Write-Output (Invoke-ChartTool $o)
"""
    script = fns + "\n" + template.replace("__ROOT__", str(tmp_path))
    proc = subprocess.run(
        [pwsh, "-NoProfile", "-NonInteractive", "-Command", script],
        capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=120,
    )
    assert proc.returncode == 0, proc.stdout + proc.stderr
    assert "Gecersiz grafik turu" in proc.stdout
