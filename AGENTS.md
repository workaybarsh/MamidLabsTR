# MamidLabs · Geliştirici ve yapay zekâ ajanları için altyapı rehberi

Bu dosya MamidLabs üzerinde çalışan geliştiriciler ve yapay zekâ ajanları (Claude, Codex, Gemini,
Copilot…) için tek doğru kaynaktır. Kod tabanının nasıl başlatıldığını, parçaların nasıl
konuştuğunu, nerede ne durduğunu ve bilinen tuzakları anlatır.

> **Zorunlu kural:** Yeni bir özellik eklediğinde, bir davranışı değiştirdiğinde ya da yeni bir
> tuzak bulduğunda **aynı commit'te** bu dosyayı güncelle: ilgili bölümü düzelt ve en alttaki
> [Değişiklik günlüğü](#16-değişiklik-günlüğü)'ne bir satır ekle. Kullanıcıya görünen değişiklikler
> `CHANGELOG.md`'ye de yazılır. Kod ile bu dosya çelişirse kod doğrudur; çelişkiyi fark eden bu
> dosyayı düzeltir.

Kullanıcıyla iletişim dili **Türkçe**dir. Kod yorumları ve PowerShell betiklerindeki metinler
çoğunlukla ASCII Türkçedir (bkz. [Tuzaklar](#14-kritik-tuzaklar)).

---

## 1. Ürün tek paragrafta

MamidLabs, Windows'ta tamamen yerel çalışan çok modlu bir yapay zekâ çalışma alanıdır. Tek bir
WinForms penceresinde sohbet, web araması, belge okuma/üretimi, OCR, görsel anlama, görsel
üretimi, fotoğraf düzenleme ve video üretimi sunar. Dil modeli `llama.cpp` (`llama-server`),
görsel/video modelleri `ComfyUI` üzerinde, kullanıcının NVIDIA ekran kartında çalışır. OpenAI,
Claude, Gemini, DeepSeek ve OpenAI uyumlu özel uçlar isteğe bağlı API sağlayıcılarıdır.
Depo: `github.com/workaybarsh/MamidLabsTR` (İngilizce sürüm: `github.com/workaybarsh/MamidLabsENG`).
Varsayılan kurulum kökü `%LOCALAPPDATA%\Programs\MamidLabs`.

## 2. Depo haritası

| Yol | İçerik |
|---|---|
| `qwen-desktop.ps1` | Ana uygulama: WinForms arayüzü, sohbet durumu, iş başlatma, olay döngüsü |
| `launch-qwen-desktop.vbs` | Masaüstü kısayolunun hedefi; uygulamayı konsolsuz başlatır |
| `agent/qwen-inference.ps1` | Sohbet işçisi: model isteği, akış, araçlar (tool calling), onay, bağlam sıkıştırma |
| `agent/api-providers.ps1` | Sağlayıcı tablosu, istek/yanıt dönüştürücüleri (OpenAI uyumlu ↔ Claude Messages) |
| `agent/api-settings.ps1` | API bağlantıları penceresi, anahtar doğrulama, DPAPI anahtar saklama |
| `agent/media-settings.ps1` | Görsel ve video modelleri penceresi, "Model dosyası seç (dosya yolu)" |
| `agent/hf-settings.ps1`, `agent/hf-hub.py` | Hugging Face token ve indirme işçisi (boyut doğrulamalı) |
| `agent/web-server.ps1`, `agent/web-settings.ps1`, `scripts/web-serve.ps1` | Yerel web yönetimi (tarayıcıdan erişim): HTTP sunucusu, ayar penceresi, başlatıcı. Varsayılan yalnızca localhost, şifre korumalı; OpenCode'un sunucu modeli örnek alındı |
| `agent/imagegen-run.ps1` | Yerel görsel üretimi / düzenleme işçisi (ComfyUI API) |
| `agent/videogen-run.ps1` | Yerel video üretimi işçisi (Wan 2.2) |
| `agent/chart-run.ps1` | Bağımsız grafik üreticisi (gömülü pwsh + System.Drawing; sohbet aracı `generate_chart`) |
| `agent/api-media-run.ps1`, `agent/api-media.py` | API ile görsel/video üretimi, profil indirme işi |
| `agent/media-model-swap.ps1` | Dil modelini boşalt → ComfyUI başlat/yeniden kullan → geri yükle (tek sahip) |
| `agent/media-paths.ps1` | Harici (kopyalanmayan) model yolları, `comfy-extra-models.yaml` |
| `agent/model-registry.ps1` | Model seçim kutusu girdileri, profil alias'ları |
| `agent/profile-catalog.ps1`, `agent/profiles.json` | Profil dosya kataloğu, Profiller penceresi, eksikleri indirme, güncelleme denetimi |
| `agent/process-launch.ps1` | `Start-DetachedProcess`: çocuk süreç stdout borusunu devralmadan başlatma |
| `agent/whisper-tools.py`, `agent/transcriber/` | Ses dökümü (faster-whisper large-v3-tr + AST ses olayları + pyannote konuşmacı ayrımı); işçi `whisper-tools.py` paketi çağırır |
| `agent/qwen-agent-tools.py` | Web araması (ddgs), sayfa okuma, bağlı klasör araçları |
| `agent/office-tools.py` | PDF/Word/Excel/PowerPoint/ZIP/RAR okuma, PDF/DOCX/PPTX üretimi |
| `agent/ocr-tools.py` | PaddleOCR işçisi (GPU görsel, CPU PDF) |
| `agent/media-tools.py` | Video kare çıkarma vb. (PyAV) |
| `agent/workflows/krea2_identity_edit.json` | Fotoğraf düzenleme iş akışı (ComfyUI arayüz biçimi) |
| `scripts/install-mamidlabs.ps1` | Asıl kurulum (aşamalı, sabit sürümler) |
| `scripts/setup-run.ps1` | Sihirbazın arka ucu: ön koşullar → kurulum → modeller → özet |
| `scripts/uninstall-mamidlabs.ps1` | Tam kaldırma (Windows PowerShell 5.1, ASCII) |
| `scripts/manage-qwen.ps1` | `llama-server`'ı profile göre başlat/durdur/değiştir, bellek kapısı |
| `scripts/download-profile.ps1`, `profile-report.ps1`, `configure-models.ps1`, `install-ocr.ps1` | Profil indirme, donanım raporu, kendi model yolları, OCR kurulumu |
| `scripts/smoke-test.ps1` | Gerçek modellerle uçtan uca doğrulama |
| `scripts/diagnose-latency.ps1` | VRAM, önbellek isabeti ve hız teşhisi |
| `packaging/windows/mamidlabs.iss` | Inno Setup kurulum sihirbazı; **sürümün tek kaynağı** (`MyAppVersion`) |
| `requirements/app.txt`, `requirements/imagegen.txt`, `requirements/asr.txt` | Python paketleri (sabit sürümler) |
| `tests/` | pytest; PowerShell fonksiyonlarını gerçek `pwsh` ile de çalıştırır |
| `tests/ui-automation/` | Uygulamayı ve sihirbazı UI Automation/Win32 ile süren yardımcılar |
| `docs/` | `kurulum.md`, `teknik-notlar.md`, `media/` |
| `.github/workflows/` | `testler.yml` (pytest), `kurulum-paketi.yml` (Inno derleme ve sürüm yayımı) |
| `AGENTS.md`, `CLAUDE.md` | Bu rehber; `CLAUDE.md` Claude Code için buraya yönlendirir. Kurulum köküne kopyalanmaz. |

## 3. Kurulum kökü düzeni (`%LOCALAPPDATA%\Programs\MamidLabs`)

```
agent\ scripts\ assets\          program dosyaları (her kurulumda kaynaktan yeniden kopyalanır)
requirements\                    Python paket listeleri (kökten güncelleme komutu buradan okur)
qwen-desktop.ps1 launch-qwen-desktop.vbs README.md LICENSE EULA.txt
runtime\pwsh\pwsh.exe            gömülü PowerShell 7.6.6 (uygulama YALNIZCA bununla çalışır)
llama.cpp\b10998\llama-server.exe CUDA 13.4 yapısı
venv\app\                        uygulama Python'u (araçlar, HF, belge)
venv\imagegen\                   ComfyUI + torch cu130 + PyAV
venv\asr\                        ses dökümü (faster-whisper + transformers/AST + pyannote; torch cu130)
tools\hf-home\                   HF önbelleği (whisper large-v3-tr + AST modelleri burada)
venv\ocr\ venv\ocr-cpu\          PaddleOCR (isteğe bağlı, sihirbazda varsayılan işaretli; install-ocr.ps1)
ComfyUI\                         sabit commit; custom_nodes: ComfyUI-GGUF, comfyui-krea2edit
ComfyUI\models\{diffusion_models,unet,text_encoders,vae,loras}\
models\                          dil modelleri (.gguf + mmproj)
settings\api.json                tüm kullanıcı ayarları (+ şifreli API anahtarları)
settings\comfy-extra-models.yaml kopyalanmadan kullanılan harici model klasörleri
settings\kurulum-kaydi.json      sihirbazın winget ile kurduğu paketler (kaldırıcı okur)
chats\                           sohbetler (DPAPI ile şifreli)
outputs\{images,videolar,belgeler,yedekler,refs,thumbs,input,comfy}\
logs\                            qwen-<profil>.std{out,err}.log, comfyui.*.log, audit.jsonl,
                                 kurulum.log, kurulum-ozeti.txt, kurulum-adim.txt, smoke-test-son.json
tools\pip-cache\                 pip önbelleği (kullanıcı profiline yazılmaz)
tools\indirme\ tools\paddle-cache\ tools\yedek\
kurulum-kaynak\                  sihirbazın açtığı kaynak paket
```

## 4. Başlatma zinciri

1. Masaüstü `MamidLabs.lnk` → `launch-qwen-desktop.vbs` (kökü kendi konumundan bulur).
2. VBS: `runtime\pwsh\pwsh.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File qwen-desktop.ps1`.
3. `qwen-desktop.ps1` başta `Start-ThreadJob` var mı diye bakar. Yanlış host'la (Windows
   PowerShell 5.1) açıldıysa kendini gömülü pwsh ile yeniden başlatır.
4. Modülleri dot-source eder (`api-providers`, `model-registry`, `profile-catalog`, `api-settings`,
   `media-settings`, `hf-settings`, `media-paths`…), `settings\api.json`'u okur, formu kurar.
5. Seçili profil için `manage-qwen.ps1 -Action switch -Profile <p>` çağrılır; bir zamanlayıcı
   `http://127.0.0.1:8080/health`'i yoklar. Hazır olunca durum "Hazır" olur.
6. Uygulama kapanınca (`FormClosing` → `Shutdown-All`) sohbet kaydedilir, `llama-server` ve
   boştaki ComfyUI kapatılır (VRAM boşalır).

## 5. Süreçler ve portlar

| Süreç | Port | Sahibi | Not |
|---|---|---|---|
| `llama-server.exe` | 8080 | `scripts/manage-qwen.ps1` | Mutex `Local\QwenLocalModelControl`; `--alias` ile profil tanınır |
| ComfyUI (`venv\imagegen\Scripts\python.exe ComfyUI\main.py`) | 8188 | `agent/media-model-swap.ps1` | Varsayılan: iş bitince kapatılır (boşta VRAM/RAM tutmaz); `comfyKeepAlive=true` (LITE) ile açık kalır |
| Uygulama | — | `pwsh.exe … qwen-desktop.ps1` | İşçiler aynı süreçte `Start-ThreadJob` runspace'leri |

**Profiller** (`manage-qwen.ps1`, alias'lar `model-registry.ps1` ile birebir aynı olmalı):

| Profil | Alias | Model | Önemli bayraklar |
|---|---|---|---|
| MAX | `qwen3.8-27b-max` | Qwen3.8 27B IQ4_XS + mmproj F16 | `--no-mmproj-offload` (projektör CPU'da), ctx 32768, predict 8192, `--reasoning-effort xhigh`, q4_0 KV, batch 512/256, `--spec-type draft-mtp` |
| FLASH | `qwen3.8-27b-flash` | aynı dosyalar | predict 8192, `--reasoning-effort low`, `--spec-type draft-mtp` |
| LITE | `qwen3.5-9b-lite` | Huihui-Qwen3.5 9B Q5_K_M + mmproj Q8_0 | ctx 32768, predict **8192** (düşünme tokenları çıktı bütçesini paylaştığından 3072 küçüktü), düşünme açık ve **sınırsız** (`--reasoning-budget` verilmez), batch 256/128, projektör CPU'da (`--no-mmproj-offload`), `--spec-type draft-mtp` (indirmede eklenir). Sistem istemi yeterince düşünüp **YANITINI DE YAZMAYI** söyler (düşünmeyi sınırsızca uzatmaya teşvik etmez); zor soruda düşünme bütçeyi yese bile görünür yanıt **düşünme-kapalı kurtarmayla** (`enable_thinking=$false`) garanti edilir |

**MTP (Multi-Token Prediction).** Qwen3.8 27B GGUF'u gömülü bir MTP/nextn draft başlığı taşır
(`qwen35.nextn_predict_layers = 1`, `blk.64.nextn.*`); LITE'ın 9B GGUF'u ise bu başlığı dönüşümde
kaybeder, indirme sırasında `agent/mtp_inject.py` ile geri eklenir (kaynak: `huihui-ai/
Huihui-Qwen3.5-9B-abliterated` MTP tensorleri; yalnızca `blk.<N>.nextn.*` + ana model normlarına
`w+1`). Böylece `--spec-type draft-mtp` **ayrı bir draft model gerektirmez** ve çıktı kayıpsızdır
(kabul edilen tokenlar hedef modelle doğrulanır). Ölçülen: LITE'ta kabul ~0,93 (içeriğe bağlı 0,31–0,96), ~2x hız (36 → ~75
tok/s); model kartında 27B için Q4_K_M kabul 0,35–0,53. Bayrak yalnızca GGUF gerçekten MTP katmanı
taşıyorsa eklenir (`Test-GgufHasMtp`); taşımayan modele verilirse llama.cpp "model doesn't contain MTP
layers" ile açılmaz. `settings/api.json` → `"mtp": false` ile kapatılabilir. MTP olmadan çalışırken
sunucu `unused tensor blk.64.*` uyarısı verir (beklenen).

MAX ve FLASH aynı dosyaları kullandığı için kurulum sihirbazında ve Profiller penceresinde tek
"Qwen3.8 27B" girdisi olarak görünür (`Get-ProfileCatalogForDisplay`); geçiş alt çubuktan yapılır.
Kimliğe göre yapılan aramalar (`Get-ProfileEntry`, `Get-ProfileState`,
`Test-LocalProfileChatFilesPresent`) tam kataloğu (`Get-ProfileCatalog`) kullanmalıdır.

**VRAM kontrolü** (`Test-MemoryBudget`): gereken = model dosyası + **600 MiB**
(LITE'ta 300 MiB); görsel projektör (mmproj) üç profilde de CPU'da (`--no-mmproj-offload`)
olduğundan bütçeye girmez. **ComfyUI yaşam döngüsü (varsayılan: yalnızca üretimde çalışır):** ComfyUI
**yalnızca görsel/video üretimi sırasında** çalışır; iş bitince ve dil modeli yüklenmeden önce
kapatılır — böylece **boşta ne VRAM ne de RAM tutar** (boşta ComfyUI ~300 MiB CUDA bağlamı + süreç
RAM'i tutuyordu; `comfyKeepAlive` varsayılanı `false`). Medya gerektiğinde yeniden açılır (~27 sn).
- **Yerel mod (MAX/FLASH):** 27B kartın sınırında olduğundan dil modeli yüklenmeden önce ComfyUI
  **her zaman** kapatılır (aksi halde MTP draft bağlamı CPU'ya taşıp sohbet aralıklı ~6-7 tok/s'ye
  düşer; ölçüldü: "medya sonrası geçiş" bir kez oran 0,18).
- **Yerel mod (LITE):** 9B ComfyUI ile birlikte çalışabilir (ölçüldü oran 1,04); medya işleri
  arasında açık tutmak isteyen `settings/api.json` → `comfyKeepAlive=true` yazar (o zaman boşta
  ~300 MiB VRAM + RAM tutar, karşılığında ~27 sn yeniden açılma olmaz).
- **API modu:** Yerel model çalışmadığı için (GPU boş) medya işi bitince ComfyUI **açık kalır**
  (VRAM çakışması yok, yeniden açılma olmaz).
Bir **kaçak/mükerrer** ComfyUI örneği her profilde önce temizlenir: ComfyUI bir süreç **çiftidir**
(venv başlatıcı + base python çocuğu), bu yüzden süreç **sayısı** ile kaçak kararı verilemez — tek
sağlıklı örnek zaten 2 süreçtir. Örnekler, parent'i ComfyUI eşleşmeyen **kök** süreçlerle sayılır
(`Get-ComfyInstanceRoots`); `Stop-ComfyLeaks` yalnızca ek kökleri kapatır ve **:8188'i dinleyen tek
örneği korur** (`Test-ComfyUnderRoot`). Ölçüm: iki ComfyUI örneği varken 27B taşıp **0,89 tok/s**.
Bütçe yetmezse ComfyUI kapatılıp yeniden ölçülür (güvenlik ağı). Açık temizlik için `manage-qwen.ps1`
`-Action closecomfy`. ComfyUI'yi yeniden açmanın maliyeti medya işi başına ~27 sn
(ölçüldü: soğuk 55 sn, sıcak 28 sn).
Ölçüm: temiz GPU'da 15244 MiB boş iken 27B model yüklendi ve ~45 tok/s
ile çalıştı (dosya 14.600 MiB → gerçek pay ~600 MiB). Önceki denemelerdeki 800/1000 MiB paylar (eşik
15400/15600) bu çalışan durumu yanlış reddedip jenerik "Model işlemi başarısız" hatası veriyordu.
Tolerans profile göredir: **LITE 1024 MiB** (9B MTP modelinin 8 GB karttaki küçük aşımı;
llama.cpp büyük gömme tensorünü CPU'da tutar), **MAX/FLASH 0** (27B kartın sınırında; küçük bir
aşım bile felaket). Ölçüm: 27B tam sığdığında ~44–58 tok/s, LITE ~97 tok/s.

## 6. Sohbet isteğinin akışı

1. Kullanıcı gönderir → `Begin-Generation` (`qwen-desktop.ps1`).
2. `Build-JobMessages`: sabit sistem istemi (`Get-SystemPrompt`) + geçmiş. Eski turlardaki görsel
   verisi atılır, yerine not konur. Tura özel ipuçları (`Get-TurnHints`) sistem istemine değil,
   **son kullanıcı mesajının başına** eklenir; böylece llama-server'ın KV önbellek öneki bozulmaz.
3. `Start-ThreadJob -FilePath agent\qwen-inference.ps1 -ArgumentList $jobData, $sharedRequest`.
   `$jobData.root` kökü **açıkça** taşır (bkz. tuzak 2).
4. İşçi `Emit` ile `[pscustomobject]@{kind; text; usage; data}` olayları üretir. Arayüz
   zamanlayıcısı bunları okur. Türler: `thinking`, `answer`, `answer-rewrite`, `status`, `metrics`,
   `tool`, `artifact`, `chart`, `ocr`, `imagegen`, `videogen`, `compact`, `denied`, `cancelled`,
   `error`, `done`.
5. **Araçlar** (`qwen-inference.ps1`): `search_web`, `fetch_page`, `read_document`,
   `read_images_ocr`, `create_document`, `generate_image`, `generate_video`, `generate_chart`,
   `find_reference_image`, `ask_model`, `list_bound_files`, `read_bound_file`, `write_bound_file`,
   `run_command`. Araçlar niyete ve çiplere (İnternet, Ajan) göre tanımlanır. Üretim
   araçları (görsel/video/belge/grafik) yalnızca kullanıcı açıkça istediğinde
   çalışır: `generate_image` gibi hepsi **çağrı anında niyet denetimiyle** korunur
   (`Test-*-RequestIntent`); güncel bilgi isteyen bir turda web erişimi yoksa modelin
   metni **kullanılmaz** ve `Get-FinalAnswer` dürüst bir mesaj gösterir; `read_document`
   yalnızca belge bağlamı varsa sunulur.
6. **Onay:** Yazma/çalıştırma araçları `Request-Approval` ile `$Shared.AskTool/AskDetail/AskId`
   yazar. Arayüz "İzin gerekiyor — <araç>" penceresini açar (10 dk zaman aşımı → red). "Tam erişim"
   çipi açıksa sorulmaz. Reddedilince arayüz modelden bağımsız "İşlem yapılmadı" notu ekler.
   Aynı istekte reddedilen (ya da zaman aşımına uğrayan) araç bir daha sorulmaz, doğrudan
   reddedilir. Sonraki model çağrısına yalnızca istek kopyasında "[Sistem notu] … REDDETTİ" diye bir
   kullanıcı notu eklenir; küçük modeller araç sonucundaki talimatı atlayabildiği için not şart.
7. **`done` olayı** son metinle birlikte o turda eklenen `assistant.tool_calls` ve `tool`
   mesajlarını da taşır. Arayüz bunları `$chatMessages`'a kalıcı ekler. Bu yapılmazsa sonraki turda
   istemcinin öneki sunucununkinden farklı olur ve bağlam baştan işlenir (tuzak 5).
8. Bağlam eşiği aşılınca ayrı bir sıkıştırma işi (`$script:compactJob`) özet çıkarır.

## 7. Görsel, fotoğraf düzenleme ve video

- Model `generate_image` çağırınca işçi `imagegen` olayı yayar. Arayüz `Start-ImageGeneration`
  ile `agent\imagegen-run.ps1`'i başlatır. Dil modeli yalnızca istemi yazar.
- `media-model-swap.ps1`: `Stop-LocalModelForMedia` → `Start-OrReuseComfy` → üretim →
  `restoreProfile` ile dil modelini geri yükle. LITE'ta ComfyUI `--lowvram` ve Krea-2 GGUF kullanır.
  - `Release-Comfy` üretimden sonra `/free` ile modelleri boşaltır; **torch sayacı sıfırlansa bile
    gerçek boş VRAM'i (`nvidia-smi`) doğrular** ve geri yüklenecek modele yetmiyorsa (MAX/FLASH
    14000 MiB, LITE 6000 MiB) ComfyUI'yi kapatır. Aksi halde CUDA bağlamı VRAM tutarken başlayan
    dil modeli paylaşılan belleğe taşınır ve sohbet ~6 tok/s'ye düşer.
- **Modlar** (`generate_image.mode`):
  - `yeni`: metinden üretir. Krea-2 Turbo, 8 adım, cfg 1.
  - `yeniden_uret` / `stil_referansi`: eklenen görselden yola çıkar.
  - `kimlik_duzenle`: Krea 2 Identity Edit v1.2 LoRA (`krea2_identity_edit_v1_2.safetensors`) ve
    `comfyui-krea2edit` düğümleriyle çalışır; kişinin yüzü korunur. **Yalnızca MAX/FLASH (16 GB+)**;
    LITE'ta sunulmaz (bkz. bölüm 13), fotoğraf düzenleme isteği `yeniden_uret`e yönlendirilir
    (`agent/qwen-inference.ps1` `$job.imageProfileLite`; `agent/profiles.json` LITE'ta LoRA yok).
  - `kimlik_duzenle` + `scene_from_previous=true`: önceki görsel sahne, son görsel kişi olur.
- Düzenleme isteminde model kullanıcının Türkçe isteğini tek cümlelik İngilizce talimata çevirir.
  Araç açıklamasında **somut örnek yoktur**; örnekler belirsiz isteklerde modeli yönlendirir.
- Gerçekçilik LoRA'sı yalnızca istek gerçekçilik niyeti taşıyorsa yüklenir. ComfyUI'nin Krea2
  LoRA anahtar öneki sorunu çalışma anında `Repair-LoraKeyPrefix` ile düzeltilir.
- Video: `videogen-run.ps1`, Wan 2.2 TI2V 5B; modlar `metin`, `gorsel`, `video` (son kareden
  devam). VAE parça parça çözülür: `VAEDecodeTiled` `tile_size=320, overlap=80, temporal_size=16,
  temporal_overlap=8`. Daha küçük değerler parça sınırı izleri bırakır.
- API medya: görsel/video sağlayıcısı API ise `api-media-run.ps1` → `api-media.py`.
- Harici model dosyaları kopyalanmadan kullanılır: `settings\comfy-extra-models.yaml` →
  ComfyUI `--extra-model-paths-config`.

## 8. API sağlayıcıları

- Tek tablo: `Get-ChatProviders` (`agent/api-providers.ps1`): `openai`, `claude`, `gemini`,
  `deepseek`, `custom`. Her satırda uç adresi, model listesi adresi, anahtar sayfası, ortam
  değişkeni ve `vision` alanı var. Yeni sağlayıcı = tabloya bir satır (OpenAI uyumlu değilse
  dönüştürücü de).
- **`custom` ("Özel (OpenAI uyumlu)"):** kullanıcının kendi OpenAI uyumlu ucu (Ollama, LM Studio,
  vLLM, kurum içi proxy vb.). Taban adres API bağlantıları penceresinden okunur
  (`settings\api.json` → `providers.custom.baseUrl`, `Get-CustomBaseUrl`); `{taban}/chat/completions`
  ve `{taban}/models` üretilir. **Anahtar isteğe bağlıdır**; boşsa `Authorization` başlığı
  gönderilmez. Bu yüzden `custom`, anahtar zorunlu kontrollerden muaftır (`qwen-desktop.ps1`'de üç
  yer, `qwen-inference.ps1`'de `Invoke-AskModel` ve ana istek döngüsü; `-and $providerId -ne 'custom'`).
- `Convert-ProviderRequest` / `Convert-ProviderChunk`: OpenAI chat biçimini Claude Messages API'ye
  ve geri çevirir. DeepSeek görsel kabul etmez; `image_url` parçaları metin notuna indirilir.
- **Claude:**
  - `thinking` alanı **gönderilmez**; Opus 5.5 ve Fable 5/5.1 `disabled` değerini 400 ile reddeder.
  - Zorunlu `tool_choice` her zaman `auto` olarak gider.
  - `max_tokens` alt sınırı 16000'dir.
  - Araç döngüsünde imzalı `thinking` blokları `Add-ClaudeReplayChunk` ile toplanır ve
    `$script:ClaudeReplay[ilk tool_use id]` üzerinden sırası bozulmadan geri gönderilir.
  - Bu kayıt yalnızca bellekte tutulur; diske ve diğer sağlayıcılara gitmez.
- Anahtarlar `settings\api.json` → `providers.<id>.key` alanında `ConvertTo-SecureString` (DPAPI,
  Windows hesabına bağlı) olarak durur. `ask_model` aracı yerel modelin başka bir sağlayıcıya
  soru sormasını sağlar.
- API akışları sahte yanıtlarla test edilir; gerçek API anahtarıyla uçtan uca test henüz yapılmadı.

## 9. Profiller, katalog ve indirme

- `agent/profiles.json`: her profil için dosya listesi. Her satırda `target` (köke göreli),
  `repo`, `revision` (commit sabit), `filename`, `bytes` alanları var. `repo` boş satır "elle
  kurulmalı" sayılır; şu an böyle bir satır yok.
- 27B dil modeli ve mmproj: `windowsxp811203/Qwen3.8-27B-Abliterated-GGUF@efb07ba`.
  Identity Edit: `conradlocke/krea2-identity-edit@89e9e7a`.
- İndirme boyutları: LITE ~36 GB, Qwen3.8 27B (MAX/FLASH) ~52 GB.
- `hf-hub.py` indirir ve boyutu `bytes` ile doğrular; eksik dosya kaldığı yerden sürer.
  `HF_HOME` kökün altındadır.
- Profil durumu yalnızca dosyanın varlığına bakar, boyut karşılaştırmaz.
- **Profil silme** (Profil yöneticisi → "Profili sil"): yalnızca o profile ÖZEL dosyalar
  silinir (`Get-ProfileUniqueTargets`); başka profillerle paylaşılanlar korunur. LITE'ın
  Krea-2 GGUF dışındaki medya dosyaları MAX/FLASH ile ortaktır. MAX ve FLASH aynı dosya
  kümesini kullandığından takma ad sayılır; birini silmek diğerini de kaldırır. Etkin profil
  siliniyorsa önce `Stop-LocalQwen` çağrılır, sonra `Update-ProviderSelection` ile liste
  tazelenir. Ölçülen: LITE ~14 GB, MAX/FLASH ~29 GB.

## 10. Kurulum, sihirbaz, güncelleme ve kaldırma

- `install-mamidlabs.ps1 -Profile <p> [-Root] [-Stage a,b] [-SkipMedia] [-SkipAudio] [-AppVersion] [-Force] [-NoUninstallEntry]`.
  Aşamalar sırasıyla: `preflight`, `layout` (program dosyaları, kısayol, Windows kaldırma kaydı),
  `runtime`, `llama`, `python`, `asr` (ses dökümü ortamı, `venv\asr`; `-SkipAudio` ile atlanır),
  `comfyui` (sabit commit'lere getirir, yerel değişiklikleri
  `tools\yedek\*.patch`'e alır), `verify`. Uygulama açıksa `layout` durur, çünkü dosyalar kilitli
  olur. Paket boyutları doğrulanır. `-Root` varsayılanı `%LOCALAPPDATA%\Programs\MamidLabs`.
  `layout`, Inno ile kurulmuş bir kökte varsa `kurulum-kaynak` (sihirbazın açtığı kaynak paketi;
  iptal/geri alma ve yeniden kurulum için) da tazeler; betik kurulumunda oluşturmaz.
  `layout` ayrıca sahip olduğu program klasörlerini (`agent\`, `scripts\`, `assets\`, `requirements\`)
  **kopyalamadan önce boşaltır**: repodan silinen dosyalar güncellemede geride kalmaz (Inno
  `ignoreversion` / `Copy-Item -Force` eski dosyayı silmez). `agent\__pycache__\*`, `*.pyc` ve
  `assets\installer\*` .iss ile aynı biçimde dışarıda bırakılır. `requirements\` artık kökte de
  bulunur; böylece `-Source` verilmeden (kurulu kopyadan) çalıştırılan güncelleme komutu
  bağımlılıkları bulur. Kaldırma kaydına `DisplayVersion` yazılır (değer, verilmezse kaynak
  paketteki `.iss` `MyAppVersion`'dan okunur; `-AppVersion` ile geçersiz kılınabilir) ve bu köke
  işaret eden bir Inno `{AppId}_is1` kaydı varsa ikinci bir `MamidLabs-<hash8>` kaydı **açılmaz**
  (mükerrer girdi olmaz).
- Sabit sürümler: PowerShell 7.6.6, llama.cpp b10998 (CUDA 13.4), ComfyUI `b0f4b7b`, ComfyUI-GGUF
  `6ea2651`, comfyui-krea2edit `86f886d`, torch cu130.
- Disk eşikleri (`profile-report.ps1` ve `install-mamidlabs.ps1`, birebir aynı): LITE 58 GB,
  FLASH/MAX 75 GB boş alan; eksikse profil "sınırda" sayılır.
- `setup-run.ps1`'in "Ön koşullar" adımı Python ve Git'e ek olarak **7-Zip** (`7zip.7zip`; RAR
  açma, `office-tools.py` `%ProgramFiles%\7-Zip\7z.exe`'yi arar) ve **Visual C++ Redistributable
  2015-2022 x64** (`Microsoft.VCRedist.2015+.x64`; `vcruntime140.dll` kontrolü) kurar. Bu ikisi
  eksik kalırsa kurulum durmaz, not düşülür. Kurulan paketler `settings\kurulum-kaydi.json`'a yazılır.
- Sihirbaz (`mamidlabs.iss`) sayfaları: karşılama → lisans → klasör (varsayılan
  `{autopf}\MamidLabs`, `PrivilegesRequired=lowest`) → profil raporu → profil → (kendi modellerin)
  → (API) → (görevler) → hazır → kurulum → özet → bitiş.
  - "Kur"dan sonra `setup-run.ps1 -FromWizard` gizli (`SW_HIDE`) çalışır, `ewNoWait` ile başlatılır
    ve sihirbaz `PumpMessages` ile kendi mesaj kuyruğunu pompalar (tuzak 20).
  - İlerleme: `setup-run.ps1` her adımda `logs\kurulum-adim.txt`'e 3 satır yazar (adım no /
    toplam / adım adı); sihirbaz `UpdateInstallProgress` ile bunu 200 ms'de bir okuyup
    `FilenameLabel` ve ilerleme çubuğunu günceller.
  - Bitiş: `setup-run.ps1` başta `logs\kurulum.pid` yazar, sonda (başarı/hata/istisna, `trap` dahil)
    `logs\kurulum-tamam.flag` yazar (birkaç denemeyle). Sihirbaz bayrağı bekler; ~2 sn'de bir
    `ProcessIsRunning` ile sürecin yaşayıp yaşamadığını da denetler.
  - İptal: kurulum sürerken Inno'nun İptal düğmesi yerine `CustomCancelButton` gösterilir (tuzak 20).
    Onaylanırsa `taskkill /PID <pid> /T /F` → `uninstall-mamidlabs.ps1 -Yes -FromWizard` →
    `ExitProcess(1)`.
  - Özet `logs\kurulum-ozeti.txt`'ten gösterilir; tüm çıktı `logs\kurulum.log`'dadır.
- **Sürüm ve yayım:** sürümün tek kaynağı `packaging/windows/mamidlabs.iss` içindeki
  `MyAppVersion`'dır (Anlamsal Sürümleme, `MAJOR.MINOR.PATCH`). `kurulum-paketi.yml` her push/PR'da
  sihirbazı derleyip artifact yükler. Bir `v*` etiketi itildiğinde etiketin `.iss` sürümüyle aynı
  olduğunu doğrular, `CHANGELOG.md`'deki `## [x.y.z]` bölümünü sürüm notu yapar ve
  `MamidLabs_Setup.exe`'yi GitHub Release'e yükler. Yeni sürüm: `.iss` sürümünü artır, CHANGELOG'a
  bölüm ekle, `v<sürüm>` etiketini it.
- **Uygulama içinden güncelleme:** Profiller penceresinde "Bu profile geç"in yanında "Güncellemeleri
  denetle" düğmesi (`agent/profile-catalog.ps1` `Test-MamidLabsUpdateAvailable`,
  `Get-InstalledMamidLabsVersion`). GitHub `releases/latest` sürümünü, Inno'nun kaldırma kaydındaki
  (`{AppId}_is1\DisplayVersion`) yerel sürümle karşılaştırır. Inno kaydı yoksa (betik tabanlı
  kurulum) betiğin yazdığı `MamidLabs-<hash8>` kaydındaki `DisplayVersion`'a, `InstallLocation`/
  `DisplayName` ile bu kuruluma ait olduğu doğrulanarak düşülür. Üç hâlli: boşta → denetle →
  güncelleme varsa "Şimdi güncelle" (kurulum dosyasını `%TEMP%`'e indirir, boyutunu doğrular,
  başlatır ve **ana pencereyi kapatır**, tuzak 21); yoksa "Güncelsiniz" ya da hata metni, 3 sn
  sonra kendini sıfırlar. Sonuç ayrıca pencerenin durum satırına yazılır. Yerel sürüm okunamazsa
  güncelleme var sayılır. Aynı sihirbaz, aynı `AppId` ve `UsePreviousAppDir` sayesinde mevcut
  klasörü günceller; `settings\`, `chats\` ve modeller korunur.
- Masaüstü kısayolu: `MamidLabs.lnk` başka bir köke işaret ediyorsa ona dokunulmaz; bu kurulum
  için `MamidLabs (<klasör>).lnk` açılır.
- **Kaldırma:** Ayarlar → Uygulamalar → MamidLabs ya da
  `powershell -File <kök>\scripts\uninstall-mamidlabs.ps1 [-DryRun] [-KeepUserData] [-KeepPrerequisites] [-PurgeSharedCaches] [-Yes]`.
  - Önce kökten çalışan süreçleri durdurur.
  - Kökteki bilinen girdileri, bu köke işaret eden `MamidLabs*.lnk` kısayollarını, bu köke ait
    Uninstall kayıtlarını ve kayıttaki winget paketlerini siler.
  - Kök dışındaki dosyalara dokunmaz. Sistem ve kullanıcı klasörlerinde çalışmayı reddeder.
  - Sihirbazın kaldırıcısı betiği `-Yes -FromWizard` ile çağırır.

## 11. Ayarlar ve kullanıcı verisi

- `settings\api.json` (uygulama bellekte tutar, değişince ve çıkışta yazar; **uygulama açıkken
  elle düzenleme ezilir**):
  - Model seçimi: `selected`, `selectedModel`, `selectedLocalModel`, `localProfile`.
  - Sağlayıcılar: `providers.<id>.{key, model, models, contextLimit, baseUrl}`.
  - Kendi modellerin: `localModels`, `imageLocalModel`, `videoLocalModel`, `imageProvider`,
    `videoProvider`, `externalMediaModels`.
  - Arayüz: `uiPreferences.{internet, agent, accessMode}`, `firstRunApiSettings`.
  - LITE ayarları: `liteModel`, `liteContext`.
  - Medya: `comfyKeepAlive` (varsayılan `false`; ComfyUI yalnızca medya üretiminde çalışır, boşta VRAM/RAM tutmaz; `true` ile LITE'ta medya işleri arasında açık kalır, bkz. bölüm 5).
  - Ses: `audioEvents` (varsayılan `true`; mikrofon menüsündeki **"Konuşma dışı sesler"** onay kutusu. İşaretli ise AST ile konuşma dışı olaylar döküme eklenir; işaret kaldırılırsa yalnızca Whisper konuşması yazılır).
- Sohbetler `chats\` altında `MAMIDLABS-CHAT-DPAPI-V2` önekiyle şifreli.
- Geçmiş sohbetler penceresindeki **"Tümünü Sil" o an AÇIK olan sohbeti silmez**: ekranda duran
  sohbetin dosyası silinecekler kümesinden çıkarılır (`Get-DeletableChatPaths`), açık sohbet
  geçmişte kalır.
- `logs\audit.jsonl`: araç çağrıları kaydı (içerik değil; yol/komut kimliği).

## 12. Testler

```powershell
python -m pip install pytest -r requirements\app.txt
python -m pytest -q          # ~450 test (455 toplanır; 451 geçti, 4 atlandı), ~185 sn; ek ayar gerekmez (tests/conftest.py)
%LOCALAPPDATA%\Programs\MamidLabs\runtime\pwsh\pwsh.exe -NoProfile -ExecutionPolicy Bypass -File %LOCALAPPDATA%\Programs\MamidLabs\scripts\smoke-test.ps1 -Profile flash -SkipVideo
```

- **`conftest.py`:** PATH'te `pwsh` yoksa kurulu MamidLabs'in (`MAMIDLABS_ROOT` ya da
  varsayılan kök) gömülü pwsh'unu PATH'e ekler; `venv\app` paketlerini `sys.path`'e alır.
  Birçok test PowerShell fonksiyonlarını AST ile çıkarıp gerçek pwsh'ta çalıştırır. PowerShell 7
  yoksa bu testler atlanır; atlanan test başarı sayılmaz.
- `test_uninstall.py` sahte bir kökte gerçekten siler; Windows PowerShell 5.1 kullanır.
- **Smoke testi adımları:** `sohbet`, `belge`, `grafik` (`-SkipChart`), `cevrimdisi` (ağ yokken web aracı çökmeden hata
  JSON'u döndürür), `ag_gecisi` (ağ açık/kapalı değişirken hiçbir tur hata vermez), `gecmis_devam`
  (sohbeti kaydet → yeniden yükle → devam et; hata yok), `mtp` (sunucu `draft-mtp` ile başlatıldıysa
  `/completion` yanıtının `timings.draft_n_accepted` değeri >0 olmalı; 0 ise başlık işlevsizdir;
  `-SkipMtp` ile atlanır), `ocr`, `gorsel`, `duzenleme`,
  `medya_sonrasi_gecis` (görselden sonra hız oranı ≥ 0,7 olmalı), `video`, `arayuz_sohbet` (gerçek
  pencereyi kullanıcı gibi sürer: yazı kutusuna yazar + Gönder'e basar, yanıt gelmeli), `arayuz` (gerçek
  masaüstü uygulamasını başlatır; pencere + model hazır olmalı, arayüzün kullandığı gerçek işçiyle
  bir tur atıp "sunucu kapatıldı"/watchdog metni olmadan yanıt üretmeli ve MTP çalışmalı;
  `-SkipUi` ile atlanır). `arayuz` en sonda çalışır çünkü uygulama kapanınca sunucuyu durdurur.
  Sesli giriş (ses dökümü) `/completion` ile değil, gerçek işçide `transcript` olayıyla ve
  `tests/test_transcriber.py` ile doğrulanır. Motor **faster-whisper large-v3-tr** + AST ses
  olayları; `agent/whisper-tools.py` işçisi `agent/transcriber/` paketini çağırır ve `venv\asr`
  (torch cu130 + faster-whisper + transformers + pyannote) içinde çalışır. Çıktı kronolojik ve
  zaman damgasızdır: `(ayak sesleri)` / `Konuşmacı: ...` satırları.
- **CI:** her push/PR'da `testler.yml` (windows-latest, Python 3.12); paketle ilgili yollar
  değişince `kurulum-paketi.yml`. `master`'a PR ile birleştirilir.

## 13. Donanım gerçekleri (ölçülmüş)

| | 16 GB (RTX 5060 Ti) FLASH | 8 GB (RTX 4060 Laptop) LITE |
|---|---|---|
| Sohbet | ~42–58 tok/s (MTP açık) | ~97 tok/s (16 GB'ta MTP ile) |
| Görsel (`yeni`), uçtan uca | 60–95 sn | 68–139 sn |
| Görselden yeniden üretim (`yeniden_uret`) | ölçülmedi | ~110–140 sn |
| Fotoğraf düzenleme (`kimlik_duzenle`) | 74–160 sn (tek/iki görsel) | **desteklenmiyor** |
| Medya sonrası geçiş | oran 1,01, 319 MiB boş VRAM | oran 0,99–1, 310–369 MiB boş VRAM |

Masaüstü uygulamaları VRAM tutar: NVIDIA Overlay ~1,45 GB, dwm ~0,8 GB ölçüldü. Süreç başına VRAM
için `Get-Counter '\GPU Process Memory(*)\Dedicated Usage'` kullanılır; `nvidia-smi` WDDM'de süreç
belleğini göstermez.

**8 GB'ta `kimlik_duzenle` neden yok:** Düz üretimde metin/görsel kodlayıcı (Qwen3-VL 4B, ~5 GB)
önce çalışıp VRAM'den atılır, sonra difüzyon modeli (LITE'ta GGUF Q4_K_M, ~7,5 GB) tek başına
yüklenir. `Krea2EditGroundedEncode` ise görseli aynı grafikte ikisine birden verdiği için ComfyUI
ikisini aynı anda VRAM'de tutmaya çalışır: 5 + 7,5 GB > 8 GB, `--lowvram` ~2 GB'ı CPU'ya taşır ve
iş 641–884 sn sürer (16 GB'taki sürenin 5–8 katı). Küçük LoRA (r64) da çözmez (641 sn). Bu yüzden
LITE'ta mod hiç sunulmaz, `imagegen-run.ps1` ikinci savunma olarak reddeder ve katalogda LoRA yoktur.

## 14. Kritik tuzaklar

1. **Uygulama yalnızca gömülü PowerShell 7 ile çalışır.** `Start-ThreadJob` 5.1'de yok. Yanlış
   host'la açılırsa sessizce "İstek başlatılamadı"da kalır; `qwen-desktop.ps1` bu yüzden kendini
   yeniden başlatır.
2. **`Start-ThreadJob -FilePath` içinde `$PSScriptRoot` boştur.** İşçiler kökü `$JobData.root`
   üzerinden alır (`Get-InstallRoot`). İşçiye yeni yol eklerken sabit yol yazma; bunu
   `test_install_root_portability.py` yakalar.
3. **Windows PowerShell 5.1 BOM'suz `.ps1`'i ANSI okur.** Türkçe karakterli 5.1 betikleri
   UTF-8 **BOM'lu** kaydet ya da ASCII tut. `uninstall-mamidlabs.ps1` bu yüzden ASCII'dir ve bunu
   test eder. pwsh 7 dosyaları da BOM'ludur; düzenlerken BOM'u koru.
4. **5.1'de native komutun stderr'i** (git'in "From https://…" satırı gibi) `NativeCommandError`
   olarak kırmızı görünür. Zararsızdır, ama `$ErrorActionPreference='Stop'` ile betiği durdurabilir.
5. **KV önbellek eşleşmesi:** Arayüzün sakladığı mesaj dizisi, sunucunun o turda gerçekten
   işlediğiyle bayt bayt aynı olmalı. Araç çağrısı/sonucu saklanmazsa ya da sistem istemi tura
   göre değişirse bağlam her turda baştan işlenir (40+ sn, bağlantı kopması). Tura özel metni son
   kullanıcı mesajına koy.
6. **`Start-DetachedProcess` kullan.** `Start-Process -Redirect…` çağıranın stdout borusunu
   devralır ve `manage-qwen | …` asılı kalır.
7. **VRAM payı profile göre küçük tutulur** (MAX/FLASH 600 MiB, LITE 300 MiB). Büyük pay 16 GB
   kartta MAX'ı hiç açtırmaz. **ComfyUI** varsayılan olarak yalnızca medya üretiminde çalışır (boşta ne VRAM ne RAM tutar) ve dil modeli yüklenmeden önce kapatılır; LITE'ta `comfyKeepAlive=true` ile medya işleri arasında açık tutulabilir. Kaçak/mükerrer örnek her profilde önce temizlenir (ComfyUI bir süreç çiftidir; örnek **sayısı** değil **kökleri** belirleyicidir).
   Kaçak örnek 27B paylaşılan belleğe taşıp 0,89 tok/s'ye düşer. MAX/FLASH'ta mmproj CPU'da
   (`--no-mmproj-offload`). GPU'ya alınırsa ~420 MiB paylaşılan belleğe taşar ve hız 25'ten
   19 tok/s'ye düşer.
8. **Tek görsel kuralı:** Sohbete aynı anda yalnızca bir görsel gider (çoklu görsel yalnızca
   "çoklu görsel okuma modu"nda OCR ile).
9. **UI Automation ile test:** Modal pencere açan bir menü öğesine UIA `Invoke` pencere kapanana
   kadar döner ve uygulamanın UIA sağlayıcısını kilitleyebilir. Modal açan düğmeler için Win32
   `PostMessage(BM_CLICK)`, menüler için klavye kullan. Inno Setup düğmeleri UIA'da `Pane`'dir.
10. **`settings\api.json`'u uygulama açıkken elle değiştirme;** çıkışta bellekteki kopya yazılır.
11. **`$input` ve `$args`** PowerShell otomatik değişkenleridir; yerel değişken adı olarak kullanma.
12. **Sıralı sözlükte (`[ordered]@{}`) tamsayı anahtar** konum olarak yorumlanır; tamsayı anahtar
    için düz `@{}` kullan.
13. **`$env:TEMP` kısa yol** (`BUYUKA~1`) döndürebilir; yol karşılaştırmalarında `GetFullPath` kullan.
14. **`run_command` komutu `cmd.exe /c` argümanı olarak vermez.** .NET'in argv tırnak kaçışı (`\"`)
    cmd.exe'nin ayrıştırmasıyla uyuşmaz; iç içe tırnaklı komutlar (`powershell -Command "if (...)
    { ... }"`) bozulur. Komut geçici bir `.cmd` dosyasına yazılır. Dosya **BOM'suz UTF-8**
    kaydedilir ve `chcp 65001` ile başlar: cmd.exe UTF-8 BOM'u güvenilir tanımaz, pwsh 7'de
    `[Text.Encoding]::Default` zaten BOM'suz UTF-8'dir.
15. **Bağlı klasör araçlarında `relative_path` doğrudan `Join-Path`'e verilmez.** Küçük modeller
    bazen tam (rooted) yol yazar ve ikilenmiş, geçersiz bir yol oluşur. `Resolve-BoundTarget`
    rooted yolu doğrudan kullanır; `Inside` kontrolü sandbox sınırını korur.
16. **`.cmd` dosyasında `%` özeldir.** Eşleşmeyen her `%` sessizce silinir (`42 % 2` → `42  2`);
    eşleşen `%TEMP%` gibi referanslar doğru genişler. Önce `%[eşleşeni]%` çiftleri korunur, kalan
    tek başına `%` `%%` yapılır:
    ```powershell
    [regex]::Replace($command, '%[^%]*%|%', { param($m) if ($m.Value.Length -gt 1) { $m.Value } else { '%%' } })
    ```
    Bilinen sınır: aynı satırda ilgisiz iki `%` (`a % b % c`) çift sanılabilir; komut başarısız
    olur (sessizce yanlış sonuç vermez), model `%%` ile yeniden dener. cmd.exe'nin `%` kuralları
    yalnızca gerçek Windows'ta doğrulanabilir.
17. **OCR "direkt yol"u** (`Test-OcrExplainIntent`) ham OCR metnini modele uğratmadan döndürür.
    İstek açıklama/özet/yorum ya da güven skoru (`guven|skor|confidence|score`) içeriyorsa modele
    gider; aksi halde skor gibi ek istekler kaybolur.
18. **İki dil sürümü aynı Inno Setup `AppId`'sini paylaşamaz.** `AppId`, Windows'un ürünü tanıdığı
    kalıcı kimliktir; TR ve ENG ayrı GUID taşır. `agent/profile-catalog.ps1`'deki
    `$script:MamidLabsAppId` `.iss` ile aynı olmalıdır (test denetler). Yeni bir dil/varyant
    eklenirse ona taze GUID ver; yayımlanmış bir sürümün `AppId`'sini asla değiştirme.
19. **`.iss`'e yeni bir `Source:` satırı eklemek CI yol filtresini güncellemez.** Pakete gömülen
    her dosya/klasör `kurulum-paketi.yml`'nin push ve PR yol filtrelerinde de olmalı.
20. **Sihirbazda `Exec(..., ewWaitUntilTerminated, ...)` mesaj döngüsünü durdurur;** pencere
    "Yanıt vermiyor" olur, İptal çalışmaz. Kurulum `ewNoWait` + `PumpMessages`
    (`PeekMessageW`/`TranslateMessage`/`DispatchMessageW`, düz `TMsg` kaydı, 28 bayt) ile beklenir.
    Bu döngü sürerken Inno'nun kendi İptal düğmesi `CancelButtonClick`'i **tetiklemez** (gerçek
    Windows'ta doğrulandı); yerine normal `OnClick`'li `CustomCancelButton` gösterilir, metni sabit
    `'İptal'`dir. `ssPostInstall`'da `Abort` sihirbazı durdurmaz, Özet/Bitiş sayfalarına geçer; iptal
    sonrası `ExitProcess(1)` kullanılır. `LoadStringFromFile` ikinci parametre olarak `AnsiString` ister.
21. **Güncelleme kurulumu uygulama açıkken tamamlanamaz.** `install-mamidlabs.ps1` `layout`
    aşamasında çalışan `qwen-desktop.ps1`'i görünce "MamidLabs acik" diye durur. Bu yüzden "Şimdi
    güncelle" kurulum sihirbazını başlattıktan sonra ana pencereyi kapatır (`$mainForm.Close()` →
    `Shutdown-All`). Profiller penceresindeki kapanışlar `GetNewClosure()` kullandığı için ana form
    fonksiyon içinde yerel bir değişkene (`$mainForm = $form`) alınarak yakalanır.
22. **`Start-ThreadJob` sınırından boş dizi `$null` olarak döner.** İşçi, araç çağrısı yokken
    `done` olayının `data` alanına boş dizi (`@()`) koyar; `Receive-Job` bunu `$null` yapar.
    `@($done.data)` bunu tek elemanlı `@($null)`'a çevirir ve günlük mesaj dizisine boş bir girdi
    ekler; sunucu da `400 All non-assistant messages must contain 'content'` ile reddeder. Bu
    yüzden işçi çıktısını tüketen her yerde önce `if ($done.data)` / `if ($jobEvent.data)`
    koruması kullanılır (arayüzdeki `Render-JobEvent` ve smoke testindeki `gecmis_devam` böyle
    yapar). Boş diziyi koşulsuz `+` ile birleştirme.

## 15. Değişiklik yaparken kontrol listesi

- [ ] İlgili testleri çalıştır; yeni davranışa test ekle (`python -m pytest -q`).
- [ ] **Yayın öncesi varyant kapısı (zorunlu):** etiket/yayın öncesi **TR ve ENG** depolarda;
      **PRO (MAX/FLASH)** ve **LITE** profilleriyle tam smoke testi; ayrıca kurulum paketinin
      (Inno, `MamidLabs_Setup.exe`) TR/ENG derlemesi. **Hepsi geçmeden yayın yok.**
- [ ] Medya/sohbet akışına dokunduysan smoke testini ilgili adımlarla çalıştır.
- [ ] Kullanıcıya görünen metin Türkçe ve doğru karakterlerle mi (BOM)?
- [ ] Kurulum/kaldırma etkisi: yeni dosya ya da klasör kökün dışına yazıyor mu? Yazıyorsa
      kaldırıcıya ekle. Varsayılan olarak her şey kökün altında kalmalı.
- [ ] `README.md`, `docs/kurulum.md`, `docs/teknik-notlar.md`, `CHANGELOG.md` ve **bu dosya** güncel mi?
- [ ] ENG deposunda da aynı değişiklik gerekiyor mu? Tanımlayıcılar orada İngilizcedir.
- [ ] Sürüm çıkarılacaksa: `.iss` `MyAppVersion`, CHANGELOG bölümü ve `v<sürüm>` etiketi aynı mı?
- [ ] Kurulu kopyayı güncellemek için uygulamayı kapat, sonra
      `install-mamidlabs.ps1 -Stage layout` çalıştır. Bu komut artık `-Source` verilmeden de
      çalışır (`requirements\` kökte); program klasörleri kopyalamadan önce boşaltıldığı için
      repodan silinen dosyalar geride kalmaz ve kaldırma kaydına sürüm yazılır.

## 16. Değişiklik günlüğü

Her özellik/değişiklik için bir satır ekle (en yeni üstte).

| Tarih | Değişiklik | Dosyalar |
|---|---|---|
| 2026-10-14 | **İstenmeden üretim engellendi + web hatası dürüstçe bildirilir + `read_document` belge bağlamı ister.** Üretim araçları (`create_document`, `generate_video`, `generate_chart`) her turda sunuluyor ve koruma yalnızca sistem istemine bağlı kalıyordu; LITE istenmeden üretiyordu. Artık `generate_image` gibi **çağrı anında niyet denetimi** var (`Test-DocumentRequestIntent`/`Test-VideoRequestIntent`/`Test-ChartRequestIntent`; video ayrıca arayüze devretmeden önceki blokta da denetlenir). **Uydurma tamamen engellendi:** güncel bilgi isteyen bir turda web erişimi yoksa (arama başarısız ya da İnternet kapalı) modelin metni **kullanılmaz**; `Get-FinalAnswer` dürüst bir mesaj gösterir (web başarısız ve güncel bilgi şart değilse `Add-WebFailureNote` not ekler). Boş yanıt net mesajla değişir; aynı üretim aracı bir turda bir kez çalışır (`$script:completedTools`). `read_document` yalnızca ekli belge veya `Test-FileIntent` varsa sunulur (model olmayan dosyayı uydurup okuyordu). Test: `tests/test_generation_intent_guard.py` (gerçek pwsh + statik). | agent/qwen-inference.ps1, tests/test_generation_intent_guard.py, CHANGELOG.md, AGENTS.md |
| 2026-10-14 | **"Tümünü Sil" açık sohbeti korur.** Geçmiş sohbetler penceresindeki "Tümünü Sil" listenin tamamını (o an ekranda duran sohbet dahil) siliyordu; artık açık sohbetin dosyası silinecekler kümesinden çıkarılır (`Get-DeletableChatPaths`), onay metni "Açık olan sohbet korunur." der ve açık sohbet geçmişte kalır. Test: `tests/test_chat_history_delete.py` (gerçek pwsh + statik denetim). | qwen-desktop.ps1, tests/test_chat_history_delete.py, CHANGELOG.md, AGENTS.md |
| 2026-10-13 | **PRO (MAX/FLASH) argümanları kilitlendi + §12 test sayıları gerçeğe çekildi.** `tests/test_lite_profile.py`'ye `test_max_flash_server_args_are_locked` eklendi: MAX/FLASH (`else`) sunucu argüman demetinin tamamını (ctx 32768, predict 8192, `--gpu-layers 99`, flash-attn, q4_0 KV, cache-reuse 256, batch 512/256, threads 6/12, `--mmproj --no-mmproj-offload --image-min-tokens 1024`, `--reasoning-effort` xhigh/low, GGUF'ta MTP varsa `--spec-type draft-mtp`) doğrular; bu demet gerçek 16 GB makinede smoke'lanmıştır ve sessiz bir değişiklik PRO'yu bozabilir. Ayrıca §12 test sayısı/süresi gerçek ölçüme çekildi. | tests/test_lite_profile.py, AGENTS.md |
| 2026-10-13 | **Ses turunda modele bağlı-klasör DOSYA araçları sunulmuyor (ses eki + "Ajan" çipi).** Ses eklenen bir tur, sesi zaten faster-whisper ile dökümleyip son kullanıcı mesajına metin olarak ekliyor; ancak Ajan çipi açıkken küçük model `[Kullanıcı bir ses dosyası ekledi: …]` notunu görüp ses DOSYASINI `list_bound_files`/`read_bound_file`/`write_bound_file` ile aramaya/okumaya/yazmaya kalkıyor ve boşa turlar harcıyordu (arayüz testinde liste/yazma döngüsü, ekranda kafa karıştırıcı "belge sanma" metni). `Get-ToolDefinitions` artık ses eki olan turda (`$job.currentAudioPaths`) bu üç aracı sunmuyor; kullanıcı açıkça dosya isterse (`Test-FileIntent`) araçlar yine sunulur. Ayrıca başarılı döküm notuna (`Add-TranscriptToMessages`) "bu bir ses dökümüdür; yanıtı doğrudan bu metne dayandır, dosyayı araçlarla açmaya çalışma" yönlendirmesi eklendi (`Set-AudioUnavailableNote` hata notuyla simetrik). | agent/qwen-inference.ps1, tests/test_transcriber.py, CHANGELOG.md, packaging/windows/mamidlabs.iss, AGENTS.md |
| 2026-10-13 | **Kurulum paketi (CI) sürüm yayınlama yarışı giderildi.** `kurulum-paketi.yml`'deki GitHub Release adımı, aynı etiket için iki koşu paralel çalıştığında ikisi de `gh release view`'i "yok" görüp `gh release create` çağırıyor ve ikincisi **HTTP 422 "Release.tag_name already exists"** alıyordu (ENG `installer.yml`'de görüldü; yayın yine de ilk koşuda oluştu, yalnızca bir koşu kırmızı göründü). Adım artık atomik: `create` başarısız olursa etiketin var olup olmadığını yeniden denetler ve varsa `upload --clobber` yapar. | .github/workflows/kurulum-paketi.yml |
| 2026-10-13 | **Doküman tutarlılık geçişi (kod davranışı değişmedi).** Son denetimin bulduğu belge/yorum düzeyindeki tutarsızlıklar giderildi: (T1) `.iss` sürüm başlığı artık sabit `v1.0.0` yazmıyor, `v<surum>` etiketiyle karşılaştırmayı anlatıyor; (T2) §12 test sayısı/süresi gerçek ölçüme çekildi (453 toplanır, 449 geçti, 4 atlandı, ~220 sn) ve §16'daki bayat sayı düzeltildi; (T3) §16'daki LITE **7885/8188 MiB** satırı "o sırada" (projektör henüz CPU'ya alınmamıştı, mmproj GPU'daydı) olarak çerçevelendi; (T4) `qwen-desktop.ps1` ses yorumları eski `whisper.cpp` yerine `faster-whisper large-v3-tr (agent\transcriber)` yazar; (T5/T6) §10 `install-mamidlabs.ps1` kullanım satırına `-AppVersion`/`-SkipAudio` ve aşama listesine `asr` eklendi, aynı `asr` `docs/kurulum.md`'ye de işlendi; (T7) §2 haritasına `requirements/asr.txt` eklendi; (T8) MTP kabul oranı §5 ve `docs/teknik-notlar.md`'de `~0,93 (içeriğe bağlı 0,31–0,96)` olarak eşitlendi; (T9) `manage-qwen.ps1` LITE boyut yorumları tek tutarlı değerde (~6,5 GB + ~0,46 GB MTP) toplandı; (T10) §12 smoke adım listesine `grafik` (`-SkipChart`) eklendi; (T11) `docs/kurulum.md` atlama anahtarları tamamlandı; (T12) `docs/kurulum.md` disk aralığı `~58–75 GB` olarak birleştirildi; (T13) `docs/kurulum.md` "Ek görevler" satırına medya/ses bileşenleri eklendi; (T14) `agent/transcriber/__init__.py` sürümünün `MyAppVersion`'dan bağımsız olduğu not edildi; (T15) §3'teki yinelenen `tools\hf-home\` girdisi tekilleştirildi; (T16) `docs/teknik-notlar.md`'deki yinelenmiş `liteModel`/Q4_K_M/Q6_K öğüdü bellek bütçesi bölümünde tek yerde toplandı. | AGENTS.md, CHANGELOG.md, docs/kurulum.md, docs/teknik-notlar.md, packaging/windows/mamidlabs.iss, qwen-desktop.ps1, scripts/manage-qwen.ps1, agent/transcriber/__init__.py |
| 2026-10-13 | **Kurulum/güncelleme doğruluk boşlukları (altı düzeltme).** (1) **Betik kurulumu ⇄ uygulama içi güncelleme uyumu:** `Invoke-Layout` kaldırma kaydına `DisplayVersion` yazar (değer `-AppVersion` ya da kaynak paketteki `.iss` `MyAppVersion`'dan, `MyAppVersion "x.y.z"`; yalnızca MAJOR.MINOR.PATCH kabul edilir) ve `Get-InstalledMamidLabsVersion` Inno `{AppId}_is1` kaydı yoksa betiğin `MamidLabs-<hash8>` kaydına `InstallLocation`/`DisplayName` eşleşmesiyle düşer. (2) **Bayat dosya temizliği:** `layout` sahip olduğu program klasörlerini (`agent\`, `scripts\`, `assets\`, `requirements\`) kopyalamadan önce boşaltır (kaynak kökün kendisiyse — kurulu kopyadan `-Source` verilmeden çalıştırılırsa — atlanır; kaynağın kökün yalnızca **içinde** olması, yani sihirbazın `{kok}\kurulum-kaynak` paketi, atlama nedeni **değildir**, aksi halde taze kuruluma program dosyaları hiç kopyalanmazdı); aynısı `kurulum-kaynak` tazelemesi için geçerlidir, böylece repodan silinen dosyalar (Inno `ignoreversion`, `Copy-Item -Force`) kalıcı olmaz. Kullanıcı verisine (`settings\`, `chats\`, `models\`, `logs\`, `outputs\`, `tools\`, venv, `ComfyUI`) dokunulmaz. (3) **`requirements\` kökte:** kök klasör+kopya listesine eklendi; belgelenen `install-mamidlabs.ps1 -Stage layout` komutu artık `-Source` verilmeden de çalışır. (4) **`.iss` ⇄ betik kopya uyumu:** `agent\__pycache__\*`, `*.pyc` ve `assets\installer\*` betik kopyasında ve kaynak pakette de dışlanır. (5) **Mükerrer kayıt engeli:** bu köke işaret eden bir `_is1` kaydı varsa betik ikinci kaydı açmaz; `MyAppVersion` yalnızca `x.y.z` iken okunur (aksi halde `DisplayVersion` yazılmaz — sessiz bozulma yerine). (6) **Kaldırıcı:** `EULA.txt` ve `requirements` `$programEntries`'e eklendi; `.iss` `[UninstallDelete]`'e `EULA.txt` ve `requirements` eklendi, böylece kök gerçekten silinir. | scripts/install-mamidlabs.ps1, scripts/uninstall-mamidlabs.ps1, agent/profile-catalog.ps1, packaging/windows/mamidlabs.iss, tests/test_uninstall.py, tests/test_install_update_gaps.py, tests/test_profile_update_check.py, AGENTS.md, CHANGELOG.md |
| 2026-10-13 | **LITE görsel projektörü (mmproj) CPU'ya taşındı; model artık 8 GB VRAM'e sığıyor.** LITE'ta Q8_0 mmproj (595 MiB) GPU'da 8 GB karta sığmıyor, llama.cpp'yi büyük gömme tensorünü CPU'ya itmeye zorlayıp VRAM'i sınırdan taşırıyordu (7885/8188 MiB, yalnızca 72 MiB boş). LITE sunucu argümanlarına `--no-mmproj-offload` eklendi ve `Test-MemoryBudget` LITE'ta artık projektör boyutunu model dosyasına eklemiyor; böylece üç profilde de mmproj CPU'da çalışır ve VRAM bütçesine girmez. Ölçüm: kullanılan VRAM **7885 → 7249 / 8188 MiB**, boş alan **72 → 708 MiB**; sohbet hızı değişmedi (içeriğe bağlı ~40–79 tok/s, 16 GB'ta ~97), görsel okuma yalnızca projektör CPU'da olduğu için hafifçe yavaşladı (görsel anlama çalışmaya devam eder). | scripts/manage-qwen.ps1, tests/test_lite_profile.py, tests/test_memory_admission.py, docs/teknik-notlar.md, agent/model-registry.ps1, AGENTS.md, CHANGELOG.md |
| 2026-10-13 | **Doküman tutarlılığı: `docs/teknik-notlar.md` güncel kodla hizalandı.** MTP bölümü düzeltildi: LITE'ın 9B GGUF'u dönüşümde MTP başlığını kaybeder ve indirme sırasında `agent/mtp_inject.py` ile geri eklenir, bu yüzden `--spec-type draft-mtp` LITE'ta da kullanılır (§5 ile aynı). LITE bellek bütçesi **o sırada 7885/8188 MiB** (projektör henüz CPU'ya alınmamıştı, mmproj GPU'daydı) ve hızı **içeriğe bağlı ~40–79 tok/s** (16 GB'ta ~97) olarak güncellendi; LITE satırındaki `reasoning` değeri `low` yerine **sınırsız** yapıldı. ComfyUI yaşam döngüsü `comfyKeepAlive` **varsayılanı `false`** (yalnızca medya üretiminde çalışır, boşta VRAM/RAM tutmaz) olarak düzeltildi; aynı düzeltmeler `README.md`, `docs/kurulum.md` ve `CHANGELOG.md`'ye uygulandı. `agent/profiles.json` MAX/FLASH özet hızları ~42–58 tok/s'ye çekildi; `docs/kurulum.md` `-Action` listesine `closecomfy` eklendi. §12 test sayısı/süresi gerçek değere çekildi (o geçişte ~435 test; sonraki tutarlılık geçişinde 453 toplanır / 449 geçti / 4 atlandı, ~220 sn olarak yeniden ölçüldü). | docs/teknik-notlar.md, README.md, CHANGELOG.md, docs/kurulum.md, agent/profiles.json, AGENTS.md |
| 2026-10-12 | **Zor soruda boş görünür yanıt regresyonu düzeltildi: düşünme tüm çıktı bütçesini yiyordu.** Uçtan uca matematik testinde LITE (9B) zor bir integral sorusunda **8192 tokenın tamamını** (~159,7 sn) düşünmeye harcayıp görünür yanıt üretmedi; baloncukta yalnızca "İntegral" kaldı (`logs\qwen-lite.stderr.log`: `eval 159714 ms / 8192 tokens`, `n_tokens 11990`). Kök neden: düşünme "sınırsız", çıktı tavanı `--predict 8192` ve arayüz `maxTokens 8192` **aynı bütçeyi** paylaşır; "adımları İKİ KEZ kontrol et" talimatı düşünmeyi daha da uzatıyordu ve mevcut boş-yanıt yedeği de aynı 8192'ye takılıyordu. (1) **Düşünme-kapalı kurtarma (asıl garanti):** yeni `Set-NoThinkingRequest` istek gövdesine `chat_template_kwargs = @{ enable_thinking = $false }` koyar (LITE `reasoning_effort`u yok saydığı için tek garantili yol); kurtarma mesajına `/no_think` de eklenir, model doğrudan yanıtı yazar. Tetikleyici genişletildi: görünür yanıt **boşsa** VEYA çıktı tavanında kesilip (`finishReason='length'`) kırık kısa metin bıraktıysa kurtarma çalışır. (2) **Sistem istemi yumuşatıldı (TR+ENG):** "en az İKİ KEZ kontrol et" → "kritik adımları tekrar gözden geçir AMA YANITINI DA MUTLAKA YAZ; çok uzun düşünüp yanıtsız kalma"; LITE derin-düşünme satırı da düşünmeyi sınırsızca uzatmaya teşvik etmeyecek biçimde güncellendi. (3) **Bütçe kararı:** düşünme sınırsız olduğundan `--predict`i artırmak yanıtı **garanti etmez**, yalnızca düşünmeyi uzatıp gecikmeyi büyütür (ölçüm: 8192 token = 159,7 sn); bu yüzden (a) yerine (b) [garanti kurtarma] seçildi, KV/bağlam taşması yaratılmadı. Yeni regresyon testleri: `test_empty_answer_recovery_disables_thinking` (statik+gerçek pwsh), sistem istemi yumuşatma iddiaları. | agent/qwen-inference.ps1, qwen-desktop.ps1, tests/test_transcriber.py, tests/test_lite_profile.py, tests/test_qwen_contracts.py, CHANGELOG.md, AGENTS.md |
| 2026-10-12 | **Blok LaTeX → okunur metin + sabit "kanıtlı/iki kez doğrula" sistem talimatı (uçtan uca matematik testinde bulundu).** (1) `Convert-MathText` artık **dengeleyen** bir ayrıştırıcıyla (`Read-MathGroup`/`Read-MathAtom`/`Add-MathAccent`/`Expand-MathCommands`) blok yapıları çözer; basit regex iç içe kumeler ve kaçışlı `\{ \}` yüzünden ham `\frac`/`\boxed` bırakıyordu (nihai kutulu sonuç bile `boxed{...}` görünüyordu). Desteklenen: iç içe/kümeli ve kaçışlı `\frac{A}{B}` → `(A)/(B)`, `\sqrt{X}`/`\sqrt[n]{X}` → `√(X)`/`ⁿ√(X)`, `\boxed`/`\fbox` → `[ X ]`, `\textbf`/`\textit`/`\mathrm`/`\text`/`\operatorname` → içerik, `\left`/`\right` → sade parantez, `\overline`/`\bar`/`\vec`/`\hat` → birleşik işaret, `\begin`/`\end` atılır. Örnek: `\boxed{\frac{\pi^5(89+72\sqrt3)}{3888}}` → `[ (π⁵(89+72√(3)))/3888 ]`. Glif tablosu, `\ce`/`\pu` ve para birimi `$` korunur. (2) `Get-SystemPrompt`'a SABİT (tura özel değil; KV önbelleği bozulmaz) doğrulama satırı: kanıtlı/doğru cevap + çok adımlı matematik/cebir/mantıkta adımları ve sembolik/sayısal **ara sonuçları en az iki kez kontrol** + **uydurma test/teorem/kaynak adı yasağı**; LITE derin-düşünme satırı bununla birleştirildi (tekrar yok). Testler genişletildi; TR 432 / ENG 431 geçti. | qwen-desktop.ps1, tests/test_math_render.py, tests/test_qwen_contracts.py, tests/test_lite_profile.py, CHANGELOG.md, AGENTS.md |
| 2026-10-12 | **Ses dökümü: LITE CPU/GPU politikası (kısa+RAM→CPU co-resident, uzun ya da RAM yetersiz→GPU+swap), GPU çalışma zamanı DLL'leri ve transcribe zaman aşımı.** (1) `config.py`: `LITE_CPU_MAX_SECONDS=15` sabiti ve `choose_plan` — LITE'ta CPU co-resident YALNIZCA kayıt eşikten KISA **VE** ses hattı sistem RAM'ine sığıyorsa (`audio_ram_mib`=5120 MiB) seçilir (`('cpu', False)`); uzun kayıt ya da RAM yetersizliğinde `('cuda', True)` (mecburi swap). PRO (20 sn) değişmedi; CPU hiçbir zaman zorlama değil (GPU yoksa son çare). Ölçüm hükmü (iki bağımsız ölçüm çelişti; daha KESİN olan ölçüm-2 = LM + ASR CPU'yu BİRLİKTE koşturan): LITE co-resident **SIĞMIYOR** (fiziksel 15,25 GB < gereksinim ~16,1 GB; marj sıfır/negatif, tepe ~15.127/15.611 MB; OOM yok ama LM'in ~6,1 GB model sayfası geri kazanılabilir önbellekten atılıp bir SONRAKİ sohbet turunda diskten okunuyor). Bu yüzden LITE `audio_ram_mib` **5.120 MiB** (`LITE_AUDIO_RAM_MIB`, PRO ile AYNI güvenli kapı) tutulur; LM yüklüyken `choose_plan` CPU dalını SEÇMEZ → GPU + swap; bol RAM'li makinede kısa kayıt yine CPU co-resident olabilir. Swap durum metni de gerçeğe uyduruldu (dil modeli RAM'e taşınmaz; `manage-qwen -Action stop` ile SÜREÇ kapatılır). (2) `requirements/asr.txt`'e `nvidia-cublas-cu12` + `nvidia-cudnn-cu12` (CTranslate2 4.x `cublas64_12.dll`/`cudnn_*64_9.dll` arar; torch cu130'da yok) → **GPU ASR artık çalışıyor**; `asr.py` `_add_cuda_dll_dirs` DLL dizinlerini ekler. (3) `qwen-inference.ps1`: `Get-AudioTimeoutSeconds` + transcribe isteğine `timeoutSeconds` (`max(600,d*4+300)`≤3600). TR+ENG testler güncellendi. | agent/transcriber/config.py, agent/qwen-inference.ps1, requirements/asr.txt, tests/test_transcriber.py, tests/test_requirements_files.py, AGENTS.md, CHANGELOG.md |
| 2026-10-12 | **Ses dökümü: CPU yedeği PowerShell sözlük (hashtable) hatası yüzünden hiç çalışmıyordu.** `Invoke-TranscribeWithModelSwap` birincil (GPU) döküm başarısız olunca CPU yedeğini `$payloadBase + @{ device = 'cpu' }` ile kuruyordu; PowerShell'de Hashtable `+` **aynı anahtarda istisna atar** ("Item has already been added. Key in dictionary: 'device'") çünkü `$payloadBase` zaten `device`/`need_swap` içerir. Bu yüzden CPU'ya gerçek bir geçiş olmuyor, gerçek ASR hatası yutuluyor ve döküm kayboluyordu (örn. `cublas64_12.dll` yoksa GPU yolu her zaman hata verir). Artık payload kopyalanıp alan ezilir (`.Clone()`); aynı düzeltme yeni "modeli bellekten çıkar ve yeniden dene" bloğunda da yapıldı. `tests/test_transcriber.py` deseni korur. | agent/qwen-inference.ps1, tests/test_transcriber.py, AGENTS.md, CHANGELOG.md |
| 2026-10-12 | **Hijyen: audit kaydı rotasyonu ve reasoning (düşünme) tekrar koruması (F3/F4).** (F3) `logs\audit.jsonl` sınırsız büyüyordu; yazımdan önce dosya boyutu 5 MB'ı aşarsa `audit.1.jsonl`'e devredilir (varsa eskisinin üzerine yazılır; tek dosya devri yeterli) ve yeni satır temiz dosyaya gider. Devir de mevcut `try/catch` içindedir: audit yazımı hata/rotasyon durumunda bile turu **düşürmez**. (F4) Tekrar (runaway) dedektörü eskiden yalnızca görünür içeriğe (`$result.content`) bakıyordu; LITE'ta düşünme **sınırsız** olduğundan model `reasoning_content` akışında tekrara girerse 8192 token tavanına kadar boş dönüyordu. Artık reasoning birikimine de görünür içerikle **AYNI eşik/desen** (aynı sözcük 6+ kez) muhafazakâr biçimde uygulanır; güçlü tekrar saptanınca akış güvenli noktada durdurulur. Görünür yanıt yoksa mevcut "boş yanıt"/düşük çaba yeniden-deneme yolu bozulmadan devreye girer. F5/D6/D7 bu değişiklikte ele alınmadı. | agent/qwen-inference.ps1, tests/test_transcriber.py, AGENTS.md, CHANGELOG.md |
| 2026-10-12 | **Ajan döngüsü dayanıklılığı: tur içi bağlam taşması, duvar-saati sınırı ve `custom` sağlayıcı toleransı (F1/F2/D2/D3).** (F1) **Bağlam taşması:** tur içinde biriken araç çıktıları prompt'u `contextLimit`/`--ctx-size` aşarsa `--no-context-shift` yüzünden llama.cpp HATA döndürüp tur düşüyordu; artık ana döngü her tur BAŞINDA tahmini prompt boyutunu (`Estimate-MessagesTokens`, masaüstündeki `Estimate-ContextTokens` ile aynı karakter/3 yaklaşımı) hesaplar, `tahmin + max_tokens + pay > contextLimit` ise `Compress-TurnMessages` ile **en eski araç çıktılarını** (sistem mesajı ve son kullanıcı mesajı korunarak, mesaj SİLİNMEDEN — assistant `tool_calls`/`tool` eşleşmesi bozulmadan) kısaltır; hâlâ sığmıyorsa araçları sunmayı bırakıp eldeki bulgularla görünür yanıt ister. Kullanıcıya "Bağlam sınırına yaklaşıldı…" durum notu düşülür. (F2) `max_tokens` kalan odaya göre sınırlanır (`Min(maxTokens, Max(256, contextLimit - promptTok - pay))`; local+custom). (D2) `Invoke-PythonTool` artık duvar-saati sınırı taşır (varsayılan 180 sn; parametre ya da `$payload.timeoutSeconds` ile geçersiz kılınabilir); aşılınca alt süreç ağacı `Kill($true)` ile öldürülüp hata döner, iptal davranışı korunur. (D3) `custom` (OpenAI uyumlu özel uç) da geçici bağlantı hatasında **bir kez** yeniden dener ve finish/icerik/araç verisi varken kopmayı hata saymaz; `openai/claude/gemini/deepseek` davranışı korunur. | agent/qwen-inference.ps1, tests/test_transcriber.py, tests/test_qwen_contracts.py, AGENTS.md, CHANGELOG.md |
| 2026-10-12 | **Ses eki döküme çevrilemediğinde bir turun boşa gitmesi düzeltildi (uçtan uca ses testinde bulundu).** İşçi döküm alınamadığında (hata ya da boş sonuç) sessizce "dökümsüz" devam ediyor ve kullanıcı mesajındaki `[Kullanıcı bir ses dosyası ekledi: <ad>]` notu tek başına kalıyordu; model dosyayı "ekli belge" sanıp `read_document`/`read_bound_file` ile `.wav`'ı açmaya çalışıyor ve **8/8 ajan turunu** döküm baloncuğu hiç oluşmadan harcıyordu. `Invoke-TranscribeWithModelSwap` artık plan "swap yok" deyip döküm yine alınamazsa dil modelini bellekten çıkarıp **temiz GPU + daha çok boş RAM** ile bir kez daha dener (WDDM'de plan'ın okuduğu boş VRAM, model yüklüyken iyimser olabildiğinden; bkz. §13 ve tuzak 7); hâlâ başarısız/boşsa yeni `Set-AudioUnavailableNote` son kullanıcı mesajına sesin **belge olmadığını** ve yazıya çevrilemediğini söyleyen açık bir not ekler. Ses motoru tek başına sağlamdı (doğrudan `whisper-tools.py` çalışıyor); kusur işçinin hatayı yutup modele yanlış bağlam bırakmasıydı. `tests/test_transcriber.py` sözleşmeyi korur. | agent/qwen-inference.ps1, tests/test_transcriber.py, AGENTS.md, CHANGELOG.md |
| 2026-10-12 | **Betik tabanlı kurulum/güncelleme artık `EULA.txt`'i köke ve `kurulum-kaynak` paketine kopyalar.** Sihirbaz `EULA.txt`'i kaynak pakete koyuyordu (`.iss` `[Files]`) ama `install-mamidlabs.ps1` `Invoke-Layout`'un üst dosya listesinde yoktu; bu yüzden betikle (sihirbazsız) güncellenen kurulumlarda lisans dosyası hiç bulunmuyordu. İki üst dosya listesine eklendi; boşluk `tests/test_install_layout_source.py` ile korunuyor. | scripts/install-mamidlabs.ps1, tests/test_install_layout_source.py, AGENTS.md |
| 2026-10-12 | **Smoke testi `arayuz` adımı gerçekçi `maxTokens` kullanır (300 → 8192).** LITE'ta düşünme sınırsız olduğundan (`--reasoning-budget` yok, `reasoning_effort=low` Qwen3.5 9B şablonunca yok sayılır) düşünme tokenları çıktı bütçesini paylaşır; 300 verildiğinde model tamamen düşünüp görünür yanıt üretmeden kesiliyor ve işçi "Model yanit metni uretmedi." hatası veriyordu. Değer gerçek arayüzle (qwen-desktop.ps1: 8192) ve sunucu `--predict 8192` ile eşitlendi; bu bir **test koşumu uyumsuzluğuydu**, uygulama hatası değil (arayuz_sohbet adımı gerçek pencereyle geçiyor). | scripts/smoke-test.ps1, AGENTS.md |
| 2026-10-12 | **Ses dökümü tier'ı artık SEÇİLİ dil-modeli profiline göre belirleniyor.** Yerel ASR hattının seviyesi eskiden yalnızca toplam VRAM'e göre seçiliyordu; artık **seçili profil** belirler: **lite** → `int8_float16`, sıralı yükleme, 15 sn CPU/GPU eşiği; **pro** (MAX/FLASH) → `float16`, paralel, 20 sn. Toplam VRAM yalnızca profil adı verilmezse (CLI) yedek ölçüttür; cihaz/swap kararı yine ölçülen gerçek boş VRAM + sistem RAM'i ve kaydın süresine göre verilir. `config.py`: tier adları `lite`/`pro`, `TIER_ALIASES` / `resolve_tier` / `select_profile_for`; `qwen-inference.ps1`: yeni `Get-AsrProfileName`, plan/transcribe isteklerine `profile` alanı. | agent/transcriber/config.py, agent/whisper-tools.py, agent/transcriber/main.py, agent/qwen-inference.ps1, AGENTS.md, docs/teknik-notlar.md, CHANGELOG.md |
| 2026-10-12 | **Profiller penceresine dil profili indirme + silme eklendi:** kullanıcı arayüz dilini (Türkçe/English) seçip diğer dil sürümünün kurulum paketini oradan indirip kurabilir (aynı klasöre, `UsePreviousAppDir`; `settings\`/`chats\` korunur) ya da indirdiği paketi **silebilir**. İndirilen paket kalıcı `tools\editions\MamidLabs_Setup_<dil>.exe`'ye iner ve `edition.json` kaydı tutulur; "Dil sürümünü sil" paket + kaydı kaldırır. `agent/profile-catalog.ps1`: `MamidLabsEditionLang`, `OtherEditionRepo`, `Get-EditionRelease`, `Get-EditionDownloadDir`/`Get-EditionRecord`, dil ComboBox + "Seçili dil sürümünü indir" + "Dil sürümünü sil" düğmeleri. | agent/profile-catalog.ps1, AGENTS.md, CHANGELOG.md |
| 2026-10-12 | **Ses dökümü CPU/GPU eşiği AR-GE ile ölçülüp ayarlandı; LITE de birleşik karara alındı.** Ölçüm (RTX 5060 Ti 16 GB, faster-whisper large-v3): CPU `≈5+0,91·d`, GPU `≈3,3+0,079·d` + swap (PRO 14 sn, LITE 9 sn). Kesişim PRO ~15 sn (→ eşik **20 sn**), LITE ~9 sn swap + 6 sn yükleme (→ eşik **15 sn**). Artık **her iki profil de** aynı `choose_plan` mantığını kullanır: VRAM'e birlikte sığarsa GPU/swap yok; sığmaz + RAM yeter + kayıt KISA ise CPU/swap yok; uzun kayıt ya da RAM yetmezse GPU + mecburi swap. LITE'ın CPU dalı yeniden açıldı (ölçüm: CPU yolu ~4,1 GB RAM, 16 GB'a sığıyor; 8 GB'da ses hattı ~3,4 GB, dil modeliyle birlikte sığmadığı için swap yine gerekir). | agent/transcriber/config.py, tests/test_transcriber.py, AGENTS.md, CHANGELOG.md |
| 2026-10-12 | **FLASH çıktı tavanı 4096 → 8192:** üç profil de artık `--predict` ve arayüz `max_tokens` olarak 8192 kullanır (tavan, hedef değil; EOS'ta durur, normal yanıt hızı değişmez). MAX/FLASH ayrımını `--reasoning-effort` korur. | scripts/manage-qwen.ps1, qwen-desktop.ps1, AGENTS.md, docs/teknik-notlar.md, CHANGELOG.md |
| 2026-10-12 | **Ses dökümü motoru Qwen3-ASR'den `agent/transcriber/` (faster-whisper + AST) hattına taşındı; Qwen3-ASR ve whisper.cpp tamamen kaldırıldı.** Yeni paket: `config` (tier SEÇİLİ profile göre: lite int8_float16 + sıralı, pro float16 + paralel; GPU toplam VRAM'i yalnızca ad yoksa yedek), `audio` (PyAV 16 kHz mono WAV), `vad` (Silero), `asr` (**faster-whisper `oguzhangokboru/whisper-large-v3-tr`**, halüsinasyon filtreleri: VAD, `condition_on_previous_text=False`, `no_speech/logprob/compression` eşikleri, düşük sıcaklık yedeği, bilinen kalıp/tekrar eleme), `events` (AST AudioSet → Türkçe etiket; "Speech" etiketleri filtrelenir), `diarize` (pyannote, opsiyonel), `merge` (**kronolojik, zaman damgasız**: `(ayak sesleri)` / `Konuşmacı: ...`), `main` (txt+json). Kurulumda **`venv\asr`** (faster-whisper + transformers/AST + pyannote + torch cu130) ve modeller HF önbelleğine iner. Ses olayları varsayılan **açık**; mikrofon menüsüne **"Konuşma dışı sesler"** onay kutusu eklendi (kapalıysa yalnızca konuşma; `settings\api.json → audioEvents`). Kırmızı mikrofon tuşu artık kaydı **iptal** eder (dur+sil; gönderme sağ tık menüsü/Gönder ile). Her iki dil sürümü (TR: tr / ENG: auto + İngilizce etiketler). | agent/transcriber/*, agent/whisper-tools.py, agent/qwen-inference.ps1, qwen-desktop.ps1, scripts/install-mamidlabs.ps1, requirements/asr.txt, agent/profile-catalog.ps1, packaging/windows/mamidlabs.iss, tests/test_transcriber.py, AGENTS.md, CHANGELOG.md |
| 2026-10-12 | **Ses dökümü ayrıştırma kusuru düzeltildi (arayüz testinde bulundu).** Sessiz/kısa bir kayıtta Qwen3-ASR çıktısını ayrıştıran `_extract_text` ham `language None<asr_text>` metnini transkript sanıp modele gönderiyordu. Artık `<asr_text>` etiketi ve `language ...` sarmalayıcısı **her zaman** temizlenir; sessiz sonuçta `text` boş döner ve arayüz/işçi "ses tanıma metin üretmedi" deyip dökümsüz sürdürür. Gerçek sessiz kayıt + TTS konuşma kaydıyla doğrulandı. | agent/qwen3-asr-tools.py, tests/test_qwen3_asr.py, CHANGELOG.md |
| 2026-10-11 | **LITE çıktı tavanı 3072 → 8192 (`--predict`).** Düşünme açık ve **sınırsız** olduğu için düşünme tokenları `--predict` **çıktı** bütçesini paylaşır (bağlam penceresi 32768'den ayrı bir şeydir). 3072 basit bir istekte bile düşünmeye tükenip **görünür yanıt üretmeden** kesiliyordu ("boş yanıt"). Arayüz LITE için zaten `max_tokens=8192` gönderiyor; sunucu da uyumlu. Smoke sohbet probe'u da 8192 kullanır. | scripts/manage-qwen.ps1, scripts/smoke-test.ps1, AGENTS.md, docs/teknik-notlar.md |
| 2026-10-11 | **"Durdur" artık o an yapılan HER işi anında keser** (yanıt, ASR/OCR/arama gibi uzun süren Python alt süreçleri, medya üretimi); ardından dil modeli arka planda yüklenir ve sohbet bir sonraki mesajla devam eder. `Invoke-PythonTool` artık çıktıyı **asenkron** toplar ve bekleme döngüsünde `$Shared.Cancel`'ı yoklar; iptalde alt süreç ağacı **anında öldürülür** (`$p.Kill($true)`), ASR cihaz döngüsü CPU yedeğine geçmeden kırılır, araç/ASR iptali hata olarak gösterilmez. **Tek istisna: dil modeli YÜKLENİYORSA kesilmez** — `Cancel-Generation` `switchProcess`/`pendingModelChange`'e dokunmaz, yükleme arka planda tamamlanır. | agent/qwen-inference.ps1, qwen-desktop.ps1, tests/test_qwen3_asr.py |
| 2026-10-11 | **Ses/OCR sonrası model geri yükleme yarışı düzeltildi (8 GB LITE).** ASR/PaddleOCR alt süreci çıktıktan sonra WDDM VRAM'i geciktirerek serbest bırakabildiği için hemen başlayan dil modeli "yer yetmiyor" ile reddedilip **kapalı kalabiliyordu**. `manage-qwen.ps1` bellek kapısı artık kısa aralıklarla **sınırlı kez** yeniden denenir (~5 sn; ilk denemede ComfyUI kapatılır, yalnızca son denemede hata verilir). Ayrıca smoke testinin sohbet probe'u sınırsız düşünmeye göre gerçekçi `max_tokens` (LITE çıktı tavanı) kullanır; küçük bir değer düşünmeye tükenip "boş yanıt" verebilirdi. | scripts/manage-qwen.ps1, scripts/smoke-test.ps1, tests/test_memory_admission.py, tests/test_smoke_test_script.py |
| 2026-10-11 | **LITE artık bir düşünme bütçesi kullanmaz (sınırsız).** `--reasoning-budget` hiç verilmez; düşünme açık kalır ve model gerektiği kadar uzun düşünür. Sistem istemi modele derin düşünmesini ve düşünme süresini kısıtlamamasını söyler; önceki 300 token'lik bütçe kaldırıldı. | scripts/manage-qwen.ps1, agent/qwen-inference.ps1, qwen-desktop.ps1, docs/teknik-notlar.md, tests/test_lite_profile.py, scripts/smoke-test.ps1, README.md, CHANGELOG.md, AGENTS.md |
| 2026-10-11 | **Ses (mikrofon) akışı düzeltildi ve ASR önceliği eklendi.** (1) Kayıt sürerken **kırmızı mikrofon tuşuna** basmak kaydı **bitirip gönderir**; kayıt yokken menü açılır. Menüdeki **"İptal"** artık kaydı gerçekten **iptal eder** (dosya silinir, gönderilmez); kayıt sürerken de erişilebilmesi için mikrofon tuşunda **sağ tık** menüyü açar ve başlıklar "Kaydı bitir ve gönder"/"Kaydı iptal et" olur (`Stop-MicrophoneCapture`/`Complete-MicrophoneCapture`/`Cancel-MicrophoneCapture`). (2) Kayıt sürerken **Gönder**'e basmak da kaydı bitirip gönderir. (3) **ASR, dil modeli yüklemesini geçersiz kılar:** ses eki olan bir tur, model hazır olmasa da hemen başlatılır; `Stop-ModelSwitchForAudio` süren model yüklemesini öldürür, işçi VRAM'i boşaltıp ASR yapar, dökumden sonra modeli geri yükler (aktif alias yokken **seçili** profile göre; yanlış profil başlatılmaz). (4) **"Durdur" ses turunda da çalışır:** transkripsiyon ve model geri yükleme beklemesi iptal bayrağını dikkate alır (`Wait-LocalModelReady` iptalde beklemez; iptal hata gibi gösterilmez). | qwen-desktop.ps1, agent/qwen-inference.ps1, tests/test_qwen3_asr.py, tests/test_desktop_behavior.py, tests/test_lite_profile.py |
| 2026-10-11 | Taze kurulum düzeltmesi: `requirements\imagegen.txt`'e **`transformers==5.17.0`** eklendi. Qwen3-ASR `transformers>=5.13` ister; ComfyUI'nin gereksinimi yalnızca `>=4.50.3` olduğundan sürüm pinlenmemişti ve taze kurulumda eski bir sürüm gelip **ses dökümü kırılabilirdi**. | requirements/imagegen.txt, tests/test_requirements_files.py |
| 2026-10-11 | Kurulum bileşenleri **isteğe bağlı** yapıldı: sihirbazda **görsel/video üretimi, ses yakalama ve OCR** görevleri (hepsi **varsayılan seçili**) işaret kaldırılınca kurulumdan atlanır (`-SkipMedia`/`-SkipAudio`; OCR zaten isteğe bağlıydı). OCR boyut metni gerçek değere (**~5,5 GB**) düzeltildi. Ayrıca **Profil yöneticisinden** bileşen seçip **indirme** ve **silme** eklendi (`Get-ProfileFileComponent`: ComfyUI→medya, `models\qwen3-asr`→ses; `Remove-ProfileComponents` yalnız profile özel dosyaları siler). | packaging/windows/mamidlabs.iss, scripts/install-mamidlabs.ps1, scripts/setup-run.ps1, agent/profile-catalog.ps1, tests/test_setup_wizard.py, tests/test_profile_delete.py |
| 2026-10-11 | EULA'ya **"Sansürsüz / Açık Kaynak Yapay Zekâ Modelleri ve Üçüncü Taraf Bileşenler"** maddesi eklendi: filtreli/filtresiz açık kaynak modellerin bilime/eğitime hizmet amacıyla sunulduğu; Hak Sahibinin bu modelleri üretmediği/eğitmediği/sahiplenmediği, yalnızca kamuya açık kaynaklara erişimi kolaylaştırdığı; kötü niyetli/yasa dışı kullanımdan münhasıran kullanıcının sorumlu olduğu ve Hak Sahibinin sorumlu tutulamayacağı. | EULA.txt, tests/test_setup_wizard.py |
| 2026-10-11 | Kurulum sihirbazına **EULA** (Son Kullanıcı Lisans Sözleşmesi) eklendi: mülkiyet/fikri mülkiyet hakları, lisansın kapsamı, yasak eylemler (kopyalama/çoğaltma/değiştirme/crack/ticari pazarlama), izinsiz kullanımın hukuki sonuçları, sorumluluk reddi ve sınırlandırılması, fesih, yürürlükteki hukuk ve yetkili mahkeme. `EULA.txt` (TR/ENG, UTF-8 BOM) sihirbazın lisans sayfasında (`LicenseFile`) gösterilir ve pakete gömülür. | EULA.txt, packaging/windows/mamidlabs.iss, tests/test_setup_wizard.py, .github/workflows/kurulum-paketi.yml |
| 2026-10-11 | **Ses dökum motoru whisper.cpp'den Qwen3-ASR-1.7B'ye taşındı** (whisper tamamen kaldırıldı). Yeni işçi `agent/qwen3-asr-tools.py` (imagegen venv'i: torch cu130 + transformers 5.x; PyAV ile 16 kHz mono float32 numpy — librosa/soundfile gerekmez; `HF_HUB_OFFLINE`/`TRANSFORMERS_OFFLINE` ile çevrimdışı). 52 dil + **Türkçe**, konuşma + şarkı/BGM; gerçek sesle doğrulandı (LibriSpeech: birebir doğru, GPU). Kurulumda `whisper` aşaması → **`asr`** (model `models\qwen3-asr`'a HF'den boyut doğrulamalı iner); `verify` kontrolü ve arayüz metinleri güncellendi. `Invoke-TranscribeWithModelSwap` artık `cuda→cpu` deniyor; mikrofon menüsündeki kalite toggle'ı (audioQuality) kaldırıldı (tek motor). Test dosyası `tests/test_whisper_tools.py` → `tests/test_qwen3_asr.py`. | agent/qwen3-asr-tools.py, agent/qwen-inference.ps1, qwen-desktop.ps1, scripts/install-mamidlabs.ps1, tests/test_qwen3_asr.py, tests/test_installer_pinning.py |
| 2026-10-11 | 1.0.0 yayın kapısı, ses/mikrofon değişikliklerinden **sonra** yeniden doğrulandı: **MAX smoke 14/14**, **LITE smoke 13/13** (+1 beklenen atlama: `duzenleme`, 8 GB'ta desteklenmiyor), pytest **TR 332 / ENG 331**, setup TR/ENG derlendi (`MamidLabs_Setup.exe`). Ölçüm: MAX 43,1→47,7 tok/s (medya sonrası oran 1,11), LITE 95,8→92,9 tok/s (oran 0,97), ikisinde de ComfyUI kapalı; arayüz turu MTP 23/23. | AGENTS.md |
| 2026-10-11 | whisper.cpp kurulum kusuru düzeltildi: arşiv `Release` alt klasörüne açıldığından "whisper-cli.exe zaten kurulu" atlama koşulu hiç tutmuyordu ve her kurulumda **662 MB ikili yeniden iniyordu**; artık `whisper-cli.exe` özyinelemeli aranıyor. | scripts/install-mamidlabs.ps1, tests/test_installer_pinning.py |
| 2026-10-11 | Ses yakalama kalitesi seçilebilir yapıldı: mikrofon menüsüne **"Yüksek kalite (large-v3)"** onay kutusu (toggle). İşaretsiz = normal (turbo-q5_0, hızlı), işaretli = yüksek (large-v3, en yüksek doğruluk, ~2x yavaş). Seçim `settings\api.json` → `audioQuality` olarak saklanır ve işçi dökumde açık model yolunu whisper'a geçirir. Kurulum artık **her iki modeli** de indirir (turbo-q5_0 + large-v3 + VAD); aksi halde yüksek kalite sıfırdan kurulumda sessizce turbo'ya düşüyordu. | qwen-desktop.ps1, agent/qwen-inference.ps1, scripts/install-mamidlabs.ps1, tests/test_whisper_tools.py |
| 2026-10-11 | Mikrofon kaydı eklendi (bağımlılıksız): winmm `mciSendString` ile Windows **varsayılan** kayıt cihazına (WAVE_MAPPER) kaydeder; mikrofon tuşu toggle (başlat/dur). Kayıt ses eki olarak eklenir ve otomatik gönderilir (dökum + yanıt). | qwen-desktop.ps1, tests/test_whisper_tools.py |
| 2026-10-11 | ComfyUI yaşam döngüsü **profile duyarlı** yapıldı: MAX/FLASH (27B, 16 GB'ta kartın sınırında) yükleme öncesi boş ComfyUI **her zaman kapatılır** — aksi halde MTP draft bağlamı CPU'ya taşıp sohbet **aralıklı ~6-7 tok/s**'ye düşüyor (ölçüldü: medya sonrası geçiş adımı bir kez oran 0,18 verdi). LITE (9B) ComfyUI ile birlikte çalışır (oran 1,04) ve **açık tutulur**. Böylece "ComfyUI açık + 27B" belirsizliği (aralıklı taşma) ortadan kalktı. | scripts/manage-qwen.ps1, tests/test_memory_admission.py |
| 2026-10-11 | Smoke testine `arayuz_sohbet` adımı eklendi (gerçek pencereyi kullanıcı gibi sürer: yazı yaz + Gönder, yanıt alınmalı); `$pid` otomatik değişken çakışması düzeltildi. | scripts/smoke-test.ps1, tests/test_smoke_test_script.py |
| 2026-10-11 | Matematik gösterimine **kimya/genel bilimsel** karakterler eklendi (`Convert-MathText`): denge oku ⇌ ile ⇋ ⇄ ⇆ ↔ ⟷ ⟹ ↪ ↑ ↓ ↕ ve **mhchem `\ce{...}`/`\pu{...}`** desteği (içerik okunur: element sayıları alt simge `H2O`→H₂O, oklar `->`/`<=>`→→/⇌). `->`/`<-` dönüşümü yalnızca `\ce` içinde yapılır; kod bloklarındaki `->` bozulmaz. | qwen-desktop.ps1, tests/test_math_render.py |
| 2026-10-11 | Ses dökümü (whisper.cpp) eklendi: sohbete eklenen ses otomatik dökumlenir ve bulgular dil modeline verilir (OCR/mmproj mantığı). `agent/whisper-tools.py` 16 kHz mono WAV'a çevirip `whisper-cli` ile yazar; **turbo-q5_0 + Silero VAD** (ölçüm: 2 dk ses CPU 53 sn / GPU 2,5 sn; VAD halüsinasyonu sıfırlar). `Invoke-TranscribeWithModelSwap` OCR gibi yerel modeli boşaltıp (GPU whisper'a kalır) geri yükler. Arayüz: Gönder'in solunda **mikrofon** tuşu (Mikrofonu kullan), ek(+) menüsünde **Ses ekle**, yazı kutusunda **sağ tık → Yapıştır** (medya/metin). Ayrıca **`custom` baseUrl işçiye geçirildi** (taban adresi işçide boş kalıyordu → custom sağlayıcı sohbette çalışmıyordu; gerçek uçtan uca testte bulundu, düzeltildi). | agent/whisper-tools.py, agent/qwen-inference.ps1, qwen-desktop.ps1, tests/test_whisper_tools.py, tests/test_qwen_contracts.py |
| 2026-10-11 | Sağlayıcı **maksimum bağlam otomatik algılama**: anahtar doğrulanınca model listesi ucundan `context_length` okunur ve bağlam penceresi otomatik uygulanır (commandcode: 1.000.000). `Get-ProviderModelContexts` (api-providers.ps1) + api-settings entegrasyonu. API çabası (effort) default; `custom` uçtan uca (metin+görsel) doğrulandı. | agent/api-providers.ps1, agent/api-settings.ps1, tests/test_api_providers.py |
| 2026-10-10 | 1.0.0 yayın öncesi varyant kapısı + doğrulama: **PRO (flash) smoke 13/13**, **LITE smoke 12/13** (+1 beklenen atlama: `kimlik_duzenle`), pytest **TR 318 / ENG 317**, kurulum `verify` 12/12, Inno paketi TR/ENG derlendi ve **v1.0.0 yayımlandı**. LITE ölçüm: 85,7 tok/s, medya sonrası 88,4 (oran 1,03), ComfyUI açık kaldı. §15'e "yayın öncesi varyant kapısı" eklendi. | AGENTS.md |
| 2026-10-10 | ComfyUI "kesinlikle açık kalsın" çözüldü: kaçak/mükerrer tespiti süreç **sayısı** yerine örnek **kökü** ile yapılır. ComfyUI bir süreç çiftidir (launcher + base python çocuğu); `Count -gt 1` tek sağlıklı ComfyUI'yi de kaçak sanıp kapatıyordu (isteğin tersi). `Get-ComfyInstanceRoots` + `Stop-ComfyLeaks` yalnızca ek kökleri kapatır ve :8188'i dinleyen örneği korur (`Test-ComfyUnderRoot`); `media-model-swap.ps1` `Clear-ComfyLeaks` aynı mantık; eski `Select-Object -First 1` yalnızca biri kapatıyordu. Ölçüm: gerçek görsel sonrası ComfyUI kapatılmadan MAX yüklendi → **62 tok/s**. | scripts/manage-qwen.ps1, agent/media-model-swap.ps1, scripts/smoke-test.ps1, scripts/install-mamidlabs.ps1, tests/test_memory_admission.py, tests/test_smoke_test_script.py |
| 2026-10-10 | ComfyUI mükerrer/kaçak süreç kusuru bulundu ve düzeltildi: ComfyUI tek süreç değil bir **çifttir** (venv başlatıcı + base python çocuğu); eski `Select-Object -First 1` yalnızca birini kapatıp kalan bağlamı bırakıyordu. Kaçak/mükerrer ComfyUI varken MAX 32K taşıp 0,89 tok/s; tek (taze) ComfyUI ile aynı model 61 tok/s (192 MiB boş) — yani ComfyUI açık kalabilir. `Get-ComfyProcesses` + `Stop-IdleComfy` artık TÜM eşleşen süreçleri kapatır; `media-model-swap.ps1` `Clear-ComfyLeaks` mükerrer kopyaları temizler; smoke-test sonu, arayüz finally'si ve install comfyui aşaması boştaki ComfyUI'yi kapatır. `comfyKeepAlive` varsayılan `true` (açık) korunur. | scripts/manage-qwen.ps1, agent/media-model-swap.ps1, scripts/smoke-test.ps1, scripts/install-mamidlabs.ps1, tests/test_memory_admission.py, tests/test_smoke_test_script.py |
| 2026-10-10 | Tam doğrulandı: `python -m pytest -q` **318 geçti** (4 beklenen atlama) ve tam smoke testi **13/13** (sohbet 44 tok/s, MTP kabul 82/87, grafik bar/pie/function, görsel 56 sn, düzenleme 96 sn, medya sonrası geçiş oran 0,97, video 161 sn, arayüz turu MTP 23/23). Kurulu kök repoyla **program dosyaları birebir aynı**. | AGENTS.md |
| 2026-10-10 | Bağımsız grafik üretimi eklendi: sohbet aracı `generate_chart` + `agent/chart-run.ps1` (gömülü pwsh + System.Drawing; bar/line/pie/scatter/function; güvenli ifade çözümleyici, `Invoke-Expression` yok). Sonuç sohbette satır içi gösterilir ve `outputs\grafikler`'e kaydedilir. Smoke testine `grafik` adımı eklendi (`-SkipChart`). ENG sürümüne de uygulandı. | qwen-desktop.ps1, agent/qwen-inference.ps1, agent/chart-run.ps1, scripts/smoke-test.ps1, tests/test_chart_run.py |
| 2026-10-10 | Matematik (LaTeX) yanıtları için `Convert-MathText` eklendi: ham `$$`/`\frac`/`\int` yerine okunur Unicode (∫, ∞, π, √, ∑, →, ≠, Yunan harfleri), kesir → a/b, üs/alt simge → Unicode (x², ∫₀). Para birimi `$` korunur. | qwen-desktop.ps1, tests/test_math_render.py |
| 2026-10-09 | `comfyKeepAlive` ayarı eklendi (varsayılan `true`): ComfyUI medya işleri arasında açık kalır (yeniden açılma yok). Ölçüm: taşma yok (tampon yerleşimi aynı, graph splits 2), sohbet ~%11 yavaş (49,7→44,2 tok/s). `false` ile tam hız. Ayrıca iki flaky test deterministik yapıldı (run_command çıktı kodlaması UTF-8; boş-dosya testi tmp_path). | scripts/manage-qwen.ps1, tests/test_memory_admission.py, tests/test_bound_path_and_run_command.py, tests/test_binary_file_detection.py |
| 2026-10-09 | Tek-örnek penceresi denetimi sağlamlaştırıldı: yalnızca başlık yerine pencere SINIFI da doğrulanır. Aynı başlıklı başka bir pencere (Explorer `TabProxyWindow`, video penceresi) varken uygulama açılmadan kapanıyordu ("pencere açılmadan kapandı"). | qwen-desktop.ps1, tests/test_qwen_contracts.py |
| 2026-10-09 | Taşma/«Model işlemi başarısız» yapısal kök nedeni çözüldü: uygulamanın tek büyük CUDA bağlamı ComfyUI, dil modeli yüklenmeden önce HER ZAMAN kapatılıyor (bağlam açıkken sürücü VRAM'i parçalıyor; 15.290 MiB "boş" + bağlam → 6 tok/s). MAX/FLASH bellek payı 800→600 MiB (eşik 15200); temiz GPU'da 15244 MiB boşken çalışan 27B model artık reddedilmiyor. LITE+MAX birlikte doğrulandı (97 / 58 tok/s). Profil yöneticisine "Profili sil" eklendi (yalnızca profile özel dosyalar; LITE'ın ortak medyası korunur). Sihirbazda 27B etiketi "PRO". ENG'e de uygulandı. | scripts/manage-qwen.ps1, agent/profile-catalog.ps1, packaging/windows/mamidlabs.iss, tests/test_memory_admission.py, tests/test_profile_delete.py |
| 2026-10-09 | VRAM eşiği gerilemesi düzeltildi: önceki ayardaki 1000 MiB pay eşiği 15600 MiB yapıp makinenin normal boş değerini (15442–15558) yanlış reddediyordu. Pay 800 MiB'a çekildi (eşik 15400); ComfyUI açıkken kapatılır, kapalı/açılışta model yüklenir. ENG sürümüne de uygulandı. | scripts/manage-qwen.ps1, tests/test_memory_admission.py |
| 2026-10-09 | Medya sonrası ~6 tok/s düşüşünün kök nedeni düzeltildi: VRAM bütçe tahmini gerçek yükü eksik hesaplıyordu (pay 300→1000 MiB, MAX/FLASH toleransı 256→0). 27B model GPU'da ~15378-15442 MiB ister; boştaki ComfyUI varken MTP draft bağlamı CPU'ya taşınıp üretim 44→6-7 tok/s'ye düşüyordu. Ayrıca `Release-Comfy` gerçek boş VRAM'i doğrular. Smoke testine gerçek arayüzü süren `arayuz` adımı eklendi (MTP + "sunucu kapatıldı" kontrolü). | scripts/manage-qwen.ps1, agent/media-model-swap.ps1, agent/imagegen-run.ps1, agent/videogen-run.ps1, scripts/smoke-test.ps1, tests/test_memory_admission.py, tests/test_media_release.py, tests/test_smoke_test_script.py |
| 2026-10-09 | Medya sonrası sohbet yavaşlaması düzeltildi: VRAM payı toleransı profile göre yapıldı; 16 GB'ta ~1 GB tolerans 27B katmanlarını paylaşılan belleğe taşırıp sohbeti yavaşlatıyordu. Ayrıca `install-mamidlabs.ps1 -Stage layout` varsa `kurulum-kaynak` kaynak paketini tazeler. (Kök neden sonraki bir düzeltmede netleşti; bkz. üstteki satır.) | scripts/manage-qwen.ps1, scripts/install-mamidlabs.ps1, tests/test_memory_admission.py, tests/test_install_layout_source.py |
| 2026-10-08 | Yerel web yönetimi eklendi: tarayıcıdan sohbet/model değiştirme/üretilen dosyalar. Sunucu (`agent/web-server.ps1`) varsayılan yalnızca localhost'a bağlanır, sabit şifre + HttpOnly/SameSite=Strict oturum çerezi (30 gün), tek kullanımlık 5 dk'lık bağlantı linki (OpenCode 'pair' tarzı), 5 hatalı girişte kilit, `outputs\` ile sınırlı dosya erişimi. Ayrıca: MTP sonrası VRAM payı küçük aşımı tolere eder (model açılmama hatası düzeldi); private depo güncelleme denetimi GitHub tokenı kullanır; üretilen dosyalar "Aç" ile tek tıkla açılır. | agent/web-server.ps1, agent/web-settings.ps1, scripts/web-serve.ps1, scripts/manage-qwen.ps1, agent/profile-catalog.ps1, qwen-desktop.ps1, tests/test_web_server.py, tests/test_memory_admission.py, tests/test_qwen_contracts.py |
| 2026-10-08 | Lisans MIT'den tescilli (tüm hakları saklı, telif: Aybars Haydar Altuntaş) lisansa geçirildi. | LICENSE, README.md, docs/kurulum.md, tests/test_setup_wizard.py, CHANGELOG.md |
| 2026-10-08 | LITE'ta MTP (speculative decoding) etkinleştirildi: 9B GGUF'una dönüşümde düşen MTP/nextn başlığı indirme sırasında `mtp_inject.py` ile eklenir (kaynak HF safetensors'tan yalnızca MTP tensorleri, HTTP range; normlara `w+1`). `manage-qwen.ps1` MTP'yi artık GGUF'ta `nextn` katmanı varsa (max/flash/lite) açar (`Test-GgufHasMtp`), yoksa eklemez. Ölçülen kabul ~0,93, ~2x hız; çıktı kayıpsız. | agent/mtp_inject.py, agent/hf-hub.py, agent/profiles.json, agent/profile-catalog.ps1, scripts/download-profile.ps1, scripts/manage-qwen.ps1, tests/test_lite_profile.py, tests/test_mtp_inject.py |
| 2026-10-08 | MAX/FLASH + LITE için MTP (Multi-Token Prediction) speculative decoding (`--spec-type draft-mtp`); ayrı draft model gerekmez ve çıktı kayıpsız. `settings.mtp=false` ile kapatılır. | scripts/manage-qwen.ps1, tests/test_lite_profile.py |
| 2026-10-07 | `run_command` artık yalnızca kullanıcı açıkça komut/terminal istediğinde modele sunulur (`Test-CommandIntent`); web hatasında model komutla "etrafından dolanmaya" kalkışamaz. LITE için derin akıl yürütme talimatı eklendi; web hatasından sonra web araçları sunulmaz + ağ-probe komutları reddedilir. | agent/qwen-inference.ps1, qwen-desktop.ps1, tests/test_qwen_contracts.py, tests/test_lite_profile.py, tests/test_approval_flow.py |
| 2026-10-07 | Smoke testine `gecmis_devam` adımı eklendi: sohbeti DPAPI ile kaydet → yeniden yükle → devam et; hiçbir tur hata vermez (`-SkipHistoryResume` ile atlanır). Adım, araçsız turda `$done.data`'nın `$null` dönmesine karşı `if ($done.data)` ile korunur. `test_chat_storage.py` kaydet/yükle serileştirmesini doğrular. | scripts/smoke-test.ps1, tests/test_chat_storage.py, tests/test_smoke_test_script.py |
| 2026-10-07 | Smoke testine `ag_gecisi` adımı eklendi: ardisik turlarda ag açık/kapalı değişirken yerel işçi hiçbir turda hata üretmez (`-SkipNetworkSwitch` ile atlanır). | scripts/smoke-test.ps1, scripts/setup-run.ps1, agent/qwen-inference.ps1 |
| 2026-10-07 | Yerel akışta finish_reason sonrası/kopma toleransı genişletildi: kullanılabilir sonuç (finish_reason veya yanıt metni veya araç çağrısı) varken bağlantı kopması hata sayılmaz; cevabın altına "[Hata]" eklenmez. | agent/qwen-inference.ps1, tests/test_stream_watchdog.py |
| 2026-10-07 | Smoke testine `cevrimdisi` adımı eklendi: kurulum sonrası doğrulamada ağ engellenip web aracının çökmeden hata JSON'u döndürdüğü kanıtlanır (`-SkipOffline` ile atlanır). | scripts/smoke-test.ps1, scripts/setup-run.ps1, tests/test_offline_mode.py |
| 2026-10-07 | Çevrimdışı davranış testleri eklendi: web araması, sayfa okuma ve referans görsel araçları ağ yokken istisna atmadan temiz hata JSON'u döndürür; gerçek alt süreç kara delik proxy ile çökmeden hata döndürür. | tests/test_offline_mode.py, docs/teknik-notlar.md |
| 2026-10-07 | Yerel akışta bayat keep-alive bağlantısı kaynaklı aralıklı "zorla kapatıldı" (WSAECONNRESET) hatası düzeltildi; yerel istekler her tur taze bağlantı kurar, yanıt metni varken kapanma hata sayılmaz. | agent/qwen-inference.ps1, tests/test_stream_watchdog.py, tests/test_qwen_contracts.py, docs/teknik-notlar.md |
| 2026-09-27 | 1.0.0 ilk sürüm. | tümü |
