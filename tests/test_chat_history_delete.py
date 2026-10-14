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


def test_delete_all_keeps_the_open_chat(tmp_path):
    """'Tümünü Sil' o an ekranda duran sohbeti silmemeli; açık sohbet geçmişte
    kalmalı. Karar saf Get-DeletableChatPaths ile verilir; burada gerçek
    PowerShell'de doğrulanır (açık sohbetin dosyası silinecekler listesinden
    çıkarılır, diğerleri silinir; açık sohbet yokken hepsi silinebilir)."""
    pwsh = shutil.which("pwsh")
    if not pwsh:
        pytest.skip("pwsh bulunamadi")
    desktop = (ROOT / "qwen-desktop.ps1").read_text(encoding="utf-8-sig")
    function = extract_function(desktop, "Get-DeletableChatPaths")
    chat_dir = tmp_path / "chats"
    chat_dir.mkdir()
    open_id = "a" * 32
    other1 = "b" * 32
    other2 = "c" * 32
    for cid in (open_id, other1, other2):
        (chat_dir / f"{cid}.json").write_text("x", encoding="utf-8")
    body = (
        "$ErrorActionPreference = 'Stop'\n"
        + function
        + "\n$dir = '" + str(chat_dir) + "'\n"
        + "$ids = @('" + open_id + "', '" + other1 + "', '" + other2 + "')\n"
        + "$paths = @($ids | ForEach-Object { Join-Path $dir \"$_.json\" })\n"
        + "$withKeep = @(Get-DeletableChatPaths $dir $paths '" + open_id + "')\n"
        + "$noKeep = @(Get-DeletableChatPaths $dir $paths '')\n"
        + "$nullKeep = @(Get-DeletableChatPaths $dir $paths $null)\n"
        + "@{ withKeep = $withKeep.Count; noKeep = $noKeep.Count; nullKeep = $nullKeep.Count; "
        + "keepsOpen = -not (($withKeep -join ';').Contains('" + open_id + ".json')) } | ConvertTo-Json -Compress\n"
    )
    script = tmp_path / "delete.ps1"
    script.write_text(body, encoding="utf-8-sig")
    result = subprocess.run(
        [pwsh, "-NoProfile", "-NonInteractive", "-File", str(script)],
        capture_output=True, encoding="utf-8", errors="replace", check=False,
    )
    assert result.returncode == 0, result.stderr or result.stdout
    got = json.loads(result.stdout.strip().splitlines()[-1])
    assert got == {"withKeep": 2, "noKeep": 3, "nullKeep": 3, "keepsOpen": True}


def test_delete_all_handler_protects_open_chat():
    """Silme döngüsü artık listenin tamamı ($entries) yerine filtrelenmiş
    $targets üzerinde çalışır; açık sohbet kullanıcıya bildirilir."""
    desktop = (ROOT / "qwen-desktop.ps1").read_text(encoding="utf-8-sig")
    assert "Get-DeletableChatPaths $chatDir $entries $script:chatId" in desktop
    assert "foreach ($path in @($targets)) { Remove-Item" in desktop
    assert "Açık olan sohbet korunur." in desktop
