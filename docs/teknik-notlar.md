# Teknik notlar

Bu belge MamidLabs'in iç işleyişini, profil ayrıntılarını, medya hattını, araçları ve bilinen
notları anlatır. Kurulum için [kurulum.md](kurulum.md), genel bakış için [README](../README.md).

**Kurulum yolu.** Bu belgedeki `%LOCALAPPDATA%\Programs\MamidLabs` **varsayılan** konumdur, sabit bir
gereklilik değil. Uygulama kendi konumundan çalışır; sihirbazda klasör seçilerek ya da
`install-mamidlabs.ps1 -Root <yol>` ile herhangi bir SSD klasörüne kurulabilir.

## Mimari

```
mamidlabs-desktop.ps1  (WinForms arayüz, tek pencere)
      │
      ├─ agent/mamidlabs-inference.ps1   → llama-server /v1/chat/completions (akış + araç döngüsü)
      │       ├─ agent/mamidlabs-agent-tools.py  → web araması, sayfa okuma, referans görsel bulma
      │       ├─ agent/office-tools.py      → PDF / Word / Excel / PowerPoint oku-yaz
      │       └─ agent/ocr-tools.py         → düz görselde GPU, PDF'te CPU PaddleOCR
      │
      ├─ agent/imagegen-run.ps1     → VRAM takası + ComfyUI + Krea-2 Turbo
      ├─ agent/videogen-run.ps1     → VRAM takası + ComfyUI + Wan 2.2 TI2V-5B
      │       └─ agent/media-tools.py       → video karesi çıkarma, küçük resim
      │
      ├─ agent/media-model-swap.ps1 → VRAM devri, ComfyUI yaşam döngüsü
      ├─ scripts/manage-mamidlabs.ps1    → llama-server başlat / durdur / profil değiştir, bellek kapısı
      │       └─ agent/process-launch.ps1   → uzun ömürlü süreçleri çağıranın çıktı hattından ayırır
      └─ agent/profile-catalog.ps1  → profil kataloğu, eksik dosya taraması, indirme
              └─ agent/profiles.json        → profil başına dosya listesi ve kaynakları
```

| Bileşen | Yol |
|---|---|
| llama.cpp (CUDA) | `%LOCALAPPDATA%\Programs\MamidLabs\llama.cpp\b10998\llama-server.exe` |
| Dil modeli | `%LOCALAPPDATA%\Programs\MamidLabs\models\Qwen3.8-27B-Abliterated-IQ4_XS\*.gguf` (+ mmproj görsel) |
| Görsel/video modelleri | `%LOCALAPPDATA%\Programs\MamidLabs\ComfyUI\models\{diffusion_models,text_encoders,vae,loras}` |
| Görsel/video ortamı | `%LOCALAPPDATA%\Programs\MamidLabs\venv\imagegen` (torch cu130, PyAV) |
| OCR ortamı | `%LOCALAPPDATA%\Programs\MamidLabs\venv\ocr` (RTX 50 sm_120 GPU PaddlePaddle + PaddleOCR) |
| PDF OCR ortamı | `%LOCALAPPDATA%\Programs\MamidLabs\venv\ocr-cpu` (standart CPU PaddlePaddle + PaddleOCR) |
| Web/belge ortamı | `%LOCALAPPDATA%\Programs\MamidLabs\venv\app` (ddgs, pypdf, reportlab, python-docx, python-pptx) |
| PowerShell 7 | `%LOCALAPPDATA%\Programs\MamidLabs\runtime\pwsh\pwsh.exe` (uygulamaya gömülü) |
| Üretilenler | `%LOCALAPPDATA%\Programs\MamidLabs\outputs\{images,videolar,belgeler,refs,thumbs}` |
| Sohbet geçmişi | `%LOCALAPPDATA%\Programs\MamidLabs\chats` |
| Loglar | `%LOCALAPPDATA%\Programs\MamidLabs\logs` |

Başlatma: masaüstündeki **MamidLabs** kısayolu → `launch-mamidlabs-desktop.vbs`
(konsol penceresi açılmaz, uygulama zaten açıksa öne getirilir).

## Profiller

| Profil | Model | Bağlam | Reasoning | max_tokens | Ölçülen hız |
|---|---|---|---|---|---|
| MAX (derin) | Qwen3.8 27B IQ4_XS | 32K | `xhigh` | 8192 | ~42–58 token/s |
| FLASH (hızlı) | Qwen3.8 27B IQ4_XS | 32K | `low` | 8192 | ~42-58 token/s |
| LITE (8 GB) | Huihui-Qwen3.5 9B Q5_K_M | 32K | sınırsız (bütçe yok) | 8192 | ~40–79 token/s (8 GB) · ~97 token/s (16 GB) |

MAX ve FLASH aynı 27B dosyasını paylaşır: 32K bağlam, `--gpu-layers 99`, flash-attn açık,
KV cache q4_0, görsel projektörü (mmproj) CPU'da (`--no-mmproj-offload`; GPU'da 16 GB karta
sığmayıp paylaşılan belleğe taşıyordu). Sağ alttaki seçiciyi **değiştirmezsen model yeniden yüklenmez**.

**LITE düşünme ve yanıt bütçesi.** LITE'ta düşünme açık ve sınırsızdır (`--reasoning-budget`
verilmez; Qwen3.5 9B şablonu `reasoning_effort`u yok sayar). Düşünme tokenları `--predict` **çıktı**
bütçesini paylaştığından zor bir soruda düşünme tüm 8192'yi yiyip görünür yanıt üretmeyebilir
(ölçüldü: 8192 token ≈ 159,7 sn, yanıt yok). Bu yüzden işçi, görünür yanıt **boşsa** ya da çıktı
tavanında kesilip (`finishReason='length'`) kırık metin bıraktıysa ikinci denemeyi **düşünme kapalı**
(`chat_template_kwargs.enable_thinking = $false` + `/no_think`) yapar ve görünür yanıtı **garanti
eder**; sistem istemi de modeli yeterince düşünüp **yanıtını da yazmaya** yönlendirir (düşünmeyi
sınırsızca uzatmaya değil).

**MTP (Multi-Token Prediction).** MAX/FLASH, Qwen3.8 27B GGUF'unun gömülü MTP/nextn draft başlığıyla
(`qwen35.nextn_predict_layers = 1`, `blk.64.nextn.*`) `--spec-type draft-mtp` ile başlar. LITE'ın
9B GGUF'u ise bu başlığı dönüşümde kaybeder; indirme sırasında `agent/mtp_inject.py` ile geri
eklenir (kaynak: `huihui-ai/Huihui-Qwen3.5-9B-abliterated` MTP tensorleri), bu yüzden
`--spec-type draft-mtp` LITE'ta da kullanılır. Ayrı bir draft model gerekmez; çıktı kayıpsızdır
(kabul edilen tokenlar hedef modelle doğrulanır) ve ~2x hız kazancı sağlar (LITE'ta kabul ~0,93
(içeriğe bağlı 0,31–0,96); model kartında 27B için Q4_K_M kabul 0,35–0,53). Bayrak yalnızca GGUF gerçekten MTP katmanı
taşıyorsa eklenir (`Test-GgufHasMtp`); taşımayan modele verilirse llama.cpp "model doesn't contain
MTP layers" ile açılmaz. Gerekirse `%LOCALAPPDATA%\Programs\MamidLabs\settings\api.json` içine
`"mtp": false` yazılıp kapatılabilir.

### 16 GB bellek bütçesi (MAX/FLASH)

RTX 5060 Ti 16 GB üzerinde llama.cpp'nin bellek dökümüyle ölçüldü (32K bağlam):

| Bileşen | VRAM |
|---|---|
| Model ağırlıkları (GPU kısmı; `token_embd` CPU'da kalır) | 13.729 MiB |
| KV önbelleği (q4_0) | 576 MiB |
| Recurrent durum | 150 MiB |
| Hesap tamponu | 184 MiB |
| **Toplam** | **~14.640 MiB** |

Görsel projektör GPU'da ağırlık ve hesap tamponuyla 1.133 MiB daha istiyordu; toplam boş alanı
aşıp ~420 MiB paylaşılan belleğe taşıyordu. Projektör CPU'ya alınınca sohbet 19,6'dan 25,0 tok/s'ye,
tek görsel okuma 56–58 sn'den 29 sn'ye indi. `scripts/manage-mamidlabs.ps1` içindeki bellek kontrolü
model dosyası + 750 MiB ister (eşik 15350 = ölçülen ayak izi). **ComfyUI yaşam döngüsü** (`settings/api.json` → `comfyKeepAlive`,
varsayılan `false`): ComfyUI **yalnızca görsel/video üretimi sırasında** çalışır; iş bitince ve dil
modeli yüklenmeden önce kapatılır, böylece boşta ne VRAM ne RAM tutar (boşta ComfyUI ~300 MiB CUDA
bağlamı + süreç RAM'i tutuyordu). Medya gerektiğinde yeniden açılır (~27 sn). MAX/FLASH'ta dil
modeli yüklenmeden önce **her zaman** kapatılır; LITE'ta `comfyKeepAlive=true` ile medya işleri
arasında açık tutulabilir (o zaman taşma yapmaz — ölçüldü: GPU tampon yerleşimi iki durumda da
aynı; graph splits 2 — yalnızca sohbet ~%11 yavaşlar, 49,7 → 44,2 tok/s). Yer yetmezse (kuyruk
boşsa) kapatılıp yeniden ölçülür.

**Otomatik VRAM temizliği:** dil modeli yüklenmeden önce uygulamaya ait **artık GPU işçileri** de
kapatılır — boşta kalmış kalıcı ses işçisi (`whisper-tools.py --serve`) ve OCR işçisi
(`ocr-tools.py`); çökme/zorla kapatma sonrası kalan CUDA bağlamları (~140–600 MiB) 27B'nin ince
payını yiyebilir. `scripts/manage-mamidlabs.ps1` → `Get-AppGpuWorkers`/`Stop-OrphanWorkers` bellek
kapısından **önce** çalışır, sürücünün VRAM'i bırakmasını bekler ve kapı sınırlı kez yeniden denenir
(~7 sn). Temizlik yalnızca kurulum kökü altındaki süreçleri hedefler; başka uygulamalara dokunulmaz.

### Lite profili (8 GB VRAM / 16 GB RAM)

8 GB kartlar 27B modeli taşıyamadığı için Lite ayrı bir 9B modeli yükler ve bütün
medya hattını küçültür:

| Alan | MAX / FLASH | LITE |
|---|---|---|
| Dil modeli | Qwen3.8 27B IQ4_XS (~15 GB) | Huihui-Qwen3.5 9B Q5_K_M (~6,6 GB) |
| Bağlam | 32K | 32K |
| Görsel okuma (mmproj) | F16, CPU'da | Q8_0, CPU'da |
| Görsel üretimi | Krea-2 Turbo (fp8, ~13,1 GB) | Krea-2 Turbo GGUF Q4_K_M (~7,5 GB, `ComfyUI-GGUF` custom node ile) |
| Stil referansı / gerçekçilik | LoRA ile | LoRA ile (MAX/FLASH ile aynı dosyalar) |
| Düşünme | sınırsız | sınırsız (düşünme açık, bütçe yok) |
| Video | 832×480, 5 sn'ye kadar | 832×480 tavan, 3 sn tavan |
| ComfyUI | normal | `--lowvram` (ağırlıklar RAM'den katman katman akar) |

Bellek bütçesi: RTX 4060 Laptop üzerinde, varsayılan Q5_K_M ve 32K bağlamla, görsel projektörü
(mmproj Q8_0) CPU'ya alındıktan sonra ölçüldü — **~7249 / 8188 MiB** (708 MiB boş; projektör
GPU'dayken ~7885 MiB idi ve yalnızca ~72 MiB kalıyordu). Üretim **içeriğe bağlı ~40–79 tok/s**
(MTP açık; kabul oranı 0,31–0,96), ön işleme ~270 tok/s. 16 GB'lık bir kartta LITE ~97 tok/s'ye
çıkar. Daha rahat bir VRAM payı istersen `%LOCALAPPDATA%\Programs\MamidLabs\settings\api.json`
içine `liteModel: "Huihui-Qwen3.5-9B-abliterated.i1-Q4_K_M.gguf"` yazıp dosyayı
`mradermacher/Huihui-Qwen3.5-9B-abliterated-i1-GGUF` deposundan elle indirip modeller klasörüne
koyabilirsin (~40 tok/s, ~1,7 GB boş VRAM kalır) — katalog yalnızca Q5_K_M'i otomatik indiriyor.
Q6_K (~7,4 GB) 8 GB kartta hiç sığmaz (dosyanın kendisi boş VRAM'i aşar).

**Düşünme (sınırsız).** Qwen3.5 şablonu `--reasoning-effort` değerini yok sayar; düşünme açık
(`--reasoning on`, `--reasoning-format deepseek`) kalır ve **düşünme bütçesi konmaz** — LITE
lazım olduğu kadar (gerektiği kadar uzun) düşünür, ölçülen sınırsız durumda 1451–2391 token (~50 sn).
Sistem istemi de modele derin düşünmesini ve düşünme süresini kısıtlamamasını söyler.

**Beklenti:** Lite'ta sohbet akıcıdır. Görsel üretimi çalışır ama `--lowvram` yüzünden
16 GB profile göre belirgin yavaştır; ~7,5 GB'lık GGUF diffusion model + ~5,2 GB metin
kodlayıcı 16 GB RAM'de sistemi zorlar. Video üretimi sınırdadır; uzun süren işlerde
bellek yetmeyebilir.

### Profiller menüsü

Sol üstteki **Profiller** menüsü her açılışta dosyaları diskten tarar ve her profilin
yanında `kurulu` / `N dosya indirilmeli` durumunu gösterir. Kurulu bir profile tıklamak
doğrudan ona geçer; eksik dosyası olan profil **Profil yöneticisi**ni açar.

Yönetici penceresi profilin dosya listesini `[kurulu]` / `[indirilecek]` /
`[elle kurulmalı]` olarak gösterir ve **Eksikleri indir** ile Hugging Face'ten çeker.
Katalog `agent/profiles.json` dosyasındadır; `repo` alanı boş olan satırlar için indirme
kaynağı tanımlı değildir ve elle kurulmaları gerekir. Şu an üç profilin bütün dosyaları
indirilebilir durumdadır (LITE ~36 GB, MAX/FLASH ~52 GB); her satır Hugging Face commit'ine ve
bayt boyutuna sabitlenmiştir. MAX/FLASH'ın 27B dil modeli ve mmproj'u
`windowsxp811203/Qwen3.8-27B-Abliterated-GGUF`, Identity Edit LoRA'sı
`conradlocke/krea2-identity-edit` deposundan iner. Herkese açık depolar için token gerekmez;
yarım kalan indirme kaldığı yerden devam eder, var olan dosya yeniden indirilmez.
Seçici, yükleme bitmesini beklemeden istediğin modeli gösterir. Hazır olan model ayrı
izlenir; eski modelin sağlık yanıtı seçimi değiştirmez ve bekleyen mesaj eski modele
gönderilmez. Hızlı ardışık seçimlerde devam eden yönetim işlemi bitince en son seçilen
model yüklenir. Yükleme hatası durum satırında gösterilir.

Hızlı iş (bağlam özetleme, görsel promptu) için modeli değiştirmek yerine istek başına
`reasoning_effort: low` gönderilir — 15 GB'lık yeniden yükleme maliyeti ödenmez.
Model adları `max` ve `flash` olarak görünür; hızlı iç işlemler için şablona `low` reasoning değeri gönderilir.

## Arayüz

- Kullanıcı mesajları sağda, model yanıtları solda baloncuk olarak.
- Düşünme akışı canlı görünür, bitince **tek satıra** düşer: `Düşündü (12,4 sn) ▸`.
  Tıklayınca düşünme adımları açılır/kapanır.
  Akış sürerken yukarı kaydırırsan okuduğun konum ve metin seçimin korunur;
  tekrar en alta indiğinde yeni metni takip eder.
- Çaba seçiminin hemen solunda sürekli görünen sayaç: `22,0 tok/s | 12,3K / 32,8K`.
  Hız ve token sayısı sunucunun canlı akış ölçümlerinden alınır (K = 1000 token).
  Üzerine gelince tam girdi/üretim/bağlam sayıları gösterilir. Agent araçları veya
  görsel/video üretimi sırasında sayaç kaybolmaz; dil modeli üretmiyorsa hız 0 olur,
  son bağlam sayısı korunur. Durum mesajı ayrı satırdadır.
- Anahtarlar: **İnternet**, **Ajan** ve alt satırda **Tam erişim**. Görsel, video ve belge
  üretimi ayrı çiplerle değil, mesajın niyetine göre ilgili araçla otomatik yapılır.
- ＋ ile görsel, video veya belge eklenir. Video ve belge **birden fazla** dosya aynı anda
  eklenebilir (pencereye sürükle-bırak da çalışır, dosya seçme penceresinde çoklu seçim
  açık); normal görsel anlama akışında mmproj'e **yalnızca bir görsel** gönderilir.
  Kullanıcı metin okuma/OCR niyetiyle birden fazla görsel seçerse özel çoklu OCR aracı açılır;
  görseller sırayla GPU PaddleOCR'dan geçirilir ve mmproj'e çoklu görsel gönderilmez. Tek dosya
  eklendiğinde büyük önizleme gösterilir; birden fazla dosya eklendiğinde tıklanınca açılan bir
  isim listesi gösterilir. Görseller 1024×1024'e ölçeklenir.
- Çoklu görsel modu açıldığında sohbet içinde kalıcı bir bildirim görünür; bildirim
  model yanıtı değildir ve model bağlamına eklenmez. Görsellerle birlikte etkinleştirme
  isteği gönderilse de görünür. Geçmişteki bildirimi açmak modu yeniden etkinleştirmez.
- Eklenen belgelerin tamamı sohbet boyunca okunabilir; yalnızca son belgeyle sınırlı
  değildir. Bu izin, eklenen dosyaların komşu dosyalarını kapsamaz.
- Enter gönderir, Shift+Enter satır atlar. Üretim sürerken Gönder → **Durdur** olur ve
  yalnızca isteği iptal eder; model bellekte kalır.
- Sağ üstteki **X** her şeyi kapatır: llama-server, ComfyUI ve arka plan işleri.

### API bağlantıları

Sohbet sağlayıcıları `agent\api-providers.ps1` içindeki tek tabloda tanımlıdır: OpenAI, Claude,
Gemini, DeepSeek ve özel (OpenAI uyumlu) uç. Uç adresi, anahtar ortam değişkeni (`OPENAI_API_KEY`, `ANTHROPIC_API_KEY`,
`GEMINI_API_KEY`, `DEEPSEEK_API_KEY`), anahtar sayfası ve model listesi adresi buradan okunur.
Arayüz listeleri, `ask_model` danışma aracı ve model kutusu aynı tabloyu kullanır.

**Özel (OpenAI uyumlu)** sağlayıcı; Ollama, LM Studio, vLLM gibi yerel sunucuları ya da kurum içi
bir ucu bağlamak içindir. Taban adres API bağlantıları penceresinden girilir
(`{taban}/chat/completions`, `{taban}/models`); anahtar isteğe bağlıdır, boşsa `Authorization`
başlığı gönderilmez.

“API bağlantıları” penceresinde **Hesabına gir, anahtar al** sağlayıcının anahtar sayfasını
tarayıcıda açar. **Doğrula ve modelleri getir** yapıştırılan anahtarı sağlayıcının model listesi
ucuyla dener; 401/403 “anahtar reddedildi” olarak gösterilir, hesabın erişebildiği sohbet modelleri
listeye dolar. Anahtar yalnızca istek başlığına yazılır ve DPAPI ile saklanır.

DeepSeek OpenAI uyumlu uç kullanır (`max_tokens`, `reasoning_content` akışı aynı yoldan işlenir).
Sohbet modelleri görsel kabul etmediği için `image_url` parçaları metne indirilir; yerlerine
“bu sağlayıcı görsel okuyamıyor” notu konur ve gerekiyorsa OCR sonucu kullanılır.

Claude isteği Messages API biçimine çevrilir. `thinking` alanı gönderilmez: Opus 5.5 ve
Fable 5/5.1 `disabled` değerini reddeder; alan yoksa yeni modeller uyarlamalı düşünür, eskiler
düşünmeden çalışır. Düşünme açıkken zorunlu araç seçimi de reddedildiği için `tool_choice`
her zaman `auto` gider. Araç döngüsünde Claude'un yanıtındaki imzalı `thinking` blokları,
metin ve `tool_use` blokları akıştan sırasıyla toplanır ve bir sonraki istekte aynen geri
gönderilir. Bu kayıt yalnızca o isteğin belleğinde tutulur; sohbet dosyasına ve diğer
sağlayıcılara geçmez. `max_tokens` düşünceyi de kapsadığı için Claude'da alt sınır 16000'dir.

OpenAI, Claude ya da Gemini **abonelik hesabıyla giriş** (OAuth) bilerek yoktur. Bu sağlayıcılar
tüketici aboneliği girişini yalnızca kendi uygulamalarına açar; üçüncü taraf uygulamanın abonelik
oturumunu kullanması kullanım koşullarına aykırıdır ve hesabın kapatılmasına yol açabilir.
Desteklenen yol API anahtarıdır; hesap bağlama penceresi bu adımı tek tıka indirir.

## Bağlam sıkıştırma

Bağlam 22.000 tokenı geçince eski mesajların %65'i düşük çabayla özetlenip tek bir sistem
mesajına indirilir, son %35 olduğu gibi korunur. Yeni sohbet açmak sayaçları sıfırlar.

Sıkıştırma **turdan hemen sonra arka planda** çalışır (`compactOnly` işi), kullanıcı bir
sonraki mesajını yazarken; böylece yeni mesaj özetlemenin bitmesini beklemez. Mesaj gönderilirse
veya sohbet temizlenirse arka plan işi iptal edilir; gerekirse gönderim anında özetleme yedek
yol olarak çalışır.

## İlk token gecikmesi (ön işleme)

Yanıt beklerken geçen sürenin neredeyse tamamı **prompt ön işlemedir**: llama-server,
promptun önbellekte olmayan kısmını yeniden işler. Bu yüzden:

- Promptun **başı turlar arasında birebir aynı kalmalıdır**. "Kullanıcı şu belgeyi ekledi",
  "sohbete görsel eklendi" gibi tura özel satırlar sistem isteminde değil, **son kullanıcı
  mesajının başında `[Sistem notu]` olarak** durur. Sistem istemi promptun ilk bloğu
  olduğu için oradaki tek karakterlik bir değişiklik bile 20K tokenlık bağlamın tamamını
  yeniden işletir.
- İstekler `cache_prompt: true` ile gider.
- Görsel okuma turu tamamlandıktan sonra görselin ham base64 verisi sohbet kaydında ve
  arayüz önizlemesinde korunur; takip eden normal mesajlara tekrar gönderilmez. Böylece
  her mesajda mmproj ön işlemesi yeniden çalışmaz. Görseli yeniden incelemek gerekirse
  tekrar eklemek, görsel üretiminde kaynak olarak kullanmak gerekirse uygulamanın tuttuğu
  son görsel yolu yeterlidir.
- Sohbet çipleri (İnternet / Ajan) açılıp kapandığında araç tanımları ve sistem istemi
  değişir; o turda tam yeniden işleme kaçınılmazdır. Üretim araçları mesaj niyetine göre
  otomatik açılır.
- Yerel sunucu `--cache-reuse 256` ile başlatılır; takip mesajlarında ortak KV önbellek
  daha geniş kullanılır. Görsel eklenen turun kendisi yine mmproj kodlama maliyeti taşıyabilir,
  ancak sonraki normal mesajlar ortak metin önekinin önbelleğinden yararlanır.

İlk token gelene kadar durum çubuğunda `Düşünüyor… ön işleme 12 sn` sayacı görünür; sayaç
alanının ipucunda (fare ile üzerine gelince) son isteğin ilk token süresi, kaç tokenın
yeniden işlendiği ve kaç tokenın önbellekten geldiği yazar.

### Yavaşlığı ölçmek

```powershell
%LOCALAPPDATA%\Programs\MamidLabs\runtime\pwsh\pwsh.exe -File %LOCALAPPDATA%\Programs\MamidLabs\scripts\diagnose-latency.ps1
```

VRAM doluluğunu, iki ardışık turda ön işleme süresini / önbellekten gelen token sayısını,
ön işleme ve üretim hızını ölçer, sunucu logundaki yeniden işleme izlerini gösterir.
Yorumu:

| Bulgu | Anlamı |
|---|---|
| 2. turda `onbellekten gelen` ≈ 0 | Prompt öneki değişiyor; KV önbelleği kullanılmıyor |
| ön işleme < ~200 token/s | Katmanlar GPU'da değil ya da VRAM taşıyor |
| üretim < ~12 token/s | VRAM taşması (Windows paylaşılan bellek) kuvvetle muhtemel |
| VRAM %95+ | `--ctx-size` düşür veya `--image-min-tokens` küçült |

Yanıt boş kalırsa (düşünme tek başına yanıt için ayrılan tokenları tüketmiş olabilir) tek bir
düşük çaba denemesi yapılır.
Önceki araç sonuçları ve son turun çalışma notları bu denemeye aktarılır; uzun
notların başı ve sonu, bağlamda yanıt için yer kalacak şekilde korunur. Tekrar boş
kalırsa sessizce tamamlanmak yerine açıklama gösterilir.

Yerel model bağlantısı sistem proxy ayarlarını kullanmaz. Akış başlamadan oluşan
bağlantı hatası bir kez yeniden denenir; kısmi yanıt başladıktan sonra istek otomatik
tekrarlanmaz. Akış kesilirse alınan metin korunur ve gerçek hata nedeni gösterilir.
İptal düğmesi bekleyen ağ okumasını da keser.

Yerel isteklerde bağlantı her turda yeniden kurulur (`Connection: close`). Sunucu, ajan aracı
çalışırken (web araması, OCR, belge okuma) boş bekleyen keep-alive bağlantısını kapatabiliyor;
istemci bu bayat bağlantıyı yeniden kullanınca akış ortasında "Varolan bir bağlantı uzaktaki bir
ana bilgisayar tarafından zorla kapatıldı." (WSAECONNRESET) hatası oluşuyordu. Loopback'te taze
bağlantı kurmanın maliyeti yok denecek kadar azdır ve sunucudaki KV önbelleği (dolayısıyla ön
işleme tasarrufu) bundan etkilenmez. Kullanılabilir bir sonuç varsa (finish_reason alınmış,
yanıt metni gelmiş ya da bir araç çağrısı oluşmuş) bağlantı kapanırsa bu durum hata olarak
gösterilmez; tamamlanan cevabın altına yanlışlıkla "[Hata]" satırı eklenmez. Yalnızca içeriksiz,
araçsız ve tamamlanmamış kopmalar hata sayılır.

İnternet çipi açıkken ağ koparsa (hotspot, DNS zaman aşımı) web araması, sayfa okuma ve referans
görsel araçları istisna atmaz; modele geçerli bir hata JSON'u döndürür, böylece ajan döngüsü
kırılmadan yanıtını tamamlar. Bu davranış `tests/test_offline_mode.py` ile doğrulanır.

Bir web aracı bu şekilde başarısız olduğunda, modelin "etrafından dolaşması" (aynı sonucu
`run_command` ile ping/curl/wget/Invoke-WebRequest kullanarak ya da başka sayfa/arama deneyerek
almaya çalışması veya sonucu uydurması) engellenir: başarısızlık `Test-WebToolFailure` ile algılanır
ve isteğin kopyasına — kalıcı geçmişe **yazılmadan** — "[Sistem notu]" eklenir; model ya elindeki
bilgiyle net yanıt verir ya da güncel veriyi uydurmadan web erişiminin kurulamadığını söyler. Sistem
isteminde de önleyici bir kural vardır. Küçük model (LITE) prompt notuna her zaman uymadığı için iki
**sert koruma** vardır: (1) bir web aracı aynı istekte başarısızsa, sonraki turlarda **web araçları
modele artık sunulmaz** (arama döngüsü engellenir); (2) `run_command` ile `ping`, `curl`, `wget`,
`nslookup`, `ipconfig` gibi **ağ-probe komutları çalıştırılmadan reddedilir**. Bu korumalar yalnızca
bir web hatasından **sonra** devreye girer; kullanıcının açık ve ilgisiz komut isteğini etkilemez.
Sözleşme testleri: `tests/test_mamidlabs_contracts.py`.

Üstelik **`run_command` aracı modele yalnızca kullanıcı açıkça komut/terminal istediğinde sunulur**
(`Test-CommandIntent`): komut, terminal, konsol, cmd, powershell, bash, script/betik, .bat/.cmd/.ps1/.exe,
çalıştır, run, execute, ipconfig, ping, curl, wget, nslookup, netstat gibi kalıplar niyet sayılır.
Genel sorularda araç hiç sunulmadığı için model komutla "etrafından dolanmaya" kalkışamaz. Kullanıcı
açıkça istediğinde ise her zamanki gibi izin (onay) gerektirir.

## Görsel okuma ve OCR

Görsel eklendiğinde kullanıcı metni deterministik olarak kontrol edilir. "Görselde ne var?"
ve benzeri anlama istekleri doğrudan Qwen mmproj'e gider; PaddleOCR başlatılmaz. "Görseldeki
metni oku", "resimde ne yazıyor?" veya "OCR yap" gibi isteklerde dil modeli önce RAM'e alınır,
VRAM PaddleOCR'a bırakılır ve düz görsel yalnızca GPU'da taranır. GPU motoru metin üretemezse
OCR sonucu boş döner; görüntü korunur ve mmproj fallback'i kullanılır. OCR bitince dil modeli
aynı profille yeniden yüklenir. OCR sonucu kullanılabilirse model isteğinden `image_url` çıkarılır ve tanınan
metin ile kullanıcının sorusu gönderilir. Kullanıcı açıkça açıklama/özet/yorum istemedikçe OCR
başarılı olduğunda modele tekrar sorulmaz ve yalnızca çıkarılan metin döndürülür. OCR kurulmamışsa,
hata verirse veya metin çıkaramazsa görsel korunur ve mmproj fallback'i kullanılır.

Birden fazla görsel ve OCR niyeti birlikte algılanırsa Qwen'e yalnızca `read_images_ocr` aracı
verilir. Araç açıldığında durum satırında çoklu görsel gönderiminin açık olduğu belirtilir; araç
görselleri tek tek GPU'da okur, sonuçları `[Görsel 1]`, `[Görsel 2]` gibi etiketlerle birleştirir
ve işlem sonunda dil modelini aynı profille yeniden yükler. OCR niyeti olmayan çoklu görsel
gönderimi güvenli biçimde reddedilir; normal mmproj çoklu görsel akışına girmez.

`read_document` ile açılan PDF'in çıkarılmış metni boşsa veya 80 karakterden azsa aynı worker'ın
mevcut CPU yolu PDF sayfalarını PaddleOCR'a verir. Kullanıcı PDF içindeki görselleri/metni yazıya
çevirmesini açıkça isterse, PDF zaten yazılı olsa bile OCR zorunlu çalışır; OCR metni belge
aracının sonucu olarak Qwen'e aktarılır.

OCR ortamını bir kez kurmak için PowerShell 7 ve güncel NVIDIA sürücüsüyle:

```powershell
%LOCALAPPDATA%\Programs\MamidLabs\runtime\pwsh\pwsh.exe -File %LOCALAPPDATA%\Programs\MamidLabs\scripts\install-ocr.ps1 -Warmup
```

OCR sonucu güven, satır ve karakter sayısı ile sohbet balonunda görünür; modelin yanıtıyla
birlikte sohbet geçmişine kaydedilir.

**GPU uyumu.** `install-ocr.ps1` önce Paddle'in RTX 50 (Blackwell/sm_120) için yayımladığı özel
GPU derlemesini kurar; standart cu126 derlemesi bu kartlarda boş OCR sonucu verebiliyor. Bu
derleme RTX 4060 Laptop (Ada Lovelace, sm_89) üzerinde de hem GPU (düz görsel, `ocr_image`) hem
CPU (taranmış PDF, `ocr_pdf`) yolunda metin üretir (güven 0,999). Özel derleme resmi bir sürüm
kanalında değildir; indirilemezse kurulum resmi kararlı kanala (`paddlepaddle.org.cn`, cu126)
düşer. `scripts\smoke-test.ps1` iki yolu da (`-SkipOcr` ile atlanabilir) doğrular.

## Görsel üretimi (Krea-2 Turbo)

16 GB VRAM'e iki model aynı anda sığmadığı için sıra şu:

1. Dil modeli görsel promptunu **İngilizce** yazar (`generate_image` aracı).
2. llama-server durdurulur → VRAM boşalır (model dosyası Windows dosya önbelleğinde kalır).
3. ComfyUI + Krea-2 Turbo yüklenir, görsel üretilir (8 adım, cfg 1, euler/simple).
4. ComfyUI'deki modeller boşaltılır ve süreç varsayılan olarak kapatılır (boşta ne VRAM ne RAM
   tutar); `comfyKeepAlive=true` (yalnızca LITE) ile süreç açık tutulur (boşta ~130–370 MiB VRAM).
   Dil modeli geri yüklenir, sohbet kaldığı yerden devam eder. Kapatıldıysa sonraki görsel/video
   için ComfyUI yeniden açılır (~27 sn); hata veya iptalde süreç yine kapatılır.

Ölçüm (RTX 5060 Ti 16 GB): üretim **25–58 sn**, arayüzde uçtan uca **60–95 sn** (dil modelinin
boşaltılıp geri yüklenmesi dahil). LITE (RTX 4060 Laptop): uçtan uca 68–139 sn; gerçekçilik
LoRA'sıyla 180–210 sn.

Gerçekçilik LoRA'sı yalnızca mesajında açıkça istendiğinde açılır ("gerçekçi",
"fotogerçekçi", "gerçek gibi", "fotoğraf gibi", "realistic", "photorealistic"…);
"gerçekçi olmasın" gibi olumsuzlar kapalı tutar. 8 GB kartta LoRA üretimi ~2 kat
yavaşlattığı için varsayılan kapalıdır. En-boy oranları:
1:1 → 1024×1024, 16:9 → 1344×768, 9:16 → 768×1344, 4:3 → 1152×896, 3:4 → 896×1152.

### Üç mod

Model `mode` parametresiyle seçer; ＋ ile sohbete görsel eklediysen ikinci ve üçüncü mod açılır.

| mode | Ne yapar | Nasıl çalışır |
|---|---|---|
| `yeni` | Sıfırdan üretir | `EmptyLatentImage` |
| `yeniden_uret` | Eklenen görselin **kompozisyonunu korur**, stilini/detayını değiştirir | `VAEEncode` + denoise = `strength` (0,2–0,95, varsayılan 0,6) |
| `stil_referansi` | Eklenen görselin **tarzını/karakterini** yeni bir sahneye taşır | `krea2_style_reference` LoRA + `TextEncodeQwenImageEditPlus` (görsel, Qwen3-VL'e koşullama olarak girer) |

Kaynak görsel ~1 MP'ye ölçeklenip `outputs\input` altına yazılır, ComfyUI oradan okur.

### Fotoğraf düzenleme (Krea 2 Identity Edit)

Yerel sağlayıcıda `generate_image` aracına dördüncü bir mod eklenir: `kimlik_duzenle`.
Kullanıcı eklenen fotoğrafı düzenlemek istediğinde ("fotoğrafı düzenle", "kıyafetini değiştir",
"arka planı değiştir", "şunu ekle/kaldır") model bu modu seçer ve `prompt` alanına tek cümlelik
İngilizce bir düzenleme talimatı yazar.

| Parça | Değer |
|---|---|
| LoRA | `krea2_identity_edit_v1_2.safetensors` (güç 1,0) |
| Düğümler | comfyui-krea2edit `86f886d`: `Krea2EditModelPatch` (kaynak VAE latent'i, piksel yolu, `fit`, `ref_boost` 4) ve `Krea2EditGroundedEncode` (talimat kaynak görselle birlikte Qwen3-VL'e girer, `grounding_px` 768) |
| Örnekleme | 10 adım, cfg 1, euler/simple (Turbo); negatif: boş talimat + aynı görsel |
| Çözünürlük | Kaynağın en-boy oranı, ~1 MP, 16'nın katı |
| İki görsel | `scene_from_previous=true`: önceki turdaki görsel sahne, son görsel kişi ("bu kişiyi o sahneye koy") |

Arayüz sürümü `agent\workflows\krea2_identity_edit.json` dosyasındadır (ComfyUI'de açılabilir).
Kod aynı grafiği API biçiminde kurar ve düğüm paketinin önerdiği `target_latent` bağlantısını
ekler. Bu bağlantı kaynağı örnekleme başlamadan kodlar ve VRAM'i dar kartlarda modelin
bölünmesini önler. LITE'ta GGUF yükleyici aynen kullanılır, LoRA onun üstüne takılır.
Gerçekçilik LoRA'sı düzenleme zincirine eklenmez. API görsel sağlayıcısı seçiliyse aynı istek
OpenAI/Gemini görsel düzenleme ucuna gider.

### Kendi görsel/video modelin (dosya yolu)

“Görsel ve video modelleri → Model dosyası seç (dosya yolu)…” dosyayı varsayılan olarak
**kopyalamaz**. Yol `settings\api.json` → `externalMediaModels` listesine yazılır ve
`settings\comfy-extra-models.yaml` üretilir. ComfyUI bu dosyayı `--extra-model-paths-config`
ile okur. Liste değişirse boşta bekleyen ComfyUI yeniden başlatılır; içerik aynıysa dosyaya
dokunulmaz. `.gguf` dosyaları `unet`, diğerleri `diffusion_models` altında görünür.

## Video üretimi (Wan 2.2 TI2V-5B)

Görsel üretimiyle aynı VRAM takası. Üç mod, `generate_video` aracının `mode` parametresi:

| mode | Ne yapar |
|---|---|
| `metin` | Sıfırdan video |
| `gorsel` | Eklenen görselden hareket başlatır (image-to-video) |
| `video` | Eklenen videonun **son karesinden** devam eder |

Varsayılan: 832×480, 2 sn (49 kare @ 24 fps), 20 adım, cfg 5, uni_pc/simple, shift 8.
`quality: yuksek` 1280×704'e çıkar ama çok daha yavaştır. Süre 1–5 sn arası sınırlı.

| Çözünürlük · süre | 16 GB (RTX 5060 Ti) | 8 GB (RTX 4060 Laptop) |
|---|---|---|
| 832×480 · 2 sn | ~132 sn | ~5 dk |
| 1280×704 · 3 sn | ~339 sn | 480p ile sınırlı |

**Önemli:** video VAE'si tüm kareleri birden çözerken 16 GB VRAM'i taşırıyor, bu yüzden
`VAEDecodeTiled` (`tile_size=320, overlap=80, temporal_size=16, temporal_overlap=8`)
kullanılıyor. Düz `VAEDecode` ile ComfyUI örnekleme bittikten sonra çöküyor. Daha küçük örtüşme
değerleri (`tile=256/overlap=64, temporal_overlap=4`) parça sınırlarında leke ve periyodik
parlaklık sıçraması bırakır; seçilen değerlerde VRAM tepe noktası ~14,6 GB'tır.

## Belge araçları

`read_document` PDF / Word / Excel / PowerPoint / **ZIP** / **RAR** okur (Masaüstü, Belgeler,
İndirilenler, `outputs`, bağlı klasör veya ＋ menüsünden "Belge ekle" ile eklenen dosya).
ZIP/RAR'da `entry` verilmezse arşiv listesi, verilirse o dosyanın içeriği döner. RAR okuma
7-Zip ile çalışır (`%ProgramFiles%\7-Zip\7z.exe`; yoksa kurulum sihirbazı winget ile kurar).
`create_document` PDF, Word veya sunum üretir; içerik markdown yazılır (başlık, madde, tablo,
kalın). PowerPoint'te her `# ` yeni bir slayt olur. Çıktılar bağlı klasöre, yoksa
`outputs\belgeler` altına düşer.

**Yedekleme.** `write_bound_file` veya `create_document` var olan bir dosyanın üzerine
yazacaksa, önceki sürüm otomatik olarak `outputs\yedekler` altına
`<dosya adı>.<zaman damgası>.bak` olarak kopyalanır (yazma işleminin kendisi ayrıca onay
gerektirir — bkz. aşağıdaki izin sistemi). Bu klasör kendiliğinden temizlenmez; zamanla
büyürse elle silinebilir. Kapsam bilerek dar tutuldu: `run_command` ile çalıştırılan
komutların etkileri kapsam dışıdır, "her şey geri alınabilir" vaadi verilmez.

## Komut çalıştırma ve izin sistemi

Sohbet kutusunun sol altındaki **Tam erişim** anahtarı kontrol eder:

- **İzin iste** (varsayılan): agent dosya yazacağı, komut çalıştıracağı veya belge oluşturacağı
  zaman onay penceresi çıkar; pencere işlemi, hedef dosyayı ve kalan süreyi gösterir. 10 dakika
  içinde yanıt verilmezse işlem reddedilir ve pencere kendiliğinden kapanır; X ya da Esc "Hayır"
  sayılır. Reddedilen işlemde araç modele açık bir "İŞLEM YAPILMADI" sonucu döner ve yanıtın
  altına modelden bağımsız "İşlem yapılmadı" notu eklenir (yalnızca ekranda; modelin sohbet
  geçmişine girmez, KV önbellek eşleşmesi korunur).
- **Tam erişim**: dosya yazma, belge oluşturma ve kullanıcının açıkça istediği `run_command`
  çağrılarını sormadan yapar. Açarken uyarı çıkar; **seçim kaydedilir ve uygulama yeniden
  açıldığında da geri yüklenir**. Kapatmak için aynı düğmeyi kullan. İlk kurulumda veya
  kayıtlı değer geçersizse varsayılan yine **İzin iste** olur. Bu kalıcı yetkiyi yalnızca
  güvendiğin bilgisayarda ve ajan işlemlerinin risklerini kabul ederek aç.

Okuma işlemleri (dosya/belge/web okuma) izin gerektirmez, yalnızca kalıcı değişiklikler.
Komut çalıştırma varsayılan olarak onay ister; Ajan kapalıysa `run_command` aracı modele verilmez.

## Geçmiş sohbetler

Her tamamlanan turdan sonra sohbet `%LOCALAPPDATA%\Programs\MamidLabs\chats\<id>.json` olarak kaydedilir
(API mesajları + ekrandaki baloncuklar, düşünme metinleri ve görsel yolları dahil). Dosya içeriği
Windows hesabına bağlı DPAPI ile şifrelenir.
Çoklu ek listeleri ve kullanıcı tarafından eklenen belgelerin erişimi de geri yüklenir;
silinen dosyalar listeden kaybolmak yerine "dosya bulunamadı" olarak işaretlenir.
Sohbet ve ayarlar önce geçici dosyaya yazılır, başarılı yazımın ardından mevcut kayıt
atomik değiştirilir. Kayıt hataları kullanıcıya bildirilir; önceki kayıt korunur.
**Dosya → Geçmiş sohbetler…** ayrı bir pencere açar; çift tıkla veya *Aç* ile sohbet
olduğu gibi geri yüklenir, *Sil* seçileni, *Tümünü Sil* listedeki tüm sohbetleri kalıcı
siler (ikisi de onay ister). Ana tasarım değişmez.

## Güvenlik sınırları

- Web sayfası ve referans görseli araçları yalnızca genel HTTP(S) hedeflerine erişir; loopback,
  özel ağ, link-local, ayrılmış adresler ve güvenilmeyen yönlendirmeler reddedilir.
- ZIP/RAR ve Office arşivleri sınırlı giriş, açılmış boyut ve toplam boyut bütçesiyle okunur;
  ComfyUI çıktıları yalnızca kendi çıktı klasörü içinde ve beklenen uzantılarda kabul edilir.
- Eklenen görsel, video ve belgelerde boyut sınırları vardır. Bu sınırlar kötü amaçlı dosyaların
  bellek veya disk tüketimini azaltır; model üretiminin kendisini sınırlamaz.

## Ses dökümü (Whisper + ses olayları)

Sohbete eklenen ses dosyası ya da mikrofon kaydı otomatik yazıya çevrilir. Hat
`agent/transcriber/` paketindedir ve `venv\asr` içinde çalışır:

- **Konuşma:** `faster-whisper` **large-v3** (Türkçe için `oguzhangokboru/whisper-large-v3-tr`).
  Silero VAD konuşma dışı aralıkları Whisper'a hiç vermez; `condition_on_previous_text=False` ve
  `no_speech`/`log_prob`/`compression_ratio` eşikleri ile düşük sıcaklık yedeği halüsinasyonu azaltır.
- **Konuşma dışı sesler:** AST (`MIT/ast-finetuned-audioset-10-10-0.4593`) olayları Türkçe etikete
  çevirir (ayak sesleri, kapı, alkış…). Speech etiketleri elenir. Varsayılan **açık**; mikrofon
  menüsündeki **"Konuşma dışı sesler"** onay kutusuyla kapatılır (`api.json → audioEvents`).
- **Konuşmacı ayrımı:** pyannote (HF token gerekir; yoksa atlanır).
- **Çıktı** kronolojik ve zaman damgasızdır: `(ayak sesleri)` / `Konuşmacı: ...` satırları.
- **Profiller (tier):** `config.py` artık tier'ı **seçili dil-modeli profiline** göre seçer
  (`select_profile_for`): **pro** (MAX/FLASH) → `float16`, modeller aynı anda; **lite** →
  `int8_float16`, modeller sırayla ve uzun kayıtlar 30 dk'lık parçalara bölünür
  (`torch.cuda.empty_cache()` ile her model iş bitince boşaltılır). Eski donanım adları
  (`pc1`/`pc2`) ve arayüz adları (`max`/`flash`) takma addır (`TIER_ALIASES`). Toplam VRAM
  yalnızca profil adı verilmezse (CLI, `--profile` yok → `select_profile`) yedek ölçüttür
  (≥ 14 GB → pro, aksi halde lite).
- **CPU / GPU seçimi:** GPU'da dökum, yerel dil modelinin VRAM'den boşaltılıp geri yüklenmesini
  gerektirir (swap). Cihaz/swap kararı tier adına göre değil, ses işi başlarken **ölçülen gerçek
  boş VRAM + sistem RAM'i ve kaydın süresine** göre verilir (`choose_plan`): Whisper + AST dil
  modeliyle birlikte boş VRAM'e sığarsa GPU (swap yok); sığmazsa ve kayıt eşikten kısaysa CPU
  (swap yok); aksi halde GPU + mecburi swap. Eşik **pro ~20 sn**, **lite ~15 sn**
  (`agent/transcriber/config.py` → `DEFAULT_CPU_MAX_SECONDS` / `Profile.cpu_max_seconds`).
- **Sıcak (kalıcı) işçi:** her ses turunda tekrarlanan sabit maliyet (Python başlatma + `torch`/
  `transformers`/`faster-whisper` importları; ölçüldü ~10 sn, ilk/disk soğukken ~25 sn) oturumda bir
  kez ödenir: `agent/whisper-tools.py --serve` tek bir kalıcı süreç olarak 127.0.0.1'de dinler
  (port/pid `logs\asr-server.json`'da) ve modelleri süreç içinde tutar; `{"action":"unload"}` ses
  modellerini boşaltır (süreç yaşar). Dil modeli VRAM'e geri yüklenmeden önce işçi **durdurulur**
  (kalan CUDA bağlamı ~140 MiB 27B'nin payını yemesin), tur sonunda arka planda yeniden başlar; boşta
  600 sn sonra / uygulama kapanınca kendini bitirir. İşçi ulaşılamazsa döküm tek-atımlık
  `Invoke-PythonTool` yoluna düşer (davranış korunur).
- **HF önbelleği (`HF_HOME`):** ses modelleri (whisper large-v3-tr + AST) kurulum kökünün HF
  önbelleğinde (`tools\hf-home`) durur ve çalışma anında **çevrimdışı** kullanılır; uygulama
  `mamidlabs-desktop.ps1`'de `$env:HF_HOME = <kok>\tools\hf-home` ayarlar ve `agent/mamidlabs-inference.ps1`
  `Get-HfHome`'u hem tek-atımlık `Invoke-PythonTool`'a (çocuk süreç ortamı) hem kalıcı
  `Start-AsrServerProcess`'e geçirir. Ayarlanmazsa işçi VARSAYILAN HF önbelleğine düşer, AST orada
  bulunmaz; `events.tag()` yüklemeyi `try/except` ile koruduğu için döküm yine tamamlanır ama
  **olaylar atlanır** (boş liste). AST'nin gerçekten çalışması `HF_HOME`'a bağlıdır (kurulumla aynı
  yol).

## Düzeltmeleri doğrulama

Python bulunan bir ortamda:

```sh
python -m pip install pytest
python -m pytest -q -rs
```

`tests/conftest.py` kurulu MamidLabs'i (`MAMIDLABS_ROOT`, yoksa `%LOCALAPPDATA%\Programs\MamidLabs`) bulursa
PATH'te `pwsh` olmasa da gömülü `runtime\pwsh`'u kullanır. `pypdf`/`reportlab` eksikse
`venv\app` paketlerini de ekler (Python sürümü aynıysa). Kaynak depoda yalnızca kurulu
ağaç gerektiren OCR testi atlanır. Kurulum betiği testleri hem PowerShell 7 hem Windows
PowerShell 5.1 ile çalışır.

Davranış testleri gerçek PowerShell fonksiyonlarını ve olay işleyicilerini çalıştırır;
model, GPU ve görsel kontroller yerine test nesneleri kullanır. Sohbet kaydı ve tercih
testleri geçici dosyalarda çalışır. PowerShell olmayan ortamda bu testler atlanır;
atlanan testler başarı sayılmamalıdır.

Windows üzerinde ayrıca şu kontroller gerekir:

1. Bir yanıtın ardından çoklu görsel modunu aç; bildirim zamanlayıcı çalışınca kaybolmamalı.
   Aynı isteği görsellerle gönder ve sohbeti kaydedip yeniden aç.
2. MAX/FLASH ve iki özel GGUF arasında geçiş yap; kutu son seçimi hemen göstermeli,
   yükleme sırasında gönderilen mesaj yalnızca seçilen model hazır olunca başlamalı.
3. Tam erişimi açıp uygulamayı yeniden başlat; ardından kapatıp yeniden başlat.
   Düğme ve gerçek araç onay davranışı kayıtlı seçimle aynı olmalı.
4. İzinli köklerin dışından iki belge ekle; ikisi de okunmalı, eklenmemiş komşu dosya
   reddedilmeli. Geçmiş sohbet çoklu ek listesini ve belge erişimini korumalı.

Bu testler gerçek WinForms render'ı, Windows DPAPI, llama-server, GPU OCR, ComfyUI
ve ücretli API sağlayıcıları için uçtan uca doğrulamanın yerini tutmaz. Bunun için:

```powershell
%LOCALAPPDATA%\Programs\MamidLabs\runtime\pwsh\pwsh.exe -File %LOCALAPPDATA%\Programs\MamidLabs\scripts\smoke-test.ps1 -Profile lite
```

`install-mamidlabs.ps1` yalnızca altyapıyı hazırlar; modeller Profiller menüsünden
ayrıca indirilir. Bu script o adımdan sonra çalıştırılır: gerçek modeli yükler,
gerçek bir istek gönderir, gerçek bir `.docx`/görsel/video üretir ve her bileşenin
gerçekten çalıştığını kanıtlar (`-SkipChat`/`-SkipDocument`/`-SkipImage`/`-SkipVideo`
ile atlanabilir). Sıfırdan farklı çıkış kodu en az bir bileşenin başarısız olduğu
anlamına gelir. RTX 5060 Ti 16 GB'ta görsel adımı 25–58 sn, video adımı ~132 sn sürer. Çıktı
dosyaya yönlendirilebilir; başlatılan `llama-server` ve ComfyUI çağıranın çıktı hattını devralmaz.
Sonuç `logs\smoke-test-son.json` dosyasına da yazılır.

## Bilinen notlar

- ComfyUI loglarındaki `WinError 10022 ... _call_connection_lost` satırları zararsızdır
  (Windows asyncio kapanış gürültüsü).
- `llama-server` yeniden yüklemesi ilk seferde diskten, sonrasında RAM önbelleğinden okur;
  ikinci yükleme belirgin şekilde hızlıdır.
- Türkçe karakter içeren yolları `.ps1` dosyalarına yazmaktan kaçının (PS 5.1 tuzağı);
  bu uygulama PowerShell 7 ile çalışır ama alışkanlık olarak korunur.
- Kurulum betiği temiz makinede Windows PowerShell 5.1 ile çalışır. 5.1 native programlara
  giden argümanlardaki çift tırnakları siler ve 'Stop' tercihiyle stderr yönlendirmesini hataya
  çevirir; betik Python kodunu stdin ile verir ve native çağrıları `Invoke-NativeText` ile yapar.
