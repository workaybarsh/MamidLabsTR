"""Kurulum kokunun tasinabilirligi.

Uygulama hangi klasore kurulduysa oradan calisir; hicbir betik sabit bir kurulum yolu
yazmaz. mamidlabs-desktop.ps1 isciler (mamidlabs-inference.ps1, imagegen-run.ps1,
videogen-run.ps1, api-media-run.ps1) Start-ThreadJob -FilePath ile baslatir; bu
baglamda $PSScriptRoot bostur ve Get-Location ilgisiz bir klasor olabilir. Bu yuzden
kok JobData.root ile acikca tasinir; isciler yalnizca dogrudan calistirildiklarinda
$PSScriptRoot'a duser.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read_text(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8-sig")


def test_no_file_hardcodes_the_install_path():
    for path in ROOT.rglob("*"):
        if path.suffix not in (".ps1", ".vbs", ".py") or "tests" in path.parts:
            continue
        text = path.read_text(encoding="utf-8-sig", errors="ignore")
        # Varsayilan kok %LOCALAPPDATA%\\Programs\\MamidLabs'tir; sabit bir surucu koku
        # (orn. C:\\AI-Local) hicbir yerde yazilmamalidir.
        for line in text.splitlines():
            if "AI-Local" in line:
                raise AssertionError(f"{path.relative_to(ROOT)}: sabit yol kaldi -> {line.strip()!r}")


def test_worker_scripts_derive_root_from_their_own_location():
    for path in ("agent/imagegen-run.ps1", "agent/videogen-run.ps1", "agent/api-media-run.ps1"):
        text = read_text(path)
        assert "Split-Path -Parent $PSScriptRoot" in text
        # KRITIK: Start-ThreadJob -FilePath baglaminda $PSScriptRoot bostur;
        # JobData.root ONCE kontrol edilmeli.
        assert "if ($JobData.root)" in text
        assert text.index("if ($JobData.root)") < text.index("Split-Path -Parent $PSScriptRoot")


def test_mamidlabs_inference_uses_get_install_root_with_jobdata_priority():
    inference = read_text("agent/mamidlabs-inference.ps1")

    assert "function Get-InstallRoot" in inference
    assert "if ($JobData -and $JobData.root)" in inference
    assert "elseif ($PSScriptRoot)" in inference


def test_desktop_passes_root_to_every_threadjob_worker():
    """mamidlabs-desktop.ps1'in 4 Start-ThreadJob cagrisinin hepsi JobData.root
    gecirmeli; biri unutulursa o worker sessizce yanlis koke duser."""
    desktop = read_text("mamidlabs-desktop.ps1")

    threadjob_count = desktop.count("Start-ThreadJob -FilePath (Join-Path $root 'agent")
    assert threadjob_count == 4, f"beklenen 4 Start-ThreadJob cagrisi, bulunan {threadjob_count}"

    # Her $jobData = @{ blogunun hemen ardindan 'root = $root' gelmeli (compact,
    # chat, image, video islerinin dorduncusu de dahil).
    assert desktop.count("root = $root") >= 4


def test_hf_and_profile_catalog_pass_root_for_api_media_run():
    """api-media-run.ps1 de Start-ThreadJob -FilePath ile baslar; onu cagiran
    her yer (HF penceresi, profil indirici, medya API'si) root'u JobData'ya
    koymali."""
    for path in ("agent/hf-settings.ps1", "agent/profile-catalog.ps1", "agent/media-settings.ps1"):
        text = read_text(path)
        assert "root=$root" in text or "root = $root" in text, f"{path}: JobData.root eksik"


def test_launcher_derives_root_from_its_own_location():
    vbs = read_text("launch-mamidlabs-desktop.vbs")
    assert "GetParentFolderName(WScript.ScriptFullName)" in vbs


def test_python_workers_derive_root_from_file_location():
    for path, marker in (
        ("agent/api-media.py", "pathlib.Path(__file__).resolve().parent.parent"),
        ("agent/media-tools.py", "pathlib.Path(__file__).resolve().parent.parent"),
        ("agent/ocr-tools.py", "Path(__file__).resolve().parent.parent"),
        ("agent/office-tools.py", "os.path.dirname(os.path.dirname(os.path.abspath(__file__)))"),
        ("agent/mamidlabs-agent-tools.py", "os.path.dirname(os.path.dirname(os.path.abspath(__file__)))"),
    ):
        assert marker in read_text(path), f"{path}: __file__ tabanli kok turetme eksik"
