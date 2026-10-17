# Sürüm geçmişi

Biçim [Keep a Changelog](https://keepachangelog.com/tr-TR/1.1.0/) önerisini, sürüm numaraları
[Anlamsal Sürümleme](https://semver.org/lang/tr/) kurallarını izler.

## [1.0.0] - 2026-10-10

İlk sürüm. Windows'ta tamamen yerel çalışan çok modlu yapay zekâ çalışma alanı: tek bir WinForms
penceresinde sohbet, web araması, belge okuma/üretimi, OCR, görsel anlama, görsel üretimi, fotoğraf
düzenleme, video üretimi ve grafik çizimi. Dil modeli `llama.cpp` (`llama-server`), görsel/video
modelleri `ComfyUI` üzerinde, kullanıcının NVIDIA ekran kartında çalışır. OpenAI, Claude, Gemini,
DeepSeek ve OpenAI uyumlu özel uçlar isteğe bağlı API sağlayıcılarıdır.

### Değişti
- **Lisans PolyForm Strict 1.0.0 oldu (kaynak-açık; yalnızca ticari olmayan kullanım).**
  `LICENSE` ve `EULA.txt` resmî PolyForm Strict 1.0.0 metnini taşır: yazılımı dağıtma ve
  değiştirme/türev eser üretme hakkı verilmez; ticari kullanım için önceden yazılı izin gerekir.
  README lisans bölümü, `docs/kurulum.md` ve lisans testi buna göre güncellendi. Sürüm numarası
  değişmedi (1.0.0).

### Belgeler
- **README'ye "Platform desteği" bölümü eklendi.** Linux ve macOS portları
  **deneysel** olarak işaretlendi ve tek tıkla o depolara götüren tıklanabilir
  platform başlıkları (rozetler) eklendi; hızlı menüye de "Platform desteği"
  bağlantısı eklendi.
- **README'nin platform bölümü sadeleştirildi.** Başlık altındaki platform
  rozetleri ("etiketler") kaldırıldı; "Linux → depo" ve "macOS → depo"
  satırlarındaki ok ve ayrı depo bağlantısı kaldırıldı, "Depo" sütunu tablodan
  çıkarıldı. **Linux** ve **macOS** yazılarının kendisi tıklanabilir oldu ve
  ilgili depoya yönlendiriyor. Kurulum sütunundaki `MamidLabs_Setup.exe`, `.deb`
  ve `.dmg` tıklanabilir ve **doğrudan indirmeye** gider
  (`releases/latest/download/...`). "Also available for Linux and macOS" bölümü
  kaldırıldı. (`mamidlabs_linux` ve `mamidlabs_mac` depolarına, `v*` etiketinde
  sabit adlı (`mamidlabs.deb` / `MamidLabs.dmg`) paketleri yükleyen GitHub Actions
  iş akışları eklendi.)
- **README'nin Kurulum sütunu artık gerçek dosya adlarını gösteriyor.**
  `.deb (kurulum sihirbazı)` / `.dmg (kurulum sihirbazı)` yerine Linux ve macOS
  satırları `mamidlabs.deb` / `MamidLabs.dmg` yazar; Windows satırındaki
  `MamidLabs_Setup.exe` ile aynı biçim. Bağlantılar yine doğrudan indirmeye gider.

### Düzeltildi
- **PRO/FLASH hızını yarıya düşüren VRAM taşması, otomatik 32K → 16K bağlam düşüşüyle
  giderildi.** Canlı ölçüm (llama.cpp'nin kendi tampon raporu, RTX 5060 Ti 16 GB) 27B'nin
  **32K bağlamda gerçek GPU ayak izinin ~15,77 GiB** olduğunu gösterdi (model tamponu 13945 MiB +
  KV 576 MiB + recurrent-state tamponu 598,5 MiB + hesap ~112 MiB + CUDA bağlamı); normal bir
  Windows masaüstü ise yalnızca **~15,50 GiB boş** bırakır. Eski sabit **750 MiB** pay (eşik 15350)
  bu yüzden 32K yüklemeyi kabul ediyor ve **~400 MiB Windows paylaşılan belleğine taşıyarak** üretimi
  **~40 tok/s'den ~27 tok/s'ye** düşürüyordu. Pay artık **bağlam-duyarlıdır** (32K'da 1200 MiB,
  16K'da 800; LITE'ta 300 değişmedi) ve MAX/FLASH **önce 32K dener, tam sığmazsa 16K'ya düşer** —
  aynı model ve ağırlıklar, yarım KV cache — böylece model tümüyle VRAM'de kalır (ölçülen 16K ayak
  izi 15324 MiB, ~40 tok/s, taşma yok). Seçilen bağlam hem bellek kapısını hem `--ctx-size`'ı
  belirler ve arayüz gerçek bağlamı çalışan sunucudan (`/props` → `default_generation_settings.n_ctx`)
  **geri okur**, böylece sıkıştırma eşiği uyuşur. Sürüm değişmedi (`MyAppVersion` 1.0.0 kalır).
- **`test_python_tool_sets_hf_home_for_child` kırılganlığı giderildi (CI'da bir kez düştü).**
  Test, `Invoke-PythonTool`'un alt sürece `HF_HOME` verdiğini yalnızca `pwsh`'in kendi
  stdout'undan okuyordu; yüklü bir koşucuda bu çıktı ara sıra boş dönüyor ve test
  **sahte kırmızı** veriyordu. Artık alt süreç `HF_HOME` değerini probe dosyasının
  yanına `hf_home.txt` olarak da yazar; asıl iddia bu dosyaya bakar (dosya sistemi
  kesin sinyal) ve `pwsh` çıktısı geldiğinde ek olarak doğrulanır. Aynı düzeltme ENG
  sürümüne de uygulandı.
- **Kısmi web başarısızlığı artık "arama başarısız" sayılmıyor.** Gerçek bir turda 7 web çağrısının
  4'ü başarılı olduğu hâlde yanıta "[İnternet araması başarısız oldu…]" notu ekleniyordu: not,
  `webToolFailCount > 0` koşuluna bağlıydı ve tek bir sayfanın 403 dönmesi ya da bir sorgunun
  "sonuç yok" demesi aramayı başarısız gösteriyordu. Artık "web erişimi kurulamadı" kararı
  **web denendi VE hiç başarılı çağrı olmadı** koşuluna bağlıdır (`webToolFailCount -gt 0 -and
  -not webToolSuccess`); en az bir web çağrısı veri getirdiyse görünür not eklenmez, modele
  "internet yok" sistem notu verilmez, ağ-probe komutları reddedilmez ve web araçları kilitlenmez.
  Aynı düzeltme `Add-WebFailureNote`, `run_command` ağ-probe bloğu ve ana döngüdeki sistem
  notu/araç kilidi için tutarlı uygulandı. Test: `tests/test_generation_intent_guard.py`.
- **Yeniden adlandırılan eski motor dosyaları güncellemede geride kalmıyor.** Motor/altyapı adları
  MamidLabs'a taşındığında üst düzey `qwen-desktop.ps1` / `launch-qwen-desktop.vbs` dosyaları eski
  kurulumlarda kalıyordu (Inno `ignoreversion` / `Copy-Item -Force` eski dosyayı silmez). `layout`
  artık bu adları kökten ve `kurulum-kaynak`ten siler (`Remove-LegacyTopFiles`); `.iss`
  `[InstallDelete]` (yükseltme) + `[UninstallDelete]` (kaldırma) ve kaldırıcı `$programEntries`
  aynı adları hedefler.
- **Normal başlatılan uygulamada sesli giriş çalışmıyordu: `HF_HOME` çalışma anında hiç
  ayarlanmıyordu.** Ses modelleri (whisper large-v3-tr + AST ses olayı modeli) kurulum kökünün HF
  önbelleğinde (`tools\hf-home`) durur; kurulum `HF_HOME`'u oraya yalnızca kurulum sırasında ayarlar.
  Çalışma anında uygulama `HF_HOME` ayarlamadığı için işçi **varsayılan** HF önbelleğine düşüyordu
  (`%USERPROFILE%\.cache\huggingface`); AST modeli orada olmadığından `events.tag()` modeli yüklerken
  istisna atıyor ve **tüm döküm** "Can't load feature extractor ..." hatasıyla düşüyordu (yalnızca
  sessiz "olay yok" durumu ele alınmıştı). İki düzeltme: (1) uygulama başlarken `HF_HOME`'u kurulum
  önbelleğine ayarlar (`mamidlabs-desktop.ps1`) ve işçi/araçlara açıkça verilir (`agent/mamidlabs-inference.ps1`
  içinde `Get-HfHome`; tek-atımlık `Invoke-PythonTool` ve kalıcı `Start-AsrServerProcess`), böylece iki
  model de çevrimdışı bulunur; (2) `events.tag()` model yüklemesini korur; model bir gün eksikse
  olaylar dökümü düşürmek yerine **atlanır** (boş liste). Testler: `tests/test_transcriber.py`
  (korumalı yükleme + `Invoke-PythonTool`'un alt sürece `HF_HOME` verdiğinin gerçek pwsh ile
  doğrulanması + statik bağlama).

### Değişen
- **Motor/altyapı adları ürün adına (MamidLabs) taşındı; "qwen" yalnızca gerçek model kimliğinde kaldı.**
  Ürün adı "Qwen" değildir; iç motor/altyapı adları ürün adıyla anılır. Yeniden adlandırılanlar:
  dosyalar `qwen-desktop.ps1`→`mamidlabs-desktop.ps1`, `launch-qwen-desktop.vbs`→
  `launch-mamidlabs-desktop.vbs`, `agent/qwen-inference.ps1`→`agent/mamidlabs-inference.ps1`,
  `agent/qwen-agent-tools.py`→`agent/mamidlabs-agent-tools.py`, `scripts/manage-qwen.ps1`→
  `scripts/manage-mamidlabs.ps1`, `tests/test_qwen_contracts.py`→`tests/test_mamidlabs_contracts.py`;
  çalışma zamanı sözleşmeleri `QwenWindow`→`MamidLabsWindow`, `Stop-LocalQwen`→`Stop-LocalMamidLabs`,
  `Restart-LocalQwen`→`Restart-LocalMamidLabs`, `Get-ManageQwenPath`→`Get-ManageMamidLabsPath`,
  mutex `Local\QwenLocalModelControl`→`Local\MamidLabsModelControl`, günlük deseni
  `qwen-<profil>.std{out,err}.log`→`mamidlabs-<profil>.std{out,err}.log`, User-Agent
  `QwenLocal/1.0`→`MamidLabs/1.0`, sihirbaz seçeneği `OptQwen38`→`OptPro`. **Korunanlar (gerçek model
  kimliği):** profil alias'ları (`qwen3.8-27b-max`/`flash`, `qwen3.5-9b-lite`), GGUF/mmproj dosya
  adları, HF depo kimlikleri, ComfyUI dosyaları (`qwen3vl_4b_fp8_scaled.safetensors`,
  `qwen_image_vae.safetensors`, `TextEncodeQwenImageEditPlus`), `qwen35.*` mimari anahtarları ve
  model adı geçen metinler. Araç adları değişmedi (hiçbiri "qwen" içermiyordu). Kurulum/kaldırma,
  CI yol filtreleri ve dokümanlar bu adlarla birlikte güncellendi.
- **Model yüklenmeden önce otomatik VRAM temizliği.** Uygulamaya ait artık/kaçak GPU işçileri
  (boşta kalmış kalıcı ses işçisi `whisper-tools.py --serve` ve OCR işçisi `ocr-tools.py`) dil
  modeli yüklenmeden **önce** otomatik kapatılır: çökme/zorla kapatma sonrası kalan CUDA bağlamları
  (~140–600 MiB) 27B'nin ince payını yiyip "yetersiz VRAM" hatasına yol açabiliyordu.
  `scripts/manage-mamidlabs.ps1` bunları `Get-AppGpuWorkers`/`Stop-OrphanWorkers` ile temizler, sürücünün
  VRAM'i bırakmasını bekler ve bellek kapısını sınırlı kez yeniden dener (6→8 deneme). Yalnızca
  kurulum kökü altındaki MamidLabs süreçleri hedeflenir; başka uygulamalara dokunulmaz. Test:
  `tests/test_memory_admission.py` (statik sıra + gerçek pwsh ile süreç seçimi).
- **Bütün araçlar bütün profillerde aynı sunulur (yalnızca kimlik düzenleme hariç).** Denetim,
  `Get-ToolDefinitions`'ın profile bağımsız olduğunu doğruladı: MAX/FLASH/LITE aynı araç kümesini
  görür; tek profil farkı, 8 GB VRAM'e sığmayan kimlik korumalı fotoğraf düzenlemedir
  (`kimlik_duzenle`; LITE'ta hiç sunulmaz ve `imagegen-run.ps1` ikinci savunma olarak reddeder).
  Bu davranış artık `tests/test_lite_profile.py`'deki yeni testle kilitlidir (gerçek pwsh ile iki
  profilin araç kümesi ve `generate_image` mod listesi karşılaştırılır).
- **Sesli giriş gecikmesi düşürüldü: sıcak (kalıcı) ses döküm işçisi.** Her ses turunda tekrarlanan
  sabit maliyet (Python başlatma + `torch`/`transformers`/`faster-whisper` importları; ölçüldü ~10 sn,
  ilk/disk soğukken ~25 sn) artık oturumda **bir kez** ödenir: `agent/whisper-tools.py --serve` tek bir
  kalıcı işçi süreci olarak 127.0.0.1 üzerinde dinler (port/pid `logs\asr-server.json`'da) ve modelleri
  süreç içinde tutar. Dil modeli VRAM'e geri yüklenmeden **önce** ses modelleri boşaltılır ve işçi
  **durdurulur** (kalan CUDA bağlamı ~140 MiB, 27B'nin ince payını yemesin), tur sonunda arka planda
  yeniden başlatılır; işçi boşta 600 sn sonra ya da uygulama kapanınca kendini bitirir (artık
  süreç/VRAM/RAM sızıntısı yok). İşçi ulaşılamazsa döküm yine tek-atımlık `Invoke-PythonTool` yoluna
  düşer; davranış korunur.
- **LITE görsel projektörü (mmproj) CPU'ya taşındı:** LITE artık 8 GB VRAM'e sığıyor
  (kullanılan 7885 → 7249 MiB, boş alan 72 → 708 MiB). Üç profilde de mmproj CPU'da çalışır ve
  VRAM bütçesine girmez; sohbet hızı değişmedi (içeriğe bağlı ~40–79 tok/s), yalnızca görsel
  okuma projektör CPU'da hafifçe yavaşladı.
- **Kurulum artık `assets\installer\*` (sihirbaz görselleri) dahil tüm program dosyalarını köke
  kopyalar;** böylece kurulu program dosyaları repoyla birebir aynıdır. Daha önce bu dosyalar `.iss`
  ve betik tarafından dışlanıyordu; artık dışlanmaz (yalnızca `agent\__pycache__\*` ve `*.pyc`
  dışlanır). Kullanıcı verisine dokunulmaz.

### Düzeltilen
- **Taşma doğrudan engelleniyor; model boş VRAM'in tamamını kullanır.** Model VRAM'e tam sığmayıp
  paylaşılan belleğe taşındığında sohbet ~20x yavaşlıyordu (ölçüm: temiz yükleme 15454 MiB boşta
  ~41-55 tok/s; taşınca ön-işleme ~20 tok/s). Ölçülen model ayak izi **15350 MiB** olduğundan
  MAX/FLASH bellek payı **750 MiB** (eşik 15350) yapıldı: model **ancak tam sığacaksa** yüklenir,
  tüm boş VRAM'i kullanır ve **taşmaz**; normal masaüstünde hatasız açılır. llama.cpp'nin `--fit`
  otomatik yerleştirmesi denendi ve daha temkinli çıktığı (tüm VRAM'i kullanmadı, ~23 tok/s) için
  kullanılmaz; `--gpu-layers 99` korunur.
- **Arayüzde model hatasının gerçek nedeni gösterilir.** Yetersiz VRAM gibi durumlarda jenerik
  "Model işlemi başarısız" yerine gerçek neden (ör. "Yetersiz boş VRAM: …") görünür; yönetici
  sürecinin stderr'i arayüze taşınır (`Format-ModelSwitchError`).
- **Sistem isteminde uydurma test/teorem/kaynak adı yasağı geri getirildi.** "Sert anti-uydurma" yeniden yazımı sabit istemden bu talimatı düşürmüştü (testler yakaladı); yeniden eklendi.
- **Sert anti-uydurma katmanı.** (1) Güncel/zaman duyarlı bilgi isteyen geniş bir küme (hava durumu,
  haber, fiyat/kur, "en son çıkan", skor, bugün/yarın, 20xx yılı…); web erişimi yoksa (arama
  başarısız ya da İnternet kapalı) bu soruların **model metni gösterilmez**, yalnızca "bu bilgi
  internet bağlantısı olmadan elde edemeyeceğim bir bilgi" mesajı verilir. (2) Web **denendi ama
  hiç başarılı olmadıysa**, diğer yanıtlarda uydurma "Kaynak:"/"Source:" satırları ve çıplak
  http(s) URL'leri **metinden çıkarılır** (`Remove-FabricatedCitations`). (3) Sistem istemi artık
  kesin olan bilgiyi (tanım, matematik, kod, genel kültür) net cevaplamayı, ancak güncel ve
  doğrulanamaz bilgide tahmin yürütmemeyi/uydurmamayı söyler. (4) Web araştırması (güncel bilgi)
  istenen bir turda açıkça istenmedikçe görsel/video/belge/grafik araçları **hiç sunulmaz**; model bu
  işlere girişemez.
- **Akış yarıda kesilirse anlaşılır mesaj; net cevap verilemiyorsa tahmin/uydurma yok.** Bir tur
  **görünür yanıt üretmeden** (yalnızca düşünme birikmişken) koparsa bu artık hata sayılmaz; düşünme
  kapatılarak yanıt doğrudan istenir (boş-yanıt kurtarma yolu). Başka bir kopma/hatada
  `Get-FriendlyErrorMessage` ham .NET/HTTP mesajını (ör. "The response ended prematurely.
  (ResponseEnded)") sade Türkçeye çevirir. Ayrıca sistem istemi, net/kesin bir cevap veremiyorsa
  **tahmin yürütmemesini ve uydurmamasını**, neyi bilmediğini kısaca söylemesini ister.
- **Uydurma tamamen engellendi; istenmeyen üretim ve araç döngüleri kapatıldı.** Uydurma eğilimini
  ortadan kaldırmak için nihai yanıt deterministik olarak güvenli hâle getirilir:
  - **Güncel bilgi** (hava durumu, haber, fiyat, "en son çıkan model"…) isteyen bir turda web
    erişimi yoksa (arama başarısız ya da İnternet çipi kapalı) modelin ürettiği **metin kullanılmaz**;
    uydurulmuş içerik ekrana hiç gelmez, yerine dürüst bir mesaj gösterilir (`Get-FinalAnswer`).
    Web araması başarısız olup yanıt bunu belirtmiyorsa (güncel bilgi şart değilse) not eklenir
    (`Add-WebFailureNote`).
  - Üretim araçları (`create_document`, `generate_video`, `generate_chart`) `generate_image` gibi
    **çağrı anında niyet denetimiyle** korunur (`Test-DocumentRequestIntent` /
    `Test-VideoRequestIntent` / `Test-ChartRequestIntent`); kullanıcı açıkça istemediyse çalışmaz.
  - `read_document` yalnızca ekli belge ya da dosya niyeti varsa sunulur (model, elinde dosya
    yokken olmayan bir dosyayı uydurup okumaya çalışıyordu).
  - Aynı üretim aracı bir turda bir kez çalışır (`$script:completedTools`): küçük model grafiği 8
    kez üretip **boş yanıt** veriyordu; artık boş yanıt yerine net bir mesaj verilir.
  Regresyon testleri: `tests/test_generation_intent_guard.py`.
- **"Tümünü Sil" artık o an AÇIK olan sohbeti silmiyor.** Geçmiş sohbetler penceresinde
  "Tümünü Sil" listenin tamamını (ekranda duran sohbet dahil) siliyordu. Artık ekranda duran
  sohbetin dosyası silinecekler listesinden çıkarılır ve onay penceresinde "Açık olan sohbet
  korunur." yazar; açık sohbet geçmişte kalmaya devam eder. Karar, saf ve test edilebilir
  `Get-DeletableChatPaths` yardımcısıyla verilir (`tests/test_chat_history_delete.py`).
- **Ses eki + "Ajan" çipi: modele dosya araçları sunulmuyor.** Ses eklenen bir turda ses zaten
  faster-whisper ile dökümlenip metne çevrildiği hâlde, Ajan çipi açıkken küçük model
  `list_bound_files`/`read_bound_file`/`write_bound_file` ile ses DOSYASINI aramaya/okumaya/yazmaya
  kalkıp boşa turlar harcayabiliyordu (arayüz testinde görüldü). Artık ses eki olan turda bu üç
  araç sunulmaz (kullanıcı açıkça dosya istemedikçe) ve başarılı döküm notuna "dosyayı araçlarla
  açma, yanıtı doğrudan döküme dayandır" yönlendirmesi eklenir.
- **Kurulum/güncelleme doğruluk düzeltmeleri.** Betikle (`scripts\install-mamidlabs.ps1`) kurulan
  kopyalarda güncelleme denetimi yerel sürümü okuyabiliyor: `layout` aşaması kaldırma kaydına
  `DisplayVersion` yazar (değer `-AppVersion` ya da `.iss` `MyAppVersion`'dan) ve uygulama içi
  denetim Inno kaydı yoksa bu kayda düşer. Güncelleme artık repodan silinen dosyaları geride
  bırakmaz: `agent\`, `scripts\`, `assets\` ve `requirements\` (ve `kurulum-kaynak` kopyası)
  kopyalamadan önce boşaltılır, kullanıcı verisi korunur. `requirements\` köke eklendiği için
  belgelenen `install-mamidlabs.ps1 -Stage layout` komutu `-Source` verilmeden de çalışır.
  Sihirbaz kurulumunda mükerrer `MamidLabs` girdisi açılmaz. Kaldırıcı artık `EULA.txt` ve
  `requirements` dizinini de siler; kök gerçekten kaldırılır.

### Belgeler
- **README ve AGENTS ürün özeti güncellendi.** `README.md`'ye (TR) grafik çizimi yeteneği — tanıtım
  satırı ve Özellikler tablosu — ve yeni güvenlik davranışları (istenmeden belge/görsel/video/grafik
  üretilmez; web araması başarısızsa ya da İnternet kapalıyken güncel bilgi istenirse uydurmak yerine
  durum dürüstçe bildirilir) eklendi. `AGENTS.md` §1 ürün özeti grafik çizimiyle hizalandı.
- **Doküman tutarlılık geçişi (davranış değişmedi).** `AGENTS.md`, `docs/kurulum.md`,
  `docs/teknik-notlar.md`, `packaging/windows/mamidlabs.iss` (yorum), `mamidlabs-desktop.ps1` (yorum),
  `scripts/manage-mamidlabs.ps1` (yorum) ve `agent/transcriber/__init__.py` (yorum) güncel kodla
  hizalandı: ses motoru açıklamaları `faster-whisper large-v3-tr (agent\transcriber)` olarak
  düzeltildi, kurulum aşama listesine `asr` ve kullanım satırına `-AppVersion`/`-SkipAudio` eklendi,
  test sayısı/süresi ile MTP kabul oranı gerçek ölçümlere çekildi ve yinelenen/süperseded notlar
  tekilleştirildi.

### Eklenen
- **Sohbet (yerel + API):** `llama-server` ile yerel sohbet (MAX/FLASH/LITE profilleri; Qwen3.8 27B ve
  Qwen3.5 9B), MTP (Multi-Token Prediction) speculative decoding ile ~2x hız (ayrı draft model
  gerekmez, çıktı kayıpsız). OpenAI, Claude, Gemini, DeepSeek ve OpenAI uyumlu özel uçlar.
- **Medya üretimi (yerel, ComfyUI):** metinden görsel (Krea-2 Turbo), görselden yeniden üretim, stil
  referansı, kimlik korumalı fotoğraf düzenleme (Krea 2 Identity Edit; MAX/FLASH) ve video üretimi
  (Wan 2.2 TI2V 5B). ComfyUI varsayılan olarak yalnızca medya üretimi sırasında çalışır (iş bitince
  kapatılır; boşta ne VRAM ne RAM tutar); LITE'ta `comfyKeepAlive=true` ile medya işleri arasında
  açık tutulabilir. Kaçak/mükerrer örnek yükleme öncesi temizlenir.
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
- **Zor soruda boş görünür yanıt regresyonu (düşünme tüm çıktı bütçesini yiyordu).** Uçtan uca
  matematik testinde LITE (9B) zor bir integral sorusunda **8192 tokenın tamamını** (~159,7 sn)
  düşünmeye harcayıp **görünür yanıt üretmedi**; baloncukta yalnızca "İntegral" kaldı
  (`logs\mamidlabs-lite.stderr.log`: `eval 159714 ms / 8192 tokens`). Kök neden: düşünme “sınırsız”,
  çıktı tavanı `--predict 8192` ve arayüz `maxTokens 8192` **aynı bütçeyi** paylaşır; “adımları
  iki kez kontrol et” talimatı düşünmeyi daha da uzatıyordu ve mevcut boş-yanıt yedeği de aynı
  8192'ye takılıyordu. (1) **Düşünme-kapalı kurtarma:** yeni `Set-NoThinkingRequest`
  (`chat_template_kwargs = @{ enable_thinking = $false }`, ayrıca `/no_think`) ile ikinci deneme
  düşünmeyi **fiilen kapatır** (LITE `reasoning_effort`u yok saydığı için tek garantili yol) ve
  görünür yanıtı **garanti eder**; tetikleyici hem **boş** hem de çıktı tavanında kesilip
  (`finishReason='length'`) **kırık metin** bırakan yanıtı kapsar. (2) **Sistem istemi yumuşatıldı:**
  “en az İKİ KEZ kontrol et” → “kritik adımları tekrar gözden geçir **ama yanıtını da mutlaka yaz**;
  çok uzun düşünüp yanıtsız kalma” (LITE derin-düşünme satırı da aynı yönde). (3) Düşünme sınırsız
  olduğundan `--predict`i artırmak yanıtı garanti etmez, yalnızca düşünmeyi uzatıp gecikmeyi büyütür
  (ölçüm: 8192 token = 159,7 sn); bu yüzden garanti kurtarma seçildi, KV/bağlam taşması yaratılmadı.
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
  `manage-mamidlabs -Action stop` ile **süreç kapatılıyor** (kod davranışı değişmedi).
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
  listesi (`mamidlabs-desktop.ps1`, `launch-mamidlabs-desktop.vbs`, `README.md`, `LICENSE`) köke ve
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
  düşüyordu); LITE'ta varsayılan olarak kapatılır, `comfyKeepAlive=true` ile medya işleri arasında açık
  tutulabilir.
- **`custom` (OpenAI uyumlu özel uç) sohbette çalışmıyordu:** taban adres yalnızca arayüz ayarında
  tutuluyordu; işçi ayarları okumadığı için `custom` istekleri "taban adresi gir" ile duruyordu
  (yalnızca ayar penceresindeki doğrulama çalışıyordu). Masaüstü artık `baseUrl` + ayarları işçiye
  geçirir; commandcode ile metin+görsel uçtan uca doğrulandı.
