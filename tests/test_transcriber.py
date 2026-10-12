"""Ses dökum hatti (agent/transcriber) + arayuz/isci sozlesmeleri.

Motor: faster-whisper large-v3-tr (Turkce) + AST ses olaylari + pyannote konusmaci ayrimi.
Qwen3-ASR ve whisper.cpp tamamen kaldirildi. Agir testler (model/ortam yoksa) atlanir;
sozlesmeler her zaman denetlenir.
"""
import importlib.util
import json
import shutil
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from types import SimpleNamespace

import pytest

ROOT = Path(__file__).resolve().parents[1]
TRANSCRIBER = ROOT / "agent" / "transcriber"
WORKER = ROOT / "agent" / "whisper-tools.py"

if str(ROOT / "agent") not in sys.path:
    sys.path.insert(0, str(ROOT / "agent"))


def read_text(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8-sig")


def load_worker():
    spec = importlib.util.spec_from_file_location("whisper_tools", WORKER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# --------------------------------------------------------------- paket / config
def test_package_modules_exist():
    for name in ("config", "audio", "vad", "asr", "events", "diarize", "merge", "main"):
        assert (TRANSCRIBER / f"{name}.py").is_file(), name + ".py yok"


def test_config_selects_profile_by_vram():
    """Ad verilmedigi (CLI) durumda tier'i toplam VRAM belirler: >=14000 MiB -> 'pro',
    alti -> 'lite'."""
    from transcriber import config

    pro = config.select_profile(total_mib=16311)
    assert pro.name == "pro" and pro.compute_type == "float16" and pro.load_mode == "parallel"
    lite = config.select_profile(total_mib=8000)
    assert lite.name == "lite" and lite.compute_type == "int8_float16" and lite.load_mode == "sequential"
    assert lite.chunk_minutes > 0 and pro.chunk_minutes == 0
    # Turkce dökum varsayilani; whisper modeli large-v3-tr.
    assert pro.language == "tr"
    assert "whisper-large-v3-tr" in pro.whisper_model


def test_select_profile_for_uses_selected_profile_name():
    """SECILI dil-modeli profil ADI tier'i belirler; toplam VRAM yalnizca ad yoksa yedektir."""
    from transcriber import config

    # 'lite' -> lite tier; VRAM bol olsa bile (16311 MiB) lite kalir.
    lite_high = config.select_profile_for("lite", total_mib=16311)
    assert lite_high.name == "lite" and lite_high.load_mode == "sequential"
    # 'pro'/'max'/'flash' (ve eski 'pc2') -> pro tier; VRAM az olsa bile (8000 MiB) pro kalir.
    for name in ("pro", "max", "flash", "PRO", " max ", "pc2"):
        prof = config.select_profile_for(name, total_mib=8000)
        assert prof.name == "pro", name
        assert prof.compute_type == "float16" and prof.load_mode == "parallel"
    # Eski donanim adi 'pc1' -> lite; VRAM bol olsa bile lite.
    assert config.select_profile_for("pc1", total_mib=16311).name == "lite"
    # Ad yok / taninmiyor -> VRAM yedegi (8000 -> lite, 16311 -> pro).
    assert config.select_profile_for(None, total_mib=8000).name == "lite"
    assert config.select_profile_for(None, total_mib=16311).name == "pro"
    assert config.select_profile_for("bilinmeyen", total_mib=8000).name == "lite"
    assert config.select_profile_for("bilinmeyen", total_mib=16311).name == "pro"
    # overrides ada gore secilen profile de uygulanir.
    tuned = config.select_profile_for("lite", total_mib=16311, language="auto", events=False)
    assert tuned.name == "lite" and tuned.language == "auto" and tuned.events is False


def test_config_overrides_are_applied():
    from transcriber import config

    profile = config.select_profile(total_mib=8000, language="auto", events=False)
    assert profile.language == "auto" and profile.events is False


# ---------------------------------------------------- otomatik cihaz secimi
def test_choose_device_without_swap_always_cuda():
    """need_swap=False (API ya da LITE): VRAM swap maliyeti yok -> her zaman cuda."""
    from transcriber import config

    profile = config.select_profile(total_mib=8000)
    assert config.choose_device(5, profile, need_swap=False) == "cuda"
    assert config.choose_device(10_000, profile, need_swap=False) == "cuda"
    # Sure okunamasa bile swap yoksa cuda.
    assert config.choose_device(None, profile, need_swap=False) == "cuda"


def test_choose_device_short_uses_cpu_long_uses_cuda_when_swap_needed():
    from transcriber import config

    profile = config.select_profile(total_mib=8000)
    # Etkin esik: profil bazli (LITE 15 sn) varsa o, yoksa varsayilan.
    threshold = profile.cpu_max_seconds or config.DEFAULT_CPU_MAX_SECONDS
    # Esigin ALTINDA -> CPU (swap maliyeti dökum kazancindan buyuk).
    assert config.choose_device(threshold - 1, profile, need_swap=True) == "cpu"
    assert config.choose_device(5, profile, need_swap=True) == "cpu"
    # Sinir degeri -> CPU (<=).
    assert config.choose_device(threshold, profile, need_swap=True) == "cpu"
    # Esigin USTUNDE -> CUDA.
    assert config.choose_device(threshold + 1, profile, need_swap=True) == "cuda"
    # Sure okunamazsa guvenli varsayilan cuda.
    assert config.choose_device(None, profile, need_swap=True) == "cuda"


def test_choose_device_cpu_max_seconds_override():
    from transcriber import config

    profile = config.select_profile(total_mib=8000)
    # Cagri bazinda gecersiz kilma.
    assert config.choose_device(300, profile, need_swap=True, cpu_max_seconds=600) == "cpu"
    assert config.choose_device(700, profile, need_swap=True, cpu_max_seconds=600) == "cuda"
    # Profil bazinda gecersiz kilma (select_profile overrides).
    tuned = config.select_profile(total_mib=8000, cpu_max_seconds=30)
    assert tuned.cpu_max_seconds == 30
    assert config.choose_device(10, tuned, need_swap=True) == "cpu"
    assert config.choose_device(60, tuned, need_swap=True) == "cuda"


def test_profile_auto_device_defaults_on():
    from transcriber import config

    assert config.select_profile(total_mib=8000).auto_device is True
    assert config.select_profile(total_mib=16311).auto_device is True


# -------------------------------------------------- bellek plani (VRAM -> RAM -> swap)
def test_profile_carries_audio_memory_thresholds():
    from transcriber import config

    profile = config.select_profile(total_mib=8000)
    assert profile.audio_vram_mib > 0 and profile.audio_ram_mib > 0
    assert config.DEFAULT_AUDIO_VRAM_MIB == profile.audio_vram_mib


def test_choose_plan_priority_vram_then_ram_then_swap():
    """pro (eski PC2; CPU dali acik) onceligi: (1) birlikte sigar -> GPU swap yok,
    (2) CPU RAM'e sigar -> CPU swap yok, (3) ikisi de yetmez -> mecburi swap."""
    from transcriber import config

    profile = config.select_profile(total_mib=16311)
    vram = profile.audio_vram_mib
    ram = profile.audio_ram_mib
    # 1) Bos VRAM yeter -> GPU, swap YOK.
    assert config.choose_plan(profile, vram_free_mib=vram, ram_free_mib=ram) == ("cuda", False)
    assert config.choose_plan(profile, vram_free_mib=vram + 1000, ram_free_mib=0) == ("cuda", False)
    # 2) VRAM yetmez ama sistem RAM'i yeter -> CPU, swap YOK (yavas, dil modeli yerinde).
    assert config.choose_plan(profile, vram_free_mib=vram - 1, ram_free_mib=ram) == ("cpu", False)
    assert config.choose_plan(profile, vram_free_mib=0, ram_free_mib=ram + 10_000) == ("cpu", False)
    # 3) Ikisi de yetmez -> mecburi VRAM swap (GPU).
    assert config.choose_plan(profile, vram_free_mib=vram - 1, ram_free_mib=ram - 1) == ("cuda", True)
    assert config.choose_plan(profile, vram_free_mib=0, ram_free_mib=0) == ("cuda", True)


def test_choose_plan_lite_uses_cpu_branch_for_short_long_uses_gpu():
    """LITE da ayni birlesik mantigi kullanir (RAM yeterli olcüldü): VRAM yetmez + KISA ->
    CPU/swap yok, UZUN -> GPU + mecburi swap."""
    from transcriber import config

    profile = config.select_profile(total_mib=8000)
    assert config.choose_plan(profile, vram_free_mib=profile.audio_vram_mib,
                             ram_free_mib=0) == ("cuda", False)
    threshold = config.DEFAULT_CPU_MAX_SECONDS
    assert config.choose_plan(profile, duration_seconds=5, vram_free_mib=0,
                             ram_free_mib=10 ** 6) == ("cpu", False)
    assert config.choose_plan(profile, duration_seconds=threshold + 1, vram_free_mib=0,
                             ram_free_mib=10 ** 6) == ("cuda", True)


def test_choose_plan_without_local_model_never_swaps():
    """API saglayicisinda yerel dil modeli yuklu degildir; GPU bostur -> swap yok."""
    from transcriber import config

    profile = config.select_profile(total_mib=8000)
    assert config.choose_plan(profile, vram_free_mib=0, ram_free_mib=0,
                             local_model_loaded=False) == ("cuda", False)


def test_choose_plan_uses_duration_short_cpu_long_gpu_when_vram_tight():
    """VRAM yetmediginde SURE belirleyicidir: RAM yeterli olsa bile kisa kayit -> CPU
    (swap maliyeti kazanci asar), UZUN kayit -> GPU + mecburi swap (GPU kazanci asar)."""
    from transcriber import config

    profile = config.select_profile(total_mib=16311)
    vram = profile.audio_vram_mib - 1      # birlikte sigmiyor
    ram = profile.audio_ram_mib + 10_000   # CPU RAM'e sigiyor
    threshold = config.DEFAULT_CPU_MAX_SECONDS
    assert config.choose_plan(profile, duration_seconds=threshold, vram_free_mib=vram,
                             ram_free_mib=ram) == ("cpu", False)
    assert config.choose_plan(profile, duration_seconds=threshold + 1, vram_free_mib=vram,
                             ram_free_mib=ram) == ("cuda", True)
    assert config.choose_plan(profile, duration_seconds=5, vram_free_mib=vram,
                             ram_free_mib=ram) == ("cpu", False)


def test_choose_plan_long_recording_swaps_even_cpu_max_override():
    """`cpu_max_seconds` esigi gecersiz kilinabilir; uzun kayit her durumda GPU+swap."""
    from transcriber import config

    profile = config.select_profile(total_mib=16311)
    assert config.choose_plan(profile, duration_seconds=600, vram_free_mib=0, ram_free_mib=10**6,
                             cpu_max_seconds=1200) == ("cpu", False)
    assert config.choose_plan(profile, duration_seconds=2000, vram_free_mib=0, ram_free_mib=10**6,
                             cpu_max_seconds=1200) == ("cuda", True)


def test_choose_plan_no_duration_falls_back_to_memory_only():
    """Sure bilinmiyorsa swap ZORLANMAZ: RAM yetiyorsa CPU, yetmiyorsa mecburi swap."""
    from transcriber import config

    profile = config.select_profile(total_mib=16311)
    assert config.choose_plan(profile, duration_seconds=None, vram_free_mib=0,
                             ram_free_mib=10**6) == ("cpu", False)
    assert config.choose_plan(profile, duration_seconds=None, vram_free_mib=0,
                             ram_free_mib=0) == ("cuda", True)


def test_audio_budget_matches_measured_pipeline():
    """Ses hatti VRAM payi, belgelenen bileşenlerin (Whisper int8 ~1,5-2,5 GB + AST
    ~0,4 GB + torch/CUDA ~0,3-0,5 GB) toplamini karsilamali; 8 GB LITE'ta dil modeli
    ~7,5 GB tutunca bu pay bos kalmadigi icin swap/CPU'ya dusulur."""
    from transcriber import config

    assert config.DEFAULT_AUDIO_VRAM_MIB >= 3500
    assert config.DEFAULT_AUDIO_RAM_MIB >= 4096



# -------------------------------------------------------------------- merge
def test_merge_is_chronological_without_timestamps_and_uses_speaker_labels():
    from transcriber import merge

    text = merge.merge(
        [{"start": 7, "end": 9, "text": "Geldin mi?"},
         {"start": 11, "end": 13, "text": "Evet, biraz geciktim."}],
        [{"start": 3, "end": 5, "text": "ayak sesleri"},
         {"start": 9, "end": 10.5, "text": "kapi kapanma sesi"}],
    )
    assert text == (
        "(ayak sesleri)\n"
        "Konuşmacı: Geldin mi?\n"
        "(kapi kapanma sesi)\n"
        "Konuşmacı: Evet, biraz geciktim."
    )
    # Zaman damgasi YAZILMAZ.
    assert "[" not in text


def test_merge_numbers_speakers_when_diarized():
    from transcriber import merge

    text = merge.merge(
        [{"start": 7, "end": 9, "text": "Geldin mi?"},
         {"start": 11, "end": 13, "text": "Evet."}],
        [],
        turns=[{"start": 7, "end": 9, "speaker": "SPEAKER_00"},
               {"start": 11, "end": 13, "speaker": "SPEAKER_01"}],
    )
    assert "Konuşmacı 1: Geldin mi?" in text
    assert "Konuşmacı 2: Evet." in text


def test_merge_can_include_timestamps_when_asked():
    from transcriber import merge

    text = merge.merge([{"start": 65, "end": 70, "text": "Merhaba"}], [], include_timestamps=True)
    assert text.startswith("[01:05] Konuşmacı: Merhaba")


# ---------------------------------------------------------------------- asr
def test_asr_hallucination_filters():
    from transcriber import asr

    def seg(text, no_speech=0.0, logprob=0.0, compression=1.0):
        return SimpleNamespace(text=text, no_speech_prob=no_speech, avg_logprob=logprob,
                               compression_ratio=compression)

    assert asr._is_hallucination(seg("")) is True                      # bos
    assert asr._is_hallucination(seg("   ...  ")) is True               # sadece noktalama
    assert asr._is_hallucination(seg("Altyazı M.K.")) is True           # bilinen kalip
    assert asr._is_hallucination(seg("Abone ol")) is True
    assert asr._is_hallucination(seg("tamam " * 8)) is True             # asiri tekrar
    assert asr._is_hallucination(seg("...", no_speech=0.95, logprob=-0.9)) is True
    assert asr._is_hallucination(seg("bir metin", compression=3.0)) is True
    assert asr._is_hallucination(seg("Gerçek bir cümle.")) is False


def test_asr_whisper_model_is_turkish_tuned():
    src = read_text("agent/transcriber/asr.py")
    assert "condition_on_previous_text=False" in src
    assert "vad_filter=True" in src
    assert "no_speech_threshold" in src and "compression_ratio_threshold" in src


# ------------------------------------------------------------------- events
def test_events_filters_speech_labels_and_translates():
    from transcriber import events

    assert events._translate("Walk, footsteps") == "ayak sesleri"
    assert events._translate("Door") == "kapı sesi"
    # Konusma etiketleri olay sayilmaz.
    assert "speech" in events.SPEECH_LABELS
    assert "male speech, man speaking" in events.SPEECH_LABELS
    src = read_text("agent/transcriber/events.py")
    assert "SPEECH_LABELS" in src and "_merge_repeats" in src


# ------------------------------------------------------------- worker / arayuz
def test_worker_exists_and_reads_json_on_stdin():
    src = read_text("agent/whisper-tools.py")
    assert "sys.stdin.read()" in src
    assert "'transcribe'" in src
    assert "from transcriber import" in src


@pytest.mark.skipif(not WORKER.is_file(), reason="worker missing")
def test_worker_rejects_missing_file():
    module = load_worker()
    with pytest.raises(ValueError):
        module.transcribe({"path": str(ROOT / "does-not-exist.wav")})


def _patch_transcriber_pipeline(monkeypatch, duration, capture):
    """Agir model cagrilarini sahtelerle degistirir; secilen cihazi yakalar."""
    from transcriber import asr, audio, diarize, events, merge

    monkeypatch.setattr(audio, "to_wav16k_mono", lambda p: str(p))
    monkeypatch.setattr(audio, "duration_seconds", lambda p: duration)
    monkeypatch.setattr(audio, "split_wav", lambda p, m: [(str(p), 0.0)])

    def fake_transcribe(chunk, profile, device="cuda", **kw):
        capture["device"] = device
        return {"segments": [], "language": None}

    monkeypatch.setattr(asr, "transcribe", fake_transcribe)
    monkeypatch.setattr(asr, "unload_model", lambda: None)
    monkeypatch.setattr(events, "tag", lambda *a, **k: [])
    monkeypatch.setattr(events, "unload_events_model", lambda: None)
    monkeypatch.setattr(diarize, "diarize", lambda *a, **k: [])
    monkeypatch.setattr(diarize, "unload_pipeline", lambda: None)
    monkeypatch.setattr(merge, "merge", lambda *a, **k: "")


def test_run_auto_selects_cpu_for_short_recording(monkeypatch, tmp_path):
    """device='auto' + need_swap=True + kisa kayit -> asr CPU ile cagrilir."""
    from transcriber import config, main

    src = tmp_path / "short.wav"
    src.write_bytes(b"")
    capture = {}
    _patch_transcriber_pipeline(monkeypatch, 5.0, capture)
    result = main.run(str(src), profile=config.select_profile(total_mib=8000),
                      device="auto", need_swap=True)
    assert capture["device"] == "cpu"
    assert result["device"] == "cpu"


def test_run_auto_selects_cuda_for_long_recording(monkeypatch, tmp_path):
    from transcriber import config, main

    src = tmp_path / "long.wav"
    src.write_bytes(b"")
    capture = {}
    _patch_transcriber_pipeline(monkeypatch, config.DEFAULT_CPU_MAX_SECONDS + 120, capture)
    result = main.run(str(src), profile=config.select_profile(total_mib=8000),
                      device="auto", need_swap=True)
    assert capture["device"] == "cuda"
    assert result["device"] == "cuda"


def test_run_auto_uses_cuda_without_swap(monkeypatch, tmp_path):
    """need_swap=False (API/LITE) -> kisa kayitta bile CUDA."""
    from transcriber import config, main

    src = tmp_path / "short2.wav"
    src.write_bytes(b"")
    capture = {}
    _patch_transcriber_pipeline(monkeypatch, 20.0, capture)
    result = main.run(str(src), profile=config.select_profile(total_mib=8000),
                      device="auto", need_swap=False)
    assert capture["device"] == "cuda"
    assert result["device"] == "cuda"


def test_run_explicit_device_is_not_overridden(monkeypatch, tmp_path):
    """device acikca 'cpu' verildiyse auto secim devreye girmez."""
    from transcriber import config, main

    src = tmp_path / "cpu.wav"
    src.write_bytes(b"")
    capture = {}
    _patch_transcriber_pipeline(monkeypatch, 5.0, capture)
    main.run(str(src), profile=config.select_profile(total_mib=8000),
             device="cpu", need_swap=True)
    assert capture["device"] == "cpu"


def test_cli_and_stdin_use_selected_profile_name(monkeypatch, tmp_path):
    """CLI/isci sozlesmesi: `--profile` ve stdin `profile` alani ADI tier'a cevirir; ad
    yoksa profile None kalir (transcriber VRAM yedegine duser)."""
    import io

    from transcriber import main as transcriber_main

    calls = []

    def fake_run(path, profile=None, **kw):
        calls.append(profile.name if profile else None)
        return {"text": "ok", "model": "m", "language": "tr",
                "profile": profile.name if profile else None}

    monkeypatch.setattr(transcriber_main, "run", fake_run)

    # stdin: 'max' -> pro.
    monkeypatch.setattr(sys, "stdin", io.StringIO(
        '{"action":"transcribe","profile":"max","path":"x.wav"}'))
    assert transcriber_main.main(["--stdin"]) == 0
    assert calls[-1] == "pro"

    # stdin: profil yok -> None (VRAM yedegi).
    monkeypatch.setattr(sys, "stdin", io.StringIO('{"action":"transcribe","path":"x.wav"}'))
    assert transcriber_main.main(["--stdin"]) == 0
    assert calls[-1] is None

    # CLI: 'lite' -> lite.
    wav = tmp_path / "a.wav"
    wav.write_bytes(b"")
    assert transcriber_main.main([str(wav), "--profile", "lite"]) == 0
    assert calls[-1] == "lite"

    # CLI: profil yok -> None.
    assert transcriber_main.main([str(wav)]) == 0
    assert calls[-1] is None


def test_worker_accepts_auto_and_need_swap(monkeypatch, tmp_path):
    """Isci sozlesmesi: 'auto' oldugu gibi gecilir; need_swap varsa iletilir, yoksa None."""
    module = load_worker()
    from transcriber import main as transcriber_main

    src = tmp_path / "a.wav"
    src.write_bytes(b"")
    captured = {}

    def fake_run(path, **kw):
        captured.clear()
        captured.update(kw)
        return {"text": "merhaba", "language": "tr", "events": [], "diarized": False,
                "model": "m"}

    monkeypatch.setattr(transcriber_main, "run", fake_run)
    module.transcribe({"path": str(src), "profile": "pc2", "device": "auto", "need_swap": True})
    assert captured["device"] == "auto"
    assert captured["need_swap"] is True
    # device/need_swap yoksa varsayilanlar: 'auto' ve None.
    module.transcribe({"path": str(src), "profile": "pc2"})
    assert captured["device"] == "auto"
    assert captured["need_swap"] is None


def test_worker_profile_maps_name_to_tier(monkeypatch):
    """Isci sozlesmesi: istek `profile` alani verilirse tier ADLA secilir ('lite'/'pro'/
    'pc1'/'pc2'/'max'/'flash'); ad yoksa tier'i toplam VRAM belirler."""
    module = load_worker()

    # Ad onceliklidir: bol VRAM (16311) olsa bile 'lite' -> lite tier.
    monkeypatch.setattr(module.config, "total_vram_mib", lambda: 16311)
    assert module._profile({"profile": "lite"}).name == "lite"
    assert module._profile({"profile": "pc1"}).name == "lite"
    # Az VRAM (8000) olsa bile 'max'/'pc2' -> pro tier.
    assert module._profile({"profile": "max"}).name == "pro"
    assert module._profile({"profile": "pc2"}).name == "pro"
    # Ad verilince gecerli language override uygulanir; 'auto' yok sayilir (profil varsayilani).
    assert module._profile({"profile": "lite", "language": "en"}).language == "en"
    assert module._profile({"profile": "lite", "language": "auto"}).language == "tr"
    # Ad yok: yalnizca language -> VRAM yedegi (8000 -> lite; bos istek -> lite).
    monkeypatch.setattr(module.config, "total_vram_mib", lambda: 8000)
    assert module._profile({"language": "tr"}).name == "lite"
    assert module._profile({}).name == "lite"


def test_worker_plan_action_decides_device_and_swap(monkeypatch, tmp_path):
    """Isci sozlesmesi: action='plan' olculen bos VRAM/RAM'e gore (device, need_swap) doner.
    pro (eski PC2) profili (CPU dali acik) uzerinden denenir."""
    module = load_worker()
    from transcriber import config

    profile = config.select_profile(total_mib=16311)
    vram, ram = profile.audio_vram_mib, profile.audio_ram_mib

    monkeypatch.setattr(config, "free_vram_mib", lambda: vram)
    monkeypatch.setattr(config, "available_ram_mib", lambda: 0)
    plan = module.plan({"profile": "pc2", "local_model_loaded": True})
    assert plan["device"] == "cuda" and plan["need_swap"] is False
    assert plan["profile"] == "pro" and plan["free_vram_mib"] == vram

    # VRAM yetmez, RAM yeter -> CPU, swap yok.
    monkeypatch.setattr(config, "free_vram_mib", lambda: 0)
    monkeypatch.setattr(config, "available_ram_mib", lambda: ram)
    plan = module.plan({"profile": "pc2", "local_model_loaded": True})
    assert plan["device"] == "cpu" and plan["need_swap"] is False

    # Ikisi de yetmez -> mecburi swap.
    monkeypatch.setattr(config, "available_ram_mib", lambda: 0)
    plan = module.plan({"profile": "pc2", "local_model_loaded": True})
    assert plan["device"] == "cuda" and plan["need_swap"] is True

    # Yerel model yuklu degil (API) -> swap yok.
    plan = module.plan({"profile": "pc2", "local_model_loaded": False})
    assert plan["device"] == "cuda" and plan["need_swap"] is False


def test_lite_profile_uses_shared_plan(monkeypatch, tmp_path):
    """LITE (8 GB) ayni plani kullanir: RAM yeterli oldugu icin kisa kayit CPU, uzun kayit
    GPU + swap. Yerel model yoksa (API) GPU zaten bos -> swap gerekmez."""
    module = load_worker()
    from transcriber import config, audio

    src = tmp_path / "kayit.wav"
    src.write_bytes(b"RIFF")
    monkeypatch.setattr(config, "free_vram_mib", lambda: 0)
    monkeypatch.setattr(config, "available_ram_mib", lambda: 10 ** 6)
    monkeypatch.setattr(audio, "probe_duration_seconds", lambda path: 5.0)
    plan = module.plan({"profile": "pc1", "local_model_loaded": True, "path": str(src)})
    assert plan["device"] == "cpu" and plan["need_swap"] is False
    monkeypatch.setattr(audio, "probe_duration_seconds", lambda path: 3600.0)
    plan = module.plan({"profile": "pc1", "local_model_loaded": True, "path": str(src)})
    assert plan["device"] == "cuda" and plan["need_swap"] is True
    # Yerel model yoksa (API) GPU zaten bos -> swap gerekmez.
    plan = module.plan({"profile": "pc1", "local_model_loaded": False})
    assert plan["device"] == "cuda" and plan["need_swap"] is False


def test_worker_plan_action_uses_path_duration(monkeypatch, tmp_path):
    """plan eylemi kaydin suresini `path`ten tahmin eder: VRAM yetmez + KISA kayit -> CPU,
    UZUN kayit -> GPU + swap. Boylece 'kisa->CPU, uzun->GPU' ekonomisi uygulanir."""
    module = load_worker()
    from transcriber import config, audio

    profile = config.select_profile(total_mib=16311)
    src = tmp_path / "kayit.wav"
    src.write_bytes(b"RIFF")
    monkeypatch.setattr(config, "free_vram_mib", lambda: 0)
    monkeypatch.setattr(config, "available_ram_mib", lambda: 10 ** 6)
    monkeypatch.setattr(audio, "probe_duration_seconds", lambda path: 5.0)
    plan = module.plan({"profile": "pc2", "local_model_loaded": True, "path": str(src)})
    assert plan["device"] == "cpu" and plan["need_swap"] is False
    monkeypatch.setattr(audio, "probe_duration_seconds", lambda path: 3600.0)
    plan = module.plan({"profile": "pc2", "local_model_loaded": True, "path": str(src)})
    assert plan["device"] == "cuda" and plan["need_swap"] is True


def test_transcription_uses_asr_environment_not_imagegen():
    """Ses iscisi KENDI ortaminda (venv\\asr) calisir; venv\\imagegen'de faster-whisper yok."""
    worker = read_text("agent/qwen-inference.ps1")
    assert "function Get-AsrPythonExe" in worker
    assert "venv\\asr\\Scripts\\python.exe" in worker
    plan = worker.split("function Get-AudioTranscriptionPlan")[1].split("function ")[0]
    assert "Get-AsrPythonExe" in plan
    assert "path = $path" in plan


def test_worker_maps_selected_profile_to_asr_tier():
    """Arayuz SECILI dil-modeli profilini ses hatti tier'ina cevirir ('lite'->'lite', aksi->
    'pro') ve hem plan hem transcribe isteklerine `profile` alani olarak gecirir."""
    worker = read_text("agent/qwen-inference.ps1")
    assert "function Get-AsrProfileName" in worker
    fn = worker.split("function Get-AsrProfileName")[1].split("function ")[0]
    assert "return 'lite'" in fn
    assert "return 'pro'" in fn
    assert "$planPayload.profile = $asrProfile" in worker
    assert "$payloadBase.profile = $asrProfile" in worker


def _extract_ps_function(source: str, name: str) -> str:
    """Basit brace sayaci ile `function <name> { ... }` govdesini cikarir."""
    start = source.index(f"function {name}")
    depth = 0
    started = False
    for index in range(start, len(source)):
        char = source[index]
        if char == "{":
            depth += 1
            started = True
        elif char == "}":
            depth -= 1
            if started and depth == 0:
                return source[start:index + 1]
    raise AssertionError(f"{name} fonksiyonunun sonu bulunamadi")


def _run_ps1(script: str, tmp_path: Path) -> str:
    """Betigi gercek pwsh'ta -File ile calistirir (Turkce karakterler -Command'da bozulabilir)."""
    pwsh = shutil.which("pwsh")
    if not pwsh:
        pytest.skip("PowerShell 7 is unavailable")
    script_path = tmp_path / "test.ps1"
    script_path.write_text(script, encoding="utf-8-sig")
    result = subprocess.run(
        [pwsh, "-NoProfile", "-NonInteractive", "-File", str(script_path)],
        capture_output=True, text=True, timeout=30, encoding="utf-8", errors="replace",
    )
    assert result.returncode == 0, result.stdout + result.stderr
    return result.stdout


def test_asr_profile_name_ignores_non_local_provider(tmp_path):
    """A2 regresyonu: API modunda (yerel model yok) `$JobData.profile` secili yerel profilden
    DEGIL, varsayilan 'max'tan gelebilir; kullanicinin kayitli localProfile'i 'lite' olsa bile
    ASR zorla 'pro' olmamali. Get-AsrProfileName yerel OLMAYAN saglayicida $null donmeli ki
    isci tier'i gercek VRAM'den secsin (config.select_profile); yerel + lite -> 'lite',
    yerel + max/flash -> 'pro'. Fonksiyon gercek pwsh'ta izole calistirilir."""
    worker = read_text("agent/qwen-inference.ps1")
    fn = _extract_ps_function(worker, "Get-AsrProfileName")
    script = fn + """

function Ask([string]$prov, $prof) {
    $script:provider = $prov
    $script:JobData = [pscustomobject]@{ profile = $prof }
    '[' + (Get-AsrProfileName) + ']'
}
Ask 'openai' 'max'
Ask 'claude' 'flash'
Ask 'custom' 'lite'
Ask 'local' 'lite'
Ask 'local' 'max'
Ask 'local' 'flash'
Ask 'local' 'pc1'
Ask 'local' ''
"""
    out = _run_ps1(script, tmp_path)
    assert out.split() == ["[]", "[]", "[]", "[lite]", "[pro]", "[pro]", "[lite]", "[]"]


def test_desktop_pipes_audio_to_worker_and_shows_transcript():
    desktop = read_text("qwen-desktop.ps1")
    worker = read_text("agent/qwen-inference.ps1")
    assert "currentTurnAudioPaths" in desktop
    assert "currentAudioPaths = @($script:currentTurnAudioPaths)" in desktop
    assert "function Invoke-TranscribeWithModelSwap" in worker
    assert "function Add-TranscriptToMessages" in worker
    assert "$JobData.currentAudioPaths" in worker
    assert "Emit 'transcript'" in worker
    assert "'transcript' {" in desktop


def test_microphone_red_button_cancels_recording():
    """Kayit surerken kirmizi mikrofon tiklamasi kaydi IPTAL eder (dur + dosya silinir,
    gonderilmez). Kaydi bitirip gondermek icin sag tik menusu ya da Gönder kullanilir."""
    desktop = read_text("qwen-desktop.ps1")
    assert "function Start-MicrophoneCapture" in desktop
    assert "mciSendString" in desktop
    assert "open new type waveaudio alias" in desktop  # WAVE_MAPPER = default device
    assert "function Stop-MicrophoneCapture" in desktop
    assert "function Complete-MicrophoneCapture" in desktop
    assert "function Cancel-MicrophoneCapture" in desktop
    # Kirmizi mikrofon (kayit surerken) tiklamasi IPTAL eder.
    assert "$micBtn.Add_Click({" in desktop
    click = desktop.split("$micBtn.Add_Click({")[1].split("})")[0]
    assert "Cancel-MicrophoneCapture" in click
    assert "Complete-MicrophoneCapture" not in click
    # Menu "bitir ve gonder" yolunu korur.
    assert "$micUse.Add_Click({" in desktop and "Complete-MicrophoneCapture" in desktop
    assert "$micBtn.Add_MouseUp({" in desktop


def test_microphone_menu_has_non_speech_events_toggle():
    """Mikrofon menusunde 'Konusma disi sesler' onay kutusu: isaretli ise AST olaylari da
    yakalanir, degilse yalnizca konusma. Ayar api.json -> audioEvents'te saklanir ve isciye
    gecirilir."""
    desktop = read_text("qwen-desktop.ps1")
    assert "Konuşma dışı sesler" in desktop
    assert "$script:audioEvents" in desktop
    assert "audioEvents = [bool]$script:audioEvents" in desktop
    assert "$script:apiSettings.audioEvents = $script:audioEvents" in desktop
    worker = read_text("agent/qwen-inference.ps1")
    assert "events = $audioEvents" in worker


def test_transcription_uses_model_swap_for_local_provider():
    """OCR ile ayni desen: yerel saglayicida (dil modeli yuklu) tier SECILI profilden gelir
    (lite/pro); cihaz/swap karari ise ses isi baslarken OLCULEN bos VRAM/RAM + kaydin
    suresine gore verilir; dil modeli gerekiyorsa bosaltilir ve geri yuklenir."""
    worker = read_text("agent/qwen-inference.ps1")
    block = worker.split("function Invoke-TranscribeWithModelSwap")[1].split("function ")[0]
    plan = worker.split("function Get-AudioTranscriptionPlan")[1].split("function ")[0]
    assert "(Get-ManageQwenPath) -Action stop" in block
    assert "Start-LocalModelRestore" in block
    # Plan iscisi whisper-tools.py'yi cagirir (cihaz/swap'i o belirler).
    assert "Get-WhisperPyPath" in plan and "action = 'plan'" in plan
    # Ses hatti KENDI ortaminda calisir: venv\asr python'u (venv\imagegen degil).
    assert "function Get-AsrPythonExe" in worker
    assert "venv\\asr\\Scripts\\python.exe" in worker
    assert "Get-AsrPythonExe" in plan
    assert "Get-AsrPythonExe" in block
    assert "$whisperPy = Get-WhisperPyPath; $asrPy = Get-AsrPythonExe" in block
    assert "Invoke-PythonTool $payloadBase $whisperPy $asrPy" in block
    # Artik @('gpu','cpu') cift dongusu yok; cihaz/swap plani isciden alinir (sure de verilir).
    assert "@('gpu', 'cpu')" not in block
    assert "Get-AudioTranscriptionPlan $path" in block
    assert "path = $path" in plan
    assert "$needSwap = [bool]$plan.need_swap" in block
    assert "device = $device" in block
    assert "need_swap = $needSwap" in block
    # Profil adina gore karar (LITE istisnasi) KALDIRILDI; LITE'ta da VRAM/RAM'e gore swap.
    assert "([string]$JobData.profile) -ne 'lite'" not in worker


def test_transcription_honors_cancel_and_stop_does_not_wait_for_restore():
    worker = read_text("agent/qwen-inference.ps1")
    block = worker.split("function Invoke-TranscribeWithModelSwap")[1].split("function ")[0]
    assert "$Shared.Cancel" in block
    wait = worker.split("function Wait-LocalModelReady")[1].split("function ")[0]
    assert "if ($Shared.Cancel) { return }" in wait
    assert "if (!$Shared.Cancel) { Emit 'status' 'Dil modeli geri yüklendi" in block
    caller = worker.split("$currentAudioPaths = @($JobData.currentAudioPaths")[1].split("Otomatik baglam")[0]
    assert "Emit 'cancelled'" in caller


def test_worker_steers_model_away_from_reading_failed_audio():
    """Regresyon (ucdan uca ses testi): dökum alinamadiginda (hata ya da bos sonuc) isci son
    kullanici mesajindaki '[Kullanici bir ses dosyasi ekledi: ...]' notunu tek basina
    BIRAKMAZ. Aksi halde model dosyayi 'ekli belge' sanip read_document/read_bound_file ile
    acmaya calisiyor ve TUM ajan turlarini (>8) bosa harcayip kullaniciya tek kelime
    yanit vermiyordu; dökum baloncugu da hic olusmuyordu. Ayrica plan 'swap yok' deyip
    dökum yine de alinamazsa dil modeli bosaltilip TEMIZ GPU/RAM ile BIR kez daha denenir."""
    worker = read_text("agent/qwen-inference.ps1")
    assert "function Set-AudioUnavailableNote" in worker
    # Basarisiz dökumun HER iki yolunda (bos/hata sonucu + istisna) yonlendirme notu eklenir.
    caller = worker.split("$currentAudioPaths = @($JobData.currentAudioPaths")[1].split("Otomatik baglam")[0]
    assert caller.count("Set-AudioUnavailableNote") >= 2
    assert "read_document/read_bound_file" in worker
    # no-swap yolu basarisizsa swap ile yeniden deneme (temiz GPU + daha cok bos RAM).
    block = worker.split("function Invoke-TranscribeWithModelSwap")[1].split("function ")[0]
    assert "!$swapModel -and $provider -eq 'local'" in block
    assert "($payloadBase + @{ device = 'cuda'; need_swap = $true })" in block
    assert "Wait-LocalModelStopped" in block
    # Regresyon: eski "dökumsuz sürüyor" yolu not eklemeden devam EDEMEZ.
    assert 'Emit \'status\' "Ses dökumlenemedi; istek dökumsuz sürüyor. $reason"' in caller


def test_set_audio_unavailable_note_isolated(tmp_path):
    """Set-AudioUnavailableNote izole calistirilir: yonlendirme notu son kullanici mesajina
    eklenir ve modeli dosyayi okumaktan acikca caydirir (gercek pwsh)."""
    worker = read_text("agent/qwen-inference.ps1")
    fn = _extract_ps_function(worker, "Set-AudioUnavailableNote")
    script = fn + """
$items = [Collections.ArrayList]::new()
[void]$items.Add(@{ role = 'user'; content = @(@{ type = 'text'; text = '[Kullanici bir ses dosyasi ekledi: ses.wav]' }) })
$ok = Set-AudioUnavailableNote $items 'ses.wav' 'CUDA out of memory'
'OK=' + $ok
'COUNT=' + @($items[0].content).Count
'NOTE=' + [string]$items[0].content[-1].text
"""
    out = _run_ps1(script, tmp_path)
    assert "OK=True" in out
    assert "COUNT=2" in out
    assert "BELGE degil" in out
    assert "read_document" in out
    assert "ses.wav" in out


def test_audio_turn_preempts_language_model_loading():
    desktop = read_text("qwen-desktop.ps1")
    assert "function Stop-ModelSwitchForAudio" in desktop
    begin = desktop.split("function Begin-Generation {")[1].split("function Set-LastUserImage")[0]
    assert "$turnAudio" in begin and "Stop-ModelSwitchForAudio" in begin
    send = desktop.split("$send.Add_Click({")[1].split("$promptBox.Add_KeyDown")[0]
    assert "currentTurnAudioPaths.Count -gt 0" in send


def test_python_tool_subprocess_is_killed_instantly_on_stop():
    worker = read_text("agent/qwen-inference.ps1")
    block = worker.split("function Invoke-PythonTool")[1].split("function ")[0]
    assert "ReadToEndAsync" in block
    assert "$Shared.Cancel" in block
    assert "$p.Kill($true)" in block
    asr = worker.split("function Invoke-TranscribeWithModelSwap")[1].split("function ")[0]
    # Cihaz dongusu kaldirildi; CPU yedegi yalnizca iptal EDILMEDIYSE denenir.
    assert "if ($err -and !$Shared.Cancel) {" in asr
    assert "if ($Shared.Cancel) { Emit 'cancelled'" in worker


# ---------------------------------------------------- D2: duvar-saati siniri
def test_python_tool_has_wall_clock_timeout():
    """D2: Invoke-PythonTool bekleme dongusu eskiden yalnizca iptali yokluyordu; alt
    surec kilitlenirse TUM is sonsuza kadar bekliyordu. Artik ust sure var (varsayilan
    180 sn; parametre ya da $payload.timeoutSeconds ile gecersiz kilinabilir) ve
    asilirsa alt surec agaci oldurulup hata donulur; iptal davranisi korunur."""
    worker = read_text("agent/qwen-inference.ps1")
    block = worker.split("function Invoke-PythonTool")[1].split("function ")[0]
    assert "function Invoke-PythonTool([hashtable]$payload, [string]$scriptPath = $null, [string]$pythonPath = $null, [int]$timeoutSeconds = 0)" in worker
    assert "$payload.timeoutSeconds" in block
    assert "if ($timeoutSeconds -le 0) { $timeoutSeconds = 180 }" in block
    assert "$deadline = [DateTime]::UtcNow.AddSeconds($timeoutSeconds)" in block
    assert "[DateTime]::UtcNow -ge $deadline" in block
    assert "return \"Arac zaman asimina ugradi ($timeoutSeconds sn).\"" in block
    # Iptal davranisi korunur (once iptal, sonra zaman asimi yoklanir).
    assert block.index("$Shared.Cancel") < block.index("-ge $deadline")


def test_python_tool_wall_clock_timeout_kills_subprocess(tmp_path):
    """D2 davranis: sonsuza kadar uyuyan alt surec zaman asiminda oldurulur ve is
    TAKILMADAN hata dondurur (gercek pwsh + gercek Python sureci)."""
    worker = read_text("agent/qwen-inference.ps1")
    fn = _extract_ps_function(worker, "Invoke-PythonTool")
    sleeper = tmp_path / "sleeper.py"
    sleeper.write_text("import time\ntime.sleep(30)\n", encoding="utf-8")
    script = fn + f"""
$shared = @{{ Cancel = $false }}
$sw = [Diagnostics.Stopwatch]::StartNew()
$out = Invoke-PythonTool @{{ x = 1 }} '{sleeper}' '{sys.executable}' 2
'OUT=' + $out
'ELAPSED=' + [int]$sw.Elapsed.TotalSeconds
"""
    out = _run_ps1(script, tmp_path)
    assert "Arac zaman asimina ugradi" in out, out
    elapsed = int(out.split("ELAPSED=")[1].split()[0])
    assert elapsed < 15, out


# --------------------------------------------- F1/F2: baglam tasmasi korumasi
def test_inference_loop_guards_against_context_overflow():
    """F1/F2: tur ici araç sonuclari birikip prompt ctx-size'i asarsa --no-context-shift
    yuzunden sunucu HATA donduruyordu ve tur dusuyordu. Her tur BASINDA tahmini prompt
    boyutu hesaplanir; butce asilirsa EN ESKI araç ciktilarini kisaltir, hala sigmazsa
    araclara devam etmeden gorunur yanit ister. Ayrica max_tokens kalan odaga gore
    sinirlanir."""
    worker = read_text("agent/qwen-inference.ps1")
    assert "function Estimate-MessagesTokens" in worker
    assert "function Compress-TurnMessages" in worker
    assert "$promptTokensEst = Estimate-MessagesTokens $messages" in worker
    assert "Compress-TurnMessages $messages $trimBudget" in worker
    assert "Baglam sinirina yaklasildi; eski arac ciktilari kisaltildi." in worker
    assert "Baglam siniri asildi; araclara devam edilmeden eldeki bulgularla yanit isteniyor." in worker
    # max_tokens kalan odaga gore sinirlanir; gonderilen govde bu degeri kullanir.
    assert "$maxTokens = [math]::Min($maxTokens, [math]::Max(256, $contextLimit - $promptTokensEst - $contextReserve))" in worker
    assert "max_tokens = $maxTokens" in worker
    assert "max_tokens = [int]$JobData.maxTokens" not in worker
    # Guvenli bitis: araclar sunulmaz.
    assert "$offeredTools = if ($forceFinalAnswer)" in worker
    assert "$forceFinalAnswer" in worker.split("function Estimate-MessagesTokens")[1]


def test_estimate_and_compress_turn_messages_isolated(tmp_path):
    """F1 davranis: tahmin araç ciktisiyla buyur; Compress-TurnMessages butceyi asan
    EN ESKI araç ciktisini kisaltir, sistem mesajini ve SON kullanici mesajini korur,
    mesaji SILMEZ (assistant tool_calls ile tool eslesmesi bozulmaz)."""
    worker = read_text("agent/qwen-inference.ps1")
    fn = _extract_ps_function(worker, "Estimate-MessagesTokens") + "\n\n" + \
        _extract_ps_function(worker, "Compress-TurnMessages")
    script = fn + """
$items = [Collections.ArrayList]::new()
[void]$items.Add(@{ role = 'system'; content = 'SISTEM TALIMATI' })
[void]$items.Add(@{ role = 'user'; content = 'ilk soru' })
[void]$items.Add(@{ role = 'assistant'; content = ''; tool_calls = @(@{ id = 'c1'; type = 'function'; function = @{ name = 'read_bound_file'; arguments = '{}' } }) })
[void]$items.Add(@{ role = 'tool'; tool_call_id = 'c1'; content = ('X' * 30000) })
[void]$items.Add(@{ role = 'user'; content = 'SON SORU' })
'BEFORE=' + (Estimate-MessagesTokens $items)
$n = Compress-TurnMessages $items 500
'AFTER=' + (Estimate-MessagesTokens $items)
'TRIMMED=' + $n
'COUNT=' + $items.Count
'SYS=' + [string]$items[0].content
'LAST=' + [string]$items[4].content
'TOOL=' + [string]$items[3].content
'ARGS=' + [string]$items[2].tool_calls[0].function.arguments
"""
    out = _run_ps1(script, tmp_path)
    before = int(out.split("BEFORE=")[1].split()[0])
    after = int(out.split("AFTER=")[1].split()[0])
    assert before >= 10000, out
    assert after < before, out
    trimmed = int(out.split("TRIMMED=")[1].split()[0])
    assert trimmed >= 1, out
    assert "COUNT=5" in out
    assert "SYS=SISTEM TALIMATI" in out
    assert "LAST=SON SORU" in out
    assert "kisaltildi" in out.split("TOOL=")[1]
    assert "ARGS={}" in out


# --------------------------------------------------- F3: audit log rotasyonu
def test_audit_log_has_size_rotation():
    """F3: logs/audit.jsonl sinirsiz buyuyordu; hicbir boyut tavani/rotasyon yoktu.
    Tavan (5 MB) asilinca mevcut dosya audit.1.jsonl'e devredilir (uzerine yazilir)
    ve yeni kayit temiz dosyaya gider. Devir de ayni try icindedir; audit yazimi
    hicbir durumda turu DUSURMEZ (mevcut catch yutar)."""
    worker = read_text("agent/qwen-inference.ps1")
    block = worker.split("function Write-AuditLog")[1].split("$endpoint =")[0]
    assert "5MB" in block
    assert "audit.1.jsonl" in block
    assert "Move-Item" in block and "-Force" in block
    # Devir, mutex kilitli bloğun ICINDE ve yazimdan ONCE olmali (yaris onlenir).
    after_lock = block.split("$owns = $lock.WaitOne(2000)")[1]
    assert after_lock.index("Move-Item") < after_lock.index("Add-Content")
    # try/catch korunur: yazim/rotasyon hatasi yutulur, tur dusmez.
    assert "catch {" in block


def test_write_audit_log_rotates_when_oversized(tmp_path):
    """F3 davranis (gercek pwsh): 5 MB'i asan audit.jsonl bir sonraki yazimdan once
    audit.1.jsonl'e devredilir (varsa eski devir dosyasinin UZERINE yazilir) ve yeni
    satir temiz dosyaya gider. Devirden sonra dosya kucuk kaldigi icin ikinci yazim
    yeniden devretmez."""
    worker = read_text("agent/qwen-inference.ps1")
    fn = _extract_ps_function(worker, "Get-AuditLock") + "\n\n" + \
        _extract_ps_function(worker, "Write-AuditLog")
    log_dir = tmp_path / "logs"
    log_path = log_dir / "audit.jsonl"
    rotated = log_dir / "audit.1.jsonl"
    script = fn + f"""
function Get-AuditLogPath {{ '{log_path}' }}
[IO.Directory]::CreateDirectory('{log_dir}') | Out-Null
# Var olan devir dosyasi (uzerine yazilmali) + tavani asan 6 MB'lik dolu kayit.
[IO.File]::WriteAllText('{rotated}', 'ESKI-DEVIR-ICERIGI')
[IO.File]::WriteAllText('{log_path}', ('x' * 999 + "`n") * 6000)
Write-AuditLog 'read_bound_file' 'not_required' 'ok' 'a.txt' ''
Write-AuditLog 'run_command' 'asked_yes' 'ok' 'echo hi' 'C:\\tmp\\out.txt'
'WROTE=ok'
"""
    out = _run_ps1(script, tmp_path)
    assert "WROTE=ok" in out, out
    new_lines = log_path.read_text(encoding="utf-8").splitlines()
    assert len(new_lines) == 2, new_lines
    assert '"tool":"read_bound_file"' in new_lines[0]
    assert '"tool":"run_command"' in new_lines[1]
    rotated_text = rotated.read_text(encoding="utf-8")
    assert rotated_text.startswith("x" * 100), rotated_text[:120]
    assert "ESKI-DEVIR-ICERIGI" not in rotated_text
    assert len(rotated_text.splitlines()) == 6000


# --------------------------------------------- F4: reasoning tekrar korumasi
def test_reasoning_repeat_guard_uses_same_threshold():
    """F4: LITE'ta dusunme sinirsizdir; runaway dedektoru yalnizca görünür icerige
    baktigindan model reasoning akisinda tekrara girerse 8192 token tavanina kadar
    bos donuyordu. reasoning birikimine de AYNI esik/desen uygulanir ve akis guvenli
    durdurulur; görünür yanit yoksa mevcut 'bos yanit' yolu (finishReason'a bakmaz)
    bozulmadan devreye girer."""
    worker = read_text("agent/qwen-inference.ps1")
    block = worker.split("if ($delta.reasoning_content) {")[1].split("if ($delta.content) {")[0]
    assert "(Test-RepeatedOutput $result.reasoning)" in block
    assert "Remove-RepeatedTail $result.reasoning" in block
    assert "$stopForRepeat = $true" in block
    assert "$finished = $true" in block
    # Koruma yerel akisla sinirlidir; uzak saglayicilar etkilenmez (icerikle ayni).
    assert "$provider -eq 'local'" in block
    # Bos-yanit yolu hala görünür icerige bakar; reasoning tekrari onu bozmaz.
    assert 'IsNullOrWhiteSpace($turn.content)' in worker


class ReasoningRepeatHandler(BaseHTTPRequestHandler):
    """SSE: yalnizca reasoning_content gonderir ve ayni sozcugu 6+ kez tekrarlar;
    [DONE] gonderilmez, baglanti acik kalir. F4 korumasi olmadan istemci 8192
    tokena kadar doner ya da 120 sn sessizlik zaman asimina kadar beklerdi."""

    protocol_version = "HTTP/1.1"

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        try:
            for _ in range(400):
                chunk = {"choices": [{"index": 0, "delta": {"reasoning_content": "dusunuyorum "}}]}
                self.wfile.write(b"data: " + json.dumps(chunk).encode() + b"\n\n")
                self.wfile.flush()
            time.sleep(60)
        except OSError:
            pass

    def log_message(self, *args):
        pass


def test_reasoning_repeat_stops_stream_early(tmp_path):
    """F4 davranis (gercek pwsh + sahte SSE sunucusu): reasoning akisinda tekrar
    erken durdurulmazsa LITE 8192 tokena kadar bos donuyordu. Ayni esik/desen
    reasoning'e uygulanir; akis 'repeat' ile guvenli kapanir, görünür yanit yoktur
    (dolayisiyla mevcut bos-yanit/retry yolu devreye girebilir) ve istisna sizmaz."""
    server = ThreadingHTTPServer(("127.0.0.1", 0), ReasoningRepeatHandler)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        script = f"""
$job = @{{ messages = @(@{{ role = 'user'; content = 'selam' }}); compactOnly = $true; model = 'test'; contextLimit = 32768; maxTokens = 8192; agent = $false; internet = $false; office = $false; documentCreate = $false }}
$shared = @{{ Cancel = $false }}
. '{ROOT}\\agent\\qwen-inference.ps1' $job $shared | Out-Null
$endpoint = 'http://127.0.0.1:{server.server_port}/v1/chat/completions'
$script:http = [Net.Http.HttpClient]::new(); $script:http.Timeout = [Threading.Timeout]::InfiniteTimeSpan
$turn = @{{ reasoning = ''; content = ''; usage = $null; toolParts = @{{}}; finishReason = $null }}
$sw = [Diagnostics.Stopwatch]::StartNew()
$threw = ''
try {{ Invoke-ChatCompletion @{{ messages = @() }} $shared $false $turn | Out-Null }} catch {{ $threw = [string]$_.Exception.GetBaseException().Message }}
@{{ content = $turn.content; reasoningLen = $turn.reasoning.Length; finish = $turn.finishReason; threw = $threw; seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1) }} | ConvertTo-Json -Compress
"""
        out = _run_ps1(script, tmp_path)
    finally:
        server.shutdown()
    got = json.loads(out.strip().splitlines()[-1])
    assert got["finish"] == "repeat", got
    assert got["content"] == "", got
    assert got["threw"] == "", got
    assert got["reasoningLen"] < 2000, got
    assert got["seconds"] < 15, got


def test_stop_cancels_work_but_never_kills_an_in_flight_model_load():
    desktop = read_text("qwen-desktop.ps1")
    cancel = desktop.split("function Cancel-Generation {")[1].split("function Stop-LocalQwen")[0]
    assert "switchProcess" not in cancel
    assert "pendingModelChange" not in cancel


# ------------------------------------------------------------------ kurulum
def test_installer_builds_asr_venv_and_downloads_models():
    """Ses dökum motoru faster-whisper (Whisper large-v3-tr) + AST'dir. Kurulum venv\\asr
    olusturur ve modelleri HF onbellegine ceker (whisper.cpp ve Qwen3-ASR kaldirildi)."""
    installer = read_text("scripts/install-mamidlabs.ps1")
    assert "venv\\asr" in installer
    assert "oguzhangokboru/whisper-large-v3-tr" in installer
    assert "asr       = { Invoke-Asr }" in installer
    # Eski motorlar tamamen kaldirildi.
    assert "whisper-cli.exe" not in installer
    assert "ggml-large-v3" not in installer
    assert "whisperCuda" not in installer
    assert "Qwen/Qwen3-ASR" not in installer
    assert "models\\qwen3-asr" not in installer
    # requirements/asr.txt paket listesini saglar.
    asr_req = read_text("requirements/asr.txt")
    assert "faster-whisper" in asr_req and "pyannote.audio" in asr_req


def test_old_audio_workers_are_removed():
    assert not (ROOT / "agent" / "qwen3-asr-tools.py").exists()
    assert (ROOT / "agent" / "whisper-tools.py").is_file()


def test_installer_known_stages_include_asr_after_python():
    installer = read_text("scripts/install-mamidlabs.ps1")
    stages = installer.split("$script:KnownStages = @(")[1].split(")")[0]
    assert "'asr'" in stages and "'whisper'" not in stages
    order = installer.split("$stages = [ordered]@{")[1]
    assert order.index("python") < order.index("asr       = { Invoke-Asr }")
