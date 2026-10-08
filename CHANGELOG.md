# Sürüm geçmişi

Biçim [Keep a Changelog](https://keepachangelog.com/tr-TR/1.1.0/) önerisini, sürüm numaraları
[Anlamsal Sürümleme](https://semver.org/lang/tr/) kurallarını izler.

## [1.0.1] - 2026-10-07

### Eklenen
- Çevrimdışı çalışma testleri: internet çipi açıkken ağ koparsa web araması, sayfa okuma ve
  referans görsel araçları istisna atmaz; modele geçerli bir hata JSON'u döndürür (bkz.
  `tests/test_offline_mode.py`).
- Smoke testine **`cevrimdisi`** adımı eklendi: kurulum sonrası doğrulamada ağ erişimi geçici
  olarak kesilip web aracının çökmeden hata JSON'u döndürdüğü kanıtlanır.
- Smoke testine **`ag_gecisi`** adımı eklendi: ardışık turlarda ağ açık/kapalı değişirken
  (internet gidip gelirken) yerel işçinin hiçbir turda hata üretmediği doğrulanır.
- Smoke testine **`gecmis_devam`** adımı eklendi: konuşma ortasında program kapatılıp yeniden
  açıldığında sohbetin kaydedilip yüklenebildiği ve devam ettirilebildiği doğrulanır.
  Adım, arac çağrısı olmayan turlarda `$done.data`'nın thread sınırından `$null` dönmesine karşı
  `if ($done.data)` ile korunur (aksi halde mesaj listesine boş bir girdi eklenip sunucudan
  `400 All non-assistant messages must contain 'content'` alınıyordu).
- **MTP (Multi-Token Prediction) speculative decoding** MAX/FLASH için etkinleştirildi
  (`--spec-type draft-mtp`). Qwen3.8 27B GGUF'u gömülü bir MTP/nextn draft başlığı taşıdığı için
  ayrı draft model gerekmez; çıktı kayıpsızdır ve ~1,2–1,5x hız beklenir. LITE (Qwen3.5 9B)
  modelinde MTP katmanı yoktur, orada kullanılmaz. `settings/api.json` → `"mtp": false` ile kapatılır.

### Düzeltmeler
- Yerel model akışında aralıklı görülen **"Varolan bir bağlantı uzaktaki bir ana bilgisayar
  tarafından zorla kapatıldı."** (WSAECONNRESET) hatası giderildi. Sunucu, ajan aracı çalışırken
  (web araması, OCR, belge okuma) boş bekleyen keep-alive bağlantısını kapatabiliyordu; istemci
  aynı bayat bağlantıyı yeniden kullanınca akış ortasında kopuyordu. Artık yerel istekler her
  turda taze bağlantı kurar (`Connection: close`; loopback'te maliyeti yoktur, sunucudaki KV
  önbelleği ve ön işleme tasarrufu korunur). Ayrıca **kullanılabilir bir sonuç** varsa
  (finish_reason alınmış, yanıt metni gelmiş ya da bir araç çağrısı oluşmuş) kapanma hata
  sayılmaz; tamamlanan cevabın altına yanlışlıkla "[Hata]" satırı eklenmez.
  (`agent/qwen-inference.ps1`)
- **Web aracı başarısız olunca modelin "etrafından dolaşması" engellendi.** Ağ yokken web
  araması/sayfa indirme başarısız olduğunda model bazen `run_command` (ping/curl/wget) gibi
  araçlarla sonucu başka yoldan almaya ya da uydurmaya çalışıyordu. Artık böyle bir başarısızlık
  algılanıp isteğin kopyasına (kalıcı geçmişe yazılmadan) bir sistem notu eklenir: etrafından
  dolaşmayı denemesini engeller, elinde bilgi varsa net yanıt vermesini, yoksa güncel veriyi
  uydurmayıp web erişiminin kurulamadığını söylemesini ister. Sistem istemine de önleyici kural
  eklendi. İki sert savunma: web hatasından sonra (1) web araçları modele artık sunulmaz, (2)
  `run_command` ağ-probe komutlarını (ping/curl/wget/nslookup/ipconfig…) **çalıştırmadan reddeder**
  (küçük model notu atlayabildiği için).
- **`run_command` artık yalnızca kullanıcı açıkça komut/terminal istediğinde modele sunulur**
  (`Test-CommandIntent`). Böylece model, web hatası gibi durumlarda komutla "etrafından dolanmaya"
  hiç kalkışamaz; genel sorularda komut aracı sunulmadığı için çağrılamaz. Açık niyet kalıpları:
  komut, terminal, konsol, cmd, powershell, bash, script/betik, .bat/.cmd/.ps1/.exe, çalıştır, run,
  execute, ipconfig, ping, curl, wget, nslookup, netstat.
  (`agent/qwen-inference.ps1`, `qwen-desktop.ps1`)

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
