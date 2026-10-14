"""Betik tabanli guncelleme (install-mamidlabs.ps1 -Stage layout) sihirbazin kaynak
paketini ({kok}\\kurulum-kaynak) de tazelemeli.

Sihirbazla kurulmus bir kokte `kurulum-kaynak` program kaynagini tutar ve Inno'nun
iptal/geri alma mekanizmasinda kullanilir. Betik tabanli guncelleme bu klasoru
tazelemedigi icin onceki surumden kaliyordu; artik varsa tazelenir, betik kurulumunda
(klasor yoksa) olusturulmaz.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read_text(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8-sig")


def test_layout_refreshes_existing_wizard_source_package():
    script = read_text("scripts/install-mamidlabs.ps1")
    assert "$kaynak = Join-Path $Root 'kurulum-kaynak'" in script
    # Yalnizca var olan (sihirbaz kurulumu) klasor tazelenir.
    assert "if (Test-Path -LiteralPath $kaynak -PathType Container)" in script
    # Ayni [Files] kumesi kopyalanir (kurulum-kaynak alt paketi).
    assert "foreach ($folder in @('agent', 'scripts', 'requirements'))" in script
    assert "Join-Path $Source 'docs\\kurulum.md'" in script
    # assets\installer da dahil tum assets kopyalanir (kurulu program dosyalari repoyla birebir ayni).
    assert "Get-ChildItem -LiteralPath $assets -Force | ForEach-Object" in script
    assert "Where-Object { $_.Name -ne 'installer' }" not in script
    # Tazeleme bildirilir; sessizce yapilmaz.
    assert "Kurulum kaynak paketi tazelendi" in script


def test_layout_creates_source_package_only_when_it_exists():
    """Betikle yapilan kurulumda `kurulum-kaynak` boşuna olusturulmamali; kopyalama
    blogu bir Test-Path kosulu icinde olmali."""
    script = read_text("scripts/install-mamidlabs.ps1")
    start = script.index("$kaynak = Join-Path $Root 'kurulum-kaynak'")
    end = script.index("Kurulum kaynak paketi tazelendi")
    block = script[start:end]
    assert "Test-Path -LiteralPath $kaynak -PathType Container" in block
    assert "New-Item -ItemType Directory -Path $kaynak" not in block


def test_layout_copies_eula_to_root_and_source_package():
    """EULA.txt sihirbazin lisans sayfasinda gosterilir ve .iss [Files] kaynak pakete
    koyar; betik tabanli guncellemede de hem koke hem kurulum-kaynak'e kopyalanmali.
    Aksi halde EULA yalnizca sihirbaz kurulumunda bulunur, betik guncellemesinde kaybolur."""
    script = read_text("scripts/install-mamidlabs.ps1")
    # Iki ust dosya listesi (kok + kurulum-kaynak) EULA.txt icermeli.
    assert script.count("'LICENSE', 'EULA.txt')") == 2
    # .iss de ayni kume ile uyusmali.
    iss = read_text("packaging/windows/mamidlabs.iss")
    assert 'Source: "..\\..\\EULA.txt"; DestDir: "{app}\\kurulum-kaynak"' in iss
