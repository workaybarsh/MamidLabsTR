"""Ses dökum iscisi: `transcriber` paketini cagirir.

Motor: faster-whisper large-v3-tr (Turkce). Ses olaylari (AST) ve konusmaci ayrimi
(pyannote) varsayilan aciktir. Cikti bicimi kronolojik, zaman damgasiz:

    (ayak sesleri)
    Konusmaci: Geldin mi?
    (kapi sesi)
    Konusmaci: Evet, biraz geciktim.

Arayuz/isci sozlesmesi: stdin'den JSON alir, stdout'a JSON yazar.
    istek: {"action":"transcribe","path":...,"device":"auto|cuda|cpu","need_swap":bool,"language":"tr", ...}
    istek: {"action":"plan","local_model_loaded":bool}   -> {"device":..,"need_swap":..}
    yanit: {"text":..., "model":..., "chars":..., "events":N, "diarized":bool} ya da {"error":...}
"""
from __future__ import annotations

import json
import os
import pathlib
import sys

# transcriber paketi bu dosyanin yanindaki alt klasordedir (<kok>/agent/transcriber).
AGENT_DIR = pathlib.Path(__file__).resolve().parent
if str(AGENT_DIR) not in sys.path:
    sys.path.insert(0, str(AGENT_DIR))

from transcriber import config, main as transcriber_main  # noqa: E402


def _profile(req: dict):
    if req.get('profile'):
        total = 20000 if str(req['profile']).lower() == 'pc2' else 8000
        return config.select_profile(total_mib=total)
    language = str(req.get('language') or '').strip()
    overrides = {}
    if language and language != 'auto':
        overrides['language'] = language
    return config.select_profile(**overrides) if overrides else config.select_profile()


def transcribe(req: dict) -> dict:
    # 'auto' oldugu gibi gecirilir; cihazi transcriber paketi kaydin suresine gore secer.
    device = str(req.get('device') or 'auto').lower()
    if device == 'gpu':
        device = 'cuda'
    # need_swap: yerel 27B saglayicida dil modeli VRAM swap maliyeti oldugunu isciye bildir.
    # Alan yoksa None birak (paket guvenli varsayilani uygular).
    need_swap = req.get('need_swap')
    if need_swap is not None:
        need_swap = bool(need_swap)
    profile = _profile(req)
    payload = transcriber_main.run(
        str(req.get('path') or ''),
        profile=profile,
        device=device,
        need_swap=need_swap,
        initial_prompt=req.get('initial_prompt'),
        events=req.get('events'),
        diarize_enabled=req.get('diarize'),
        token=req.get('token'),
        include_timestamps=False,
        out_base=req.get('out_base'),
        keep_wav=False,
    )
    return {
        'text': payload['text'],
        'model': os.path.basename(profile.whisper_model),
        'vad': 'silero',
        'chars': len(payload['text']),
        'language': payload['language'],
        'profile': profile.name,
        'events': len(payload['events']),
        'diarized': payload['diarized'],
    }


def plan(req: dict) -> dict:
    """Ses isi baslamadan once (cihaz, swap) planini doner (bkz. config.choose_plan).

    Oncelik: (1) dil modeliyle birlikte bos VRAM'e sigarsa GPU + swap yok; (2) sigmazsa ve
    kayit KISAYSA (swap maliyeti kazanci asar) CPU'da RAM'e sigiyorsa CPU + swap yok;
    (3) aksi halde (uzun kayit ya da RAM yetmiyor) GPU + mecburi swap. Kaydin suresi
    `path`ten cozmeden tahmin edilir.
    Isci bu plani arayuz/isci katmanina bildirir; dil modeli YALNIZCA swap gerektiginde
    bosaltilir.
    """
    profile = _profile(req)
    local = req.get('local_model_loaded')
    local = True if local is None else bool(local)
    vram = config.free_vram_mib()
    ram = config.available_ram_mib()
    # Kaydin suresi (kisa -> CPU, uzun -> GPU ekonomisi icin). Dosyayi cozmeden tahmin edilir.
    duration = None
    path = str(req.get('path') or '')
    if path:
        try:
            from transcriber import audio
            duration = audio.probe_duration_seconds(path)
        except Exception:
            duration = None
    device, need_swap = config.choose_plan(
        profile, duration_seconds=duration, vram_free_mib=vram, ram_free_mib=ram,
        local_model_loaded=local)
    return {
        'device': device,
        'need_swap': need_swap,
        'profile': profile.name,
        'duration_seconds': duration,
        'free_vram_mib': vram,
        'free_ram_mib': ram,
    }


ACTIONS = {'transcribe': transcribe, 'plan': plan}


def main() -> None:
    try:
        sys.stdout.reconfigure(encoding='utf-8')
        sys.stdin.reconfigure(encoding='utf-8')
    except Exception:
        pass
    req = json.loads(sys.stdin.read() or '{}')
    handler = ACTIONS.get(req.get('action'))
    if not handler:
        print(json.dumps({'error': 'bilinmeyen islem'}, ensure_ascii=False))
        return
    try:
        print(json.dumps(handler(req), ensure_ascii=False))
    except Exception as exc:
        print(json.dumps({'error': '%s: %s' % (type(exc).__name__, exc)}, ensure_ascii=False))


if __name__ == '__main__':
    main()
