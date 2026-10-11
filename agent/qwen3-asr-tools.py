"""Qwen3-ASR iscisi: eklenen ses dosyasini Qwen3-ASR-1.7B ile metne cevirir.

imagegen venv'i ile calisir (torch cu130 + transformers 5.x + PyAV). stdin'den JSON alir,
stdout'a JSON yazar. Ses, PyAV ile 16 kHz mono WAV'a cevrilir; ardindan transformers
(Qwen3ASR / AutoModelForMultimodalLM) ile cok dilli dökum yapilir (52 dil; Türkce dahil,
konusma + sarki/BGM). Model kurulum kokunde aranir (models\\qwen3-asr).

Tek motor, tek model. Agir LLM tabanli oldugu icin GPU onerilir;
GPU yoksa CPU'ya duser (yavas).
"""
from __future__ import annotations

import json
import os
import pathlib
import sys
import tempfile

# Cevrimdisi garanti: model zaten yerelde; transformers/HF calisma aninda aga cikmasin.
os.environ.setdefault('HF_HUB_OFFLINE', '1')
os.environ.setdefault('TRANSFORMERS_OFFLINE', '1')

# Kurulum kokunu kendi konumundan turet: bu dosya her zaman <kok>/agent/ altindadir.
ROOT = pathlib.Path(__file__).resolve().parent.parent
MAX_AUDIO_BYTES = 1024 * 1024 * 1024
MODEL_DIRNAME = 'qwen3-asr'
# Istenen dil adlari (kucuk harf -> Qwen3-ASR dil adi). 'auto' -> otomatik algilama.
LANGUAGE_NAMES = {
    'tr': 'Turkish', 'en': 'English', 'de': 'German', 'fr': 'French', 'es': 'Spanish',
    'it': 'Italian', 'pt': 'Portuguese', 'ru': 'Russian', 'ar': 'Arabic', 'ja': 'Japanese',
    'ko': 'Korean', 'zh': 'Chinese', 'hi': 'Hindi', 'nl': 'Dutch', 'sv': 'Swedish',
    'da': 'Danish', 'fi': 'Finnish', 'pl': 'Polish', 'cs': 'Czech', 'el': 'Greek',
    'hu': 'Hungarian', 'ro': 'Romanian', 'th': 'Thai', 'vi': 'Vietnamese', 'id': 'Indonesian',
    'ms': 'Malay', 'fa': 'Persian', 'fil': 'Filipino', 'mk': 'Macedonian',
}

_MODEL_CACHE: dict = {}


def _model_path(explicit: str | None) -> str:
    if explicit and os.path.isdir(explicit):
        return explicit
    if explicit and os.path.isfile(explicit):
        return os.path.dirname(explicit)
    base = ROOT / 'models' / MODEL_DIRNAME
    if (base / 'config.json').is_file():
        return str(base)
    raise RuntimeError('Qwen3-ASR modeli bulunamadi (models\\%s). Once model indir.' % MODEL_DIRNAME)


def _decode_float32_16k(src: str):
    """Herhangi bir ses/video dosyasini 16 kHz mono float32 numpy dizisine cevirir.

    PyAV (av) kullanilir; soundfile/librosa gerekmez. 16 kHz mono s16'ya yeniden orneklenip
    [-1, 1] araligina olceklenir.
    """
    import av
    import numpy as np
    from av.audio.resampler import AudioResampler

    chunks = []
    with av.open(src) as container:
        if not container.streams.audio:
            raise ValueError('Ses akisi bulunamadi.')
        stream = container.streams.audio[0]
        resampler = AudioResampler(format='s16', layout='mono', rate=16000)
        for frame in container.decode(stream):
            for resampled in resampler.resample(frame):
                chunks.append(resampled.to_ndarray())
        for resampled in resampler.resample(None):
            chunks.append(resampled.to_ndarray())
    if not chunks:
        raise ValueError('Ses cozulemedi (bos akis).')
    arr = np.concatenate([c.reshape(-1) for c in chunks]).astype('float32') / 32768.0
    return arr


def _load_model(model_dir: str, device: str):
    key = (model_dir, device)
    if key in _MODEL_CACHE:
        return _MODEL_CACHE[key]
    import torch
    from transformers import AutoProcessor

    try:
        from transformers import AutoModelForMultimodalLM as _ModelCls
    except Exception:  # daha eski transformers
        from transformers import Qwen3ASRForConditionalGeneration as _ModelCls

    processor = AutoProcessor.from_pretrained(model_dir)
    if device == 'cpu':
        model = _ModelCls.from_pretrained(model_dir)
    else:
        # bf16 (sikistirilmamis). int8 olculdu: ayni metin ama uzun seste ~2x yavas ->
        # kullanilmiyor. device_map/accelerate gerektirmez; dogrudan GPU'ya tasi.
        model = _ModelCls.from_pretrained(model_dir, dtype=torch.bfloat16)
        model = model.to(device)
    model.eval()
    _MODEL_CACHE[key] = (processor, model)
    return processor, model


def _extract_text(processor, raw: str) -> tuple[str, str]:
    """Qwen3-ASR cikisi 'language <LANG><asr_text>metin' bicimindedir. (metin, dil) doner."""
    text, lang = raw, ''
    try:
        parsed = processor.extract_transcription(raw)
        if isinstance(parsed, list):
            parsed = parsed[0] if parsed else raw
        if isinstance(parsed, str) and parsed.strip():
            text = parsed
    except Exception:
        try:
            parsed = processor.parse_asr_output(raw)
            if isinstance(parsed, list) and parsed:
                parsed = parsed[0]
            if isinstance(parsed, dict):
                text = parsed.get('transcription') or parsed.get('text') or text
                lang = parsed.get('language') or ''
        except Exception:
            pass
    if not lang and 'language ' in raw:
        try:
            head = raw.split('<asr_text>')[0]
            lang = head.replace('language', '').strip()
        except Exception:
            pass
    return text.strip(), lang.strip()


def transcribe(req: dict) -> dict:
    path = str(req.get('path') or '')
    if not path or not os.path.isfile(path):
        raise ValueError('Ses dosyasi bulunamadi.')
    if os.path.getsize(path) > MAX_AUDIO_BYTES:
        raise ValueError('Ses dosyasi boyut guvenlik sinirini asti.')
    model_dir = _model_path(req.get('model'))
    device = str(req.get('device') or '').lower()
    if device not in ('cpu', 'cuda', 'gpu'):
        try:
            import torch
            device = 'cuda' if torch.cuda.is_available() else 'cpu'
        except Exception:
            device = 'cpu'
    if device == 'gpu':
        device = 'cuda'
    if device == 'cuda':
        device = 'cuda:0'

    language = str(req.get('language') or 'auto').strip().lower()
    lang_name = None if language in ('', 'auto') else LANGUAGE_NAMES.get(language, language.title())
    timeout_tokens = int(req.get('max_new_tokens') or 0)

    samples = _decode_float32_16k(path)
    processor, model = _load_model(model_dir, device)
    import torch
    req_kwargs = {'audio': samples}
    if lang_name:
        req_kwargs['language'] = lang_name
    inputs = processor.apply_transcription_request(**req_kwargs)
    inputs = inputs.to(model.device, model.dtype if model.dtype.is_floating_point else None)
    max_new = timeout_tokens or 1024
    with torch.no_grad():
        output_ids = model.generate(**inputs, max_new_tokens=max_new)
    generated = output_ids[:, inputs['input_ids'].shape[1]:]
    raw = processor.batch_decode(generated, skip_special_tokens=True)
    raw = raw[0] if isinstance(raw, list) and raw else str(raw)
    text, detected = _extract_text(processor, raw)
    return {
        'text': text,
        'model': 'Qwen3-ASR-1.7B',
        'language': detected or (lang_name or 'auto'),
        'device': device,
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
