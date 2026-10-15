"""Gercek regresyon: tek mesajli, arac-yok bir sohbet turu 400 hatasiyla
patliyordu (Amp #28 duzeltmesinin yan etkisi).

mamidlabs-inference.ps1 icinde $body.messages "if (...) {...} else {...}" seklinde
DOGRUDAN hashtable degeri olarak atanmisti. PowerShell'de bir if/else
ifadesinin ciktisi bir hashtable degerine ya da degiskene bu sekilde
yakalandiginda, TEK ELEMANLI bir dizi tek nesneye "acilir" (array
unwrapping); ConvertTo-Json bunu JSON dizisi [...] degil duz nesne {...}
olarak yazar. llama-server bu durumda "Expected 'messages' to be an array"
ile 400 doner.

Gercek makinede yakalandi: yeni bir sohbette (tek kullanici mesaji), arac
etkin degilken (agent/internet/office/documentCreate hepsi kapali,
toolTrustGuard = $null) istek her zaman basarisiz oluyordu - bu, en yaygin
gercek kullanim senaryosuydu (yeni sohbet acmak).

Bu test PowerShell'i gercekten calistirip bug'i ve duzeltmeyi dogrudan
kanitlar (yalnizca kaynak metnini aramaz).
"""
import json
import shutil
import subprocess

import pytest


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
    return proc.stdout.strip()


def test_broken_pattern_collapses_a_single_element_array():
    """Once neyin bozuk oldugunu belgeler: dogrudan if/else atamasi tek
    elemanli diziyi ConvertTo-Json'da duz nesneye cevirir."""
    out = run_pwsh(r"""
$messages = [Collections.ArrayList]::new()
[void]$messages.Add(@{ role = 'user'; content = 'merhaba' })
$toolTrustGuard = $null
$body = @{ messages = if ($toolTrustGuard) { @($toolTrustGuard) + @($messages.ToArray()) } else { @($messages.ToArray()) } }
Write-Output ($body | ConvertTo-Json -Compress -Depth 10)
""")
    parsed = json.loads(out)
    assert not isinstance(parsed["messages"], list), (
        "Bu test 'bozuk deseni' belgeliyor; artik dizi olarak geliyorsa "
        "PowerShell'in davranisi degismis olabilir - test guncellenmeli."
    )


def test_array_cast_pattern_keeps_a_single_element_as_a_json_array():
    """Gercek duzeltme: [array] cast'i ile once ayri bir degiskene atamak,
    tek elemanli dahi olsa JSON dizisini korur."""
    out = run_pwsh(r"""
$messages = [Collections.ArrayList]::new()
[void]$messages.Add(@{ role = 'user'; content = 'merhaba' })
$toolTrustGuard = $null
[array]$sendMessages = if ($toolTrustGuard) { @($toolTrustGuard) + @($messages.ToArray()) } else { @($messages.ToArray()) }
$body = @{ messages = $sendMessages }
Write-Output ($body | ConvertTo-Json -Compress -Depth 10)
""")
    parsed = json.loads(out)
    assert isinstance(parsed["messages"], list)
    assert len(parsed["messages"]) == 1
    assert parsed["messages"][0]["content"] == "merhaba"


def test_array_cast_pattern_also_works_with_multiple_elements():
    out = run_pwsh(r"""
$messages = [Collections.ArrayList]::new()
[void]$messages.Add(@{ role = 'user'; content = 'merhaba' })
[void]$messages.Add(@{ role = 'assistant'; content = 'selam' })
$toolTrustGuard = $null
[array]$sendMessages = if ($toolTrustGuard) { @($toolTrustGuard) + @($messages.ToArray()) } else { @($messages.ToArray()) }
$body = @{ messages = $sendMessages }
Write-Output ($body | ConvertTo-Json -Compress -Depth 10)
""")
    parsed = json.loads(out)
    assert isinstance(parsed["messages"], list)
    assert len(parsed["messages"]) == 2
