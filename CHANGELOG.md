# Sürüm geçmişi

Biçim [Keep a Changelog](https://keepachangelog.com/tr-TR/1.1.0/) önerisini, sürüm numaraları
[Anlamsal Sürümleme](https://semver.org/lang/tr/) kurallarını izler.

## [1.0.0] - 2026-10-10

İlk sürüm. Windows'ta tamamen yerel çalışan çok modlu yapay zekâ çalışma alanı: tek bir WinForms
penceresinde sohbet, web araması, belge okuma/üretimi, OCR, görsel anlama, görsel üretimi, fotoğraf
düzenleme, video üretimi ve grafik çizimi. Dil modeli `llama.cpp` (`llama-server`), görsel/video
modelleri `ComfyUI` üzerinde, kullanıcının NVIDIA ekran kartında çalışır. OpenAI, Claude, Gemini,
DeepSeek ve OpenAI uyumlu özel uçlar isteğe bağlı API sağlayıcılarıdır.

### Eklenen
- **Sohbet (yerel + API):** `llama-server` ile yerel sohbet (MAX/FLASH/LITE profilleri; Qwen3.8 27B ve
  Qwen3.5 9B), MTP (Multi-Token Prediction) speculative decoding ile ~2x hız (ayrı draft model
  gerekmez, çıktı kayıpsız). OpenAI, Claude, Gemini, DeepSeek ve OpenAI uyumlu özel uçlar.
- **Medya üretimi (yerel, ComfyUI):** metinden görsel (Krea-2 Turbo), görselden yeniden üretim, stil
  referansı, kimlik korumalı fotoğraf düzenleme (Krea 2 Identity Edit; MAX/FLASH) ve video üretimi
  (Wan 2.2 TI2V 5B). ComfyUI medya işleri arasında açık tutulur ve tek sağlıklı örnekle dil modeliyle
  birlikte çalışır (ölçüldü 61-62 tok/s); kaçak/mükerrer örnek yükleme öncesi temizlenir.
- **Belge ve OCR:** PDF/Word/Excel/PowerPoint/ZIP/RAR okuma, PDF/DOCX/PPTX üretimi; PaddleOCR ile
  görsel ve PDF OCR.
- **Ses dökümü (Whisper + ses olayları):** sohbete eklenen ses dosyası veya mikrofon kaydı otomatik
  yazıya çevrilir ve bulgular dil modeline verilir (OCR/mmproj mantığı). Motor **faster-whisper
  large-v3 (Türkçe ince ayarlı sürüm)**: en yüksek doğruluk + **Silero VAD** ile sessizlikte uydurma
  metin bastırılır. **Konuşma dışı ses olayları** (AudioSet/AST; ör. ayak sesleri, kapı) ve
  (isteğe bağlı) **konuşmacı ayrımı** (pyannote) aynı döküme eklenir. Çıktı **kronolojik ve zaman
  damgasızdır**:
  ```
  (ayak sesleri)
  Konuşmacı: Geldin mi?
  (kapı kapanma sesi)
  Konuşmacı: Evet, biraz geciktim.
  ```
  GPU'da hızlı (yoksa CPU'ya düşer). Yerel sağlayıcıda dil modeli VRAM'den boşaltılıp dökum alınır ve
  geri yüklenir. Arayüzde Gönder'in solunda **mikrofon** tuşu (**Windows varsayılan kayıt cihazından
  canlı kayıt**, bağımlılıksız) ve ek (+) menüsünde **Ses ekle**. Motor ve modeller kurulumda
  `venv\asr` + HF önbelleğine indirilir.
- **ASR, dil modeli yüklemesini geçersiz kılar:** ses eki olan bir mesaj gönderildiğinde dil modeli
  hazır olmasa bile işlem hemen başlar; süren model yüklemesinden vazgeçilir, ses Whisper ile
  yazıya çevrilir, ardından dil modeli (seçili profile göre) geri yüklenir. Böylece ses göndermek için
  modelin yüklenmesini beklemek gerekmez.
- **Sağlayıcı maksimum bağlam otomatik algılama:** API anahtarı doğrulanınca modelin bağlam penceresi
  uçtan okunup otomatik uygulanır (ör. commandcode 1.000.000).
- **Bağımsız grafik üretimi:** `generate_chart` sohbet aracı + `agent/chart-run.ps1` (gömülü pwsh +
  System.Drawing; çubuk/çizgi/pasta/saçılım/fonksiyon grafikleri; güvenli ifade çözümleyici,
  `Invoke-Expression` yok). Sonuç sohbette satır içi gösterilir ve `outputs\grafikler`'e kaydedilir.
- **Matematik gösterimi:** LaTeX yanıtları okunur Unicode'a çevrilir (∫, ∞, π, √, ∑, →, ≠, Yunan
  harfleri; kesir → a/b; üs/alt simge → Unicode). Ayrıca **kimya/genel bilimsel** karakterler:
  denge oku ⇌, ↔ ⟷ ⟹ ↪ ↑ ↓ ↕ ve **mhchem `\ce{...}`/`\pu{...}`** (element sayıları alt simge,
  oklar ok). Para birimi `$` korunur.
- **Web ve yerel yönetim:** web araması ve sayfa okuma araçları; tarayıcıdan erişilen yerel yönetim
  sunucusu (yalnızca localhost, şifre korumalı oturum).
- **Kurulum ve güncelleme:** Inno Setup sihirbazı; sabit sürümlü altyapı (PowerShell 7.6.6, llama.cpp
  b10998 CUDA 13.4, ComfyUI b0f4b7b); uygulama içinden güncelleme denetimi; tam kaldırma.
  Kurulumda **görsel/video üretimi, ses yakalama ve OCR isteğe bağlıdır** (varsayılan seçili; işaret
  kaldırılırsa yalnızca sohbet/belge araçları kurulur). Aynı bileşenler **Profil yöneticisinden**
  seçilip indirilebilir veya silinebilir.
- **Lisans (EULA):** Kurulum sihirbazında **Son Kullanıcı Lisans Sözleşmesi** gösterilir ve kabul
  edilmeden kurulum sürmez. Yazılımın mülkiyeti ve tüm hakları geliştiriciye aittir; kopyalama,
  değiştirme, kırma (crack) veya ticari amaçla pazarlama yasaktır. İzinsiz kullanım hukuki ve cezai
  sorumluluk doğurabilir; sorumluluk reddi ve sınırlandırılması, fesih ile hukuk/mahkeme hükümleri yer alır.
- **Dil profili (Profiller penceresi):** Profiller penceresine **arayüz dili / dil profili** seçimi
  eklendi (Türkçe/English). Kullanıcı buradan **diğer dil sürümünün kurulum paketini indirip
  kurabilir**; kurulum aynı klasöre yapılır (`UsePreviousAppDir`), `settings\` ve `chats\` korunur.
  İndirilen paket `tools\editions` altında saklanır ve **"Dil sürümünü sil"** ile kaldırılabilir.

### Değişen
- **FLASH çıktı tavanı 4096 → 8192:** artık üç profil de (`--predict` ve arayüz `max_tokens`) 8192
  kullanır. Bu bir **tavan**dır, hedef değil: üretim EOS'ta durduğu için normal yanıtların hızı
  değişmez; yalnızca uzun yanıtlarda/düşünmede yanıtın yarıda kesilmesi (boş yanıt) engellenir.
  MAX/FLASH ayrımını `--reasoning-effort` (xhigh vs low) korur.
- **Ses döküm motoru değişti:** Qwen3-ASR ve whisper.cpp kaldırıldı; yerine **faster-whisper
  large-v3 + AST ses olayları** hattı (`agent/transcriber/`) geldi. Mikrofon menüsüne **"Konuşma
  dışı sesler"** onay kutusu eklendi (kapalıysa yalnızca konuşma dökumlenir). **Kırmızı mikrofon
  tuşuna basmak artık kaydı iptal eder** (durur, dosya silinir, hiçbir şey gönderilmez); kaydı
  bitirip göndermek için sağ tık menüsü ya da **Gönder** kullanılır.
- **Kurulum sihirbazı Türkçe/İngilizce dil seçimi sunar** (bu sürümde varsayılan Türkçe).
- **LITE artık düşünme bütçesi kullanmaz (sınırsız):** `--reasoning-budget` hiç verilmez; düşünme
  açık kalır ve model gerektiği kadar uzun düşünür. Sistem istemi modele derin düşünmesini ve
  düşünme süresini kısıtlamamasını söyler. Önceki 300 token'lik bütçe kaldırıldı.

### Düzeltilen
- **Sessiz/boş ses kaydında döküm sarmalayıcısı sızıyordu:** Qwen3-ASR çıktısını ayrıştıran
  `_extract_text`, konuşma algılanmayan (sessiz) kısa kayıtlarda ham `language None<asr_text>`
  metnini transkript olarak modele gönderiyordu; model de "transkript boş" diye yanıt veriyordu.
  Artık `<asr_text>` etiketi ve `language ...` sarmalayıcısı **her zaman** temizlenir; sessiz sonuçta
  metin **boş** döner (arayüz testinde yakalandı, gerçek sessiz kayıt ve konuşma kaydıyla doğrulandı).
- **"Durdur" artık o an yapılan HER işi anında keser:** yanıt üretimi, **ASR/OCR/arama gibi uzun
  süren alt süreçler** (Python alt süreçleri anında öldürülür) ve medya üretimi beklemeden durur;
  ardından dil modeli arka planda yüklenir ve sohbet bir sonraki mesajla devam eder. **Tek istisna:**
  o sırada dil modeli **yükleniyorsa** yükleme kesilmez (arka planda tamamlanır).
- **Ses/OCR sonrası model geri yükleme yarışı (8 GB LITE):** transkripsiyon/PaddleOCR alt süreci
  çıktıktan sonra WDDM VRAM'i geciktirerek serbest bırakabildiği için hemen başlayan dil modeli
  "yer yetmiyor" ile reddedilip kapalı kalabiliyordu. Bellek kontrolü artık kısa aralıklarla sınırlı
  kez yeniden denenir (~5 sn), tek bir gecikmede model düşmez.
- **Ses kaydı (mikrofon) akışı düzeltildi:** kayıt sürerken **kırmızı mikrofon tuşuna** basmak kaydı
  **bitirip gönderir** (eskiden yalnızca menü açılıyordu ve gönderilmiyordu). **"İptal"** artık kaydı
  gerçekten iptal eder (dosya silinir, gönderilmez); kayıt sürerken de erişilebilmesi için mikrofon
  tuşunda **sağ tık** menüyü açar. Kayıt sürerken **Gönder**'e basmak da kaydı bitirip gönderir.
- **Ses atıldıktan sonra "Durdur" düzgün çalışıyor:** transkripsiyon ve dil modelini geri yükleme
  beklemesi artık iptal isteğine uyar; arayüz uzun süre "Durduruluyor" durumunda kalmaz.
- **ComfyUI yaşam döngüsü profile duyarlı yapıldı:** MAX/FLASH (27B) profillerinde dil modeli yüklenmeden
  önce ComfyUI her zaman kapatılır (aksi halde 16 GB kartta MTP draft taşıp sohbet aralıklı ~6-7 tok/s'ye
  düşüyordu); LITE'ta ComfyUI açık kalır ve medya işleri arasında yeniden açılmaz.
- **`custom` (OpenAI uyumlu özel uç) sohbette çalışmıyordu:** taban adres yalnızca arayüz ayarında
  tutuluyordu; işçi ayarları okumadığı için `custom` istekleri "taban adresi gir" ile duruyordu
  (yalnızca ayar penceresindeki doğrulama çalışıyordu). Masaüstü artık `baseUrl` + ayarları işçiye
  geçirir; commandcode ile metin+görsel uçtan uca doğrulandı.
