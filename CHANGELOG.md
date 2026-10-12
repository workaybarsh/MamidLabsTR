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
- **Ses dökümü tier'ı artık seçili profile göre:** yerel ASR hattının seviyesi (`int8_float16` +
  sıralı yükleme + 15 sn CPU/GPU eşiği olan **LITE** ya da `float16` + paralel + 20 sn olan **PRO**
  (MAX/FLASH)) artık **seçili dil-modeli profiline** göre belirlenir; eskiden yalnızca toplam VRAM'e
  bakılıyordu. Toplam VRAM artık yalnızca profil adı verilmezse (CLI) yedek ölçüttür. Cihaz/swap
  kararı yine ölçülen gerçek boş VRAM + sistem RAM'i ve kaydın süresine göre verilir.
- **Ses dökümünde CPU/GPU seçimi ölçüme göre:** cihaz artık gerçek boş VRAM + sistem RAM'i +
  kaydın **süresine** göre otomatik seçilir. Ölçülen eşik **PRO ~20 sn**, **LITE ~15 sn**;
  bu süreden kısa kayıtlarda CPU, uzunlarda GPU (swap) kullanılır. Dil modeli + ses hattı boş
  VRAM'e birlikte sığıyorsa GPU her zaman (swap yok).
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
- **Blok LaTeX artık okunur metne çevrilir.** `Convert-MathText`, basit regex'in çözemediği blok
  yapıları **dengeleyen bir ayrıştırıcıyla** (`Read-MathGroup`/`Read-MathAtom`/`Expand-MathCommands`)
  işler: iç içe/kümeli ve kaçışlı `\{ \}` parantezli `\frac{A}{B}`, `\sqrt{X}` / `\sqrt[n]{X}`,
  `\boxed{X}`/`\fbox{X}` (kutu yerine `[ X ]`), `\textbf`/`\textit`/`\mathrm`/`\text`/`\operatorname`
  (içerik), `\left`/`\right` (sade parantez), `\overline`/`\bar`/`\vec`/`\hat` (birleşik işaret) ve
  `\begin`/`\end`. Örnek: `\boxed{\frac{\pi^5(89+72\sqrt3)}{3888}}` → `[ (π⁵(89+72√(3)))/3888 ]`.
  Mevcut glif tablosu, kimya `\ce`/`\pu` ve para birimi `$` davranışı korunur.
- **Sistem istemine sabit "kanıtlı ve iki kez doğrula" talimatı.** `Get-SystemPrompt`'a (tura özel
  değil; KV önbelleği bozulmaz) doğru/kanıtlı cevap, çok adımlı matematik/cebir/mantıkta adımları ve
  sembolik/sayısal **ara sonuçları en az iki kez kontrol** ve **uydurma test/teorem/kaynak adı
  kullanmama** talimatı eklendi; LITE derin-düşünme satırı bununla birleştirildi (tekrar yok).
- **Ses dökümü: LITE CPU/GPU politikası ve GPU çalışma zamanı DLL'leri netleştirildi; transcribe
  zaman aşımı kayıt süresine bağlandı.** (1) LITE ASR artık kayıt `LITE_CPU_MAX_SECONDS` (15 sn)
  süresinden **kısa VE** sistem RAM'i yetiyorsa **CPU co-resident** kullanır
  (`('cpu', False)`; dil modeli VRAM'de kalır, ses modeli CPU/sistem RAM'inde koşar; swap yok),
  uzun kayıtta ya da RAM yetersizken **GPU + mecburi swap** (`('cuda', True)`). CPU yolu hiçbir
  zaman zorlama değildir: seçilen cihaz başarısız olursa CPU yedeğine düşülür, GPU yoksa son çare
  olarak kalır. PRO davranışı değişmedi (20 sn). **Ölçüm hükmü** (iki bağımsız ölçüm çelişti;
  DAHA KESİN olan ölçüm-2 = LM + ASR CPU'yu BİRLİKTE gerçekten koşturan): LITE co-resident
  **SIĞMIYOR** — fiziksel RAM 15,25 GB < gereksinim ~16,1 GB; marj sıfır/negatif (tepe
  ~15.127/15.611 MB, yalnız ~489 MB boş); OOM olmasa da LM'in ~6,1 GB model sayfası geri
  kazanılabilir önbellekten atılıp **bir sonraki sohbet turunda diskten yeniden okunuyor**.
  Bu yüzden LITE `audio_ram_mib` **5.120 MiB'de** (PRO ile AYNI güvenli kapı) tutulur; LM
  yüklüyken `choose_plan` CPU dalını SEÇMEZ → **GPU + swap** (kullanıcı kuralı: RAM'e sığıyorsa
  co-resident, sığmıyorsa VRAM swap). Bol RAM'li makinede kısa kayıt yine CPU co-resident
  olabilir. (2) `requirements\asr.txt`'e `nvidia-cublas-cu12`
  + `nvidia-cudnn-cu12` eklendi (CTranslate2 4.x Windows'ta `cublas64_12.dll` / `cudnn_*64_9.dll`
  arar; torch'un cu130 tekerlekleri `cublas64_13.dll` getirir) ve `asr.py`
  `_add_cuda_dll_dirs` ile `site-packages\nvidia\*\bin` dizinlerini DLL arama yoluna ekler; **GPU
  dökümü artık çalışır** (gerçek kayıtla doğrulandı, `device=cuda`). (3) Transcribe isteğine kayıt
  süresinden türeyen sonlu bir `timeoutSeconds` eklendi (`max(600, d*4+300)`, üst sınır 3600;
  süre yoksa 1800) — uzun CPU co-resident/swap dökümü sabit 180 sn zaman aşımıyla kesilmez;
  "Durdur" yine anında etkilidir. `tests/test_transcriber.py` ve `tests/test_requirements_files.py`
  bu sözleşmeleri korur. Ayrıca swap durum metni düzeltildi: dil modeli RAM'e taşınmıyor,
  `manage-qwen -Action stop` ile **süreç kapatılıyor** (kod davranışı değişmedi).
- **Ses dökümü: CPU yedeği PowerShell sözlük hatası yüzünden hiç çalışmıyordu (uçtan uca ses
  testinde bulundu).** `Invoke-TranscribeWithModelSwap` birincil cihaz (GPU) dökümü başarısız
  olunca CPU yedeğini `$payloadBase + @{ device = 'cpu' }` ile kuruyordu; ancak PowerShell'de
  Hashtable `+` **aynı anahtarda istisna atar** ("Item has already been added. Key in dictionary:
  'device'"), çünkü `$payloadBase` zaten `device`/`need_swap` içerir. Bu yüzden CPU'ya gerçek bir
  geçiş hiç olmuyor, gerçek ASR hatası yutuluyor ve tur dökümsüz bitiyordu (örn. ctranslate2'nin
  istediği `cublas64_12.dll` yoksa GPU yolu her zaman hata verir). Artık payload kopyalanır ve
  alan ezilir (`$cpuPayload = $payloadBase.Clone(); $cpuPayload['device'] = 'cpu'`); aynı düzeltme
  "modeli bellekten çıkarıp yeniden dene" bloğunda da yapıldı. `tests/test_transcriber.py` bu
  deseni korur.
- **Hijyen: audit kaydı rotasyonu ve düşünme (reasoning) tekrar koruması (F3/F4).** (F3) Araç
  çağrısı kaydı `logs\audit.jsonl` sınırsız büyüyordu; artık yazımdan önce dosya 5 MB'ı aşarsa
  `audit.1.jsonl`'e devredilir (varsa üzerine yazılır) ve yeni satır temiz dosyaya gider — devir
  de mevcut `try/catch` içinde olduğundan audit yazımı hiçbir durumda turu düşürmez. (F4) Tekrar
  (runaway) dedektörü yalnızca görünür içeriğe bakıyordu; LITE'ta düşünme **sınırsız** olduğundan
  model `reasoning_content` akışında tekrara girerse 8192 token tavanına kadar boş dönüyordu. Artık
  reasoning birikimine görünür içerikle **aynı eşik/desen** muhafazakâr biçimde uygulanır; güçlü
  tekrar saptanınca akış güvenli noktada durdurulur (görünür yanıt yoksa mevcut boş-yanıt yolu
  korunur).
- **Ajan döngüsü dayanıklılığı: tur içi bağlam taşması, duvar-saati sınırı ve `custom` sağlayıcı
  toleransı.** (F1) Araç sonuçları tur içinde birikip prompt `contextLimit`/`--ctx-size`'i aşınca
  `--no-context-shift` yüzünden sunucu hata döndürüp tur düşüyordu; artık her tur başında tahmini
  prompt boyutu hesaplanır, bütçe aşılırsa **en eski araç çıktıları** (sistem mesajı ve son kullanıcı
  mesajı korunarak) kısaltılır; hâlâ sığmazsa araçlara devam etmeden eldeki bulgularla görünür yanıt
  istenir. (F2) `max_tokens` kalan bağlam odasına göre sınırlanır (küçük bağlamlı model/uç).
  (D2) Python alt süreçlerine duvar-saati sınırı eklendi (varsayılan 180 sn; aşılınca öldürülür).
  (D3) OpenAI uyumlu `custom` uç geçici kopmada bir kez yeniden dener ve yanıt üretildiyse kopmayı
  hata saymaz; uzak sağlayıcılarda davranış korunur.
- **Ses eki döküme çevrilemediğinde model dosyayı okumaya çalışıp turları boşa harcıyordu (uçtan uca
  ses testinde bulundu).** Eklenen bir `.wav` transkript üretemediğinde işçi sessizce "dökümsüz"
  devam ediyor, kullanıcı mesajındaki `[Kullanıcı bir ses dosyası ekledi: ...]` notu tek başına
  kalıyordu; model bunu "ekli belge" sanıp `read_document`/`read_bound_file` ile `.wav`'ı açmaya
  çalışıyor ve **8/8 ajan turunu** döküm baloncuğu hiç oluşmadan harcıyordu. Artık (1) plan "swap
  yok" deyip döküm alınamazsa dil modeli bellekten çıkarılıp **temiz GPU/RAM** ile bir kez daha
  denenir (WDDM'de plan'ın okuduğu boş VRAM, model yüklüyken iyimser olabiliyordu), (2) yine
  alınamazsa son kullanıcı mesajına sesin **belge olmadığını** ve yazıya çevrilemediğini söyleyen
  açık bir yönlendirme notu eklenir. Motor tek başına sağlamdı (doğrudan `whisper-tools.py`
  çağrısı çalışıyor); kusur işçinin başarısızlığı yutup modele yanlış bağlam bırakmasıydı.
- **Betik tabanlı güncellemede `EULA.txt` kopyalanmıyordu:** `install-mamidlabs.ps1` üst dosya
  listesi (`qwen-desktop.ps1`, `launch-qwen-desktop.vbs`, `README.md`, `LICENSE`) köke ve
  `kurulum-kaynak` paketine kopyalanır; `EULA.txt` listede olmadığı için lisans dosyası betikle
  (sihirbazsız) güncellenen kurulumlarda eksik kalıyordu. Listeye eklendi.
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
