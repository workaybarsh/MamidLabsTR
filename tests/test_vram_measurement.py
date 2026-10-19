"""VRAM olcumu (agent/gpu-info.ps1) + bellek kapisi entegrasyonu.

Regresyon: eski kod `-replace '\\D',''` ile TUM rakamlari birlestiriyordu; surucu hatasi
metnindeki surum numaralari dev bir "bos VRAM" degerine donusebiliyor, `[N/A]`/bos cikti 0
oluyor ve `-5` isareti atiliyordu. 0 "gercek olcum" gibi kullanildiginda ComfyUI gereksiz
kapatiliyor (~30 sn), sahte BUYUK deger ise kapiyi atlatip modelin paylasilan bellege tasmasina
(sohbet ~40 -> ~27 tok/s) yol acabiliyordu. Artik siki ayristirma: yalnizca tam sayi (istege
bagli "MiB") kabul edilir; geri kalan her sey "olculemedi" = $null.
"""
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]


def _pwsh() -> str:
    exe = shutil.which("pwsh")
    if not exe:
        pytest.skip("PowerShell 7 is unavailable")
    return exe


def _run(body: str, workdir: Path, timeout: int = 90) -> str:
    script = workdir / "run.ps1"
    script.write_text(body, encoding="utf-8-sig")
    proc = subprocess.run(
        [_pwsh(), "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(script)],
        cwd=workdir, capture_output=True, text=True, encoding="utf-8",
        errors="replace", timeout=timeout,
    )
    assert proc.returncode == 0, proc.stdout + proc.stderr
    return proc.stdout


def _fake_smi(workdir: Path, lines) -> Path:
    """nvidia-smi'yi taklit eden bir .cmd yazar (argumanlari yok sayar)."""
    case = workdir / "fakesmi"
    case.mkdir(parents=True, exist_ok=True)
    body = "\r\n".join("@echo " + str(x) for x in lines) if lines else "@echo."
    (case / "nvidia-smi.cmd").write_text(body + "\r\n", encoding="ascii")
    return case


def test_free_vram_parser_rejects_garbage_and_keeps_real_values(tmp_path):
    """Gercek pwsh: yalnizca temiz tam sayi kabul edilir; [N/A], hata metni, negatif, bos
    -> $null (0 DEGIL). Boylece "olculemedi" ile "0 MiB bos" karismaz."""
    gpu_info = ROOT / "agent" / "gpu-info.ps1"
    assert gpu_info.is_file()
    case_dir = _fake_smi(tmp_path, ["15628"])
    body = f"""
$env:PATH = '{case_dir};' + $env:PATH
. '{gpu_info}'
'REAL=' + (Get-NvidiaFreeVramMiB)
foreach ($raw in @('[N/A]', '', '-5', 'NVIDIA-SMI has failed 580.88 driver', '15628 MiB', '0')) {{
    $v = ConvertFrom-MiBText $raw
    'PARSE[' + $raw + ']=' + $(if ($null -eq $v) {{ 'NULL' }} else {{ [string]$v }})
}}
"""
    out = _run(body, tmp_path)
    assert "REAL=15628" in out
    assert "PARSE[[N/A]]=NULL" in out
    assert "PARSE[]=NULL" in out
    assert "PARSE[-5]=NULL" in out
    assert "PARSE[NVIDIA-SMI has failed 580.88 driver]=NULL" in out
    assert "PARSE[15628 MiB]=15628" in out
    assert "PARSE[0]=0" in out


def test_measurement_is_not_used_as_zero_when_unavailable(tmp_path):
    """Medya ve smoke sarmalayicilari `$null` dondurmeli; 0 donerse Release-Comfy "VRAM
    yetersiz" sanip ComfyUI'yi gereksiz kapatir."""
    gpu_info = ROOT / "agent" / "gpu-info.ps1"
    media = ROOT / "agent" / "media-model-swap.ps1"
    smoke = ROOT / "scripts" / "smoke-test.ps1"
    case_dir = _fake_smi(tmp_path, ["[N/A]"])
    body = f"""
$env:PATH = '{case_dir};' + $env:PATH
function Emit {{ param($k, $t, $d = $null) }}
. '{gpu_info}'
. '{media}'
$m = Get-MediaFreeVramMiB
'MEDIA=' + $(if ($null -eq $m) {{ 'NULL' }} else {{ [string]$m }})
"""
    out = _run(body, tmp_path)
    assert "MEDIA=NULL" in out
    # Smoke'ta tanim, paylasilan olcume delege etmeli (kopya ayristirma kalmamali).
    text = smoke.read_text(encoding="utf-8-sig")
    assert "return (Get-NvidiaFreeVramMiB)" in text


def test_all_vram_readers_delegate_to_one_strict_source():
    """Dort ayri `-replace '\\D'` kopyasi vardi; artik tek kaynak kullanilir. Bu, birinin
    duzeltilip digerinin unutulmasi riskini kaldirir."""
    files = [
        ROOT / "scripts" / "manage-mamidlabs.ps1",
        ROOT / "agent" / "media-model-swap.ps1",
        ROOT / "scripts" / "smoke-test.ps1",
    ]
    for path in files:
        text = path.read_text(encoding="utf-8-sig")
        assert "Get-NvidiaFreeVramMiB" in text, f"{path.name} paylasilan olcumu kullanmiyor"
        assert "-replace '\\D'" not in text, f"{path.name} icinde eski kayipsiz ayristirma kaldi"
        assert "gpu-info.ps1" in text, f"{path.name} gpu-info.ps1'i yuklemiyor"


def test_max_context_parameter_binding_positional_named_and_spaced_paths(tmp_path):
    """Parametre BAGLAMA davranisi (onceden hic test edilmemisti; yalnizca metin eslesmesi
    vardi). `$modelPath` gercekten kullanilmali: farkli model boyutlari FARKLI baglam
    uretmeli, konumsal ve named cagri ayni sonucu vermeli, bosluklu yollarda bozulmamali,
    yol verilmezse 27B varsayimina dusmeli, LITE hesap yapmamali.
    (Buyuk dosya yaratmamak icin ayni ayrim sahte bos VRAM degeriyle de saglanir.)"""
    gpu_info = ROOT / "agent" / "gpu-info.ps1"
    small = tmp_path / "kucuk.gguf"
    small.write_bytes(b"x" * (4 * 1024 * 1024))  # 4 MiB -> taban ~282 MiB -> tavana dayanir
    spaced_dir = tmp_path / "bosluklu klasor"
    spaced_dir.mkdir()
    spaced = spaced_dir / "bosluklu model.gguf"
    spaced.write_bytes(b"x" * (4 * 1024 * 1024))
    prelude = f"""
$root = '{ROOT}'
function Get-Functions([string]$path) {{
    $t=$null; $e=$null
    $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$t, [ref]$e)
    if ($e.Count) {{ throw ($e | Out-String) }}
    return (($ast.EndBlock.Statements | Where-Object {{ $_ -is [Management.Automation.Language.FunctionDefinitionAst] }} |
        ForEach-Object {{ $_.Extent.Text }}) -join "`n")
}}
. (Join-Path $root 'agent/gpu-info.ps1')
. ([scriptblock]::Create((Get-Functions (Join-Path $root 'scripts/manage-mamidlabs.ps1'))))
"""
    # BOL bos VRAM: kucuk model tavana, 27B varsayimi 20480'e dayanir.
    big_free = _fake_smi(tmp_path / "big", ["15538"])
    body = f"""
$env:PATH = '{big_free};' + $env:PATH
{prelude}
'KUCUK_POS='   + (Get-MaxContextForProfile 'flash' '{small}')
'BOSLUK_POS='  + (Get-MaxContextForProfile 'flash' '{spaced}')
'KUCUK_NAMED=' + (Get-MaxContextForProfile -profileName 'flash' -modelPath '{small}')
'YOL_YOK='     + (Get-MaxContextForProfile 'flash')
'BOS_DIZE='    + (Get-MaxContextForProfile 'flash' '')
'VARSAYIM='    + (Get-MaxContextForProfile 'flash' 'C:\\yok\\boyle.gguf')
'LITE=['       + (Get-MaxContextForProfile 'lite' '{small}') + ']'
"""
    out = _run(body, tmp_path, timeout=180)
    # 4 MiB model -> taban kucuk -> tavan; bosluklu yol da AYNI sonucu vermeli (yol bozulmuyor).
    assert "KUCUK_POS=131072" in out, out
    assert "BOSLUK_POS=131072" in out, out
    # Konumsal ve named cagri ayni sonucu vermeli.
    assert "KUCUK_NAMED=131072" in out, out
    # Yol verilmez / bos / var olmayan yol -> 27B varsayimi (14878 MiB taban) -> 20480.
    assert "YOL_YOK=20480" in out, out
    assert "BOS_DIZE=20480" in out, out
    assert "VARSAYIM=20480" in out, out
    # LITE hesap yapmaz (sabit baglamini korur).
    assert "LITE=[]" in out, out

    # DAR bos VRAM: ayni 4 MiB model bile tavana dayanamaz -> varsayimdan KUCUK olmali.
    tight_free = _fake_smi(tmp_path / "tight", ["15300"])
    out2 = _run(f"""
$env:PATH = '{tight_free};' + $env:PATH
{prelude}
'TIGHT_KUCUK=' + (Get-MaxContextForProfile 'flash' '{small}')
'TIGHT_DEFAULT=' + (Get-MaxContextForProfile 'flash')
""", tmp_path, timeout=180)
    values = dict(line.split("=", 1) for line in out2.strip().splitlines() if "=" in line)
    assert int(values["TIGHT_KUCUK"]) == 131072, out2   # kucuk model hala tavana dayanir
    assert int(values["TIGHT_DEFAULT"]) == 10240, out2  # 27B varsayimi dar VRAM'e gore kuculur
    assert int(values["TIGHT_DEFAULT"]) != int(values["TIGHT_KUCUK"]), out2


def test_max_context_uses_the_real_model_size(tmp_path):
    """Baglam hesabi taban olarak 27B'nin sabit 14878 MiB'ini degil, GERCEK model dosyasini
    kullanmali; aksi halde kullanicinin kendi (custom) modeli icin yanlis baglam secilir."""
    manage = ROOT / "scripts" / "manage-mamidlabs.ps1"
    text = manage.read_text(encoding="utf-8-sig")
    fn = text.split("function Get-MaxContextForProfile")[1].split("function ")[0]
    assert "[string]$modelPath" in fn
    assert "Length / 1MB" in fn
    assert "$baseMiB = [int][math]::Ceiling" in fn
    assert "$dynamicCtx = Get-MaxContextForProfile $Profile $model" in text

    gpu_info = ROOT / "agent" / "gpu-info.ps1"
    case_dir = _fake_smi(tmp_path, ["15628"])
    small = tmp_path / "kucuk-model.gguf"
    small.write_bytes(b"x" * (4 * 1024 * 1024))  # 4 MiB
    body = f"""
$env:PATH = '{case_dir};' + $env:PATH
$root = '{ROOT}'
function Get-Functions([string]$path) {{
    $t=$null; $e=$null
    $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$t, [ref]$e)
    if ($e.Count) {{ throw ($e | Out-String) }}
    return (($ast.EndBlock.Statements | Where-Object {{ $_ -is [Management.Automation.Language.FunctionDefinitionAst] }} |
        ForEach-Object {{ $_.Extent.Text }}) -join "`n")
}}
. (Join-Path $root 'agent/gpu-info.ps1')
. ([scriptblock]::Create((Get-Functions (Join-Path $root 'scripts/manage-mamidlabs.ps1'))))
'SMALL=' + (Get-MaxContextForProfile 'flash' '{small}')
'DEFAULT=' + (Get-MaxContextForProfile 'flash' '')
'LITE=' + (Get-MaxContextForProfile 'lite' '{small}')
"""
    out = _run(body, tmp_path)
    # Kucuk model -> taban ~282 MiB -> tavana (131072) dayanir.
    assert "SMALL=131072" in out
    # Model yolu yoksa 27B varsayimi (14878) kullanilir.
    assert "DEFAULT=22528" in out
    # LITE sabit baglamini korur (hesap yapilmaz).
    assert "LITE=" in out
