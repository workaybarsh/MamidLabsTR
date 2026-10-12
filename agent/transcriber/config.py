"""Calisma profili: GPU toplam VRAM'ine bakip PC1 (8 GB) / PC2 (16 GB) secer.

Tek kod tabani, iki donanim profili. Tek fark: Whisper'in compute_type'i ve modellerin
ayni anda mi (paralel) yoksa sirayla mi yuklendigi.

- PC2 (>= 14 GB): float16, modeller ayni anda bellekte.
- PC1 (< 14 GB): int8_float16, modeller sirayla; uzun kayitlar parcalanir.
"""
from __future__ import annotations

import os
import subprocess
from dataclasses import dataclass, replace

PC1 = 'pc1'
PC2 = 'pc2'
VRAM_THRESHOLD_MIB = 14000

# --- Otomatik cihaz secimi (CPU / GPU) ---------------------------------------
# GPU'da dökum yapilirken yerel dil modeli VRAM'den bosaltilir ve sonra geri yuklenir
# (swap). Bu swap'in sabit bir maliyeti vardir; CPU'da dökum ise GPU'dan yavastir ama
# swap maliyeti YOKTUR. Kisa kayitlarda swap maliyeti dökum kazancindan buyuk olur:
#
#     GPU_döküm + swap_maliyeti > CPU_döküm  ise  CPU secilir.
#
# Esik SURESI asagidaki sabittir; AR-GE olcum sonucu gelince yalnizca bu satir guncellenir
# (ya da profil bazinda `Profile.cpu_max_seconds` ile gecersiz kilinir).
DEFAULT_CPU_MAX_SECONDS = 240.0  # 4 dakika

# Tek motor: Whisper large-v3'un Turkce ince ayarli CTranslate2 (float16) surumu.
DEFAULT_WHISPER_MODEL = 'oguzhangokboru/whisper-large-v3-tr'
# AudioSet tabanli ses olayi modeli (AST). 'none' ile kapatilir.
DEFAULT_EVENTS_MODEL = 'MIT/ast-finetuned-audioset-10-10-0.4593'

# --- Ses hatti bellek gereksinimleri (MiB) -----------------------------------
# Cihaz/swap karari PROFIL ADINA gore DEGIL, ses isi baslarken olculen GERCEK bos
# VRAM ve sistem RAM'ine gore verilir (bkz. choose_plan). LITE profili hem 8 GB
# (hedef makine) hem 16 GB kartta kullanildigi icin profil adi tek basina yeterli
# degildir.
#
# `audio_vram_mib`: Whisper large-v3 + AST + torch/CUDA baglami icin gereken en kotu
# senaryo payi. Olculen: int8_float16 large-v3 ~1,5-2,5 GB, AST (fp32) ~0,4 GB,
# torch/CUDA baglami ~0,3-0,5 GB; PC2 float16'da Whisper ~2,9 GB'a cikar.
DEFAULT_AUDIO_VRAM_MIB = 4096
# `audio_ram_mib`: CPU yolunda (swap yok) ses hattinin sistem RAM'inde tuttugu en
# kotu senaryo payi: Whisper int8 (~2 GB) + AST (fp32 ~0,4 GB) + torch/Python
# (~0,8 GB) + parca/cozumleme tamponlari (30 dk float32 ~0,15 GB; parcali dökum).
DEFAULT_AUDIO_RAM_MIB = 5120


@dataclass(frozen=True)
class Profile:
    name: str
    compute_type: str      # faster-whisper compute_type ('float16' | 'int8_float16')
    load_mode: str         # 'parallel' | 'sequential'
    chunk_minutes: int     # uzun kayitlari bolme; 0 = bolme
    whisper_model: str
    events_model: str      # 'ast' | 'none'
    language: str
    events: bool
    diarize: bool
    auto_device: bool = True          # cihaz secimini kaydin suresine gore otomatik yap
    cpu_max_seconds: float | None = None  # bu sureden kisa kayitlarda CPU (None -> DEFAULT_CPU_MAX_SECONDS)
    audio_vram_mib: int = DEFAULT_AUDIO_VRAM_MIB  # ses hatti dil modeliyle birlikte bu kadar bos VRAM istar
    audio_ram_mib: int = DEFAULT_AUDIO_RAM_MIB    # CPU yolunda ses hatti bu kadar sistem RAM'i ister


PROFILES = {
    PC2: Profile(
        name=PC2, compute_type='float16', load_mode='parallel', chunk_minutes=0,
        whisper_model=DEFAULT_WHISPER_MODEL, events_model=DEFAULT_EVENTS_MODEL,
        language='tr', events=True, diarize=True,
    ),
    PC1: Profile(
        name=PC1, compute_type='int8_float16', load_mode='sequential', chunk_minutes=30,
        whisper_model=DEFAULT_WHISPER_MODEL, events_model=DEFAULT_EVENTS_MODEL,
        language='tr', events=True, diarize=True,
    ),
}


def total_vram_mib() -> int:
    """nvidia-smi ile en buyuk kartin toplam VRAM'i (MiB). Yoksa 0 (-> PC1 profili)."""
    try:
        out = subprocess.run(
            ['nvidia-smi', '--query-gpu=memory.total', '--format=csv,noheader,nounits'],
            capture_output=True, text=True, timeout=15,
        ).stdout
    except Exception:
        return 0
    values = [int(x) for x in out.replace(',', ' ').split() if x.strip().isdigit()]
    return max(values) if values else 0


def free_vram_mib() -> int:
    """nvidia-smi ile en buyuk kartin BOS VRAM'i (MiB). Yoksa 0."""
    try:
        out = subprocess.run(
            ['nvidia-smi', '--query-gpu=memory.free', '--format=csv,noheader,nounits'],
            capture_output=True, text=True, timeout=15,
        ).stdout
    except Exception:
        return 0
    values = [int(x) for x in out.replace(',', ' ').split() if x.strip().isdigit()]
    return max(values) if values else 0


def available_ram_mib() -> int:
    """Kullanilabilir (bos) sistem RAM'i MiB. Okunamazsa 0."""
    if os.name == 'nt':
        try:
            import ctypes

            class _MemoryStatusEx(ctypes.Structure):
                _fields_ = [
                    ('dwLength', ctypes.c_ulong),
                    ('dwMemoryLoad', ctypes.c_ulong),
                    ('ullTotalPhys', ctypes.c_ulonglong),
                    ('ullAvailPhys', ctypes.c_ulonglong),
                    ('ullTotalPageFile', ctypes.c_ulonglong),
                    ('ullAvailPageFile', ctypes.c_ulonglong),
                    ('ullTotalVirtual', ctypes.c_ulonglong),
                    ('ullAvailVirtual', ctypes.c_ulonglong),
                    ('ullAvailExtendedVirtual', ctypes.c_ulonglong),
                ]

            status = _MemoryStatusEx()
            status.dwLength = ctypes.sizeof(_MemoryStatusEx)
            if ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(status)):
                return int(status.ullAvailPhys // (1024 * 1024))
        except Exception:
            return 0
        return 0
    try:
        with open('/proc/meminfo', encoding='utf-8') as fh:
            for line in fh:
                if line.startswith('MemAvailable:'):
                    return int(line.split()[1]) // 1024
    except Exception:
        pass
    return 0


def select_profile(total_mib: int | None = None, **overrides) -> Profile:
    """VRAM'e gore profil secer; overrides ile tek tek alanlar degistirilebilir."""
    total = total_vram_mib() if total_mib is None else int(total_mib)
    profile = PROFILES[PC2] if total >= VRAM_THRESHOLD_MIB else PROFILES[PC1]
    clean = {k: v for k, v in overrides.items() if v is not None and hasattr(profile, k)}
    return replace(profile, **clean) if clean else profile


def choose_device(duration_seconds: float | None, profile: Profile, need_swap: bool,
                  cpu_max_seconds: float | None = None) -> str:
    """Kaydin suresine gore 'cuda' ya da 'cpu' secer.

    Kural (bkz. DEFAULT_CPU_MAX_SECONDS):
      - need_swap=False: VRAM swap maliyeti yok (orn. API saglayici ya da LITE; dil modeli
        ses hattiyla birlikte sigar) -> her zaman 'cuda'.
      - need_swap=True: GPU dökumunde dil modeli bosaltilip geri yuklenir (swap). Kayit
        `esik` saniyeden KISAYSA swap maliyeti dökum kazancindan buyuk oldugu icin 'cpu';
        aksi halde 'cuda'.

    Esik: verilirse `cpu_max_seconds`, yoksa `profile.cpu_max_seconds`, o da yoksa
    `DEFAULT_CPU_MAX_SECONDS`. Sure okunamazsa (None) guvenli varsayilan 'cuda'dir.

    NOT: Uygulama yolu (arayuz/isci) artik bu fonksiyonu kullanmaz; cihaz ve swap karari
    `choose_plan` ile GERCEK bos VRAM/sistem RAM'ine gore verilir (profil adi yerine).
    Bu fonksiyon yalnizca CLI'in `--device auto` akisi icin korunmustur.
    """
    if not need_swap:
        return 'cuda'
    threshold = cpu_max_seconds
    if threshold is None:
        threshold = profile.cpu_max_seconds
    if threshold is None:
        threshold = DEFAULT_CPU_MAX_SECONDS
    if duration_seconds is not None and duration_seconds <= threshold:
        return 'cpu'
    return 'cuda'


def choose_plan(profile: Profile, duration_seconds: float | None = None,
                vram_free_mib: int | None = None, ram_free_mib: int | None = None,
                local_model_loaded: bool = True,
                cpu_max_seconds: float | None = None) -> tuple[str, bool]:
    """Ses hatti icin (device, need_swap) planini ONCELIK sirasiyla doner.

    Karar PROFIL ADINA DEGIL; gercek bos VRAM + sistem RAM'i ve kaydin SURESINE gore verilir
    (LITE hem 8 GB hem 16 GB kartta calisir; ayrica "kisa -> CPU, uzun -> GPU" ekonomisi):

      1) Whisper + AST, yerel dil modeliyle BIRLIKTE bos VRAM'e sigarsa (`audio_vram_mib`)
         -> ('cuda', False): GPU'da dökum, swap YOK (en hizli, maliyetsiz).
      2) Sigmazsa ve kayit `esik` saniyeden KISAYSA (swap maliyeti dökum kazancindan buyuk):
         ses hatti CPU'da sistem RAM'ine sigiyorsa (`audio_ram_mib`)
         -> ('cpu', False): swap YOK; yavastir ama dil modeli VRAM'de kalir.
      3) Aksi halde (kayit UZUN; CPU RAM'e sigmiyor; ya da sure bilinmiyor ve RAM yetmiyor)
         -> ('cuda', True): GPU dökumu. Dil modeli gerekiyorsa MECBURI boşaltilir/geri yuklenir
         (uzun kayitta GPU kazanci swap maliyetini asar; RAM yetmezse zaten kaçınılmaz).

    Yerel dil modeli yuklu degilse (API saglayicisi) GPU zaten bostur -> ('cuda', False).
    `vram_free_mib`/`ram_free_mib` verilmezse makineden okunur (olculemezse 0 -> guvenli
    taraf: sigmiyor sayilir).
    """
    if not local_model_loaded:
        return 'cuda', False
    if vram_free_mib is None:
        vram_free_mib = free_vram_mib()
    if ram_free_mib is None:
        ram_free_mib = available_ram_mib()
    if vram_free_mib >= profile.audio_vram_mib:
        return 'cuda', False
    ram_ok = ram_free_mib >= profile.audio_ram_mib
    # Sure bilinmiyorsa yalnizca bellek kuralina gore karar ver (swap'i zorlamadan).
    if duration_seconds is None:
        return ('cpu', False) if ram_ok else ('cuda', True)
    threshold = cpu_max_seconds
    if threshold is None:
        threshold = profile.cpu_max_seconds
    if threshold is None:
        threshold = DEFAULT_CPU_MAX_SECONDS
    short = duration_seconds <= threshold
    if short and ram_ok:
        return 'cpu', False
    return 'cuda', True
