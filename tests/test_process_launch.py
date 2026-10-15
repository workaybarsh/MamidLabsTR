"""Uzun yasayan alt surecler cagiranin stdout borusunu devralmamali.

Gercek makinede: "smoke-test.ps1 *> dosya", "manage-mamidlabs.ps1 | Out-String" ve
Start-Process -Wait, llama-server/ComfyUI calistikca hic bitmedi; cunku
Start-Process -Redirect* cocuga cagiranin devredilebilir tanitcilarini veriyordu.

Olcut sureye bagli degildir: cagiran surec ne kadar yavas acilirsa acilsin (CI'da
PowerShell ve Add-Type yavas olabilir) bitmesi beklenir; ardindan borunun kapanip
kapanmadigina bakilir. Cocuk hala calisirken boru acik kaliyorsa cocuk devralmistir.
"""
import shutil
import subprocess
import threading
import time
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
CHILD_SECONDS = 60  # Olcum penceresinden cok uzun: cocuk yasarken borunun durumu olculur.


def pipe_held_after_caller_exits(tmp_path, launch_line: str):
    pwsh = shutil.which("pwsh")
    if not pwsh:
        pytest.skip("pwsh bulunamadi")
    script = tmp_path / "launch.ps1"
    script.write_text(
        f"""
. '{ROOT}\\agent\\process-launch.ps1'
$childArgs = @('-NoProfile', '-Command', 'Start-Sleep -Seconds {CHILD_SECONDS}')
{launch_line}
Write-Output "child=$($child.Id)"
""",
        encoding="utf-8-sig",
    )
    proc = subprocess.Popen(
        [pwsh, "-NoProfile", "-NonInteractive", "-File", str(script)],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, encoding="utf-8", errors="replace",
    )
    lines = []
    reader = threading.Thread(target=lambda: lines.extend(proc.stdout), daemon=True)
    reader.start()
    try:
        proc.wait(timeout=90)  # Cagiranin kendisi yavas olabilir; bu takilma sayilmaz.
        # Cagiran bitti: boru ancak baska bir surec tutuyorsa acik kalir.
        reader.join(timeout=4)
        held = reader.is_alive()
    finally:
        if proc.poll() is None:
            proc.kill()
        child = next((line.strip().split("=", 1)[1] for line in list(lines) if line.startswith("child=")), "")
        if child.isdigit():
            subprocess.run(["taskkill", "/PID", child, "/T", "/F"], capture_output=True, check=False)
        reader.join(timeout=10)
    output = "".join(lines)
    assert "child=" in output, output
    return held, output


def test_detached_child_does_not_hold_callers_pipe(tmp_path):
    held, output = pipe_held_after_caller_exits(
        tmp_path,
        f"$child = Start-DetachedProcess (Get-Process -Id $PID).Path $childArgs $env:TEMP "
        f"'{tmp_path}\\c.out' '{tmp_path}\\c.err'",
    )
    assert not held, output


def test_plain_start_process_redirect_holds_the_pipe(tmp_path):
    """Eski yontemin sorunu gercekten urettigini gosterir (duzeltmenin kaniti)."""
    held, output = pipe_held_after_caller_exits(
        tmp_path,
        f"$child = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $childArgs "
        f"-RedirectStandardOutput '{tmp_path}\\c.out' -RedirectStandardError '{tmp_path}\\c.err' "
        f"-WindowStyle Hidden -PassThru",
    )
    assert held, output


def test_long_lived_servers_use_detached_launch():
    manage = (ROOT / "scripts" / "manage-mamidlabs.ps1").read_text(encoding="utf-8-sig")
    swap = (ROOT / "agent" / "media-model-swap.ps1").read_text(encoding="utf-8-sig")
    assert "$child = Start-DetachedProcess $server" in manage
    assert "$comfy = Start-DetachedProcess $python" in swap
    assert "-RedirectStandardOutput" not in manage
    assert "-RedirectStandardOutput" not in swap
