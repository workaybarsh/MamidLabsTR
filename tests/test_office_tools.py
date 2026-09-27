"""Belge kenar durumlari: bozuk, sifreli ve izin kisitli PDF.

- Kullanici parolasiyla sifreli PDF: teknik istisna yerine acik bir Turkce mesaj.
- Yalnizca izinleri kisitlanmis (bos kullanici parolali) PDF: decrypt('') ile acilir
  ve okunur; ayrim is_encrypted'e degil decrypt('')'in donus koduna gore yapilir.
- Bozuk PDF: main() her handler'i genel bir try/except ile sarar; hata JSON error
  alaninda doner, worker cokmez.
"""
import importlib.util
import io
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKER = ROOT / "agent" / "office-tools.py"
SPEC = importlib.util.spec_from_file_location("office_tools", WORKER)
OFFICE_TOOLS = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(OFFICE_TOOLS)


def make_plain_pdf_to_buffer(dest, text):
    """dest bir dosya yolu (str) veya bir BytesIO olabilir."""
    from reportlab.pdfgen import canvas
    c = canvas.Canvas(dest)
    c.drawString(50, 700, text)
    c.save()
    if hasattr(dest, "seek"):
        dest.seek(0)


def run_worker(payload: dict) -> dict:
    """agent/office-tools.py'yi gercek cagrildigi gibi (stdin JSON -> stdout JSON)
    ayri bir surecte calistirir; main() icindeki genel try/except'i de kapsar."""
    proc = subprocess.run(
        [sys.executable, str(WORKER)],
        input=json.dumps(payload), capture_output=True, text=True,
        encoding="utf-8", errors="replace", timeout=30,
    )
    assert proc.returncode == 0, f"worker cokmus olmamali: {proc.stderr}"
    return json.loads(proc.stdout)


def test_read_pdf_works_on_a_plain_unencrypted_file(tmp_path):
    pdf = tmp_path / "plain.pdf"
    make_plain_pdf_to_buffer(str(pdf), "Sifresiz normal PDF metni.")
    result = OFFICE_TOOLS.read_pdf({"path": str(pdf)})
    assert "error" not in result
    assert "Sifresiz normal PDF metni" in result["text"]


def test_read_pdf_opens_permission_only_encrypted_files(tmp_path):
    """Bos kullanici parolali, yalnizca izin kisitli PDF'ler cok yaygindir
    (or. 'yazdirmayi engelle' ile disa aktarilan belgeler) ve gercekten
    okunabilir olmalidir."""
    from pypdf import PdfReader, PdfWriter

    buf = io.BytesIO()
    make_plain_pdf_to_buffer(buf, "Izin kisitli ama okunabilir metin.")
    plain = PdfReader(buf)
    writer = PdfWriter()
    writer.add_page(plain.pages[0])
    writer.encrypt(user_password="", owner_password="sahipsifresi", permissions_flag=-4)
    pdf = tmp_path / "perm-only.pdf"
    with open(pdf, "wb") as f:
        writer.write(f)

    result = OFFICE_TOOLS.read_pdf({"path": str(pdf)})
    assert "error" not in result, f"izin-kisitli PDF okunamadi: {result}"
    assert "Izin kisitli ama okunabilir metin" in result["text"]


def test_read_pdf_gives_a_clear_turkish_error_for_password_protected_files(tmp_path):
    from pypdf import PdfWriter

    writer = PdfWriter()
    writer.add_blank_page(width=200, height=200)
    writer.encrypt("gercekbirsifre")
    pdf = tmp_path / "encrypted.pdf"
    with open(pdf, "wb") as f:
        writer.write(f)

    result = OFFICE_TOOLS.read_pdf({"path": str(pdf)})
    assert result.get("error") == "Bu PDF sifreyle korunuyor; parolasiz okunamaz."


def test_worker_reports_a_readable_error_for_a_corrupt_pdf_without_crashing(tmp_path):
    pdf = tmp_path / "corrupt.pdf"
    pdf.write_bytes(b"%PDF-1.4 bozuk veri" + bytes([0, 1, 2, 3]) * 50)

    result = run_worker({"action": "read_pdf", "path": str(pdf)})
    assert "error" in result
    assert result["error"]  # bos olmayan, okunabilir bir mesaj
