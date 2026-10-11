"""Whisper.cpp iscisi: eklenen ses dosyasini metne cevirir.

imagegen venv'i ile calisir (PyAV kurulu). stdin'den JSON alir, stdout'a JSON yazar.
Ses, PyAV ile 16 kHz mono WAV'a cevrilir; whisper-cli (whisper.cpp) ile dökumlenir.
Model ve binary kurulum kokunde aranir (models\\whisper, whisper.cpp).
"""
from __future__ import annotations

import json
import os
import pathlib
import subprocess
import sys
import tempfile

# Kurulum kokunu kendi konumundan turet: bu dosya her zaman <kok>/agent/ altindadir.
ROOT = pathlib.Path(__file__).resolve().parent.parent
MAX_AUDIO_BYTES = 512 * 1024 * 1024
# Tercihe gore model; yoksa klasordeki ilk ggml-*.bin kullanilir. turbo once gelir:
# olculdu (RTX 5060 Ti + Ryzen 5 3600): CPU'da ~2x, CUDA'da ~4-13x daha hizli ve temiz
# konusmada large-v3 ile ayni dogrulukta. Halusinasyon (sessizlik/muzikte) VAD ile
# bastirilir (bkz. asagida); turbo large-v3'e gore daha "sapitan" DEGILDIR.
MODEL_PREFERENCE = (
    'ggml-large-v3-turbo-q5_0.bin',
    'ggml-large-v3-turbo-q8_0.bin',
    'ggml-large-v3-turbo.bin',
    'ggml-large-v3.bin',
    'ggml-large-v2.bin',
    'ggml-medium.bin',
    'ggml-small.bin',
)


def _find_cli() -> str:
    base = ROOT / 'whisper.cpp'
    candidates = list(base.rglob('whisper-cli.exe')) if base.exists() else []
    if not candidates:
        raise RuntimeError('whisper-cli.exe bulunamadi; whisper.cpp indirilmemis olabilir.')
    # CUDA derlemesi varsa onu tercih et (ayni klasorde toplanmis olabilir).
    cuda = [c for c in candidates if 'cuda' in str(c).lower()]
    return str((cuda or candidates)[0])


def _find_model(explicit: str | None) -> str:
    if explicit:
        if os.path.isfile(explicit):
            return explicit
        raise ValueError('Belirtilen Whisper modeli bulunamadi: %s' % explicit)
    model_dir = ROOT / 'models' / 'whisper'
    for name in MODEL_PREFERENCE:
        candidate = model_dir / name
        if candidate.is_file():
            return str(candidate)
    found = sorted(model_dir.glob('ggml-*.bin')) if model_dir.exists() else []
    if found:
        return str(found[0])
    raise RuntimeError('Whisper modeli bulunamadi (models\\whisper). Once model indir.')


def _to_wav16k_mono(src: str, dst: str) -> None:
    import av
    from av.audio.resampler import AudioResampler

    with av.open(src) as container:
        if not container.streams.audio:
            raise ValueError('Ses akisi bulunamadi.')
        stream = container.streams.audio[0]
        resampler = AudioResampler(format='s16', layout='mono', rate=16000)
        with av.open(dst, 'w', format='wav') as out:
            out_stream = out.add_stream('pcm_s16le', rate=16000)
            out_stream.layout = 'mono'
            for frame in container.decode(stream):
                for resampled in resampler.resample(frame):
                    for packet in out_stream.encode(resampled):
                        out.mux(packet)
            for resampled in resampler.resample(None):
                for packet in out_stream.encode(resampled):
                    out.mux(packet)


def _find_vad() -> str | None:
    """Silero VAD modeli (halusinasyonu onler). Varsa doner; yoksa None."""
    model_dir = ROOT / 'models' / 'whisper'
    for candidate in sorted(model_dir.glob('ggml-silero-*.bin')):
        if candidate.is_file():
            return str(candidate)
    return None


def transcribe(req: dict) -> dict:
    path = str(req.get('path') or '')
    if not path or not os.path.isfile(path):
        raise ValueError('Ses dosyasi bulunamadi.')
    if os.path.getsize(path) > MAX_AUDIO_BYTES:
        raise ValueError('Ses dosyasi boyut guvenlik sinirini asti.')
    cli = _find_cli()
    model = _find_model(req.get('model'))
    language = str(req.get('language') or 'auto').strip() or 'auto'
    timeout = int(req.get('timeout') or 1800)
    device = str(req.get('device') or '').lower()
    vad = None if req.get('vad') is False else _find_vad()

    with tempfile.TemporaryDirectory() as temp_dir:
        wav = os.path.join(temp_dir, 'audio.wav')
        _to_wav16k_mono(path, wav)
        out_base = os.path.join(temp_dir, 'transcript')
        args = [cli, '-m', model, '-f', wav, '-of', out_base, '-otxt', '-nt']
        if language != 'auto':
            args += ['-l', language]
        if device == 'cpu':
            args += ['-ng']  # GPU kullanma
        # VAD (Silero): sessizlik/muzikte halusinasyonu bastirir, konusmayi bolmeye
        # yardim eder. Metin baglamini kapatmak (-mc 0) tek basina yetmiyordu; VAD sart.
        if vad:
            args += ['--vad', '-vm', vad, '-mc', '0']
        proc = subprocess.run(args, capture_output=True, text=True, encoding='utf-8',
                              errors='replace', timeout=timeout)
        text_file = out_base + '.txt'
        if os.path.exists(text_file):
            text = pathlib.Path(text_file).read_text(encoding='utf-8', errors='replace').strip()
        elif proc.stdout:
            text = proc.stdout.strip()
        else:
            text = ''
        if proc.returncode != 0 and not text:
            detail = (proc.stderr or proc.stdout or '').strip()
            raise RuntimeError('whisper-cli hata verdi: %s' % detail[:400])
    return {
        'text': text,
        'model': os.path.basename(model),
        'vad': os.path.basename(vad) if vad else '',
        'language': language,
        'chars': len(text),
    }


ACTIONS = {'transcribe': transcribe}


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
