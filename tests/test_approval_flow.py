"""Ajan izin akisi (gercek arayuz testinde bulunan iki hata).

1) Onay 10 dk icinde verilmeyince arac tarafi "timeout" ile vazgeciyordu ama
   arayuzdeki MessageBox acik kaliyor, sonradan verilen "Evet" sessizce yok
   sayiliyordu. Artik her soru bir AskId tasir; pencere kimlik degisince kapanir.
2) Reddedilen create_document'tan sonra model "Belge hazir" dedi, dosya yoktu.
   Arac sonucu artik acik bir emir tasir ve arayuze modelden bagimsiz bir not gider.
"""
import json
import re
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]


def read_text(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8-sig")


def run_pwsh(tmp_path, body: str) -> dict:
    pwsh = shutil.which("pwsh")
    if not pwsh:
        pytest.skip("pwsh bulunamadi")
    script = tmp_path / "approval.ps1"
    script.write_text(
        f"""
# Cikti UTF-8 okunur; konsol kod sayfasi calistiran kabuga gore degisir (Git Bash'te bozuluyordu).
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$job = @{{ messages = @(@{{ role = 'user'; content = 'selam' }}); compactOnly = $true; provider = 'local'; model = 'test'; contextLimit = 32768; maxTokens = 100; agent = $true; internet = $false; office = $false; documentCreate = $true }}
$shared = [hashtable]::Synchronized(@{{ Cancel = $false; AccessMode = 'ask'; AskTool = $null; AskDetail = $null; AskAnswer = $null; AskId = $null; AskDeadline = $null }})
. '{ROOT}\\agent\\mamidlabs-inference.ps1' $job $shared | Out-Null
{body}
""",
        encoding="utf-8-sig",
    )
    result = subprocess.run(
        [pwsh, "-NoProfile", "-NonInteractive", "-File", str(script)],
        capture_output=True, encoding="utf-8", errors="replace", check=False, timeout=90,
    )
    assert result.returncode == 0, result.stderr or result.stdout
    return json.loads(result.stdout.strip().splitlines()[-1])


def test_timed_out_document_request_is_reported_as_not_done(tmp_path):
    got = run_pwsh(tmp_path, f"""
$script:ApprovalTimeout = [TimeSpan]::FromSeconds(1)
$arguments = [pscustomobject]@{{ filename = 'ozet.docx'; format = 'docx'; content = '# Test' }}
$result = Invoke-Tool 'create_document' $arguments '{tmp_path}'
@{{ result = $result; note = $script:deniedNote; outcome = $script:lastApprovalOutcome
   askId = $shared.AskId; askTool = $shared.AskTool; exists = (Test-Path '{tmp_path}\\ozet.docx') }} | ConvertTo-Json -Compress
""")
    assert got["outcome"] == "timeout"
    assert got["result"].startswith("ISLEM YAPILMADI: belge olusturulmadi")
    assert "yapildi, hazir ya da izin bekleniyor deme" in got["result"]
    assert got["note"].startswith("İşlem yapılmadı: belge oluşturulmadı")
    assert "izin süresinde verilmedi" in got["note"]
    # Arayuz penceresinin kapanmasini tetikleyen alanlar temizlenmis olmali.
    assert got["askId"] is None and got["askTool"] is None
    assert got["exists"] is False


def test_refused_command_is_reported_as_not_done(tmp_path):
    got = run_pwsh(tmp_path, """
# Arayuz yerine: soru gelince (AskId atandiginda) "Hayir" cevabi veren is parcacigi.
$askIds = [Collections.Concurrent.ConcurrentBag[string]]::new()
$responder = Start-ThreadJob -ArgumentList $shared, $askIds -ScriptBlock {
    param($s, $ids)
    $end = [DateTime]::UtcNow.AddSeconds(20)
    while (!$s.AskId -and [DateTime]::UtcNow -lt $end) { Start-Sleep -Milliseconds 50 }
    $ids.Add([string]$s.AskId); $s.AskAnswer = 'no'
}
$arguments = [pscustomobject]@{ command = 'echo selam' }
$result = Invoke-Tool 'run_command' $arguments $env:TEMP
Wait-Job $responder -Timeout 30 | Out-Null
@{ result = $result; note = $script:deniedNote; outcome = $script:lastApprovalOutcome
   askIdSeen = @($askIds)[0]; askId = $shared.AskId } | ConvertTo-Json -Compress
""")
    assert got["outcome"] == "asked_no"
    assert re.fullmatch(r"[0-9a-f]{32}", got["askIdSeen"])
    assert got["askId"] is None
    assert got["result"].startswith("ISLEM YAPILMADI: komut calistirilmadi")
    assert got["note"] == "İşlem yapılmadı: komut çalıştırılmadı (izin verilmedi)."


def test_refused_tool_is_not_asked_again_in_the_same_request(tmp_path):
    """Gercek arayuz testi: "Hayir"dan sonra model ayni komutu 4 kez denedi, her seferinde
    yeniden soruldu ve model reddi "cikti yakalanamadi" diye yanlis yorumladi."""
    got = run_pwsh(tmp_path, """
$responder = Start-ThreadJob -ArgumentList $shared -ScriptBlock {
    param($s)
    $end = [DateTime]::UtcNow.AddSeconds(20)
    while (!$s.AskId -and [DateTime]::UtcNow -lt $end) { Start-Sleep -Milliseconds 50 }
    $s.AskAnswer = 'no'
}
$arguments = [pscustomobject]@{ command = 'echo selam' }
$first = Invoke-Tool 'run_command' $arguments $env:TEMP
Wait-Job $responder -Timeout 30 | Out-Null
$firstNote = $script:deniedNote
# Ikinci deneme: kimse cevap vermiyor; soru acilsaydi zaman asimini (10 dk) beklerdi.
$sw = [Diagnostics.Stopwatch]::StartNew()
$second = Invoke-Tool 'run_command' ([pscustomobject]@{ command = 'py selam.py' }) $env:TEMP
@{ first = $first; firstNote = $firstNote; second = $second; secondNote = $script:deniedNote
   outcome = $script:lastApprovalOutcome; askId = $shared.AskId; ms = $sw.ElapsedMilliseconds } | ConvertTo-Json -Compress
""")
    assert "kullanicinin karari" in got["first"] and "tekrar deneme" in got["first"]
    assert got["firstNote"] == "İşlem yapılmadı: komut çalıştırılmadı (izin verilmedi)."
    assert got["outcome"] == "repeat_denied"
    assert got["askId"] is None and got["ms"] < 5000
    assert got["second"].startswith("ISLEM YAPILMADI") and "tekrar sorulmadi" in got["second"]
    assert got["secondNote"] is None


def test_desktop_uses_self_closing_approval_dialog_instead_of_messagebox():
    desktop = read_text("mamidlabs-desktop.ps1")
    assert "Ajan bilgisayarında bir değişiklik yapmak istiyor" not in desktop.split("function Show-ApprovalDialog")[0]
    assert "[System.Windows.Forms.MessageBox]::Show(\n                \"Ajan" not in desktop
    update = desktop.split("function Update-ApprovalDialog")[1].split("function Show-ApprovalDialog")[0]
    # Arac tarafi vazgecince (kimlik degisti / iptal) pencere kendini kapatir.
    assert "[string]$ctx.request.AskId -ne $ctx.askId -or $ctx.request.Cancel" in update
    assert "DialogResult]::Abort" in update
    dialog = desktop.split("function Show-ApprovalDialog")[1].split("function Show-ChatHistory")[0]
    assert "$approvalTimer.Add_Tick({ Update-ApprovalDialog $this.Tag })" in dialog
    # Yalnizca arac tarafi vazgecince (Abort) cevap yok; X/Esc eski MessageBox gibi "hayir"
    # sayilir, yoksa arayuz ayni soruyu hemen yeniden acardi.
    assert "DialogResult]::Abort) { return $null }\n    return 'no'" in dialog
    # Gec gelen cevap yazilmaz.
    assert "if ($answer -and [string]$request.AskId -eq $askId)" in desktop


def test_denied_note_is_shown_but_not_sent_back_to_the_model():
    desktop = read_text("mamidlabs-desktop.ps1")
    inference = read_text("agent/mamidlabs-inference.ps1")
    assert "if ($script:deniedNote) { Emit 'denied' $script:deniedNote }" in inference
    done = desktop.split("        'done' {")[1].split("        'cancelled' {")[0]
    assert "$b.deniedNote" in done
    # KV onbellek eslesmesi icin gecmise modelin gercek metni gider, not degil.
    assert "[void]$chatMessages.Add(@{ role = 'assistant'; content = [string]$jobEvent.text })" in done


def test_denial_note_is_added_to_the_request_copy_only():
    """Red sonrasi model cagrisina acik bir not eklenir; kalici gecmise ($messages) yazilmaz,
    boylece KV onbellek oneki bozulmaz. Not, web-hatasi notuyla birlesebildigi icin
    $systemNotes'a eklenir ve istek-kopyasina ([Sistem notu]) yazilir."""
    inference = read_text("agent/mamidlabs-inference.ps1")
    # Denial notu istek-kopyasina yazilan $systemNotes listesine eklenir.
    assert "$systemNotes += (" in inference
    assert "REDDETTI" in inference and "nedenini tahmin etme" in inference
    assert "$body.messages = @($sendMessages) + @(@{ role = 'user'; content = ('[Sistem notu] '" in inference
    assert "foreach ($m in @($systemNotes)) { [void]$messages.Add($m) }" not in inference
