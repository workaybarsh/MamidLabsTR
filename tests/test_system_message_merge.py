"""Gercek regresyon: sikistirilmis + arac-etkin bir sohbette 500 hatasi.

Kullanicinin gercek masaustu uygulamasinda karsilastigi hata (ekran goruntusu
ile bildirildi): "Jinja Exception: System message must be at the beginning."

Kok neden: baglam sikistirmasi $messages[0]'a zaten bir sistem mesaji
("[Onceki sohbetin ozeti]...") yerlestiriyor. Amp #28 duzeltmesi
(toolTrustGuard) araclar etkinken (agent/internet/office/documentCreate'den
en az biri acik) KOSULSUZCA basa bir BASKA sistem mesaji daha ekliyordu.
Sonuc: iki sistem mesaji (biri guard, biri ozet). Qwen'in Jinja sohbet
sablonu bunu acikca reddediyor - yalnizca TEK bir sistem mesaji kabul eder,
o da index 0'da olmali.

Gercek makinede uctan uca yeniden uretildi ve dogrulandi: sikistirilmis bir
sohbet gecmisi ($messages[0] sistem mesaji) + araclar acik (agent=true,
internet=true) ile gercek Start-ThreadJob -FilePath uretim cagrisi -
duzeltmeden ONCE bu senaryo asla test edilmemisti (yalnizca "sikistirma
olmadan arac-yok" ve "sikistirma olmadan arac-etkin" senaryolari test
edilmisti, bkz. test_tool_trust_boundary.py). Duzeltmeden SONRA gercek bir
yanit uretildi, hata yok.
"""
import json
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]


def read_text(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8-sig")


def run_pwsh(script: str) -> str:
    pwsh = shutil.which("pwsh")
    if not pwsh:
        pytest.skip("PowerShell 7 is unavailable")
    proc = subprocess.run(
        [pwsh, "-NoProfile", "-Command", script],
        capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=30,
    )
    if proc.returncode != 0:
        raise AssertionError(f"pwsh basarisiz oldu: {proc.stderr}")
    return proc.stdout


HELPER = r"""
$toolTrustGuard = @{ role = 'system'; content = 'GUARD' }
function BuildSend($messages) {
    $rest = @($messages)
    if ($rest.Count -gt 0 -and [string]$rest[0].role -eq 'system') {
        $merged = @{ role = 'system'; content = ([string]$rest[0].content) + "`n`n" + [string]$toolTrustGuard.content }
        $tail = if ($rest.Count -gt 1) { $rest[1..($rest.Count - 1)] } else { @() }
        return @($merged) + $tail
    } else {
        return @($toolTrustGuard) + $rest
    }
}
"""


def test_fix_is_present_in_source_and_merges_instead_of_duplicating():
    inference = read_text("agent/mamidlabs-inference.ps1")
    assert "[string]$rest[0].role -eq 'system'" in inference
    assert "$merged = @{ role = 'system'; content = ([string]$rest[0].content)" in inference
    # En fazla bir sistem mesaji uretilmeli; eski kosulsuz "@($toolTrustGuard) + $rest"
    # tek basina (birlestirme kontrolu olmadan) artik kalmamali.
    assert "[array]$sendMessages = if ($toolTrustGuard) { @($toolTrustGuard) + @($messages.ToArray()) } else" not in inference


def test_single_existing_system_message_gets_merged_not_duplicated():
    """PowerShell'e ozgu kenar durumu: $rest.Count -eq 1 iken '1..($rest.Count-1)'
    = '1..0' - PowerShell bunu bos degil, rest[0]'i TEKRAR donduren bir aralik
    olarak degerlendirir (dogrulandi). Bu korunmazsa birlestirilmis mesaj +
    orijinalin bir kopyasi = yine iki sistem mesaji, tam olarak duzeltilmeye
    calisilan hatanin kendisi."""
    out = run_pwsh(HELPER + r"""
$result = BuildSend @(@{role='system'; content='[Onceki sohbetin ozeti] X'})
Write-Output ($result | ConvertTo-Json -Compress -Depth 5)
""")
    parsed = json.loads(out.strip().splitlines()[-1])
    assert isinstance(parsed, dict), f"tek elemanli dizi beklenirdi, iki mesaj donmus olabilir: {parsed}"
    assert parsed["role"] == "system"
    assert "GUARD" in parsed["content"]
    assert "[Onceki sohbetin ozeti]" in parsed["content"]


def test_system_message_plus_more_history_merges_and_preserves_order():
    out = run_pwsh(HELPER + r"""
$result = BuildSend @(
    @{role='system'; content='[Onceki sohbetin ozeti] X'},
    @{role='user'; content='devam'},
    @{role='assistant'; content='tamam'}
)
Write-Output ($result | ConvertTo-Json -Compress -Depth 5)
""")
    parsed = json.loads(out.strip().splitlines()[-1])
    assert len(parsed) == 3, f"tam olarak 3 mesaj (1 birlesmis sistem + 2 gecmis) beklenirdi: {parsed}"
    assert parsed[0]["role"] == "system"
    assert "GUARD" in parsed[0]["content"] and "[Onceki sohbetin ozeti]" in parsed[0]["content"]
    assert [m["role"] for m in parsed[1:]] == ["user", "assistant"]
    assert sum(1 for m in parsed if m["role"] == "system") == 1


def test_no_existing_system_message_still_prepends_guard_normally():
    """Regresyon olmadigini dogrular: sikistirma olmayan normal durumda guard
    hala eskisi gibi basa ekleniyor."""
    out = run_pwsh(HELPER + r"""
$result = BuildSend @(@{role='user'; content='merhaba'})
Write-Output ($result | ConvertTo-Json -Compress -Depth 5)
""")
    parsed = json.loads(out.strip().splitlines()[-1])
    assert len(parsed) == 2
    assert parsed[0] == {"role": "system", "content": "GUARD"}
    assert parsed[1]["role"] == "user"
