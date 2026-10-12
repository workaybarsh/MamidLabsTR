"""LaTeX (matematik) -> okunur Unicode donusumu (qwen-desktop.ps1 Convert-MathText).

Model matematik yaniti urettiginde ham "$$", "\\frac{}{}", "\\int" gibi isaretler
arayuzde "bozuk sembol" gibi gorunuyordu. Convert-MathText bunlari Unicode
karsiliklariyla degistirir (∫, ∞, π, √, ∑), kesirleri a/b yapar ve us/alt simgeleri
cevirir (x^2 -> x²). Gercek matematik dizgisi degil; okunur metin amaclidir.
"""
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]


def read_text(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8-sig")


def extract_functions(source: str, names) -> str:
    import re
    out = []
    for name in names:
        m = re.search(r"function " + re.escape(name) + r"\b[\s\S]*?\n\}", source)
        assert m, f"{name} bulunamadi"
        out.append(m.group(0))
    return "\n".join(out)


def run_convert(samples) -> str:
    pwsh = shutil.which("pwsh")
    if not pwsh:
        pytest.skip("PowerShell 7 is unavailable")
    src = read_text("qwen-desktop.ps1")
    fns = extract_functions(src, [
        "Read-MathGroup", "Read-MathAtom", "Add-MathAccent",
        "Convert-ToSuperscript", "Convert-ToSubscript", "Expand-MathCommands",
        "Convert-MathText",
    ])
    # Python ciktiyi UTF-8 cozer; konsol kod sayfasi farkli olabilir (cp1254). Sabitle.
    prelude = "[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)\n"
    blocks = []
    for s in samples:
        # Here-string terminatöru ('@) satir basinda (girintisiz) olmali.
        blocks.append("$__s = @'\n" + s + "\n'@\nWrite-Output (Convert-MathText $__s)")
    script = prelude + fns + "\n" + "\n".join(blocks) + "\n"
    proc = subprocess.run([pwsh, "-NoProfile", "-NonInteractive", "-Command", script],
                          capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=60)
    assert proc.returncode == 0, proc.stdout + proc.stderr
    return proc.stdout


def test_math_symbols_are_converted_to_unicode():
    samples = [
        r"$$\int_0^\infty \frac{(\ln x)^4}{1+x^6}\,dx < \infty$$",
        r"$$\sum_{n=1}^{\infty}\frac{\pi^2}{6}$$",
        r"$x \to 0^+$ ve $\alpha \geq \beta$",
    ]
    out = run_convert(samples)
    for glyph in ("\u222b", "\u221e", "\u03c0", "\u2211", "\u2192", "\u2265", "\u03b1"):
        assert glyph in out, f"eksik glif: {glyph!r}"
    # Ham LaTeX isaretleri kalmamali
    assert "$$" not in out
    assert "\\frac" not in out
    assert "\\int" not in out


def test_exponents_and_subscripts_become_unicode():
    out = run_convert([r"x^4 + x^6 + x^{10}", r"\int_0^\infty", r"n^2"])
    for glyph in ("\u2074", "\u2076", "\u00b9", "\u2070", "\u2080", "\u00b2"):
        assert glyph in out, f"eksik us/alt simge: {glyph!r}"


def test_plain_currency_dollar_is_not_stripped_without_latex():
    out = run_convert(["Fiyat: 100 $ ve 200 $"])
    assert "100 $ ve 200 $" in out


def test_plain_text_is_not_corrupted():
    """Onceki surumde ic ice dizi duzlesmesi harfleri bozuyordu ('Fiyat'->'Fiyaa'); regresyon."""
    out = run_convert(["Fiyat: 100 $ ve 200 $ (LaTeX yok)", "Merhaba dunya"])
    assert "Fiyat" in out
    assert "Merhaba dunya" in out


def test_chemistry_symbols_and_mhchem_ce():
    """Kimya: denge oku (\\rightleftharpoons -> ⇌) ve mhchem \\ce{...} icerigi okunur hale
    gelir (element sayilari alt simge, oklar ok). Kod bloklarindaki '->' bozulmaz."""
    out = run_convert([
        r"A + B \rightleftharpoons C",
        r"\ce{2H2 + O2 -> 2H2O}",
        r"\ce{H2SO4}",
    ])
    assert "\u21cc" in out, "denge oku (⇌) yok"
    assert "\u2082" in out and "\u2084" in out, "kimya alt simgeleri (₂, ₄) yok"
    assert "\u2192" in out, "kimyasal ok (→) yok"
    # \ce sarmalayicisi kalmamali
    assert "\\ce" not in out


def test_plain_arrow_outside_ce_is_not_converted():
    """'->' yalnizca \\ce icinde oka cevrilir; kod/duz metin bozulmaz."""
    out = run_convert(["sozluk a->b biciminde ve x <- y"])
    assert "a->b" in out
    assert "x <- y" in out


def test_nested_fraction_groups_are_balanced():
    """Blok \\frac ic ice/kumeli parantezli olabilir; regex + `[^{}]*` bunu cozemiyordu.
    Dengeleyen ayristirici ic ice kumeleri ve kacisli \\{ \\} karakterlerini dogru isler."""
    out = run_convert([
        r"\frac{\pi^5 (89+72\sqrt{3})}{3888}",
        r"\frac{\{a\}}{b}",
    ])
    # Ham LaTeX kalintisi olmamali; kesir '/' ile okunur olmali.
    assert "\\frac" not in out
    assert "\\sqrt" not in out
    assert "3888" in out
    assert "\u03c0" in out and "\u221a" in out  # π, √
    assert "/" in out
    # Kacisli kume parantezleri icerik olarak korunur (kacis kaldirilir).
    assert "({a})/b" in out


def test_boxed_and_fbox_become_readable_text():
    """\\boxed/\\fbox kutu yerine duz metne (koseli parantezle) cevrilir; icerigi de cozulur."""
    out = run_convert([
        r"\boxed{x=5}",
        r"\fbox{E}",
        r"\boxed{\frac{\pi^5(89+72\sqrt3)}{3888}}",
    ])
    assert "\\boxed" not in out and "\\fbox" not in out
    assert "\\frac" not in out and "\\sqrt" not in out
    assert "[ x=5 ]" in out
    assert "[ E ]" in out
    assert "3888" in out and "\u03c0" in out and "\u221a" in out


def test_text_wrappers_keep_their_content():
    """\\textbf/\\textit/\\mathrm/\\text/\\operatorname sarmalayicilari icerikle degisir."""
    out = run_convert([
        r"\textbf{Kalin} \textit{egik} \mathrm{d}x \text{duz} \operatorname{sgn}(x)",
    ])
    for cmd in ("\\textbf", "\\textit", "\\mathrm", "\\text", "\\operatorname"):
        assert cmd not in out, f"ham komut kaldi: {cmd}"
    assert "Kalin" in out and "egik" in out
    assert "dx" in out and "duz" in out and "sgn(x)" in out


def test_sqrt_nested_and_root_index():
    """\\sqrt{X} -> √(X); ic ice \\sqrt ve \\sqrt[n]{X} -> ⁿ√(X)."""
    out = run_convert([
        r"\sqrt{1+x^2}",
        r"\sqrt[3]{8}",
        r"\sqrt{\frac{a}{b}}",
    ])
    assert "\\sqrt" not in out
    assert "\u221a" in out          # √
    assert "\u00b3" in out          # ³ kok derecesi
    assert "1+x\u00b2" in out        # x²
    assert "\u221a(a/b)" in out      # ic ice kesir


def test_left_right_delimiters_are_simplified():
    """\\left/\\right sade paranteze indirilir; \\{ \\} kacislari { } olur."""
    out = run_convert([
        r"\left( \frac{a}{b} \right)",
        r"\left\{ x \right\}",
    ])
    assert "\\left" not in out and "\\right" not in out
    assert "a/b" in out
    assert "( a/b )" in out
    assert "{ x }" in out


def test_integral_and_sum_limits_become_unicode():
    """\\int_0^\\infty -> ∫₀^∞; alt/ust sinirlar Unicode'a cevrilir; ^/\\_ kalmaz (∞ haric)."""
    out = run_convert([
        r"\int_0^\infty e^{-x}\,dx",
        r"\sum_{n=1}^{\infty} \frac{1}{n^2}",
    ])
    assert "\u222b" in out and "\u2211" in out   # ∫, ∑
    assert "\u2080" in out and "\u221e" in out   # ₀, ∞
    assert "\\int" not in out and "\\sum" not in out and "\\frac" not in out
    assert "_{" not in out and "_0" not in out
    assert "^{" not in out


def test_greek_letters_and_operator_symbols_expanded():
    """Yunan harfleri ve \\cdot/\\times/\\pm/\\approx/\\neq/\\leq/\\geq glifleri."""
    out = run_convert([
        r"\zeta(s) = \sum \frac{1}{n^s}",
        r"a \cdot b \times c \pm d \approx e \neq f \leq g \geq h",
    ])
    for glyph in ("\u03b6", "\u00b7", "\u00d7", "\u00b1", "\u2248", "\u2260", "\u2264", "\u2265"):
        assert glyph in out, f"eksik glif: {glyph!r}"
    assert "\\zeta" not in out


def test_accents_overline_vec_hat():
    """\\overline/\\bar ust cizgi; \\vec ok; \\hat sapka birlestirici isaretle eklenir."""
    out = run_convert([r"\overline{AB}", r"\vec{v}", r"\hat{x}", r"\bar{z}"])
    assert "\u0305" in out          # combining overline
    assert "\u20d7" in out          # combining right arrow above
    assert "\u0302" in out          # combining circumflex
    assert "\\overline" not in out and "\\vec" not in out and "\\hat" not in out
