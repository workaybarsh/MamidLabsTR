"""Yerel RAG: bagli klasorde BM25 aramasi (`agent/rag-tools.py`).

Model buyuk bir klasorde ilgili parcalari bulmak icin once tum dosyalari
okumak zorunda kalmasin diye sozluk tabanli (BM25) yerel arama vardir; ek
paket gerekmez ve tamamen cevrimdisidir. Indeks tools\\rag altinda tutulur ve
dosya imzasi degismedikce yeniden kurulmaz. Bu testler gercek Python
alt sureciyle calisir; PowerShell tarafi statik olarak denetlenir.
"""
import json
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
TOOL = ROOT / "agent/rag-tools.py"


def read_text(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8-sig")


def run_tool(payload: dict) -> dict:
    result = subprocess.run(
        [sys.executable, str(TOOL)],
        input=json.dumps(payload), capture_output=True, text=True,
        encoding="utf-8", timeout=120,
    )
    assert result.returncode == 0, result.stderr
    return json.loads(result.stdout)


def make_folder(tmp_path: Path) -> Path:
    folder = tmp_path / "belgeler"
    (folder / "alt").mkdir(parents=True)
    (folder / "muhasebe.txt").write_text(
        "2026 butce raporu\n"
        "Muhasebe departmani gider kalemlerini aylik olarak raporlar.\n"
        "Kira, elektrik ve personel giderleri ana kalemlerdir.\n",
        encoding="utf-8",
    )
    (folder / "alt" / "yazilim.md").write_text(
        "# Kurulum\n"
        "Sunucu kurulumu icin once Python yuklenir, ardindan sanal ortam olusturulur.\n",
        encoding="utf-8",
    )
    (folder / "notlar.log").write_text("toplanti notlari\n" * 40, encoding="utf-8")
    return folder


def make_store(tmp_path: Path) -> Path:
    return tmp_path / "rag" / "bound.json"


def test_search_ranks_the_relevant_chunk_first(tmp_path):
    folder = make_folder(tmp_path)
    store = make_store(tmp_path)
    answer = run_tool({"action": "search", "root": str(folder),
                       "query": "muhasebe gider raporu", "top": 3, "store": str(store)})
    assert answer["hits"], "eslesme bulunmali"
    assert answer["hits"][0]["path"] == "muhasebe.txt"
    assert "gider" in answer["hits"][0]["text"]
    assert answer["hits"][0]["line"] == 1
    assert store.is_file(), "indeks tools\\rag altinda saklanmali"
    assert answer["cached"] is False


def test_second_search_reuses_the_index(tmp_path):
    folder = make_folder(tmp_path)
    store = make_store(tmp_path)
    payload = {"action": "search", "root": str(folder),
               "query": "sunucu kurulumu", "top": 3, "store": str(store)}
    first = run_tool(payload)
    second = run_tool(payload)
    assert first["hits"][0]["path"].endswith("yazilim.md")
    assert second["cached"] is True, "degisiklik yoksa indeks yeniden kurulmamali"


def test_index_is_rebuilt_when_a_file_changes(tmp_path):
    folder = make_folder(tmp_path)
    store = make_store(tmp_path)
    payload = {"action": "search", "root": str(folder), "query": "pasifik", "top": 3,
               "store": str(store)}
    assert run_tool(payload)["hits"] == []
    (folder / "yeni.txt").write_text("Pasifik okyanusu en buyuk okyanustur.\n", encoding="utf-8")
    answer = run_tool(payload)
    assert answer["cached"] is False
    assert answer["hits"][0]["path"] == "yeni.txt"


def test_binary_and_unknown_files_are_skipped(tmp_path):
    folder = tmp_path / "ikili"
    folder.mkdir()
    (folder / "gorsel.png").write_bytes(b"\x89PNG\r\n\x1a\n" + b"okyanus" * 10)
    (folder / "veri.bin").write_bytes(b"\x00\x01okyanus\x00\x02")
    (folder / "okyanus.txt").write_text("okyanus notu\n", encoding="utf-8")
    answer = run_tool({"action": "search", "root": str(folder), "query": "okyanus",
                       "top": 5, "store": str(make_store(tmp_path))})
    paths = [hit["path"] for hit in answer["hits"]]
    assert paths == ["okyanus.txt"]


def test_heavy_directories_are_skipped(tmp_path):
    folder = tmp_path / "proje"
    (folder / "node_modules" / "paket").mkdir(parents=True)
    (folder / "venv" / "Scripts").mkdir(parents=True)
    (folder / "node_modules" / "paket" / "index.js").write_text("okyanus bağımlılık\n", encoding="utf-8")
    (folder / "venv" / "Scripts" / "activate.ps1").write_text("okyanus venv\n", encoding="utf-8")
    (folder / "kaynak.py").write_text("# okyanus projesi\n", encoding="utf-8")
    answer = run_tool({"action": "search", "root": str(folder), "query": "okyanus",
                       "top": 5, "store": str(make_store(tmp_path))})
    paths = [hit["path"] for hit in answer["hits"]]
    assert paths == ["kaynak.py"], paths


def test_missing_folder_and_empty_query_report_clearly(tmp_path):
    missing = run_tool({"action": "search", "root": str(tmp_path / "yok"),
                        "query": "x", "store": str(make_store(tmp_path))})
    assert "error" in missing
    folder = make_folder(tmp_path)
    empty = run_tool({"action": "search", "root": str(folder), "query": "   ",
                      "store": str(make_store(tmp_path))})
    assert empty["hits"] == []
    assert "terim" in empty["message"]


def test_index_action_reports_counts(tmp_path):
    folder = make_folder(tmp_path)
    answer = run_tool({"action": "index", "root": str(folder), "store": str(make_store(tmp_path))})
    assert answer["files"] >= 3
    assert answer["chunks"] >= 3
    assert answer["cached"] is False


def test_corrupt_index_is_rebuilt(tmp_path):
    folder = make_folder(tmp_path)
    store = make_store(tmp_path)
    store.parent.mkdir(parents=True, exist_ok=True)
    store.write_text("{bozuk json", encoding="utf-8")
    answer = run_tool({"action": "search", "root": str(folder), "query": "muhasebe",
                       "top": 3, "store": str(store)})
    assert answer["hits"], "bozuk indeks sessizce yok sayilip yeniden kurulmali"


def test_inference_exposes_the_search_folder_tool():
    source = read_text("agent/mamidlabs-inference.ps1")
    assert "function Get-RagPyPath" in source
    assert "function Get-RagStorePath" in source
    assert "$defs += @{ type = 'function'; function = @{ name = 'search_folder';" in source
    # Klasor araclariyla ayni kapi: ses turunda (dosya istenmedikce) sunulmaz.
    guard = source.index("$audioAttachedThisTurn = @($job.currentAudioPaths")
    tool_def = source.index("name = 'search_folder'")
    assert guard < tool_def
    branch = source.index("if ($name -eq 'search_folder')")
    assert "Get-RagStorePath $folder" in source[branch:branch + 1200]
    assert "Get-RagPyPath" in source[branch:branch + 1200]


def test_search_folder_result_is_labeled_untrusted():
    source = read_text("agent/mamidlabs-inference.ps1")
    label = source.index("$script:untrustedContentRead = $true")
    block = source[label - 300:label + 300]
    assert "'search_folder'" in block, "bagli klasor icerigi guvenilmeyen veri olarak etiketlenmeli"
