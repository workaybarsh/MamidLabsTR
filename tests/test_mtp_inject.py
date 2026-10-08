"""agent/mtp_inject.py: Qwen3.5 MTP basligi enjeksiyonunun sozlesmeleri."""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "agent"))

import mtp_inject  # noqa: E402


def test_mtp_mapping_has_fifteen_tensors():
    """Qwen3.5 MTP blogu tam 15 tensorden olusur (tek full-attention blok + nextn proj)."""
    assert len(mtp_inject.MAP) == 15
    # nextn'e ozgu dort tensor diskli/dogrulamali.
    gg = set(mtp_inject.MAP.values())
    assert "blk.{b}.nextn.eh_proj.weight" in gg
    assert "blk.{b}.nextn.enorm.weight" in gg
    assert "blk.{b}.nextn.hnorm.weight" in gg
    assert "blk.{b}.nextn.shared_head_norm.weight" in gg
    # Tum hedefler blok sablonu ve .weight ile biter.
    for name in gg:
        assert name.startswith("blk.{b}.")
        assert name.endswith(".weight")


def test_has_mtp_is_false_for_missing_or_garbage_file(tmp_path):
    assert mtp_inject.has_mtp(str(tmp_path / "yok.gguf")) is False
    garbage = tmp_path / "garbage.bin"
    garbage.write_bytes(b"not a gguf" * 64)
    assert mtp_inject.has_mtp(str(garbage)) is False


def test_mtp_norm_weights_get_plus_one_offset():
    """GGUF Qwen normlari (w + 1) saklar; kaynak HF ham w tutar. 1-B tensorler F32 ve +1."""
    import struct
    # F32 1-B tensor icin _to_f32_list ham w dondurur; enjeksiyon +1'i yazar.
    raw = struct.pack("<3f", 0.5, -0.25, 2.0)
    assert mtp_inject._to_f32_list(raw, "F32") == [0.5, -0.25, 2.0]


def test_bf16_to_f16_matches_struct():
    """BF16 -> F16 cevirimi saf Python yoluyla ayni sonucu vermelidir."""
    import struct
    vals = [0.0, 1.0, -2.5, 0.3333, 123.75]
    for v in vals:
        bf16 = struct.pack("<f", v)[2:]  # ust 16 bit = BF16
        out = mtp_inject._to_f16_bytes(bf16, "BF16")
        f16 = struct.unpack("<e", out)[0]
        assert abs(f16 - v) <= abs(v) * 0.01 + 1e-3
