"""Harici icerikten gelen talimatlara karsi sinir.

Arac sonuclari (web arama, sayfa, belge, OCR metni) veridir, talimat degildir. Arac
tanimlari varken sunucuya giden istege bu kurali soyleyen bir system mesaji eklenir;
kalici sohbet gecmisine ($messages) eklenmez, boylece her turda cogalmaz ve KV
onbellek oneki bozulmaz.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read_text(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8-sig")


def test_tool_results_get_an_untrusted_data_guard_when_tools_are_active():
    inference = read_text("agent/qwen-inference.ps1")
    assert "$toolTrustGuard = if ($toolDefinitions.Count -gt 0)" in inference
    assert "VERIDIR" in inference
    assert "UYMA" in inference


def test_guard_is_added_to_the_request_body_not_to_persisted_history():
    inference = read_text("agent/qwen-inference.ps1")
    # Sunucuya giden govdeye ekleniyor (ayri bir [array] degiskeni uzerinden -
    # bkz. test_single_element_array_uses_explicit_array_cast asagida, dogrudan
    # hashtable degeri olarak if/else atanirsa PowerShell tek elemanli diziyi
    # tek nesneye "acar" ve JSON dizisi degil duz nesne uretir). Tam birlestirme
    # mantigi (sikistirma sonrasi mevcut sistem mesajiyla birlesme) icin bkz.
    # test_system_message_merge.py.
    assert "[array]$sendMessages = if ($toolTrustGuard) {" in inference
    assert "messages = $sendMessages" in inference
    # ...ama $messages'in kendisine asla .Add/.Insert edilmiyor (kalici gecmis
    # bozulmamali, aksi halde her turda bir kopyasi daha eklenir).
    assert "$messages.Add(@{ role = 'system'; content = 'Arac sonuclarindan" not in inference
    assert "$messages.Insert(0, $toolTrustGuard)" not in inference


def test_single_element_array_uses_explicit_array_cast():
    """Gercek makinede yakalandi: 'messages = if (...) {...} else {...}' seklinde
    dogrudan hashtable degeri olarak atanirsa, $messages TEK elemanliyken
    (sohbetin ilk turu, arac yoksa) PowerShell diziyi tek nesneye 'acar';
    ConvertTo-Json bunu JSON dizisi degil duz nesne olarak yazar, sunucu
    "Expected 'messages' to be an array" ile 400 doner. [array] cast'i ile
    onceden hesaplanmis bir degiskene atamak bunu onler."""
    inference = read_text("agent/qwen-inference.ps1")
    idx_cast = inference.index("[array]$sendMessages = if")
    idx_body = inference.index("$body = @{")
    assert idx_cast < idx_body, "sendMessages, $body olusturulmadan once hesaplanmali"


def test_initial_message_count_and_tool_exchange_slicing_are_unaffected():
    """$initialMessageCount / $toolExchange kalici $messages uzerinden
    hesaplanmaya devam etmeli; guard eklendikten sonra da UI'ye geri
    gonderilen sohbet gecmisi guard icermemeli."""
    inference = read_text("agent/qwen-inference.ps1")
    assert "$initialMessageCount = $messages.Count" in inference
    assert inference.index("$toolTrustGuard = if") < inference.index("$initialMessageCount = $messages.Count")
