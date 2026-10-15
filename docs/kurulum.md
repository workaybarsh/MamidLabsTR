# Kurulum

Bu belge MamidLabs'in ilk kurulumunu, güncellenmesini, doğrulanmasını ve sık karşılaşılan
sorunların giderilmesini anlatır.

## Gereksinimler

| | LITE | MAX / FLASH |
|---|---|---|
| İşletim sistemi | Windows 10 2004+ ya da Windows 11 | Windows 10 2004+ ya da Windows 11 |
| Ekran kartı | NVIDIA, en az 8 GB VRAM | NVIDIA, en az 16 GB VRAM |
| Bellek | 16 GB RAM | 32 GB RAM |
| Boş disk (SSD) | ~58 GB (modeller ~36 GB) | ~75 GB (modeller ~52 GB) |
| Yazılım | Güncel NVIDIA sürücüsü | Güncel NVIDIA sürücüsü |

Kurulum betiği bu koşulları ön kontrolde denetler ve eksikleri uyarı olarak raporlar. Python 3.10+,
Git, 7-Zip ve Visual C++ Redistributable yoksa sihirbaz bunları winget ile kurar; betikle kurulumda
Python ve Git önceden kurulu olmalıdır.

## Tek tıkla kurulum (sihirbaz)

`MamidLabs_Setup.exe` çalıştırılınca şu sayfalar gelir:

| Sayfa | İş |
|---|---|
| Karşılama ve lisans | Tescilli lisans (tüm hakları saklı) |
| Kurulum klasörü | Varsayılan kullanıcı başına program klasörü (`%LOCALAPPDATA%\Programs\MamidLabs`); istenirse değiştirilebilir. Modeller dahil ~58–75 GB, SSD önerilir |
| Profil raporu | GPU, VRAM, RAM ve boş disk ölçülür; her profil için uygun / sınırda / uygun değil kararı ve öneri (`scripts\profile-report.ps1`) |
| Model profili | LITE, Qwen3.8 27B (MAX ve FLASH aynı dosyaları kullanır), **şimdi indirme (sonra kuracağım)** ya da **kendi modelim / API hesabım** |
| Kendi modellerin | Dil (.gguf), görsel (Krea 2 Turbo) ve video (Wan 2.2 TI2V 5B) dosyasını yoluyla seç; kopyalanmaz |
| API hesabı | İlk açılışta API bağlantıları penceresini aç (anahtar kurulumda istenmez) |
| Ek görevler | Görsel/video üretimi, ses yakalama ve OCR bileşenleri ile kurulum sonunda smoke testi (hepsi varsayılan seçili) |

Kurulum düğmesinden sonra `scripts\setup-run.ps1` arka planda çalışır ve ilerlemeyi sihirbaza
bildirir: eksik ön koşulları winget ile kurar, `install-mamidlabs.ps1`'i çalıştırır, seçilen profilin modellerini indirir
(`download-profile.ps1`), model tercihlerini yazar (`configure-models.ps1`), smoke testini çalıştırır
ve `logs\kurulum-ozeti.txt` özetini yazar. Sihirbazın son sayfası bu özeti gösterir; tüm çıktı
`logs\kurulum.log` dosyasındadır. Üç profilin bütün dosyaları (27B dil modeli ve Identity Edit
LoRA'sı dahil) Hugging Face'ten sabit sürüm ve boyut doğrulamasıyla iner.

Sihirbazı derlemek için: GitHub Actions → **Kurulum paketi** (ya da yerelde Inno Setup 6 ile
`iscc packaging\windows\mamidlabs.iss`). Çıktı `dist\MamidLabs_Setup.exe`.

**Profili daha sonra kurmak** için uygulamada Profiller → Profil yöneticisi → Eksikleri indir, ya da:

```powershell
%LOCALAPPDATA%\Programs\MamidLabs\runtime\pwsh\pwsh.exe -File %LOCALAPPDATA%\Programs\MamidLabs\scripts\download-profile.ps1 -Profile lite
```

**Kendi modelini sonradan eklemek** için uygulamada “Yerel dil modeli ekle (GGUF)…” ve
“Görsel ve video modelleri → Model dosyası seç (dosya yolu)…”, ya da:

```powershell
%LOCALAPPDATA%\Programs\MamidLabs\runtime\pwsh\pwsh.exe -File %LOCALAPPDATA%\Programs\MamidLabs\scripts\configure-models.ps1 -LlmPath D:\modeller\model.gguf -ImageModelPath D:\modeller\krea2_turbo_fp8_scaled.safetensors
```

## Betikle kurulum

1. Kaynağı indirin:
   ```powershell
   git clone https://github.com/workaybarsh/MamidLabsTR.git C:\MamidLabs-src
   ```
2. Kurulum betiğini profilinizle çalıştırın (`lite`, `flash` ya da `max`):
   ```powershell
   powershell -ExecutionPolicy Bypass -File C:\MamidLabs-src\scripts\install-mamidlabs.ps1 -Profile lite
   ```
   Betik sırasıyla şu aşamaları yürütür:

   | Aşama | İş |
   |---|---|
   | `preflight` | Windows, GPU, RAM, disk, Python ve Git kontrolü |
   | `layout` | Klasör düzeni, program dosyaları, masaüstü kısayolu |
   | `runtime` | Gömülü PowerShell 7.6.6 |
   | `llama` | llama.cpp b10998 (CUDA 13.4) |
   | `python` | Uygulama ve medya Python ortamları (sürümleri sabit) |
   | `asr` | Ses dökümü ortamı `venv\asr` (faster-whisper + AST + pyannote; `-SkipAudio` ile atlanır) |
   | `comfyui` | ComfyUI `b0f4b7b`, ComfyUI-GGUF `6ea2651` ve comfyui-krea2edit `86f886d` (fotoğraf düzenleme) |
   | `verify` | Bileşenlerin varlık ve çalışma kontrolü |

   Varsayılan kurulum kökü `%LOCALAPPDATA%\Programs\MamidLabs`'dır; `-Root <yol>` ile başka bir SSD klasörüne
   kurulabilir. Tek bir aşamayı çalıştırmak için `-Stage comfyui` gibi, medya bileşenlerini
   atlamak için `-SkipMedia` kullanılabilir.
3. Uygulamayı masaüstündeki **MamidLabs** kısayoluyla açın.
4. **Profiller → Profil yöneticisi → Eksikleri indir** ile modelleri indirin. Yarım kalan indirme
   kaldığı yerden sürer; var olan dosya yeniden indirilmez.
5. OCR için (isteğe bağlı, bir kez):
   ```powershell
   %LOCALAPPDATA%\Programs\MamidLabs\runtime\pwsh\pwsh.exe -File %LOCALAPPDATA%\Programs\MamidLabs\scripts\install-ocr.ps1 -Warmup
   ```

## Güncelleme

**Uygulamadan:** Profiller → Profil yöneticisi → **Güncellemeleri denetle**. Düğme GitHub'daki son
sürümü kurulu sürümle karşılaştırır. Yeni sürüm varsa **Şimdi güncelle** kurulum sihirbazını indirir
(boyutu doğrulanır), başlatır ve MamidLabs'i kapatır; sihirbaz aynı klasörü günceller. Sohbetler,
ayarlar ve modeller korunur.

**Betikle kurulumda:**

1. MamidLabs'i kapatın; Görev Yöneticisi'nde `llama-server.exe` kalmadığından emin olun.
2. Kaynağı güncelleyin ve kurulumu yeniden çalıştırın:
   ```powershell
   git -C C:\MamidLabs-src pull
   %LOCALAPPDATA%\Programs\MamidLabs\runtime\pwsh\pwsh.exe -NoProfile -ExecutionPolicy Bypass -File C:\MamidLabs-src\scripts\install-mamidlabs.ps1 -Profile lite
   ```
   - `settings\` ve `chats\` klasörlerine dokunulmaz; program dosyaları yeniden kopyalanır.
   - Yalnızca program dosyalarını tazelemek için tam kurulum yerine
     `install-mamidlabs.ps1 -Stage layout` yeterlidir: repodan silinen dosyalar temizlenir,
     `requirements\` köke kopyalanır ve kaldırma kaydına sürüm yazılır.
   - ComfyUI ve ComfyUI-GGUF sabit sürümde değilse sabit sürüme getirilir. Yerel değişiklikler
     önce `%LOCALAPPDATA%\Programs\MamidLabs\tools\yedek\` altına `.patch` olarak yedeklenir.
3. Uygulamada **Eksikleri indir** ile yeni model dosyalarını tamamlayın.

## Doğrulama

**Uçtan uca smoke testi** sohbet, belge, OCR, görsel, fotoğraf düzenleme, medya sonrası model
geçişi ve video bileşenlerini gerçek modellerle dener:

```powershell
%LOCALAPPDATA%\Programs\MamidLabs\runtime\pwsh\pwsh.exe -NoProfile -ExecutionPolicy Bypass -File %LOCALAPPDATA%\Programs\MamidLabs\scripts\smoke-test.ps1 -Profile lite
```

Beklenen sonuç: tüm adımlar `[GECTI]`; Identity Edit LoRA'sı kurulu değilse fotoğraf düzenleme
`[ATLA]` olur. Adımlar `-SkipChat`, `-SkipDocument`, `-SkipOcr`, `-SkipChart`, `-SkipImage`,
`-SkipEdit`, `-SkipMtp`, `-SkipOffline`, `-SkipNetworkSwitch`, `-SkipHistoryResume`,
`-SkipVideo`, `-SkipUi` ile atlanabilir. Sonuç `logs\smoke-test-son.json` dosyasına da yazılır.

**Medya sonrası model geçişi (8 GB LITE kart):** görsel adımı, uygulamadaki gibi dil modelini
VRAM'den boşaltıp üretimden sonra geri yükler. Ardından sohbet hızı ilk ölçümle karşılaştırılır.
Hız %70'in altına düşerse (`-MinSpeedRatio`) model paylaşılan belleğe taşmış demektir ve adım
başarısız olur. Detayda boş VRAM ve ComfyUI'nin açık kalıp kalmadığı da yazar.

**Birim testleri** kaynak klasörde çalışır; ek ortam ayarı gerekmez:

```powershell
cd C:\MamidLabs-src
python -m pip install pytest
python -m pytest -q
```

## Kaldırma

**Ayarlar → Uygulamalar → MamidLabs → Kaldır** MamidLabs'i geride iz bırakmadan siler; bilgisayar
hiç kurulmamış gibi kalır. Sihirbazla kurulanlarda da, betikle kurulanlarda da aynı kaldırıcı
(`scripts\uninstall-mamidlabs.ps1`) çalışır:

| Silinen | Ayrıntı |
|---|---|
| Çalışan süreçler | Uygulama, llama-server ve ComfyUI önce durdurulur |
| Kurulum klasörü | Program, gömülü PowerShell, llama.cpp, Python ortamları, ComfyUI, modeller, pip / Hugging Face / OCR önbellekleri, loglar, sohbetler, çıktılar, ayarlar ve şifreli API anahtarları |
| Masaüstü kısayolu | Yalnızca bu kuruluma işaret ediyorsa |
| Windows kaldırma kaydı | Ayarlar → Uygulamalar'daki satır |
| Ön koşullar | Python, Git, 7-Zip ve VC++ Redistributable; yalnızca sihirbaz bunları winget ile kendisi kurduysa (`settings\kurulum-kaydi.json`). Önceden kurulu olanlara dokunulmaz |

Kurulum klasörünün dışındaki dosyalara dokunulmaz: dosya yoluyla seçilen kendi modellerin yerinde
kalır. Klasörde MamidLabs'e ait olmayan dosya varsa silmeden önce sorulur. Sihirbazın kaldırıcısı
sohbetleri, üretilen dosyaları ve ayarları saklamak isteyip istemediğini sorar.

Betikle:

```powershell
# Önce neyin silineceğini gör (hiçbir şey silinmez)
powershell -ExecutionPolicy Bypass -File %LOCALAPPDATA%\Programs\MamidLabs\scripts\uninstall-mamidlabs.ps1 -DryRun
# Kaldır (onay ister)
powershell -ExecutionPolicy Bypass -File %LOCALAPPDATA%\Programs\MamidLabs\scripts\uninstall-mamidlabs.ps1
```

| Seçenek | Etki |
|---|---|
| `-KeepUserData` | `chats`, `outputs`, `settings` kalır |
| `-KeepPrerequisites` | MamidLabs'in kurduğu ön koşullar kaldırılmaz |
| `-PurgeSharedCaches` | Kurulum klasörü dışındaki paylaşılan Python önbelleklerini de siler: `%LOCALAPPDATA%\pip\cache`, `~\.cache\huggingface\xet`, `%TEMP%\torchinductor_*`. Başka Python projeleri de kullanabildiği için varsayılan olarak silinmez; MamidLabs kendi pip ve Hugging Face önbelleklerini kurulum klasöründe tutar. |
| `-Yes` | Onay sormaz |

Kaldırıcı Windows PowerShell 5.1 ile çalışır; gömülü PowerShell 7 de silindiği için onu kullanmaz.

## Model sunucusunu elle yönetmek

```powershell
%LOCALAPPDATA%\Programs\MamidLabs\runtime\pwsh\pwsh.exe -File %LOCALAPPDATA%\Programs\MamidLabs\scripts\manage-mamidlabs.ps1 -Action switch -Profile max
%LOCALAPPDATA%\Programs\MamidLabs\runtime\pwsh\pwsh.exe -File %LOCALAPPDATA%\Programs\MamidLabs\scripts\manage-mamidlabs.ps1 -Action stop
```

`-Action` değerleri: `start`, `switch`, `stop`, `closecomfy`. Profil değerleri: `max`, `flash`, `lite`.

## Sorun giderme

| Belirti | Neden ve çözüm |
|---|---|
| `Yetersiz bos VRAM` hatası | Ekran kartını başka bir uygulama kullanıyor. Tarayıcı donanım hızlandırması gibi GPU kullanan uygulamaları kapatın ya da daha küçük bir profil seçin. Boşta bekleyen ComfyUI otomatik kapatılır. |
| Sohbet beklenenden yavaş | `scripts\diagnose-latency.ps1` VRAM doluluğunu, önbellek isabetini ve üretim hızını ölçer. Dizüstünde pilde hız düşer. |
| OCR çalışmıyor | `install-ocr.ps1 -Warmup` ile OCR ortamını kurun; smoke testi OCR adımını doğrular. |
| Görsel ya da video üretilemiyor | `logs\comfyui.stderr.log` dosyasına bakın. `WinError 10022` satırları zararsızdır. |
| “Fotoğraf duzenleme LoRA'si bulunamadi” | Profil yöneticisinde **Eksikleri indir** ile LoRA'yı indirin (`krea2_identity_edit_v1_2.safetensors`, [conradlocke/krea2-identity-edit](https://huggingface.co/conradlocke/krea2-identity-edit), ~1,7 GB). |
| “comfyui-krea2edit dugum paketi kurulu degil” | `install-mamidlabs.ps1 -Stage comfyui` ile düğüm paketini kurun. |
| Kısayol çalışmıyor | Kurulumu yeniden çalıştırın; kısayol `launch-mamidlabs-desktop.vbs` üzerinden gömülü PowerShell 7 ile açar. |
