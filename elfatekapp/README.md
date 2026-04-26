# Elfatek Uygulaması

Flutter + Flask + Supabase tabanlı proje/versiyon yönetim uygulaması.

### Mevcut Özellikler
- Proje ağacını görüntüleme (veri DB’den okunur)
- Proje klasörü adı değiştirme (ID korunur)
  - Backend `/update_project_name` ile hem Supabase Storage klasörü taşınır hem `projects.project_name` ve `projects.storage_path` güncellenir
  - İlgili tüm `versions.storage_path` değerleri yeni prefix ile güncellenir
- Klasör oluşturma: `/create_folder`
- Versiyon oluşturma: `/add_version` (info.txt, image, hr.hex, settings.json yükleme)
- Versiyon dosyalarını güncelleme: `/update_version`
- Proje/versiyon silme: `/delete_version_or_project`

### Bilerek Devre Dışı (Teslim Sonrası İsteğe Bağlı)
- Versiyon adı değiştirme (rename)
  - Şu an kapalı. İstenirse aşağıdaki “Gelecekte Etkinleştirilebilir” planıyla hızla eklenebilir.

### Gelecekte Etkinleştirilebilir Fonksiyonlar
- Versiyon adı değiştirme
  - Backend (öneri): `POST /update_version_name { version_id, new_name }`
  - İşleyiş: Storage `.../oldVersion` → `.../newVersion` taşı; DB’de `versions.version_name` ve `versions.storage_path` güncelle; ID’ler korunur
- Alternatif klasör taşıma: `POST /rename_node`
  - Proje dışı özel taşıma senaryoları için kullanılabilir
- Senkronizasyon uçları
  - `POST /sync` (DB-Storage eşitleme)
  - `POST /sync_all` (toplu indirme/yerel eşitleme)
- Genel upload indirme/düzenleme uçları
  - `POST /upload_file`, `GET /download_file`, `POST /update_file`, `GET /get_txt_content`

### Frontend Notları (ApiService)
- Aktif: `updateProjectName`, `createFolderOnServer`, `addVersion`, `updateVersion`, `deleteFolder`, `fetchProjectTree`, `fetchImageBytes`, `getTxtContent`
- Gelecek için not (UI’da bağlı değil ya da backend’de karşılığı yok):
  - `updateVersionFiles` → `/update_version_files` (backend yok)
  - `renameFolder` → `/rename_folder` (backend yok; yerine `/rename_node` var)
  - `addMainFolder`/`addProject` → `/add_project` (backend yok; yerine `/create_folder` kullanılıyor)
  - `createProject` → `/create_project` (backend yok)
  - `downloadFile` → `/download` (backend’de `/download_file` var)

### Mimari Notlar
- Ağaç verisi DB’den gelir. Proje adı değiştirme, Storage + DB’yi birlikte günceller ve ilgili versiyon path’lerini otomatik yansıtır. `project_id` ve `version_id` değerleri değişmez.
- Versiyon rename teslim sonrası talebe göre etkinleştirilecektir.
-SQL kodları da örnek şekilleri ile SQL klasörü içerisinde bulunmaktadır.