import json
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]


def extract_function(source: str, name: str) -> str:
    start = source.index(f"function {name}")
    end = source.find("\nfunction ", start + 1)
    return source[start:end if end != -1 else len(source)]


def test_long_chat_round_trips_and_legacy_chats_stay_readable(tmp_path):
    """V1 SecureString kullaniyordu ve 65.536 karakteri asan sohbetler (ornegin
    eklenmis gorselli olanlar) hic kaydedilemiyordu. V2 dogrudan DPAPI kullanir;
    eski V1 dosyalar okunmaya devam etmeli."""
    pwsh = shutil.which("pwsh")
    if not pwsh:
        pytest.skip("pwsh bulunamadi")
    desktop = (ROOT / "qwen-desktop.ps1").read_text(encoding="utf-8-sig")
    header = "\n".join(
        line for line in desktop.splitlines()
        if line.startswith(("Add-Type -AssemblyName System.Security.Cryptography.ProtectedData", "$chatProtectionPrefix"))
    )
    functions = extract_function(desktop, "Protect-ChatText") + "\n" + extract_function(desktop, "Read-ChatData")
    new_path, legacy_path = tmp_path / "long.json", tmp_path / "legacy.json"
    script = tmp_path / "chat.ps1"
    script.write_text(
        "$ErrorActionPreference = 'Stop'\n" + header + "\n" + functions + f"""
$long = @{{ id = 'uzun'; messages = @(@{{ role = 'user'; content = ('g' * 200000) }}) }} | ConvertTo-Json -Depth 5
[IO.File]::WriteAllText('{new_path}', (Protect-ChatText $long))
$secure = ConvertTo-SecureString -String (@{{ id = 'eski'; title = 'ş' }} | ConvertTo-Json) -AsPlainText -Force
[IO.File]::WriteAllText('{legacy_path}', $chatProtectionPrefix + "`n" + (ConvertFrom-SecureString $secure))
$a = Read-ChatData '{new_path}'; $b = Read-ChatData '{legacy_path}'
@{{ newId = $a.id; newLen = $a.messages[0].content.Length; legacyId = $b.id; legacyTitle = $b.title }} | ConvertTo-Json -Compress -EscapeHandling EscapeNonAscii
""",
        encoding="utf-8-sig",
    )
    result = subprocess.run(
        [pwsh, "-NoProfile", "-NonInteractive", "-File", str(script)],
        capture_output=True, encoding="utf-8", errors="replace", check=False,
    )
    assert result.returncode == 0, result.stderr or result.stdout
    got = json.loads(result.stdout.strip().splitlines()[-1])
    assert got == {"newId": "uzun", "newLen": 200000, "legacyId": "eski", "legacyTitle": "ş"}
    assert new_path.read_text(encoding="utf-8").startswith("MAMIDLABS-CHAT-DPAPI-V2\n")
    assert "g" * 100 not in new_path.read_text(encoding="utf-8")


def test_reloaded_chat_keeps_tool_history_for_continuation(tmp_path):
    """Kullanicinin senaryosu: konusma ORTASINDA programi kapat, yeniden ac,
    gecmis sohbetlerden yukle ve devam et. Kaydedilen modele donuk mesaj dizisi
    (assistant tool_calls + tool sonuclari dahil) ConvertTo-Json + DPAPI
    gidis-donusunden bozulmadan gecmeli; aksi halde devam turunda sunucu gecersiz
    bir gecmis görur (ornegin tool_call sonucu eksik) ve hata verir. Burada
    Save-Chat/Load-Chat'in tam serilestirme yolu taklit edilir."""
    pwsh = shutil.which("pwsh")
    if not pwsh:
        pytest.skip("pwsh bulunamadi")
    desktop = (ROOT / "qwen-desktop.ps1").read_text(encoding="utf-8-sig")
    header = "\n".join(
        line for line in desktop.splitlines()
        if line.startswith(("Add-Type -AssemblyName System.Security.Cryptography.ProtectedData", "$chatProtectionPrefix"))
    )
    functions = extract_function(desktop, "Protect-ChatText") + "\n" + extract_function(desktop, "Read-ChatData")
    path = tmp_path / "reload.json"
    script = tmp_path / "reload.ps1"
    # Gercek bir arac turunun kalici hali: user + assistant(tool_calls) + tool + assistant.
    script.write_text(
        "$ErrorActionPreference = 'Stop'\n" + header + "\n" + functions + f"""
$messages = @(
    @{{ role = 'user'; content = 'Einstein bilmecesi nedir?' }}
    @{{ role = 'assistant'; content = ''; tool_calls = @(@{{ id = 'call_1'; type = 'function'; function = @{{ name = 'search_web'; arguments = '{{"query":"einstein"}}' }} }}) }}
    @{{ role = 'tool'; tool_call_id = 'call_1'; content = '{{"error":"Web aramasi basarisiz"}}' }}
    @{{ role = 'assistant'; content = 'Einstein bilmecesi bir mantik sorusudur.' }}
)
$data = @{{ id = 'reload0000000000000000000000000'; title = 'devam'; messages = @($messages); transcript = @() }}
$json = $data | ConvertTo-Json -Depth 30
[IO.File]::WriteAllText('{path}', (Protect-ChatText $json), [Text.UTF8Encoding]::new($false))
$loaded = Read-ChatData '{path}'
$m = @($loaded.messages)
$tc = $m[1].tool_calls[0].function.name
@{{ count = $m.Count; tool = [string]$tc; callId = [string]$m[2].tool_call_id; last = [string]$m[3].content }} | ConvertTo-Json -Compress -EscapeHandling EscapeNonAscii
""",
        encoding="utf-8-sig",
    )
    result = subprocess.run(
        [pwsh, "-NoProfile", "-NonInteractive", "-File", str(script)],
        capture_output=True, encoding="utf-8", errors="replace", check=False,
    )
    assert result.returncode == 0, result.stderr or result.stdout
    got = json.loads(result.stdout.strip().splitlines()[-1])
    assert got["count"] == 4
    assert got["tool"] == "search_web"
    assert got["callId"] == "call_1"
    assert got["last"] == "Einstein bilmecesi bir mantik sorusudur."
    # Arac argumanlari JSON dizesi olarak korunmali (nesne olsaydi sablon bozulurdu).
    assert got["count"] == 4

