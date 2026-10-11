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
- **Ses dökümü (Qwen3-ASR-1.7B):** sohbete eklenen ses dosyası otomatik yazıya çevrilir ve bulgular
  dil modeline verilir (OCR/mmproj mantığı). Motor **Qwen3-ASR**: 52 dil + **Türkçe**; konuşma,
  şarkı ve fon müzikli kayıtlar; GPU'da hızlı (yoksa CPU'ya düşer). Yerel sağlayıcıda dil modeli
  VRAM'den boşaltılıp dökum alınır ve geri yüklenir. Arayüzde Gönder'in solunda **mikrofon** tuşu
  (**Windows varsayılan kayıt cihazından canlı kayıt**, bağımlılıksız) ve ek (+) menüsünde
  **Ses ekle**. Model kurulumda `models\qwen3-asr` altına indirilir.
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
- **Lisans (EULA):** Kurulum sihirbazında **Son Kullanıcı Lisans Sözleşmesi** gösterilir ve kabul
  edilmeden kurulum sürmez. Yazılımın mülkiyeti ve tüm hakları geliştiriciye aittir; kopyalama,
  değiştirme, kırma (crack) veya ticari amaçla pazarlama yasaktır. İzinsiz kullanım hukuki ve cezai
  sorumluluk doğurabilir; sorumluluk reddi ve sınırlandırılması, fesih ile hukuk/mahkeme hükümleri yer alır.

### Düzeltilen
- **ComfyUI yaşam döngüsü profile duyarlı yapıldı:** MAX/FLASH (27B) profillerinde dil modeli yüklenmeden
  önce ComfyUI her zaman kapatılır (aksi halde 16 GB kartta MTP draft taşıp sohbet aralıklı ~6-7 tok/s'ye
  düşüyordu); LITE'ta ComfyUI açık kalır ve medya işleri arasında yeniden açılmaz.
- **`custom` (OpenAI uyumlu özel uç) sohbette çalışmıyordu:** taban adres yalnızca arayüz ayarında
  tutuluyordu; işçi ayarları okumadığı için `custom` istekleri "taban adresi gir" ile duruyordu
  (yalnızca ayar penceresindeki doğrulama çalışıyordu). Masaüstü artık `baseUrl` + ayarları işçiye
  geçirir; commandcode ile metin+görsel uçtan uca doğrulandı.
