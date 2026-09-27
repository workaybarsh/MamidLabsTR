# Arayüz testi yardımcıları

MamidLabs'in WinForms uygulamasını ve Inno Setup sihirbazını, masaüstü kontrol aracı olmadan
PowerShell'den sürmek için kullanılan yardımcılar. Tam arayüz testleri bunlarla yapılır.

| Dosya | İçerik |
|---|---|
| `ui.ps1` | UI Automation: `Get-Window`, `Show-Tree`, `Find-El`, `Click-Name`, `Set-Text`, `Save-Shot`; Inno düğmeleri için `Click-Pane` / `Click-Hwnd` (BM_CLICK) |
| `win32.ps1` | Salt Win32: `Find-Top`, `Kids-Text`, `Shot-Hwnd`, `Click-Btn` (PostMessage, bloklamaz) |

Kullanım (Windows PowerShell 5.1):

```powershell
. .\tests\ui-automation\ui.ps1
. .\tests\ui-automation\win32.ps1
```

Ekran görüntüleri `%TEMP%\claude\ui\shots\` altına yazılır.

## Öğrenilenler

- **Inno Setup:** düğmeler UIA'da `Pane` görünür; `Click-Pane` (BM_CLICK) kullanılır.
  Profil seçimi bir sahip-çizimli (owner-drawn) liste olduğu için satırın konumuna
  `WM_LBUTTONDOWN/UP` gönderilir.
- **Modal pencere açan öğeler** (menü öğesi, düğme): UIA `Invoke` pencere kapanana kadar döner ve
  uygulamanın UIA bağlantısını kilitleyebilir. Bu öğeler için:
  - Düğmelerde `Click-Btn` (PostMessage) kullan.
  - Bağlam menüsünde önce düğmeye bas, sonra `SendKeys('{DOWN}{DOWN}{ENTER}')` gönder.
- **Gizli sekmeler:** WinForms, gizli sekmedeki (Model Kontrolü) düğmelerin tutamacını sekme ilk kez
  gösterilince oluşturur. Önce Görünüm → Model kontrolü'nü aç.
- **Görsel ekleme:** `Set-Clipboard -Path <dosya>` ile panoya koy, istem kutusuna odaklanıp
  `SendKeys('^v')` gönder.
- **Onay penceresi:** başlığı `İzin gerekiyor — <araç>`, düğmeleri `Evet, izin ver` / `Hayır`.
- **Kodlama:** bu yardımcıları çağıran betikler Türkçe metin içeriyorsa UTF-8 **BOM'lu**
  kaydedilmeli. Windows PowerShell 5.1 BOM'suz dosyayı ANSI okur ve "Gönder" gibi metinler bozulur.
- **Ayarlar:** testten önce `<kök>\settings\` klasörünü yedekle. Uygulama kapandıktan sonra geri
  yükle; uygulama açıkken yazılan dosya çıkışta ezilir.
- **WinForms `ComboBoxStyle.DropDownList` için UIA `ValuePattern.SetValue` ve
  `SelectionItemPattern.Select()` güvenilir değil:** görünümde metni değiştirebilir ama gerçek
  `SelectedIndexChanged` olayını tetiklemeyebilir (arayüz ile gerçek durum birbirinden kopar —
  16 GB PC testinde profil kutusu "MAX" gösterdi ama model hâlâ FLASH'tı). Çözüm: gerçek fare
  tıklaması simüle et — `SetCursorPos` + `mouse_event` (`LEFTDOWN`/`LEFTUP`) ile önce kutuyu aç
  (kenarına tıkla), UIA'dan listedeki `ListItem`'ların `BoundingRectangle`'ını oku, sonra o
  koordinata tıkla.
- **Bir düğmeye UIA `Invoke` çağrısı modal bir pencere açtığında zaman aşımına uğrarsa** (yukarıdaki
  tuzak), düğmenin HWND'sini bul ve `win32.ps1`'deki `Click-Btn` (PostMessage, bloklamayan) ile
  tekrar dene — pencere sunucu tarafında zaten açılmış olabilir, istemci tarafı bekleyen çağrı
  sadece zaman aşımına uğramıştır.
