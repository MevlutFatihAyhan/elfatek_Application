import os
import re
from supabase import create_client, Client
from datetime import datetime
from bagıntı import list_storage_recursive, download_file_from_supabase, upload_file_to_supabase, list_storage
from config import SUPABASE_URL, SUPABASE_KEY, BUCKET_NAME, DESKTOP_FOLDER

supabase: Client = create_client(SUPABASE_URL, SUPABASE_KEY)

def sync_supabase_to_local(bucket_folder=""):
    """Supabase'den yerel klasöre dosyaları indir"""
    print(f"[SYNC] Supabase'den yerel klasöre senkronizasyon başlatılıyor...")
    data = list_storage_recursive(bucket_folder)
    downloaded_count = 0
    
    for file_path in data.get("files", []):
        local_path = os.path.join(DESKTOP_FOLDER, file_path.replace("/", os.sep))
        if not os.path.exists(local_path):
            os.makedirs(os.path.dirname(local_path), exist_ok=True)
            if download_file_from_supabase(file_path, local_path):
                downloaded_count += 1
                print(f"[DOWNLOAD] {file_path} indirildi")
    
    print(f"[SUCCESS] {downloaded_count} dosya indirildi")
    return downloaded_count

def sync_local_to_supabase(bucket_folder=""):
    """Yerel klasörden Supabase'e dosyaları yükle"""
    print(f"[SYNC] Yerel klasörden Supabase'e senkronizasyon başlatılıyor...")
    uploaded_count = 0
    
    for root, _, files in os.walk(DESKTOP_FOLDER):
        for file in files:
            local_path = os.path.join(root, file)
            rel_path = os.path.relpath(local_path, DESKTOP_FOLDER).replace("\\", "/")
            supabase_path = f"{bucket_folder}/{rel_path}" if bucket_folder else rel_path
            
            if upload_file_to_supabase(local_path, supabase_path):
                uploaded_count += 1
                print(f"[UPLOAD] {supabase_path} yüklendi")
    
    print(f"[SUCCESS] {uploaded_count} dosya yüklendi")
    return uploaded_count

def get_storage_structure():
    """Storage'dan proje ve versiyon yapısını al"""
    print(f"[INFO] Storage yapısı analiz ediliyor...")
    
    storage_data = list_storage_recursive(path="")
    all_storage_folders = storage_data.get("folders", [])
    all_storage_files = storage_data.get("files", [])

    # .keep dosyalarını klasör olarak ekle
    keep_files = [f for f in all_storage_files if f.endswith('.keep')]
    for keep_file in keep_files:
        folder_path = os.path.dirname(keep_file)
        if folder_path not in all_storage_folders:
            all_storage_folders.append(folder_path)

    # .keep dosyalarını ana dosya listesinden çıkar
    all_storage_files = [f for f in all_storage_files if not f.endswith('.keep')]

    projects = {}
    versions = []

    for folder_path in all_storage_folders:
        parts = folder_path.strip('/').split('/')
        if len(parts) == 0:
            continue
        last_segment = parts[-1]
        # Versiyon kontrolü (v ile başlayan klasörler)
        if last_segment.startswith('v'):
            version_name = last_segment
            project_path = "/".join(parts[:-1])
            versions.append({
                'project_path': project_path,
                'version_path': folder_path,
                'version_name': version_name
            })
        else:
            # Proje klasörü
            project_name = last_segment
            projects[folder_path] = project_name

    print(f"[INFO] {len(projects)} proje ve {len(versions)} versiyon bulundu")
    return projects, versions, all_storage_files

def sync_projects_to_database(projects):
    """Projeleri veritabanına senkronize et"""
    print(f"[SYNC] Projeler veritabanına senkronize ediliyor...")
    
    # Mevcut projeleri al
    response = supabase.table('projects').select('project_id, project_name, storage_path').execute()
    db_projects = {row['storage_path']: row for row in response.data}
    
    added_count = 0
    updated_count = 0
    deleted_count = 0

    for storage_path, project_name in projects.items():
        if storage_path not in db_projects:
            # Yeni proje ekle
            try:
                result = supabase.table('projects').insert({
                        "project_name": project_name,
                        "storage_path": storage_path
                    }).execute()
                
                if result.data:
                    added_count += 1
                    print(f"[ADD] Proje eklendi: {project_name} ({storage_path})")
                else:
                    print(f"[ERROR] Proje eklenemedi: {project_name} ({storage_path})")
            except Exception as e:
                print(f"[ERROR] Proje ekleme hatası: {project_name} ({storage_path}): {e}")
                # Aynı isimde proje varsa, storage_path'i güncelle
                try:
                    existing_project = supabase.table('projects').select('project_id').eq('project_name', project_name).execute()
                    if existing_project.data:
                        existing = existing_project.data[0]
                        supabase.table('projects').update({
                            "storage_path": storage_path
                        }).eq('project_id', existing['project_id']).execute()
                        updated_count += 1
                        print(f"[UPDATE] Mevcut proje güncellendi: {project_name} ({storage_path})")
                except Exception as update_error:
                    print(f"[ERROR] Proje güncelleme hatası: {project_name}: {update_error}")
        else:
            # Mevcut projeyi güncelle (isim değişmişse)
            db_project = db_projects[storage_path]
            if db_project['project_name'] != project_name:
                supabase.table('projects').update({
                    "project_name": project_name
                }).eq('project_id', db_project['project_id']).execute()
                updated_count += 1
                print(f"[UPDATE] Proje güncellendi: {project_name} ({storage_path})")

    # Storage'da olmayan projeleri sil
    for db_storage_path, db_project in db_projects.items():
        if db_storage_path not in projects:
            # Önce bu projeye ait versiyonları kontrol et
            versions_response = supabase.table('versions').select('version_id').eq('project_id', db_project['project_id']).execute()
            if versions_response.data:
                print(f"[WARNING] Proje silinmedi - {len(versions_response.data)} versiyon var: {db_project['project_name']}")
                continue
            
            supabase.table('projects').delete().eq('project_id', db_project['project_id']).execute()
            deleted_count += 1
            print(f"[DELETE] Proje silindi: {db_project['project_name']} ({db_storage_path})")

    print(f"[SUCCESS] Projeler: {added_count} eklendi, {updated_count} güncellendi, {deleted_count} silindi")
    return {storage_path: projects[storage_path] for storage_path in projects}

def sync_versions_to_database(versions, projects):
    """Versiyonları veritabanına senkronize et"""
    print(f"[SYNC] Versiyonlar veritabanına senkronize ediliyor...")
    
    # Mevcut versiyonları al
    response = supabase.table('versions').select('version_id, project_id, version_name, storage_path').execute()
    db_versions = {row['storage_path']: row for row in response.data}
    
    # Proje ID'lerini al
    project_response = supabase.table('projects').select('project_id, storage_path').execute()
    project_ids = {row['storage_path']: row['project_id'] for row in project_response.data}
    
    added_count = 0
    updated_count = 0
    deleted_count = 0

    for version_info in versions:
        version_path = version_info['version_path']
        version_name = version_info['version_name']
        project_path = version_info['project_path']
        
        # Proje ID'sini bul
        project_id = project_ids.get(project_path)
        if not project_id:
            # Proje yoksa oluştur
            project_name = os.path.basename(project_path)
            # Önce aynı isimde proje var mı kontrol et
            existing_project = supabase.table('projects').select('project_id, storage_path').eq('project_name', project_name).execute()
            if existing_project.data:
                existing = existing_project.data[0]
                supabase.table('projects').update({
                    "storage_path": project_path
                }).eq('project_id', existing['project_id']).execute()
                project_id = existing['project_id']
                project_ids[project_path] = project_id
                print(f"[UPDATE] Mevcut proje güncellendi: {project_name} ({project_path})")
            else:
                try:
                    result = supabase.table('projects').insert({
                        "project_name": project_name,
                        "storage_path": project_path
                    }).execute()
                    if result.data:
                        project_id = result.data[0]['project_id']
                        project_ids[project_path] = project_id
                        print(f"[ADD] Yeni proje oluşturuldu: {project_name} ({project_path})")
                    else:
                        print(f"[ERROR] Proje oluşturulamadı: {project_path}")
                        continue
                except Exception as e:
                    print(f"[ERROR] Proje oluşturma hatası: {e}")
                    continue

        if version_path not in db_versions:
            # Yeni versiyon ekle
            result = supabase.table('versions').insert({
                "project_id": project_id,
                "version_name": version_name,
                "storage_path": version_path
            }).execute()
            
            if result.data:
                added_count += 1
                version_id = result.data[0]['version_id']
                print(f"[ADD] Versiyon eklendi: {version_name} ({version_path})")
                
                # Kullanıcı atamalarını da ekle
                try:
                    user_assignments = supabase.table('user_projects').select('user_id').eq('project_id', project_id).execute()
                    for user in user_assignments.data:
                        supabase.table('user_projects').insert({
                            "user_id": user['user_id'],
                            "project_id": project_id,
                            "version_id": version_id
                        }).execute()
                        print(f"[ASSIGN] Kullanıcı {user['user_id']} versiyona atandı: {version_path}")
                except Exception as e:
                    print(f"[WARNING] Kullanıcı ataması yapılamadı: {e}")
        else:
            # Mevcut versiyonu güncelle
            db_version = db_versions[version_path]
            if (db_version['version_name'] != version_name or 
                db_version['project_id'] != project_id):
                supabase.table('versions').update({
                    "version_name": version_name,
                    "project_id": project_id
                }).eq('version_id', db_version['version_id']).execute()
                updated_count += 1
                print(f"[UPDATE] Versiyon güncellendi: {version_name} ({version_path})")

    # Storage'da olmayan versiyonları sil
    existing_version_paths = {v['version_path'] for v in versions}
    for db_storage_path, db_version in db_versions.items():
        if db_storage_path not in existing_version_paths:
            # Önce bu versiyona ait dosya kayıtlarını kontrol et
            storage_files = list_storage(db_version['storage_path']).get("files", [])
            if storage_files:
                print(f"[WARNING] Versiyon silinmedi - {len(storage_files)} dosya bulundu (Storage): {db_version['version_name']}")
                continue
            supabase.table('versions').delete().eq('version_id', db_version['version_id']).execute()
            deleted_count += 1
            print(f"[DELETE] Versiyon silindi: {db_version['version_name']} ({db_storage_path})")

    print(f"[SUCCESS] Versiyonlar: {added_count} eklendi, {updated_count} güncellendi, {deleted_count} silindi")

def sync_storage_to_database():
    """Ana senkronizasyon fonksiyonu"""
    print(f"[{datetime.now()}] Supabase Storage ve Veritabanı Eşitlemesi Başlatılıyor...")

    try:
        # Storage yapısını al
        projects, versions, files = get_storage_structure()
        
        # Projeleri senkronize et
        projects = sync_projects_to_database(projects)
        
        # Versiyonları senkronize et
        sync_versions_to_database(versions, projects)
        
        print(f"[SUCCESS] [{datetime.now()}] Supabase Storage eşitlenmesi tamamlandı.")
        return True

    except Exception as e:
        print(f"[ERROR] [{datetime.now()}] Eşitleme sırasında hata oluştu: {e}")
        import traceback
        traceback.print_exc()
        return False

def run():
    print(f"[{datetime.now()}] Supabase senkronizasyon başlatılıyor...")
    
    # Storage'dan veritabanına senkronizasyon
    if sync_storage_to_database():
        print("[SUCCESS] Storage-Database senkronizasyonu tamamlandı")
    else:
        print("[ERROR] Storage-Database senkronizasyonu başarısız")
    
    # Yerel senkronizasyon
    print("[SYNC] Yerel senkronizasyon başlatılıyor...")
    downloaded_count = sync_supabase_to_local()
    uploaded_count = sync_local_to_supabase()
    
    print(f"[SUCCESS] Yerel senkronizasyon tamamlandı: {downloaded_count} dosya indirildi, {uploaded_count} dosya yüklendi")
    print("[SUCCESS] Supabase senkronizasyon tamamlandı.")

if __name__ == "__main__":
    run()
