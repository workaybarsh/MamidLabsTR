"""Masaustu kisayolu calismiyordu: launch-mamidlabs-desktop.vbs UTF-8 BOM ile
kaydedilmisti (0xEF 0xBB 0xBF ile baslayan bayt dizisi). Klasik VBScript
motoru (cscript/wscript - WinForms uygulamasini baslatan .vbs dosyasi bunu
kullanir) UTF-8 BOM'u ANLAMAZ; dosyayi "Geçersiz karakter" derleme
hatasiyla reddeder. wscript ile calistirildiginda bu hata sessiz bir
"Windows Script Host" hata penceresi olarak gorunur - konsol yok, hicbir
sey acilmiyormus gibi gorunur, tam da kullanicinin bildirdigi belirti.

Gercek makinede dogrulandi: kullanicinin gercek .lnk kisayolu (Start-Process
ile) ve dogrudan cscript ile calistirildi - duzeltmeden ONCE ikisi de
sessizce basarisiz oldu (wscript "Windows Script Host" hata penceresiyle
takildi kaldi, cscript "derleme hatasi: Geçersiz karakter" bastı). BOM
kaldirildiktan sonra ikisi de MamidLabs penceresini gercekten actı.

Bu dosya her zaman ASCII icerik tasimali (Turkce karakter kullanilmiyor,
bkz. "gomulu" degil "gömülü") - bu yuzden BOM olmadan UTF-8/ANSI farki
yoktur, guvenle BOM'suz kaydedilebilir.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VBS = ROOT / "launch-mamidlabs-desktop.vbs"


def test_launcher_has_no_utf8_bom():
    data = VBS.read_bytes()
    assert not data.startswith(b"\xef\xbb\xbf"), (
        "launch-mamidlabs-desktop.vbs UTF-8 BOM ile kaydedilmis; klasik VBScript "
        "motoru bunu 'Gecersiz karakter' derleme hatasiyla reddeder ve "
        "masaustu kisayolu sessizce hicbir sey acmaz."
    )


def test_launcher_is_pure_ascii():
    """Turkce karakter kullanilmadigindan (bkz. 'gomulu') BOM'suz kaydetmek
    guvenlidir; ileride bir Turkce karakter eklenirse bu test bunu yakalar -
    boyle bir durumda BOM'suz UTF-8 yerine ayri bir cozum (or. ANSI) gerekir."""
    data = VBS.read_bytes()
    try:
        data.decode("ascii")
    except UnicodeDecodeError as exc:
        raise AssertionError(
            "launch-mamidlabs-desktop.vbs artik ASCII olmayan bir karakter iceriyor; "
            "klasik VBScript motoru icin dogru kodlamayi (ANSI/UTF-16LE+BOM) "
            "ayrica dogrula, sessizce UTF-8'e guvenme."
        ) from exc
