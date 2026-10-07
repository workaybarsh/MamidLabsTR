# Sürüm geçmişi

Biçim [Keep a Changelog](https://keepachangelog.com/tr-TR/1.1.0/) önerisini, sürüm numaraları
[Anlamsal Sürümleme](https://semver.org/lang/tr/) kurallarını izler.

## [1.0.1] - 2026-10-07

### Düzeltmeler
- Yerel model akışında aralıklı görülen **"Varolan bir bağlantı uzaktaki bir ana bilgisayar
  tarafından zorla kapatıldı."** (WSAECONNRESET) hatası giderildi. Sunucu, ajan aracı çalışırken
  (web araması, OCR, belge okuma) boş bekleyen keep-alive bağlantısını kapatabiliyordu; istemci
  aynı bayat bağlantıyı yeniden kullanınca akış ortasında kopuyordu. Artık yerel istekler her
  turda taze bağlantı kurar (`Connection: close`; loopback'te maliyeti yoktur, sunucudaki KV
  önbelleği ve ön işleme tasarrufu korunur). Ayrıca yanıt metni zaten alınmışsa kapanma hata
  sayılmaz; tamamlanan cevabın altına yanlışlıkla "[Hata]" satırı eklenmez.
  (`agent/qwen-inference.ps1`)

## [1.0.0] - 2026-09-27

İlk kararlı sürüm.

### Uygulama
- Tek pencerede sohbet, web araması, belge okuma ve üretimi, OCR, görsel anlama, görsel
  üretimi, fotoğraf düzenleme ve video üretimi.
- Üç donanım profili: **MAX** ve **FLASH** (Qwen3.8 27B, 16 GB VRAM) ile **LITE** (Qwen3.5 9B,
  8 GB VRAM). Profiller menüsünden kurulum durumu, eksik dosya indirme ve profil geçişi.
- Görsel üretimi Krea-2 Turbo ile; yeniden üretim, stil referansı ve istek üzerine gerçekçilik
  LoRA'sı. Fotoğraf düzenleme Krea 2 Identity Edit ile (yalnızca 16 GB profillerde).
- Video üretimi Wan 2.2 TI2V 5B ile: metinden, görselden ve videodan devam.
- İsteğe bağlı API sağlayıcıları: OpenAI, Claude, Gemini, DeepSeek ve OpenAI uyumlu özel uç.
- Kendi dil, görsel ve video modelini dosya yoluyla kullanma; dosyalar kopyalanmaz.
- Ajan modu: bağlı klasörde dosya okuma/yazma ve komut çalıştırma, kullanıcı onayıyla.
- Uygulama içinden güncelleme denetimi (Profiller → Güncellemeleri denetle); güncelleme
  kurulum sihirbazını açar ve uygulamayı kapatır.

### Kurulum
- Tek tıkla kurulum sihirbazı (`MamidLabs_Setup.exe`): donanım ölçümüyle profil önerisi, model
  indirmeyi sonraya bırakma, kendi model/API hesabı seçeneği, canlı ilerleme, iptal ve geri
  alma, kurulum sonunda isteğe bağlı smoke testi ve özet.
- Varsayılan kurulum klasörü `%LOCALAPPDATA%\Programs\MamidLabs`; yönetici yetkisi gerekmez.
- Bileşenler sabit sürümlerle kurulur: PowerShell 7.6.6, llama.cpp b10998 (CUDA 13.4), ComfyUI
  `b0f4b7b`; uygulama ve medya ortamlarının Python paketleri kilitlidir. Model dosyaları commit
  ve bayt boyutuyla doğrulanır.
- Eksik ön koşullar (Python, Git, 7-Zip, VC++ Redistributable) winget ile kurulur.
- Tam kaldırma: modeller, önbellekler, sohbetler ve MamidLabs'in kurduğu ön koşullar dahil.

### Güvenlik
- Dosya yazma, komut çalıştırma ve belge oluşturma varsayılan olarak onay ister; onay 10
  dakikada verilmezse işlem reddedilir.
- Araç çağrıları `logs\audit.jsonl` denetim günlüğüne yazılır; sohbetler ve API anahtarları
  Windows DPAPI ile şifrelenir.
- Web araçları yalnızca genel HTTP(S) adreslerine erişir; DNS rebinding koruması vardır.

[1.0.1]: https://github.com/workaybarsh/MamidLabsTR/releases/tag/v1.0.1
[1.0.0]: https://github.com/workaybarsh/MamidLabsTR/releases/tag/v1.0.0
