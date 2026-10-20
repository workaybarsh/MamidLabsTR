import json
import shutil
import struct
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]


def read_text(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8-sig")


def extract_function(source: str, name: str) -> str:
    start = source.index(f"function {name}")
    end = source.find("\nfunction ", start + 1)
    return source[start:end if end != -1 else len(source)]


def write_safetensors(path: Path, tensors: dict, metadata: dict) -> bytes:
    header = {"__metadata__": metadata}
    data = b""
    for key, raw in tensors.items():
        header[key] = {"dtype": "F32", "shape": [len(raw) // 4], "data_offsets": [len(data), len(data) + len(raw)]}
        data += raw
    encoded = json.dumps(header).encode("utf-8")
    path.write_bytes(struct.pack("<Q", len(encoded)) + encoded + data)
    return data


def read_safetensors(path: Path):
    blob = path.read_bytes()
    length = struct.unpack("<Q", blob[:8])[0]
    return length, json.loads(blob[8:8 + length]), blob[8 + length:]


def test_comfy_is_reused_and_released_instead_of_restarted():
    """ComfyUI'yi her iste sifirdan acmak ~20 sn suruyordu (gercek donanimda
    olculdu, bu surede VRAM bos bekliyordu). Basarili isten sonra surec
    kapatilmaz, modeller /free ile bosaltilir; gorsel ve video ayni sureci
    paylasir, yoksa ikinci surec ayni portta cakisir."""
    swap = read_text("agent/media-model-swap.ps1")
    assert "function Start-OrReuseComfy" in swap
    assert "function Release-Comfy" in swap
    assert '"unload_models":true,"free_memory":true' in swap
    assert "if ($lite) { $comfyArgs += '--lowvram' }" in swap

    for path in ("agent/imagegen-run.ps1", "agent/videogen-run.ps1"):
        script = read_text(path)
        assert "Start-Process -FilePath $python" not in script, path
        assert "Release-Comfy $comfy $comfyUrl" in script, path
        # Acilis sirasindaki hatada yari acik surec de oldurulmeli.
        assert "Stop-Comfy $(if ($comfy) { $comfy } else { $Shared.Process })" in script, path


def test_comfy_start_timeout_covers_first_run_initialization():
    """ComfyUI ilk acilista kendi asset DB'sini kurar. Gercek makinede ilk
    acilis 297 sn, sonraki acilis 16 sn olculdu; 180/240 sn sinirlari kurulum
    smoke testini bilesenler calistigi halde basarisiz gosteriyordu."""
    for path in ("agent/imagegen-run.ps1", "agent/videogen-run.ps1"):
        script = read_text(path)
        assert "Start-OrReuseComfy $python $comfyDir $comfyOut $comfyIn $logs $comfyUrl $lite 600 $Shared" in script, path


REALISM_CASES = [
    ("Gün batımında sahilde koşan bir köpeğin fotoğrafını üret.", False),
    ("Karlı bir dağ köyünde ahşap kulübe çiz", False),
    ("Anime tarzında bir kedi çiz", False),
    ("Gerçekçi bir portre üret", True),
    ("GERÇEKÇİ bir araba görseli", True),
    ("fotogerçekçi bir mutfak", True),
    ("Bunu daha gerçekçi yap", True),
    ("gerçek gibi görünen bir orman", True),
    ("gerçek bir fotoğraf gibi olsun", True),
    ("fotoğraf kalitesinde bir manzara", True),
    ("a photorealistic portrait of a sailor", True),
    ("realistic lighting on a city street", True),
    ("Gerçekçi olmasın, çizgi film gibi olsun", False),
    ("gerçekçi değil, suluboya tarzı", False),
    ("an unrealistic dreamlike castle", False),
    ("surrealistic melting clocks", False),
    ("not realistic, cartoon style", False),
]


def test_realism_lora_is_enabled_only_when_user_asks_for_realism(tmp_path):
    """Gerceklik LoRA'si 8 GB kartta uretimi ~2 kat yavaslatiyor; kullanici
    istegiyle yalnizca kullanicinin kendi mesaji gercekci gorsel istediginde
    acilir. Karar dil modeline birakilmaz (aractan realism parametresi kaldirildi)."""
    inference = read_text("agent/mamidlabs-inference.ps1")
    assert "realism = (Test-RealismIntent $userText)" in inference
    assert "realism = @{ type = 'boolean'" not in inference
    assert "$realism = [bool]$JobData.realism" in read_text("agent/imagegen-run.ps1")

    pwsh = shutil.which("pwsh")
    if not pwsh:
        pytest.skip("pwsh bulunamadi")
    function = extract_function(inference, "Test-RealismIntent")
    cases = "\n".join(
        "Write-Output ([string](Test-RealismIntent '{}'))".format(text.replace("'", "''")) for text, _ in REALISM_CASES
    )
    script = tmp_path / "realism.ps1"
    script.write_text(function + "\n" + cases + "\n", encoding="utf-8-sig")
    result = subprocess.run(
        [pwsh, "-NoProfile", "-NonInteractive", "-File", str(script)],
        capture_output=True, encoding="utf-8", errors="replace", check=False,
    )
    assert result.returncode == 0, result.stderr or result.stdout
    got = [line.strip() == "True" for line in result.stdout.splitlines() if line.strip()]
    assert got == [expected for _, expected in REALISM_CASES], list(zip(REALISM_CASES, got))


# (metin, sohbette/istekte gorsel var mi, beklenen)
IMAGE_REQUEST_CASES = [
    ("İstanbul için bu hafta sonunun hava durumu tahmini nasıl? Kısa bir özet ver.", False, False),
    ("Bugün Euro/TL kuru kaç?", False, False),
    ("Bu toplantı için bir Word belgesi oluştur", False, False),
    ("Neon ışıklı fütüristik bir şehir illüstrasyonu üret", False, True),
    ("Bir kedi çiz", False, True),
    ("Şirketim için minimal bir logo tasarla", False, True),
    ("Karlı bir dağ manzarası üret", False, True),
    ("Bana bir görsel yap", False, True),
    ("köpeğin fotoğrafını üret", False, True),
    ("draw a dragon", False, True),
    ("generate an image of a forest", False, True),
    # Gercek testte: eklenen gorsel icin soru soruldu, model "yeniden uretim" baslatti.
    ("Bu görselde ne görüyorsun? Kısaca anlat.", True, False),
    ("Görseldeki kişiler ne yapıyor?", True, False),
    ("Bu görseldeki metni oku.", True, False),
    ("Bunu daha karanlık yap", True, True),
    ("Gece versiyonu olsun", True, True),
    ("Arka planı değiştir", True, True),
    ("Bunu daha karanlık yap", False, False),
]


def test_generate_image_is_rejected_when_user_did_not_ask_for_an_image(tmp_path):
    """Gercek arayuz testinde model hava durumu sorusuna kendiliginden gorsel uretti."""
    inference = read_text("agent/mamidlabs-inference.ps1")
    assert "!(Test-ImageRequestIntent $userText ([bool]$JobData.hasSourceImage -or (Test-ConversationHasImage $messages)))" in inference

    pwsh = shutil.which("pwsh")
    if not pwsh:
        pytest.skip("pwsh bulunamadi")
    functions = extract_function(inference, "Test-ImageRequestIntent") + "\n" + extract_function(inference, "Test-ConversationHasImage")
    cases = "\n".join(
        "Write-Output ([string](Test-ImageRequestIntent '{}' ${}))".format(text.replace("'", "''"), str(ctx).lower())
        for text, ctx, _ in IMAGE_REQUEST_CASES
    )
    history = """
$h = [Collections.ArrayList]::new(); [void]$h.Add(@{ role = 'user'; content = 'selam' })
Write-Output ([string](Test-ConversationHasImage $h))
[void]$h.Add(@{ role = 'assistant'; content = '[Gorsel uretildi: 1024x1024, seed 1, mod yeni, dosya: x.png] Prompt: cat' })
Write-Output ([string](Test-ConversationHasImage $h))
$h2 = [Collections.ArrayList]::new(); [void]$h2.Add(@{ role = 'user'; content = @(@{ type = 'text'; text = 'bak' }, @{ type = 'image_url'; image_url = @{ url = 'data:' } }) })
Write-Output ([string](Test-ConversationHasImage $h2))
"""
    script = tmp_path / "image_intent.ps1"
    script.write_text(functions + "\n" + cases + "\n" + history, encoding="utf-8-sig")
    result = subprocess.run(
        [pwsh, "-NoProfile", "-NonInteractive", "-File", str(script)],
        capture_output=True, encoding="utf-8", errors="replace", check=False,
    )
    assert result.returncode == 0, result.stderr or result.stdout
    got = [line.strip() == "True" for line in result.stdout.splitlines() if line.strip()]
    expected = [e for _, _, e in IMAGE_REQUEST_CASES] + [False, True, True]
    assert got == expected, list(zip([t for t, _, _ in IMAGE_REQUEST_CASES] + ["gecmis:yok", "gecmis:uretilmis", "gecmis:ekli"], got))


def test_turn_hint_is_not_mistaken_for_user_text_in_image_messages(tmp_path):
    """Gorselli mesajda masaustunun '[Sistem notu]' parcasi kullanici metni sanildigi
    icin notun 'metin okuma' ifadesi her gorsel sorusunu OCR'a gonderiyordu."""
    pwsh = shutil.which("pwsh")
    if not pwsh:
        pytest.skip("pwsh bulunamadi")
    inference = read_text("agent/mamidlabs-inference.ps1")
    functions = "\n".join(extract_function(inference, n) for n in ("Get-PlainText", "Get-CurrentUserText", "Test-OcrIntent", "Test-ImageRequestIntent"))
    script = tmp_path / "hint.ps1"
    script.write_text(functions + """
$note = '[Sistem notu] Bu turda yeni bir gorsel eklendi. Metin/yazi okuma isteginde OCR sonucunu kullan. Kullanici acikca uretim istemedikce generate_image cagirma.'
$m = [Collections.ArrayList]::new()
[void]$m.Add(@{ role = 'user'; content = @(@{ type = 'text'; text = $note }, @{ type = 'text'; text = 'Bu gorselde ne goruyorsun?' }, @{ type = 'image_url'; image_url = @{ url = 'data:' } }) })
$t = Get-CurrentUserText $m
Write-Output $t
Write-Output ([string](Test-OcrIntent $t))
Write-Output ([string](Test-ImageRequestIntent $t $true))
$s = [Collections.ArrayList]::new(); [void]$s.Add(@{ role = 'user'; content = ($note + "`n`nselam") })
Write-Output (Get-CurrentUserText $s)
""", encoding="utf-8-sig")
    result = subprocess.run(
        [pwsh, "-NoProfile", "-NonInteractive", "-File", str(script)],
        capture_output=True, encoding="utf-8", errors="replace", check=False,
    )
    assert result.returncode == 0, result.stderr or result.stdout
    lines = [line.strip() for line in result.stdout.splitlines() if line.strip()]
    assert lines == ["Bu gorselde ne goruyorsun? [gorsel]", "False", "False", "selam"], lines


def test_realism_lora_prefix_is_rewritten_without_touching_tensor_data(tmp_path):
    """fal'in krea-2 egitim araci anahtarlari base_model.model. onekiyle yazar;
    ComfyUI diffusion_model. bekler ve eslesmeyenleri sessizce atlar."""
    pwsh = shutil.which("pwsh")
    if not pwsh:
        pytest.skip("pwsh bulunamadi")

    lora = tmp_path / "krea2_realism_lora.safetensors"
    tensors = {
        "base_model.model.blocks.0.attn.wq.lora_A.weight": struct.pack("<4f", 1, 2, 3, 4),
        "base_model.model.txtmlp.1.lora_B.weight": struct.pack("<2f", 5, 6),
    }
    metadata = {"base_model": "fal/krea-2", "lora_rank": "32"}
    original_data = write_safetensors(lora, tensors, metadata)

    function = extract_function(read_text("agent/imagegen-run.ps1"), "Repair-LoraKeyPrefix")
    script = tmp_path / "run.ps1"
    script.write_text(
        "$ErrorActionPreference = 'Stop'\n" + function +
        f"\nRepair-LoraKeyPrefix '{lora}'\nRepair-LoraKeyPrefix '{lora}'\n",
        encoding="utf-8-sig",
    )
    result = subprocess.run(
        [pwsh, "-NoProfile", "-NonInteractive", "-File", str(script)],
        capture_output=True, encoding="utf-8", errors="replace", check=False,
    )
    assert result.returncode == 0, result.stderr or result.stdout

    length, header, data = read_safetensors(lora)
    assert length % 8 == 0
    assert header.pop("__metadata__") == metadata
    assert set(header) == {
        "diffusion_model.blocks.0.attn.wq.lora_A.weight",
        "diffusion_model.txtmlp.1.lora_B.weight",
    }
    assert data == original_data
    assert not (tmp_path / "krea2_realism_lora.safetensors.tmp").exists()
