"""Test ortamini kurulu MamidLabs'ten tamamlar.

Sistemde PowerShell 7 PATH'te degilse PowerShell testleri atlanir, pypdf/reportlab
sistem Python'unda yoksa PDF testleri calismaz. Kurulum koku (MAMIDLABS_ROOT, yoksa
%LOCALAPPDATA%\\Programs\\MamidLabs) varsa:
- gomulu runtime\\pwsh PATH'in basina eklenir,
- venv\\app paketleri (ayni Python surumuyse) sys.path'e eklenir.
"""
import os
import re
import shutil
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]


def _install_roots():
    roots = [
        os.environ.get("MAMIDLABS_ROOT"),
        str(REPO),
        os.path.expandvars(r"%LOCALAPPDATA%\Programs\MamidLabs"),
    ]
    return [Path(r) for r in roots if r]


def _add_bundled_pwsh():
    if shutil.which("pwsh"):
        return
    for root in _install_roots():
        candidate = root / "runtime" / "pwsh" / "pwsh.exe"
        if candidate.is_file():
            os.environ["PATH"] = str(candidate.parent) + os.pathsep + os.environ.get("PATH", "")
            return


def _add_app_packages():
    try:
        import pypdf  # noqa: F401
        import reportlab  # noqa: F401
        return
    except ImportError:
        pass
    for root in _install_roots():
        venv = root / "venv" / "app"
        cfg = venv / "pyvenv.cfg"
        site = venv / "Lib" / "site-packages"
        if not (cfg.is_file() and site.is_dir()):
            continue
        # Derlenmis paketler yalnizca ayni ana/alt surumde calisir.
        match = re.search(r"^version\s*=\s*(\d+)\.(\d+)", cfg.read_text(encoding="utf-8"), re.MULTILINE)
        if match and (int(match.group(1)), int(match.group(2))) == sys.version_info[:2]:
            sys.path.append(str(site))
            return


_add_bundled_pwsh()
_add_app_packages()
