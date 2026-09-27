"""Python bagimliliklarinin tek kaynagi requirements/*.txt dosyalaridir.

Kurulum betigi paket listelerini bu dosyalardan okur; surumler kilitlidir ve
requirements/app.txt agent/*.py dosyalarindaki gercek import'larla ayni olmalidir.
"""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read_text(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8-sig")


def parse_requirements(name: str) -> list[str]:
    lines = (ROOT / "requirements" / name).read_text(encoding="utf-8").splitlines()
    return [line.split("#", 1)[0].strip() for line in lines if line.split("#", 1)[0].strip()]


def package_name(pin: str) -> str:
    """'requests==2.34.2' -> 'requests'."""
    return re.split(r"[=<>!~]", pin, 1)[0].strip()


def test_requirements_files_exist_and_are_not_empty():
    for name in ("app.txt", "imagegen.txt"):
        packages = parse_requirements(name)
        assert packages, f"requirements/{name} bos olmamali"


def test_requirements_are_version_pinned():
    """Kilitli surumler olmadan farkli tarihlerde yapilan kurulumlar farkli
    paket surumleri alabilir."""
    for name in ("app.txt", "imagegen.txt"):
        for pin in parse_requirements(name):
            assert "==" in pin, f"requirements/{name}: '{pin}' surume kilitlenmemis"


def test_app_requirements_cover_every_agent_import():
    """agent/*.py'deki gercek import'larla requirements/app.txt ayni olmali;
    biri digerinden once guncellenirse kurulum sessizce eksik paket birakir."""
    packages = {package_name(p) for p in parse_requirements("app.txt")}
    # Modul adi -> PyPI paket adi (bire bir ayni olmayanlar).
    expected = {
        "requests", "pillow", "huggingface_hub", "ddgs", "pypdf",
        "reportlab", "python-docx", "python-pptx", "openpyxl", "rarfile",
    }
    assert packages == expected


def test_imagegen_requirements_exclude_torch():
    """torch/torchvision/torchaudio CUDA 13.0 index'inden ayri kurulur;
    requirements/imagegen.txt icinde olursa pip varsayilan CPU tekerlegini
    cekip GPU hizlandirmayi sessizce devre disi birakabilir."""
    packages = [package_name(p) for p in parse_requirements("imagegen.txt")]
    assert "av" in packages
    assert not any("torch" in p for p in packages)


def test_installer_reads_packages_from_requirements_files():
    installer = read_text("scripts/install-mamidlabs.ps1")

    assert "function Read-Requirements" in installer
    assert "$script:AppPackages = Read-Requirements 'app.txt'" in installer
    assert "$script:ImagegenPackages = Read-Requirements 'imagegen.txt'" in installer
    # Eksik dosyada sessizce bos listeyle devam etmemeli.
    assert "throw ('Bagimlilik dosyasi bulunamadi: ' + $path)" in installer
    # Bulunamayan dosya artik acikca hata vermeli; eski inline dizi kalmamali.
    assert "$script:AppPackages = @(" not in installer
