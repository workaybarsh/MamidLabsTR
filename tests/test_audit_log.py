"""Islem denetim kaydi (logs/audit.jsonl).

Her arac cagrisindan sonra bir JSON satiri yazilir: is/arac kimligi, kaynak kanal,
onay durumu, sonuc ve degisen yollar. Belge/komut icerigi ve API anahtarlari yazilmaz.
Fonksiyonlar AST ile cikarilip gercek pwsh'ta calistirilir:
1) Onay gerektirmeyen arac (read_bound_file) -> approval=not_required, result=ok.
2) Tam erisimde dosya yazma (write_bound_file) -> approval=full_access, changedPath dolu.
3) Reddedilen onay -> approval=asked_no, result=denied.
Kilit nesnesi (Get-AuditLock) top-level atama degil, tembel yuklenen bir fonksiyondur;
yalnizca fonksiyonlar yuklendiginde de calisir.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read_text(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8-sig")


def test_write_audit_log_function_exists_and_never_logs_full_content():
    inference = read_text("agent/mamidlabs-inference.ps1")
    assert "function Write-AuditLog" in inference
    assert "function Get-ToolAuditDetail" in inference
    # write_bound_file/create_document icin relative_path/filename gecer,
    # 'content' alanini (belge/dosya ICERIGI) ASLA gecmez.
    detail_fn = inference.split("function Get-ToolAuditDetail")[1].split("function Wait-LocalModelStopped")[0]
    assert "'write_bound_file' { return [string]$arguments.relative_path }" in detail_fn
    assert "$arguments.content" not in detail_fn


def test_audit_lock_is_a_lazy_accessor_function_not_a_top_level_assignment():
    """Gercek makinede yakalandi: $script:auditLock top-level bir atamaydi;
    AST ile yalnizca fonksiyonlar cikarilip yuklendiginde (davranis testleri,
    veya baska bir sebeple dosyanin tamami calismadiginda) tanimsiz kalirdi,
    Write-AuditLog icindeki .WaitOne() cagrisi null referans hatasi verirdi."""
    inference = read_text("agent/mamidlabs-inference.ps1")
    assert "function Get-AuditLock" in inference
    assert "$lock = Get-AuditLock" in inference
    # Mutex olusturma satiri Get-AuditLock govdesi ICINDE olmali, fonksiyonun
    # disinda (top-level) degil.
    lock_fn = inference.split("function Get-AuditLock")[1].split("function Write-AuditLog")[0]
    assert "[System.Threading.Mutex]::new($false, 'Local\\MamidLabsAuditLog')" in lock_fn


def test_tool_call_site_logs_both_success_and_error_paths():
    inference = read_text("agent/mamidlabs-inference.ps1")
    assert "Write-AuditLog $name $approval $auditResult $auditDetail" in inference
    assert "Write-AuditLog $name (if ($script:lastApprovalOutcome)" in inference


def test_denied_approval_is_recorded_as_denied_not_ok():
    inference = read_text("agent/mamidlabs-inference.ps1")
    assert "$auditResult = if ($approval -in @('asked_no', 'cancelled', 'timeout')) { 'denied' } else { 'ok' }" in inference


def test_write_bound_file_tracks_its_changed_path():
    """create_document zaten $script:createdArtifact ayarliyordu; write_bound_file
    ayarlamiyordu - audit kaydinda changedPath hep bos kalirdi."""
    inference = read_text("agent/mamidlabs-inference.ps1")
    section = inference.split("if ($name -eq 'write_bound_file')")[1].split(
        "if ($name -eq 'run_command')"
    )[0]
    assert "$script:createdArtifact = $target" in section
