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


def _ps_quote(text: str) -> str:
    return "'" + text.replace("'", "''") + "'"


def test_intent_helpers_classify_prompts(tmp_path):
    """Belge/video/grafik niyet yardimcilari: kullanici acikca istemediyse arac
    CALISTIRILMAZ. Gercek PowerShell'de siniflandirma dogrulanir."""
    pwsh = shutil.which("pwsh")
    if not pwsh:
        pytest.skip("pwsh bulunamadi")
    desktop = (ROOT / "agent" / "mamidlabs-inference.ps1").read_text(encoding="utf-8-sig")
    defs = "\n".join(
        extract_function(desktop, name)
        for name in ("Test-DocumentRequestIntent", "Test-VideoRequestIntent", "Test-ChartRequestIntent")
    )
    cases = [
        ("doc_pdf", "Test-DocumentRequestIntent $T", "bana bir PDF oluştur", True),
        ("doc_word", "Test-DocumentRequestIntent $T", "word belgesi hazırla", True),
        ("doc_sunum", "Test-DocumentRequestIntent $T", "bir sunum yap", True),
        ("doc_rapor", "Test-DocumentRequestIntent $T", "kısa bir rapor hazırla ve kaydet", True),
        ("doc_neg_bilgi", "Test-DocumentRequestIntent $T", "kediler hakkında kısaca bilgi ver", False),
        ("doc_neg_oku", "Test-DocumentRequestIntent $T", "bu belgeyi oku ve özetle", False),
        ("doc_neg_mat", "Test-DocumentRequestIntent $T", "2 + 2 kaç eder?", False),
        ("vid_uret", "Test-VideoRequestIntent $T $false", "kısa bir video üret", True),
        ("vid_olustur", "Test-VideoRequestIntent $T $false", "bir video oluştur", True),
        ("vid_neg_bilgi", "Test-VideoRequestIntent $T $false", "kediler hakkında bilgi ver", False),
        ("vid_neg_soru", "Test-VideoRequestIntent $T $false", "bu videoda ne oluyor?", False),
        ("vid_ctx_devam", "Test-VideoRequestIntent $T $true", "bu videonun devamını getir", True),
        ("chart_ciz", "Test-ChartRequestIntent $T", "nüfus grafiği çiz", True),
        ("chart_cubuk", "Test-ChartRequestIntent $T", "çubuk grafiği oluştur", True),
        ("chart_plot", "Test-ChartRequestIntent $T", "plot sin(x) from 0 to 10", True),
        ("chart_neg_bilgi", "Test-ChartRequestIntent $T", "kediler hakkında bilgi ver", False),
        ("chart_neg_mat", "Test-ChartRequestIntent $T", "5 faktöriyel kaçtır?", False),
    ]
    lines = ["$ErrorActionPreference = 'Stop'", defs, "$T = ''", "$res = [ordered]@{}"]
    for key, call, prompt, _ in cases:
        lines.append(f"$T = {_ps_quote(prompt)}")
        lines.append(f"$res['{key}'] = [bool]({call.replace('$T', '$T')})")
    lines.append("$res | ConvertTo-Json -Compress")
    script = tmp_path / "intent.ps1"
    script.write_text("\n".join(lines), encoding="utf-8-sig")
    proc = subprocess.run([pwsh, "-NoProfile", "-NonInteractive", "-File", str(script)],
                          capture_output=True, encoding="utf-8", errors="replace", check=False)
    assert proc.returncode == 0, proc.stderr or proc.stdout
    got = json.loads(proc.stdout.strip().splitlines()[-1])
    for key, _, prompt, expected in cases:
        assert got[key] is expected, f"{key} ({prompt!r}) = {got[key]}, beklenen {expected}"


def test_worker_refuses_unprompted_generation_calls():
    """Arac dongusunde niyet yoksa create_document/generate_video/generate_chart
    calistirilmaz (generate_image'daki korumanin aynisi)."""
    worker = (ROOT / "agent" / "mamidlabs-inference.ps1").read_text(encoding="utf-8-sig")
    assert "function Test-DocumentRequestIntent" in worker
    assert "function Test-VideoRequestIntent" in worker
    assert "function Test-ChartRequestIntent" in worker
    assert "$name -eq 'generate_video' -and !(Test-VideoRequestIntent $userText" in worker
    assert "$name -eq 'create_document' -and !(Test-DocumentRequestIntent $userText)" in worker
    assert "$name -eq 'generate_chart' -and !(Test-ChartRequestIntent $userText)" in worker
    # Video uretimi ayrica ust blokta (arayuze devretmeden once) korunur.
    assert "if ($videoCall -and !(Test-VideoRequestIntent $userText" in worker


def test_web_failure_note_is_appended(tmp_path):
    """Web araci DENENIP HIC basarili olmadiysa ve yanit bunu belirtmiyorsa durust bir not
    eklenir; zaten belirtiliyorsa yanit degismez. Kismi basarisizlik (bir sayfa 403 / bir
    sorgu 'sonuc yok') aramayi basarisiz YAPMAZ: en az bir web cagrisi basarili olduysa
    'arama basarisiz' notu eklenmez (gercek testte 7 cagrinin 4'u basariliydi)."""
    pwsh = shutil.which("pwsh")
    if not pwsh:
        pytest.skip("pwsh bulunamadi")
    desktop = (ROOT / "agent" / "mamidlabs-inference.ps1").read_text(encoding="utf-8-sig")
    fn = extract_function(desktop, "Add-WebFailureNote")
    body = (
        "$ErrorActionPreference = 'Stop'\n" + fn + "\n"
        "$r = [ordered]@{}\n"
        "$script:webToolFailCount = 0; $r['none'] = Add-WebFailureNote 'merhaba'\n"
        "$script:webToolFailCount = 1; $r['plain'] = Add-WebFailureNote 'merhaba'\n"
        "$script:webToolFailCount = 1; $r['ack'] = Add-WebFailureNote 'Web aramasi basarisiz oldu.'\n"
        "$script:webToolFailCount = 1; $script:webToolSuccess = $true; $r['mixed'] = Add-WebFailureNote 'merhaba'\n"
        "$r | ConvertTo-Json -Compress -EscapeHandling EscapeNonAscii\n"
    )
    script = tmp_path / "note.ps1"
    script.write_text(body, encoding="utf-8-sig")
    proc = subprocess.run([pwsh, "-NoProfile", "-NonInteractive", "-File", str(script)],
                          capture_output=True, encoding="utf-8", errors="replace", check=False)
    assert proc.returncode == 0, proc.stderr or proc.stdout
    got = json.loads(proc.stdout.strip().splitlines()[-1])
    assert got["none"] == "merhaba"
    assert "İnternet araması başarısız" in got["plain"]
    assert got["ack"] == "Web aramasi basarisiz oldu."
    assert got["mixed"] == "merhaba"


def test_document_tool_requires_a_document_context():
    """read_document yalnizca ekli belge ya da dosya niyeti varsa sunulur (kucuk model
    olmayan bir dosyayi uydurup cagiriyordu)."""
    worker = (ROOT / "agent" / "mamidlabs-inference.ps1").read_text(encoding="utf-8-sig")
    assert "function Add-WebFailureNote" in worker
    assert "function Get-FinalAnswer" in worker
    assert "Emit 'done' (Get-FinalAnswer $final $userText ([bool]$JobData.internet)) $lastUsage $toolExchange" in worker
    assert "$hasDocumentContext = @($script:attachedDocuments).Count -gt 0 -or (Test-FileIntent $userText)" in worker
    assert "if ($hasDocumentContext) {" in worker
    # Tekrar-dongu saglamlastirmasi.
    assert "$script:completedTools = @{}" in worker
    assert "$offeredTools = @($offeredTools | Where-Object { -not $script:completedTools.ContainsKey($_.function.name) })" in worker


def test_web_research_turn_does_not_offer_generation_tools():
    """Web arastirmasi (guncel bilgi) turunda acikca istenmedikce gorsel/video/belge/grafik
    araclari hic sunulmaz; model bu islere girisemez."""
    worker = (ROOT / "agent" / "mamidlabs-inference.ps1").read_text(encoding="utf-8-sig")
    assert "if (Test-CurrentInfoIntent $userText) {" in worker
    assert "$defs = @($defs | Where-Object { $_.function.name -notin @('generate_image', 'generate_video', 'create_document', 'generate_chart') })" in worker
    assert "Test-DocumentRequestIntent $userText" in worker
    assert "Test-ChartRequestIntent $userText" in worker


def test_final_answer_blocks_fabrication_and_empty(tmp_path):
    """Guncel bilgi + web yoksa (arama basarisiz / Internet kapali) modelin metni
    KULLANILMAZ (uydurma ekrana gelmez); bos yanit yerine net mesaj verilir."""
    pwsh = shutil.which("pwsh")
    if not pwsh:
        pytest.skip("pwsh bulunamadi")
    desktop = (ROOT / "agent" / "mamidlabs-inference.ps1").read_text(encoding="utf-8-sig")
    defs = "\n".join(
        extract_function(desktop, n)
        for n in ("Test-CurrentInfoIntent", "Add-WebFailureNote", "Get-FinalAnswer")
    )
    cur = _ps_quote("Bugun Istanbulda hava durumu nasil? Guncel bilgi ver.")
    other = _ps_quote("Kediler hakkinda bilgi ver.")
    body = (
        "$ErrorActionPreference = 'Stop'\n" + defs + "\n"
        "$script:webToolFailCount = 0; $script:lastProducedFile = ''\n"
        "$r = [ordered]@{}\n"
        f"$r['offline'] = Get-FinalAnswer 'UYDURMA 21 derece' {cur} $false\n"
        "$script:webToolFailCount = 2\n"
        f"$r['webfail'] = Get-FinalAnswer 'UYDURMA iPhone 15' {cur} $true\n"
        "$script:webToolFailCount = 0\n"
        f"$r['normal'] = Get-FinalAnswer 'kediler memelidir' {other} $true\n"
        f"$r['empty'] = Get-FinalAnswer '' {other} $true\n"
        "$script:lastProducedFile = 'C:\\out\\grafik.png'\n"
        f"$r['empty_file'] = Get-FinalAnswer '' {other} $true\n"
        "$r | ConvertTo-Json -Compress -EscapeHandling EscapeNonAscii\n"
    )
    script = tmp_path / "final.ps1"
    script.write_text(body, encoding="utf-8-sig")
    proc = subprocess.run([pwsh, "-NoProfile", "-NonInteractive", "-File", str(script)],
                          capture_output=True, encoding="utf-8", errors="replace", check=False)
    assert proc.returncode == 0, proc.stderr or proc.stdout
    got = json.loads(proc.stdout.strip().splitlines()[-1])
    assert "UYDURMA" not in got["offline"] and "internet bağlantısı olmadan" in got["offline"]
    assert "UYDURMA" not in got["webfail"] and "başarısız" in got["webfail"]
    assert got["normal"] == "kediler memelidir"
    assert "üretilemedi" in got["empty"]
    assert "grafik.png" in got["empty_file"]


def test_strict_fabrication_guard_strips_citations_and_blocks_current_info(tmp_path):
    """Sert anti-uydurma: web DENENDI ama basarili olmadiysa (a) guncel bilgi sorusunda
    model metni gosterilmez, (b) diger yanitlarda uydurma 'Kaynak:'/URL satirlari cikarilir."""
    pwsh = shutil.which("pwsh")
    if not pwsh:
        pytest.skip("pwsh bulunamadi")
    desktop = (ROOT / "agent" / "mamidlabs-inference.ps1").read_text(encoding="utf-8-sig")
    defs = "\n".join(
        extract_function(desktop, n)
        for n in ("Test-CurrentInfoIntent", "Add-WebFailureNote", "Remove-FabricatedCitations", "Get-FinalAnswer")
    )
    cur = _ps_quote("En son cikan iPhone modeli hangisi?")
    other = _ps_quote("Python'da liste nasil ters cevrilir?")
    body = (
        "$ErrorActionPreference = 'Stop'\n" + defs + "\n"
        "$script:lastProducedFile = ''\n"
        "$r = [ordered]@{}\n"
        # Web denendi, basarisiz; guncel bilgi sorusu -> metin gosterilmez.
        "$script:webToolFailCount = 1; $script:webToolAttempted = $true; $script:webToolSuccess = $false\n"
        f"$r['cur_fail'] = Get-FinalAnswer 'UYDURMA iPhone 15 Pro' {cur} $true\n"
        # Web denendi, basarisiz; normal soru -> uydurma kaynak/URL satirlari cikarilir.
        f"$r['strip'] = Get-FinalAnswer \"Kisa yol: reversed().`nKaynak: https://example.com/x`nDaha fazla: https://foo.bar\" {other} $true\n"
        # Web hic denenmedi -> normal yanit DOKUNULMAZ (mesru baglanti korunur).
        "$script:webToolFailCount = 0; $script:webToolAttempted = $false; $script:webToolSuccess = $false\n"
        f"$r['no_web'] = Get-FinalAnswer 'Bkz. https://docs.python.org/3/' {other} $true\n"
        # Web basarili -> metin aynen kalir.
        "$script:webToolAttempted = $true; $script:webToolSuccess = $true\n"
        f"$r['web_ok'] = Get-FinalAnswer 'Sonuc: iPhone 16. Kaynak: https://apple.com' {cur} $true\n"
        # Kismi basarisizlik: bir cagri 403/bos dondu ama baska cagrilar veriyi getirdi
        # -> 'arama basarisiz' notu EKLENMEZ ve atiflar korunur (gercek test bulgusu).
        "$script:webToolFailCount = 1; $script:webToolAttempted = $true; $script:webToolSuccess = $true\n"
        f"$r['partial'] = Get-FinalAnswer 'Zonguldak yarin 21 derece. Kaynak: https://www.hurriyet.com.tr/hava-durumu/zonguldak/' {cur} $true\n"
        "$r | ConvertTo-Json -Compress -EscapeHandling EscapeNonAscii\n"
    )
    script = tmp_path / "strict.ps1"
    script.write_text(body, encoding="utf-8-sig")
    proc = subprocess.run([pwsh, "-NoProfile", "-NonInteractive", "-File", str(script)],
                          capture_output=True, encoding="utf-8", errors="replace", check=False)
    assert proc.returncode == 0, proc.stderr or proc.stdout
    got = json.loads(proc.stdout.strip().splitlines()[-1])
    assert "UYDURMA" not in got["cur_fail"] and "internet bağlantısı olmadan" in got["cur_fail"]
    assert "example.com" not in got["strip"] and "foo.bar" not in got["strip"]
    assert "reversed()" in got["strip"]
    assert "docs.python.org" in got["no_web"]
    assert "apple.com" in got["web_ok"] and "iPhone 16" in got["web_ok"]
    assert "hurriyet.com.tr" in got["partial"] and "İnternet araması başarısız" not in got["partial"]


def test_friendly_error_message_maps_raw_dotnet(tmp_path):
    """Ham .NET/HTTP hata mesajlari (or. 'The response ended prematurely.') kullaniciya
    sade Turkce mesaj olarak gosterilir; taninmayan mesaj aynen doner."""
    pwsh = shutil.which("pwsh")
    if not pwsh:
        pytest.skip("pwsh bulunamadi")
    desktop = (ROOT / "agent" / "mamidlabs-inference.ps1").read_text(encoding="utf-8-sig")
    fn = extract_function(desktop, "Get-FriendlyErrorMessage")
    raw = _ps_quote("The response ended prematurely. (ResponseEnded)")
    unknown = _ps_quote("Beklenmedik ozel hata")
    body = (
        "$ErrorActionPreference = 'Stop'\n" + fn + "\n"
        "$r = [ordered]@{}\n"
        f"$r['premature'] = Get-FriendlyErrorMessage {raw}\n"
        f"$r['unknown'] = Get-FriendlyErrorMessage {unknown}\n"
        f"$r['empty'] = Get-FriendlyErrorMessage ''\n"
        "$r | ConvertTo-Json -Compress -EscapeHandling EscapeNonAscii\n"
    )
    script = tmp_path / "friendly.ps1"
    script.write_text(body, encoding="utf-8-sig")
    proc = subprocess.run([pwsh, "-NoProfile", "-NonInteractive", "-File", str(script)],
                          capture_output=True, encoding="utf-8", errors="replace", check=False)
    assert proc.returncode == 0, proc.stderr or proc.stdout
    got = json.loads(proc.stdout.strip().splitlines()[-1])
    assert "yarıda kesildi" in got["premature"] and "prematurely" not in got["premature"]
    assert got["unknown"] == "Beklenmedik ozel hata"
    assert "Beklenmeyen" in got["empty"]
    # Sadece dusunme birikmisken kopan akis HATA degil (kurtarma yoluna gider).
    worker = (ROOT / "agent" / "mamidlabs-inference.ps1").read_text(encoding="utf-8-sig")
    assert "$usable = $result.finishReason -or ![string]::IsNullOrWhiteSpace($result.content) -or $result.toolParts.Count -gt 0 -or ![string]::IsNullOrWhiteSpace($result.reasoning)" in worker
    assert "Get-FriendlyErrorMessage $cause.Message" in worker
