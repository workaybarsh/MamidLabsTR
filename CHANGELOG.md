# Sürüm geçmişi

Biçim [Keep a Changelog](https://keepachangelog.com/tr-TR/1.1.0/) önerisini, sürüm numaraları
[Anlamsal Sürümleme](https://semver.org/lang/tr/) kurallarını izler.

## [1.0.8] - 2026-10-09

### Düzeltilen
- **Uygulama bazen hiç açılmıyordu ("pencere açılmadan kapandı"):** Tek-örnek denetimi
  yalnızca pencere başlığına (`MamidLabs`) bakıyordu. Aynı başlığı taşıyan başka bir pencere
  (ör. Windows Gezgini'nin `TabProxyWindow`'u ya da bir video/medya penceresi) varken uygulama
  kendini "zaten açık" sanıp açılmadan çıkıyordu. Denetim artık pencere **sınıfını** da doğrular
  (yalnızca `WindowsForms10.*` gerçek uygulama penceresi sayılır).
- **"Model işlemi başarısız" hatası ve taşma (yapısal kök neden):** Uygulamanın açtığı tek
  büyük CUDA bağlamı boşta bekleyen ComfyUI'ydi. Bağlam açıkken sürücü VRAM'i parçalı
  tutuyor; boş VRAM yeterli görünse bile 27B model paylaşılan belleğe taşıp üretim ~6
  tok/s'ye düşüyordu (ölçüldü: 15.290 MiB "boş" + başka bağlam → 6 tok/s; aynı model temiz
  GPU'da 45+ tok/s). Artık dil modeli yüklenmeden önce ComfyUI **her zaman** kapatılır
  (kuyruğu boşsa); boş VRAM ölçümü yalnızca o zaman güvenilirdir. Ayrıca MAX/FLASH bellek
  payı 800→600 MiB'a çekildi: 1.0.4–1.0.7'deki 800/1000 MiB eşikleri, temiz GPU'da 15244
  MiB boşken çalışan (45 tok/s) modeli yanlış reddedip jenerik "Model işlemi başarısız"
  hatası veriyordu. Bir sonraki görsel/video ComfyUI'yi yeniden açar.
- LITE ve MAX/FLASH profilleri aynı makinede birlikte sorunsuz çalışır (ölçüldü: LITE
  ~97 tok/s, MAX ~58 tok/s, ikisinde de MTP etkin).

### Eklenen
- **Profil silme:** Profil yöneticisinde "Profili sil" düğmesi. Yalnızca o profile ÖZEL
  dosyalar silinir; başka profillerle paylaşılanlar korunur (LITE'ın MAX/FLASH ile ortak
  medya dosyaları). Etkin profil siliniyorsa önce model durdurulur. MAX ve FLASH aynı dosya
  kümesini kullandığından takma ad sayılır; birini silmek diğerini de kaldırır.
- **Kurulum sihirbazında 27B profili artık "PRO" olarak görünür** (kullanıcıya görünen ad).

## [1.0.7] - 2026-10-09

### Düzeltilen
- **VRAM eşiği makineyi yanlış reddedebiliyordu (1.0.6 gerilemesi):** 1.0.6'da MAX/FLASH payı
  1000 MiB'a çıkarılınca eşik 15600 MiB oldu; bu makinenin normal boş değeri (15442–15558 MiB)
  bile bu eşiğin altında kalıp "Yetersiz bos VRAM" hatası veriyordu (sohbet ve arayüz smoke
  adımları düştü). Ölçüm: model GPU'da ~15422–15442 MiB ister, ComfyUI açıkken boş ~15020 MiB'ye
  düşer. Pay **800 MiB**'a çekildi (eşik 15400): ComfyUI açıkken kapatılır, ComfyUI kapalı/açılışta
  model yüklenir. Aynı düzeltme ENG sürümüne de uygulandı.

## [1.0.6] - 2026-10-09

### Eklenen
- **Arayüz smoke adımı (`arayuz`):** smoke testi artık gerçek masaüstü uygulamasını
  (`qwen-desktop.ps1`) başlatıp pencerenin ve dil modelinin hazır olduğunu doğrular; ardından
  arayüzün kullandığı gerçek işçiyle (`agent/qwen-inference.ps1`) bir tur atıp **"sunucu
  kapatıldı"/watchdog metni olmadığını** ve **MTP'nin gerçekten çalıştığını** (`--spec-type
  draft-mtp` + draft kabulü) kanıtlar. Uygulama kapanışta ayarları ezdiği için ayarlar
  yedeklenip geri yüklenir (`-SkipUi` ile atlanır).

### Düzeltilen
- **Medya sonrası sohbetin ~6 tok/s'ye düşmesi (kök neden):** VRAM bütçe tahmini gerçek
  yükü eksik hesaplıyordu (model + 300 MiB). Oysa 27B model 16 GB kartta (32K bağlam, q4_0 KV,
  MTP draft bağlamı) GPU'da ~**15.378 MiB** yer kaplar; dosya ile arasındaki ~778 MiB
  hesaplanmıyordu. Bu yüzden bütçe "sığar" diyor, ama boşta bekleyen ComfyUI (~300–460 MiB)
  varken model tam sığmayıp bir bileşeni (MTP draft bağlamı, ~185 MiB) sessizce CPU'ya
  taşınıyor ve üretim 44 tok/s'den ~6–7 tok/s'ye düşüyordu (ölçüldü: llamaVRAM 15378 → 15193).
  Pay gerçeğe çekildi (**1000 MiB**) ve MAX/FLASH toleransı **0** yapıldı; böylece boş VRAM
  yetmezse önce boştaki ComfyUI kapatılıp yer açılır ve model her seferinde tam sığar.
- **`Release-Comfy` sağlamlaştırması:** ComfyUI `/free` ile kendi PyTorch önbelleğini boşaltsa
  bile CUDA bağlamı ve sürücü tarafı rezervasyon bir süre VRAM tutabiliyordu; artık gerçek boş
  VRAM (`nvidia-smi`) de doğrulanır ve yetmezse ComfyUI kapatılır (görsel/video işçileri
  MAX/FLASH 14000 MiB, LITE 6000 MiB eşiği geçirir).

## [1.0.5] - 2026-10-09

### Düzeltilen
- **Medya sonrası sohbet kat kat yavaşlaması:** 16 GB kartta (MAX/FLASH) VRAM payı
  toleransı ~1 GB idi; bu, 27B modelin katmanlarının Windows'un paylaşılan belleğine
  taşmasına ve sohbetin ~5–6 tok/s'ye düşmesine yol açabiliyordu (ör. bir görsel/düzenleme
  işinden sonra dil modeli geri yüklenirken). Tolerans artık profile göre: LITE'ta 1024 MiB
  (MTP ile büyüyen 9B modelin 8 GB karttaki küçük aşımı, llama.cpp büyük gömme tensorünü
  CPU'da tutarak sorunsuz kaldırıyor), MAX/FLASH'ta 256 MiB. Böylece VRAM dara girdiğinde
  boşta bekleyen ComfyUI kapatılır ve model paylaşılan belleğe taşmadan tam sığar.
- **Eksik güncelleme paketi:** betik tabanlı güncelleme (`install-mamidlabs.ps1 -Stage layout`)
  sihirbazın kaynak paketini (`kurulum-kaynak`) tazelemiyordu; Inno ile kurulmuş bir kökte bu
  klasör önceki sürümden kalıyordu. Artık varsa aynı dosya kümesiyle tazelenir (yoksa
  oluşturulmaz).

## [1.0.4] - 2026-10-08

### Eklenen
- **Yerel web yönetimi:** uygulama arayüzü tarayıcıdan yönetilebilir (sohbet, model
  değiştirme, üretilen dosyalar). Varsayılan olarak yalnızca bu bilgisayardan (127.0.0.1)
  erişilir; şifre korumalıdır (Windows hesabına bağlı DPAPI) ve tek kullanımlık, 5 dakikada
  süresi dolan bir bağlantı linki üretir. Yerel ağa açmak açık bir ayar ister; oturum 30 gün
  sürer ve şifre değişince iptal olur. Dosya erişimi yalnızca `outputs\` ile sınırlıdır.
- Üretilen dosyalar (görsel/video/belge) sohbet balonundan **tek tıkla açılabilir** ("Aç").

### Düzeltilen
- **Model yüklenememe hatası ("Model işlemi başarısız"):** MTP başlığı eklenince LITE modeli
  ~464 MiB büyüyordu ve VRAM kontrolü 8 GB kartta modeli hiç açmıyordu. Kontrol artık küçük
  aşımı tolere eder (llama.cpp büyük gömme tensorünü CPU'da tutar); yalnızca belirgin aşımda durur.
- **Özel (private) depo güncelleme denetimi:** "Güncellemeleri denetle" 404 veriyordu; artık bir
  GitHub tokenı (GITHUB_TOKEN/GH_TOKEN ya da Profiller penceresindeki "Güncelleme tokenı") kullanır.

## [1.0.3] - 2026-10-08

### Eklenen
- **LITE için MTP (Multi-Token Prediction) speculative decoding.** Huihui-Qwen3.5 9B GGUF'una
  dönüşümde düşen MTP/nextn başlığı indirme sırasında otomatik eklenir (`agent/mtp_inject.py`);
  ayrı draft model gerekmez ve çıktı kayıpsızdır. Ölçülen kabul ~0,93, ~2x hız (36 → ~75 tok/s).
  `settings/api.json` → `"mtp": false` ile kapatılır.

### Değişen
- Lisans MIT'den tescilli (tüm hakları saklı) lisansa geçirildi; telif hakkı Aybars Haydar
  Altuntaş'a aittir.

## [1.0.2] - 2026-10-08

### Eklenen
- **MTP (Multi-Token Prediction) speculative decoding** MAX/FLASH için etkinleştirildi
  (`--spec-type draft-mtp`). Qwen3.8 27B GGUF'u gömülü bir MTP/nextn draft başlığı taşıdığı için
  ayrı draft model gerekmez; çıktı **kayıpsızdır** (kabul edilen tokenlar hedef modelle doğrulanır)
  ve ~1,2–1,5x hız beklenir. LITE (Qwen3.5 9B) modelinde MTP katmanı yoktur, orada kullanılmaz.
  `settings/api.json` → `"mtp": false` ile kapatılır.

### Notlar
- MTP'nin çıktıyı değiştirmediği doğrulandı: greedy (temperature 0) + sabit tohumla MTP'li ve
  MTP'siz çıktı birebir aynı.

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

[1.0.4]: https://github.com/workaybarsh/MamidLabsTR/releases/tag/v1.0.4
[1.0.3]: https://github.com/workaybarsh/MamidLabsTR/releases/tag/v1.0.3
[1.0.2]: https://github.com/workaybarsh/MamidLabsTR/releases/tag/v1.0.2
[1.0.1]: https://github.com/workaybarsh/MamidLabsTR/releases/tag/v1.0.1
[1.0.0]: https://github.com/workaybarsh/MamidLabsTR/releases/tag/v1.0.0
