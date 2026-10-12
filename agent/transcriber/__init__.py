"""MamidLabs yerel konusma + ses olayi dökum hatti.

Moduller:
    config   tier = secili profil (lite/pro); VRAM yalnizca yedek (select_profile_for/select_profile)
    audio    16 kHz mono WAV'a cevirme + parcalama
    vad      Silero VAD konusma araliklari
    asr      faster-whisper (Whisper large-v3-tr), halusinasyon filtreleri
    events   AudioSet/AST ses olayi etiketleri (Turkce)
    diarize  pyannote konusmaci ayrimi (opsiyonel)
    merge    zaman damgasina gore birlestirme -> metin
    main     hatti calistirir; txt + json yazar
"""
__version__ = '1.0.0'
