import base64
import shutil
import threading
from flask import Flask, request, jsonify, send_from_directory 
import os
from datetime import datetime
import subprocess
from flask_cors import CORS
from supabase import StorageException, create_client, Client
import supabase
from auth import token_required 
from config import DESKTOP_FOLDER, TEMP_UPLOAD_FOLDER, FLASK_HOST, FLASK_PORT, FLASK_DEBUG, SYNC_INTERVAL, BUCKET_NAME
from postgrest.exceptions import APIError
from bagıntı import (
    list_storage,
    list_storage_recursive,
    download_file_from_supabase,
    get_full_project_tree,
    rename_supabase_object,
    upload_file_to_supabase,
    insert_file_record_to_db,
    delete_file_from_supabase,
    update_file_content,
    read_file_from_storage,
    supabase
)

from supabase_sync import sync_storage_to_database 

app = Flask(__name__)
CORS(app) 

if not os.path.exists(TEMP_UPLOAD_FOLDER):
    os.makedirs(TEMP_UPLOAD_FOLDER)

def full_path(rel_path):
    rel_path = rel_path.lstrip("/\\")  # baştaki / veya \ işaretlerini kaldır
    safe_path = os.path.normpath(os.path.join(DESKTOP_FOLDER, rel_path))
    if not safe_path.startswith(os.path.normpath(DESKTOP_FOLDER) + os.sep) and \
       os.path.normpath(DESKTOP_FOLDER) != safe_path: 
        raise ValueError(f"Geçersiz klasör yolu: {rel_path}. {DESKTOP_FOLDER} dışında bir yola erişim denemesi.")
    return safe_path

def create_default_files_content(file_type):
    if file_type == 'info.txt':
        return 'Bu info.txt dosyasının başlangıç içeriğidir.\nOluşturulma Tarihi: ' + datetime.now().strftime('%Y-%m-%d %H:%M:%S')
    elif file_type == 'hr.hex':
        return '4865782046696C652044617461' 
    elif file_type == 'settings': 
        return '{"default_setting": "value"}'
    elif file_type == 'image.jpg': 
        return b'' 
    return ''

def run_supabase_sync_periodically():
    try:
        print(f"[{datetime.now()}] supabase_sync.py çalıştırılıyor...")
        result = subprocess.run(
            ["python", "supabase_sync.py"],
            capture_output=True, 
            text=True,           
            check=True           
        )
        print(f"[{datetime.now()}] supabase_sync.py stdout:\n{result.stdout}")
        if result.stderr:
            print(f"[{datetime.now()}] supabase_sync.py stderr:\n{result.stderr}")
    except subprocess.CalledProcessError as e:
        print(f"[{datetime.now()}] supabase_sync.py çalıştırılırken hata oluştu: {e}")
        print(f"[{datetime.now()}] stdout: {e.stdout}")
        print(f"[{datetime.now()}] stderr: {e.stderr}")
    except FileNotFoundError:
        print(f"[{datetime.now()}] Hata: 'python' komutu bulunamadı veya 'supabase_sync.py' dosyası mevcut değil.")
    except Exception as e:
        print(f"[{datetime.now()}] Beklenmeyen hata: {e}")
    finally:
        threading.Timer(SYNC_INTERVAL, run_supabase_sync_periodically).start()

@app.route('/list', methods=['GET'])
def list_files():
    path = request.args.get('path', '')
    result = list_storage(path) 
    print("TEST: list_files endpoint çağrıldı - reload çalışıyor!")  # Test mesajı
    return jsonify(result)

@app.route('/list_files', methods=['GET'])
def list_files_endpoint():
    path = request.args.get('path', '')
    result = list_storage(path) 
    return jsonify(result)


@app.route('/project_tree', methods=['GET'])
@token_required  
def project_tree_endpoint(user):
    print(f"Giriş yapan kullanıcı: {user}")
    try:
        user_id = user['id']
        is_admin = user['is_admin']

        project_data = get_full_project_tree(user_id=user_id, is_admin=is_admin)
        return jsonify(project_data)
    except Exception as e:
        print(f"Hata oluştu: {e}")
        return jsonify({"error": str(e)}), 500

@app.route('/sync_all', methods=['POST'])
def sync_all_files():
    storage_data = list_storage_recursive(path="") or {}
    downloaded = []
    already = []
    failed = []

    files = storage_data.get("files", [])
    folders = storage_data.get("folders", [])
    
    print("Supabase'den gelen files:", files)
    print("Supabase'den gelen folders:", folders)

    for file_path in files:
        local_file_path = full_path(file_path.replace("/", os.sep))
        os.makedirs(os.path.dirname(local_file_path), exist_ok=True)

        if not os.path.exists(local_file_path):
            success = download_file_from_supabase(file_path, local_file_path)
            if success:
                downloaded.append(file_path)
            else:
                failed.append(file_path)
        else:
            already.append(file_path)

    return jsonify({
        "downloaded": downloaded,
        "already_exists": already,
        "failed": failed,
        "folders": folders,
        "files": files
    })


@app.route('/create_file', methods=['POST']) 
def create_empty_file_endpoint(): 
    data = request.get_json()
    file_path = data.get("file_path") 
    
    if not file_path:
        return jsonify({"success": False, "message": "file_path gerekli"}), 400

    local_path = full_path(file_path.replace("/", os.sep))
    file_name = os.path.basename(file_path) 
    error_messages = []

    try:
        # Dizin oluştur
        os.makedirs(os.path.dirname(local_path), exist_ok=True)
        print(f"Dizin oluşturuldu: {os.path.dirname(local_path)}")

        if os.path.exists(local_path):
            return jsonify({"success": False, "message": "Dosya zaten var."}), 409

        # Dosya içeriğini oluştur
        content = create_default_files_content(file_name) 
        if isinstance(content, bytes):
            with open(local_path, 'wb') as f:
                f.write(content)
        else:
            with open(local_path, 'w', encoding='utf-8') as f:
                f.write(content)
        
        print(f"Yerel dosya oluşturuldu: {local_path}")
        
        # Supabase'e yükle
        upload_success = upload_file_to_supabase(local_path, file_path) 
        
        if upload_success:
            print(f"Supabase'e başarıyla yüklendi: {file_path}")
            
            # Veritabanı kaydını ekle
            try:
                insert_file_record_to_db(file_path) 
                print(f"Veritabanı kaydı eklendi: {file_path}")
            except Exception as e:
                print(f"Veritabanı kaydı ekleme hatası: {e}")
                error_messages.append(f"Veritabanı kaydı ekleme hatası: {e}")
            
            # Senkronizasyon yap
            try:
                sync_storage_to_database()
                print("[SUCCESS] Senkronizasyon tamamlandı")
            except Exception as e:
                print(f"Senkronizasyon hatası: {e}")
                error_messages.append(f"Senkronizasyon hatası: {e}")
            
            return jsonify({
                "success": True, 
                "message": f"'{file_path}' başarıyla oluşturuldu ve yüklendi.",
                "local_path": local_path,
                "supabase_path": file_path,
                "errors": error_messages
            })
        else:
            # Supabase yükleme başarısızsa yerel dosyayı sil
            try:
                os.remove(local_path) 
                print(f"Yerel dosya silindi (Supabase yükleme başarısız): {local_path}")
            except Exception as e:
                print(f"Yerel dosya silme hatası: {e}")
            
            return jsonify({
                "success": False, 
                "message": "Dosya oluşturuldu ancak Supabase'e yüklenemedi.",
                "errors": error_messages
            }), 500
            
    except Exception as e:
        print(f"Dosya oluşturma hatası: {e}")
        # Hata durumunda yerel dosyayı temizle
        try:
            if os.path.exists(local_path):
                os.remove(local_path)
                print(f"Yerel dosya temizlendi: {local_path}")
        except Exception as cleanup_error:
            print(f"Dosya temizleme hatası: {cleanup_error}")
        
        return jsonify({
            "success": False, 
            "message": f"Dosya oluşturma hatası: {str(e)}",
            "errors": [str(e)]
        }), 500


@app.route('/delete_file', methods=['POST'])
def delete_file_endpoint():
    data = request.get_json()
    supabase_path = data.get("supabase_path")
    if not supabase_path:
        return jsonify({"error": "supabase_path gerekli"}), 400

    local_deleted = False
    supabase_deleted = False
    error_messages = []

    try:
        # Yerel dosyayı sil
        local_file_path = full_path(supabase_path.replace("/", os.sep))
        if os.path.exists(local_file_path):
            os.remove(local_file_path)
            local_deleted = True
            print(f"'{local_file_path}' yerelden başarıyla silindi.")
        else:
            print(f"Yerel dosya bulunamadı: {local_file_path}")
            error_messages.append(f"Yerel dosya bulunamadı: {local_file_path}")
    except Exception as e:
        print(f"[delete_file_endpoint] Yerel dosya silme hatası: {e}")
        error_messages.append(f"Yerel dosya silme hatası: {e}")

    try:
        # Supabase'den dosyayı sil
        supabase_deleted = delete_file_from_supabase(supabase_path)
        if supabase_deleted:
            print(f"'{supabase_path}' Supabase'den başarıyla silindi.")
        else:
            print(f"Supabase'den dosya silinemedi: {supabase_path}")
            error_messages.append(f"Supabase'den dosya silinemedi: {supabase_path}")
    except Exception as e:
        print(f"[delete_file_endpoint] Supabase silme hatası: {e}")
        error_messages.append(f"Supabase silme hatası: {e}")
    
    # Senkronizasyon yap
    try:
        sync_storage_to_database() 
        print("[SUCCESS] Senkronizasyon tamamlandı")
    except Exception as e:
        print(f"Senkronizasyon hatası: {e}")
        error_messages.append(f"Senkronizasyon hatası: {e}")

    final_success = local_deleted and supabase_deleted
    status_message = f"'{supabase_path}' başarıyla silindi." if final_success else "Silme işleminde hatalar oluştu."

    return jsonify({
        "success": final_success, 
        "local_deleted": local_deleted,
        "supabase_deleted": supabase_deleted,
        "message": status_message,
        "errors": error_messages
    })

@app.route('/update_file', methods=['POST'])
def update_file_endpoint():
    data = request.get_json()
    supabase_path = data.get("supabase_path")
    content = data.get("content")
    if not supabase_path or content is None:
        return jsonify({"error": "supabase_path ve content gerekli"}), 400

    local_file_path = full_path(supabase_path.replace("/", os.sep))
    error_messages = []

    try:
        # Dizin oluştur (eğer yoksa)
        os.makedirs(os.path.dirname(local_file_path), exist_ok=True)
        
        filename = os.path.basename(local_file_path).lower()

        # Yerel dosyayı güncelle
        if filename in ["info.txt", "hr.hex", "settings.json"]:
            with open(local_file_path, 'w', encoding='utf-8') as f:
                f.write(content)
            print(f"Yerel dosya güncellendi (text): {local_file_path}")

        elif filename.endswith(('.png', '.jpg', '.jpeg')):
            img_data = base64.b64decode(content)
            with open(local_file_path, 'wb') as f:
                f.write(img_data)
            print(f"Yerel dosya güncellendi (image): {local_file_path}")

        else:
            with open(local_file_path, 'w', encoding='utf-8') as f:
                f.write(content)
            print(f"Yerel dosya güncellendi (binary): {local_file_path}")

        # Supabase'e yükle
        print(f"[UPLOAD] {supabase_path} Supabase'e yükleniyor...")
        upload_success = upload_file_to_supabase(local_file_path, supabase_path)
        
        if upload_success:
            print(f"[SUCCESS] {supabase_path} başarıyla güncellendi")
            
            # Veritabanı kaydını güncelle
            try:
                insert_file_record_to_db(supabase_path)
                print(f"Veritabanı kaydı güncellendi: {supabase_path}")
            except Exception as e:
                print(f"Veritabanı kaydı güncelleme hatası: {e}")
                error_messages.append(f"Veritabanı kaydı güncelleme hatası: {e}")
            
            # Senkronizasyon yap
            try:
                sync_storage_to_database()
                print("[SUCCESS] Senkronizasyon tamamlandı")
            except Exception as e:
                print(f"Senkronizasyon hatası: {e}")
                error_messages.append(f"Senkronizasyon hatası: {e}")

            return jsonify({
                "success": True,
                "supabase_path": supabase_path,
                "local_path": local_file_path,
                    "message": "Dosya başarıyla güncellendi.",
                    "errors": error_messages
                })
        else:
            print(f"[ERROR] {supabase_path} güncellenemedi")
            return jsonify({
                "success": False,
                "message": "Dosya yerel olarak güncellendi ancak Supabase'e yüklenemedi.",
                "errors": error_messages
            }), 500

    except Exception as e:
        print(f"[ERROR] Dosya güncelleme hatası: {e}")
        return jsonify({
            "success": False, 
            "message": f"Dosya güncellenirken hata: {str(e)}",
            "errors": [str(e)]
        }), 500

@app.route('/add_version', methods=['POST'])
@token_required
def add_version_endpoint(user):
    try:
        # Multipart form data'dan bilgileri al
        project = request.form.get('project')
        version = request.form.get('version')
        project_name = request.form.get('project_name')
        
        print(f"[DEBUG] add_version called with project={project}, version={version}, project_name={project_name}")

        if not project or not version:
            return jsonify({'success': False, 'message': 'project ve version gerekli'}), 400

        # Version path oluştur
        version_path = f"{project}/{version}"
        full_version_path = full_path(version_path)
        
        print(f"[DEBUG] Version path: {version_path}")
        print(f"[DEBUG] Full version path: {full_version_path}")
        
        if os.path.exists(full_version_path):
            return jsonify({'success': False, 'message': 'Bu versiyon zaten var'}), 409
            
        # Versiyon klasörünü oluştur
        os.makedirs(full_version_path, exist_ok=True)
        print(f"[DEBUG] Version folder created: {full_version_path}")
        
        # Dosyaları işle ve kaydet
        uploaded_files = []
        for file_key in request.files:
            file = request.files[file_key]
            if file and file.filename:
                # Dosya adını belirle
                if file_key == 'info_txt':
                    filename = 'info.txt'
                elif file_key == 'image':
                    filename = 'image.jpg'
                elif file_key == 'hex':
                    filename = 'hr.hex'
                elif file_key == 'settings':
                    filename = 'settings.json'
                else:
                    filename = file.filename
                
                # Yerel dosya yolu
                local_file_path = os.path.join(full_version_path, filename)
                file.save(local_file_path)
                
                # Supabase yolu
                supabase_file_path = f"{version_path}/{filename}"
                
                # Supabase'e yükle
                upload_success = upload_file_to_supabase(local_file_path, supabase_file_path)
                
                if upload_success:
                    uploaded_files.append(filename)
                    print(f"[SUCCESS] File uploaded: {filename}")
                else:
                    print(f"[ERROR] File upload failed: {filename}")
                    # Hata durumunda yerel klasörü temizle
                    if os.path.exists(full_version_path):
                        shutil.rmtree(full_version_path)
                    return jsonify({
                        'success': False, 
                        'message': f'{filename} dosyası yüklenemedi'
                    }), 500
        
        if uploaded_files:
            print(f"[SUCCESS] Version created with files: {uploaded_files}")
            return jsonify({
                'success': True,
                    'version_path': version_path,
                    'uploaded_files': uploaded_files,
                    'message': f'Versiyon {version} başarıyla oluşturuldu'
                }), 200
        else:
            # Hiç dosya yüklenmemişse klasörü temizle
            if os.path.exists(full_version_path):
                shutil.rmtree(full_version_path)
            return jsonify({
                'success': False,
                'message': 'Hiç dosya yüklenmedi'
            }), 400

    except Exception as e:
        print(f"[ERROR] add_version genel hatası: {e}")
        return jsonify({'success': False, 'message': f'Sunucu hatası: {str(e)}'}), 500

# Utility fonksiyonları
def full_path(relative_path):
    return os.path.join(DESKTOP_FOLDER, relative_path)

@app.route('/delete_version_or_project', methods=['POST'])
def delete_version_or_project_endpoint():
    data = request.json
    path_to_delete = data.get('path') 
    if not path_to_delete:
        return jsonify({'success': False, 'message': 'path gerekli'}), 400

    local_deleted = False
    supabase_deleted_all_files = True 
    supabase_folder_deleted = False
    db_records_deleted = False
    error_messages = [] 

    try:
        full_p = full_path(path_to_delete)
        if os.path.exists(full_p):
            shutil.rmtree(full_p)
            local_deleted = True
            print(f"Masaüstünden '{full_p}' başarıyla silindi.")
        else:
            error_messages.append(f"Masaüstünde '{path_to_delete}' bulunamadı.")
            print(f"Masaüstünde '{path_to_delete}' bulunamadı, silmeye gerek yok.")
    except Exception as e:
        local_deleted = False
        error_messages.append(f"Masaüstü klasör silme hatası: {e}")
        print(f"[delete_version_or_project_endpoint] Masaüstü klasör silme hatası: {e}")

    try:
        # Önce klasör içindeki tüm dosyaları sil
        all_items_in_path = list_storage_recursive(path=path_to_delete)
        
        if not all_items_in_path.get('files'): 
            print(f"Supabase'de '{path_to_delete}' altında silinecek dosya bulunamadı.")
            supabase_deleted_all_files = True 
        else:
            print(f"Supabase'den '{path_to_delete}' altındaki {len(all_items_in_path['files'])} dosya siliniyor...")
            for item_file_path in all_items_in_path['files']:
                if not delete_file_from_supabase(item_file_path):
                    supabase_deleted_all_files = False
                    error_messages.append(f"Supabase'den '{item_file_path}' silinemedi.")
                    print(f"Hata: Supabase'den '{item_file_path}' silinemedi.")
            print(f"Supabase'deki dosya silme işlemi tamamlandı.")

        # Şimdi klasörün kendisini sil (eğer dosyalar başarıyla silindiyse)
        if supabase_deleted_all_files:
            try:
                print(f"Klasör siliniyor: {path_to_delete}")
                
                # Klasör yolunu temizle
                clean_path = path_to_delete.strip('/')
                
                # Farklı path formatlarını dene
                folder_paths_to_try = [
                    clean_path,
                    f"projects/{clean_path}",
                    clean_path.replace('projects/', '') if clean_path.startswith('projects/') else clean_path
                ]
                
                folder_deleted = False
                for folder_path in folder_paths_to_try:
                    try:
                        # Klasörün hala içinde dosya var mı kontrol et
                        remaining_files = list_storage_recursive(path=folder_path)
                        if not remaining_files.get('files'):
                            print(f"Klasör başarıyla silindi")
                            folder_deleted = True
                            break
                        else:
                            # Kalan dosyaları da silmeye çalış
                            for remaining_file in remaining_files['files']:
                                if delete_file_from_supabase(remaining_file):
                                    pass
                                else:
                                    pass
                            
                            # Tekrar kontrol et
                            final_check = list_storage_recursive(path=folder_path)
                            if not final_check.get('files'):
                                print(f"Klasör başarıyla silindi")
                                folder_deleted = True
                                break
                            
                    except Exception as folder_error:
                        continue
                
                if folder_deleted:
                    supabase_folder_deleted = True
                    print(f"Klasör başarıyla silindi")
                else:
                    error_messages.append(f"Klasör silinemedi")
                    print(f"Klasör silinemedi")
                    
            except Exception as e:
                error_messages.append(f"Klasör silme hatası: {e}")
                print(f"Klasör silme hatası: {e}")

        # Veritabanından ilgili kayıtları sil
        try:
            print(f"Veritabanından '{path_to_delete}' ile ilgili kayıtlar siliniyor...")
            
            # Path'i temizle
            clean_path = path_to_delete.strip('/')
            
            # Önce versions tablosundan kontrol et
            versions_response = supabase.table('versions').select('version_id, version_name, storage_path').execute()
            versions_to_delete = []
            
            for version in versions_response.data:
                if version.get('storage_path') and clean_path in version['storage_path']:
                    versions_to_delete.append(version['version_id'])
                    print(f"Silinecek versiyon bulundu: {version['version_name']} (ID: {version['version_id']})")
            
            # Versiyonları sil
            if versions_to_delete:
                for version_id in versions_to_delete:
                    try:
                        data, count = supabase.table('versions').delete().eq('version_id', version_id).execute()
                        if data:
                            print(f"Versiyon ID {version_id} başarıyla silindi.")
                        else:
                            print(f"Versiyon ID {version_id} silinemedi.")
                    except Exception as e:
                        print(f"Versiyon silme hatası (ID: {version_id}): {e}")
                        error_messages.append(f"Versiyon silme hatası: {e}")
            
            # Şimdi projects tablosundan kontrol et
            projects_response = supabase.table('projects').select('project_id, project_name, storage_path').execute()
            projects_to_delete = []
            
            for project in projects_response.data:
                if project.get('storage_path') and clean_path in project['storage_path']:
                    projects_to_delete.append(project['project_id'])
                    print(f"Silinecek proje bulundu: {project['project_name']} (ID: {project['project_id']})")
            
            # Projeleri sil (eğer versiyonları yoksa)
            if projects_to_delete:
                for project_id in projects_to_delete:
                    try:
                        # Önce bu projeye ait versiyon var mı kontrol et
                        remaining_versions = supabase.table('versions').select('version_id').eq('project_id', project_id).execute()
                        
                        if not remaining_versions.data:
                            # Versiyon yoksa projeyi sil
                            data, count = supabase.table('projects').delete().eq('project_id', project_id).execute()
                            if data:
                                print(f"Proje ID {project_id} başarıyla silindi.")
                            else:
                                print(f"Proje ID {project_id} silinemedi.")
                        else:
                            print(f"Proje ID {project_id} silinmedi çünkü hala {len(remaining_versions.data)} versiyonu var.")
                    except Exception as e:
                        print(f"Proje silme hatası (ID: {project_id}): {e}")
                        error_messages.append(f"Proje silme hatası: {e}")
            
            db_records_deleted = True
            print(f"Veritabanı kayıtları başarıyla silindi.")
            
        except Exception as e:
            error_messages.append(f"Veritabanı kayıt silme hatası: {e}")
            print(f"[delete_version_or_project_endpoint] Veritabanı kayıt silme hatası: {e}")

    except Exception as e:
        supabase_deleted_all_files = False
        error_messages.append(f"Supabase rekürsif dosya silme hatası: {e}")
        print(f"[delete_version_or_project_endpoint] Supabase rekürsif dosya silme hatası: {e}")
    
    sync_storage_to_database() 

    final_success = local_deleted and supabase_deleted_all_files and supabase_folder_deleted and db_records_deleted
    status_message = "Klasör, içerikleri ve veritabanı kayıtları başarıyla silindi." if final_success else "Silme işleminde hatalar oluştu."
    
    return jsonify({
        "success": final_success,
        "local_deleted": local_deleted,
        "supabase_deleted": supabase_deleted_all_files,
        "supabase_folder_deleted": supabase_folder_deleted,
        "db_records_deleted": db_records_deleted,
        "message": status_message,
        "errors": error_messages 
    })
@app.route('/create_folder', methods=['POST'])
@token_required
def create_folder_endpoint(user):

    try:
        data = request.json
        if not data:
            return jsonify({'success': False, 'message': 'JSON data gerekli'}), 400
            
        folder_path = data.get('folder_path')
        
        print(f"[DEBUG] create_folder called with: folder_path={folder_path}")

        if not folder_path:
            return jsonify({'success': False, 'message': 'folder_path gerekli'}), 400
        
        # Path'i normalize et (başta/sonda slash olmasın)
        folder_path = folder_path.strip('/')
        
        # Storage'da klasör oluştur
        full_folder_path = full_path(folder_path)
        
        print(f"[DEBUG] Full folder path: {full_folder_path}")
        
        if os.path.exists(full_folder_path):
            return jsonify({'success': False, 'message': 'Bu klasör zaten var'}), 409
            
        # Yerel klasör oluştur
        os.makedirs(full_folder_path, exist_ok=True)
        print(f"[DEBUG] Local folder created: {full_folder_path}")
        
        # .keep dosyası oluştur (boş klasörlerin Supabase'de görünmesi için)
        placeholder_file_name = ".keep"
        local_placeholder_path = os.path.join(full_folder_path, placeholder_file_name)
        supabase_placeholder_path = f"{folder_path}/{placeholder_file_name}"

        # .keep dosyasını oluştur
        with open(local_placeholder_path, 'w') as f:
            f.write("# Bu dosya klasörün boş olsa bile görünmesini sağlar\n")

        print(f"[DEBUG] Placeholder file created: {local_placeholder_path}")
        print(f"[DEBUG] Will upload to: {supabase_placeholder_path}")
        
        # Supabase Storage'a yükle
        upload_success = upload_file_to_supabase(local_placeholder_path, supabase_placeholder_path)
        
        # Yerel temp dosyayı sil
        if os.path.exists(local_placeholder_path):
            os.remove(local_placeholder_path) 

        if upload_success:
            print(f"[SUCCESS] Klasör başarıyla oluşturuldu: {folder_path}")
            return jsonify({
                'success': True, 
                'path': folder_path, 
                'message': f"'{folder_path}' klasörü başarıyla oluşturuldu."
            }), 200
        else:
            # Hata durumunda yerel klasörü temizle
            if os.path.exists(full_folder_path):
                shutil.rmtree(full_folder_path)
                print(f"[CLEANUP] Local folder removed due to upload failure: {full_folder_path}")
            return jsonify({
                'success': False, 
                'message': 'Klasör oluşturuldu ancak Supabase Storage\'a yüklenemedi'
            }), 500

    except Exception as e:
        print(f"[ERROR] create_folder genel hatası: {e}")
        return jsonify({'success': False, 'message': f'Sunucu hatası: {str(e)}'}), 500
@app.route('/update_version', methods=['POST'])
@token_required
def update_version_endpoint(user):

    version_path = request.form.get('version_path')
    if not version_path:
        print("[ERROR] version_path parametresi eksik!")
        print(f"[DEBUG] Gelen form fields: {list(request.form.keys())}")
        print(f"[DEBUG] Gelen files: {list(request.files.keys())}")
        return jsonify({
            'success': False, 
            'message': 'version_path gerekli. Lütfen versiyon yolunu belirtin.'
        }), 400

    clean_version_path = version_path.strip('/')
    print(f"[UPDATE_VERSION] Versiyon path: {clean_version_path}")
    print(f"[UPDATE_VERSION] User: {user.get('email', 'Unknown')}")
    
    # ✅ Files validation
    if not request.files and not any([
        request.form.get("info_txt_content"),
        request.form.get("hex_content"), 
        request.form.get("settings_content")
    ]):
        return jsonify({
            'success': False, 
            'message': 'Güncellenecek dosya veya içerik bulunamadı.'
        }), 400
    
    uploaded_files = {}
    success_count = 0
    failed_files = []
    user_id = user.get('id') if user else None

    try:
        content_mappings = {
            'info_txt_content': ('info.txt', 'txt'),
            'hex_content': ('hr.hex', 'hex'),
            'settings_content': ('settings.json', 'json')
        }
        
        for form_key, (target_filename, file_ext) in content_mappings.items():
            content = request.form.get(form_key)
            if content and content.strip():
                temp_file_name = f"temp_{file_ext}_{int(datetime.now().timestamp())}.{file_ext}"
                local_path = os.path.join(TEMP_UPLOAD_FOLDER, temp_file_name)
                
                try:
                    with open(local_path, 'w', encoding='utf-8') as f:
                        f.write(content)
                    
                    uploaded_files[local_path] = {
                        'supabase_path': f"{clean_version_path}/{target_filename}",
                        'local_target_path': full_path(f"{clean_version_path}/{target_filename}".replace("/", os.sep)),
                        'type': 'content'
                    }
                    print(f"[UPDATE_VERSION] Content hazırlandı: {target_filename}")
                except Exception as content_error:
                    print(f"[ERROR] Content hazırlama hatası ({target_filename}): {content_error}")
        
        file_mappings = {
            'info_txt': 'info.txt',
            'image': 'image.jpg',  # Default, gerçek uzantı korunacak
            'hex': 'hr.hex',
            'settings': 'settings.json'
        }
        
        for file_key, default_name in file_mappings.items():
            if file_key in request.files:
                file_storage = request.files[file_key]
                
                if not file_storage.filename:
                    print(f"[WARNING] Boş dosya atlandı: {file_key}")
                    continue
        
                original_filename = file_storage.filename
                if file_key == 'image':      # Image için uzantıyı koru
                    ext = original_filename.split('.')[-1].lower() if '.' in original_filename else 'jpg'
                    if ext not in ['jpg', 'jpeg', 'png']:
                        ext = 'jpg'
                    target_filename = f"image.{ext}"
                else:
                    target_filename = default_name
                
                # ✅ Temp file oluştur
                temp_file_name = f"temp_{file_key}_{int(datetime.now().timestamp())}_{target_filename}"
                local_temp_path = os.path.join(TEMP_UPLOAD_FOLDER, temp_file_name)
                
                try:
                    file_storage.save(local_temp_path)
                    
                    # ✅ File size check
                    if os.path.getsize(local_temp_path) == 0:
                        print(f"[WARNING] Boş dosya atlandı: {original_filename}")
                        os.remove(local_temp_path)
                        continue
                    
                    uploaded_files[local_temp_path] = {
                        'supabase_path': f"{clean_version_path}/{target_filename}",
                        'local_target_path': full_path(f"{clean_version_path}/{target_filename}".replace("/", os.sep)),
                        'type': 'file',
                        'original_name': original_filename
                    }
                    print(f"[UPDATE_VERSION] Dosya hazırlandı: {original_filename} -> {target_filename}")
                    
                except Exception as file_error:
                    print(f"[ERROR] Dosya kaydetme hatası ({original_filename}): {file_error}")

        # ✅ Final validation
        if not uploaded_files:
            return jsonify({
                'success': False, 
                'message': 'İşlenebilir dosya bulunamadı. Dosyaların boş olmadığından emin olun.'
            }), 400

        print(f"[UPDATE_VERSION] Toplam {len(uploaded_files)} dosya işlenecek")

        # ✅ Process files
        for temp_local_path, file_info in uploaded_files.items():
            supabase_path = file_info['supabase_path']
            local_target_path = file_info['local_target_path']
            file_type = file_info['type']
            
            try:
                print(f"[UPDATE_VERSION] İşleniyor: {supabase_path} ({file_type})")
                
                # ✅ Local directory oluştur
                os.makedirs(os.path.dirname(local_target_path), exist_ok=True)
                
                # ✅ Supabase'e yükle
                upload_success = upload_file_to_supabase(temp_local_path, supabase_path)
                
                if upload_success:
                    print(f"[SUCCESS] Supabase'e yüklendi: {supabase_path}")
                    
                    # ✅ Local kopyala
                    try:
                        shutil.copy2(temp_local_path, local_target_path)
                        print(f"[SUCCESS] Yerel kopyalandı: {local_target_path}")
                    except Exception as copy_error:
                        print(f"[WARNING] Yerel kopyalama hatası: {copy_error}")
                    
                    # ✅ Database record
                    try:
                        insert_file_record_to_db(supabase_path, user_id=user_id)
                        print(f"[SUCCESS] DB kaydı güncellendi: {supabase_path}")
                    except Exception as db_error:
                        print(f"[WARNING] DB güncelleme hatası: {db_error}")
                    
                    success_count += 1
                else:
                    failed_files.append({
                        'path': supabase_path,
                        'error': 'Supabase yükleme başarısız'
                    })
                    print(f"[ERROR] Supabase yükleme başarısız: {supabase_path}")
                    
            except Exception as file_error:
                failed_files.append({
                    'path': supabase_path,
                    'error': str(file_error)
                })
                print(f"[ERROR] Dosya işleme hatası ({supabase_path}): {file_error}")
            
            finally:
                # ✅ Cleanup temp file
                try:
                    if os.path.exists(temp_local_path):
                        os.remove(temp_local_path)
                        print(f"[CLEANUP] Temp dosya silindi: {temp_local_path}")
                except Exception as cleanup_error:
                    print(f"[WARNING] Cleanup hatası: {cleanup_error}")

        # ✅ Sync database if any success
        if success_count > 0:
            print(f"[SYNC] {success_count} dosya güncellendi, senkronizasyon başlatılıyor...")
            try:
                sync_storage_to_database()
                print("[SUCCESS] Senkronizasyon tamamlandı")
            except Exception as sync_error:
                print(f"[WARNING] Senkronizasyon hatası: {sync_error}")
        
        if success_count > 0:
            message = f"Versiyon başarıyla güncellendi ({success_count} dosya başarılı"
            if failed_files:
                message += f", {len(failed_files)} dosya başarısız"
            message += ")"
            
            return jsonify({
                'success': True,
                    'message': message,
                    'successful_files': success_count,
                    'failed_files': failed_files
            }), 200
        else:
            error_details = [f['error'] for f in failed_files[:3]] 
            return jsonify({
            'success': False,
                'message': f'Hiçbir dosya güncellenemedi. İlk hatalar: {", ".join(error_details)}',
                'failed_files': failed_files
            }), 500

    except Exception as e:
        print(f"[ERROR] Version güncelleme genel hatası: {e}")
        
        for temp_path in uploaded_files.keys():
            try:
                if os.path.exists(temp_path):
                    os.remove(temp_path)
                    print(f"[CLEANUP] Hata durumunda temizlendi: {temp_path}")
            except:
                pass
        
        return jsonify({
            'success': False,
            'message': f'Versiyon güncellenirken beklenmeyen hata: {str(e)}'
        }), 500
    
def debug_path_info(version_path, file_name=None):
    clean_path = version_path.strip('/')
    print(f"=== PATH DEBUG ===")
    print(f"Original path: {version_path}")
    print(f"Cleaned path: {clean_path}")
    
    if file_name:
        supabase_path = f"{clean_path}/{file_name}"
        local_path = full_path(f"{clean_path}/{file_name}".replace("/", os.sep))
        print(f"File: {file_name}")
        print(f"Supabase path: {supabase_path}")
        print(f"Local path: {local_path}")
        print(f"Local dir exists: {os.path.exists(os.path.dirname(local_path))}")
    
    print(f"==================")
    
@app.route('/rename_node', methods=['POST'])
@token_required
def rename_node_endpoint(user):
    data = request.json
    old_path = data.get('old_path', '').strip()
    new_path = data.get('new_path', '').strip()

    if not old_path or not new_path:
        return jsonify({
            'success': False, 
            'message': 'Eski yol ve yeni yol gerekli.'
        }), 400
    
    if old_path == new_path:
        return jsonify({
            'success': False, 
            'message': 'Eski yol ve yeni yol aynı olamaz.'
        }), 400
    
    # ✅ Path format normalization: 'projects/' önekli/öneksiz yolları kabul et
    def _normalize(p: str) -> str:
        p = p.strip().strip('/')
        return p if not p.startswith('projects/') else p[9:]

    old_norm = _normalize(old_path)
    new_norm = _normalize(new_path)
    if not old_norm or not new_norm:
        return jsonify({'success': False, 'message': 'Geçersiz yol.'}), 400
    
    # ✅ Versiyon klasörlerinin yeniden adlandırılmasını engelle
    if '/v' in old_path.lower() or 'version' in old_path.lower():
        return jsonify({
            'success': False, 
            'message': 'Versiyon klasörleri yeniden adlandırılamaz.'
        }), 403
    
    try:
        print(f"Renaming: {old_path} -> {new_path} (normalized: {old_norm} -> {new_norm})")
        success, message = rename_supabase_object(old_norm, new_norm)
        
        if success:
            # Database sync
            sync_storage_to_database()
            return jsonify({
                'success': True, 
                'message': message
            }), 200
        else:
            return jsonify({
                'success': False, 
                'message': message
            }), 500
            
    except Exception as e:
        print(f"Rename endpoint error: {e}")
        return jsonify({
            'success': False, 
            'message': f'İşlem sırasında hata oluştu: {str(e)}'
        }), 500
    
@app.route('/download_file', methods=['GET']) 
def download_file_endpoint(): 
    file_path = request.args.get('path')
    if not file_path:
        return jsonify({'error': 'path gerekli'}), 400

    try:
        print(f"Dosya indirme isteği: {file_path}")
        
        # Dosya yolunu temizle ve farklı formatları dene
        clean_paths = []
        
        # Format 0: projects/ARM/Handvell/ABC/v1/image.jpg
        if file_path.startswith('projects/'):
            clean_paths.append(file_path[9:])  # 'projects/' kısmını kaldır
        
        # Format 1: ARM/Handvell/ABC/v1/image.jpg (zaten temiz)
        clean_paths.append(file_path)
        
        # Format 2: İlk segmenti kaldır (eğer projects/ ile başlamıyorsa)
        if not file_path.startswith('projects/'):
            path_parts = file_path.split('/')
            if len(path_parts) > 1:
                clean_paths.append('/'.join(path_parts[1:]))
        
        # Format 3: projects/ prefix'li path (eğer yoksa)
        if not file_path.startswith('projects/'):
            clean_paths.append(f"projects/{file_path}")
        
        print(f"Denenecek path'ler: {clean_paths}")
        
        # Dosya türünü belirle
        file_extension = os.path.splitext(file_path)[1].lower()
        is_image = file_extension in ['.jpg', '.jpeg', '.png', '.gif', '.bmp', '.webp']
        is_text = file_extension in ['.txt', '.json', '.hex', '.md', '.log']
        
        # Her path formatını dene
        for clean_path in clean_paths:
            try:
                print(f"Path deneniyor: {clean_path}")
                
                # Yerel dosya yolu oluştur
                local_file_path = full_path(clean_path.replace("/", os.sep))
                
                # Yerel dosya varsa oku
                if os.path.exists(local_file_path):
                    print(f"Dosya yerelde bulundu: {local_file_path}")
                    
                    if is_image:
                        # Resim dosyası - binary olarak oku
                        with open(local_file_path, 'rb') as f:
                            content = f.read()
                        return content, 200, {'Content-Type': 'image/jpeg' if file_extension in ['.jpg', '.jpeg'] else 'image/png'}
                    elif is_text:
                        # Metin dosyası - text olarak oku
                        with open(local_file_path, 'r', encoding='utf-8') as f:
                            content = f.read()
                        return content, 200
                    else:
                        # Diğer dosyalar - binary olarak oku
                        with open(local_file_path, 'rb') as f:
                            content = f.read()
                        return content, 200

                print(f"Dosya yerelde bulunamadı, Supabase'den indiriliyor: {clean_path}")
                
                # Supabase'den indir
                download_success = download_file_from_supabase(clean_path, local_file_path)
                if download_success:
                    print(f"Dosya başarıyla indirildi: {local_file_path}")
                    
                    if is_image:
                        with open(local_file_path, 'rb') as f:
                            content = f.read()
                        return content, 200, {'Content-Type': 'image/jpeg' if file_extension in ['.jpg', '.jpeg'] else 'image/png'}
                    elif is_text:
                        # Metin dosyası - text olarak oku
                        with open(local_file_path, 'r', encoding='utf-8') as f:
                            content = f.read()
                        return content, 200 
                    else:
                        with open(local_file_path, 'rb') as f:
                            content = f.read()
                        return content, 200
                        
            except Exception as e:
                print(f"Path {clean_path} için hata: {e}")
                continue
        
        # Hiçbir path formatı çalışmadı
        print(f"Tüm path formatları başarısız: {file_path}")
        return jsonify({'error': f'Dosya bulunamadı veya indirilemedi: {file_path}'}), 404
            
    except FileNotFoundError:
        print(f"Dosya bulunamadı: {file_path}")
        return jsonify({'error': f'Dosya bulunamadı: {file_path}'}), 404
    except Exception as e:
        print(f"Dosya indirme hatası: {e}")
        return jsonify({'error': f'Dosya okuma veya indirme hatası: {str(e)}'}), 500

@app.route('/preview_file', methods=['GET'])
def preview_file_endpoint():
    path = request.args.get('path')
    if not path:
        return jsonify({"error": "path parametresi gerekli"}), 400

    try:
        content, ftype = read_file_from_storage(path)
        if content is None:
            return jsonify({"error": "Dosya okunamadı"}), 404

        if ftype == 'text':
            return content, 200, {'Content-Type': 'text/plain; charset=utf-8'}
        elif ftype == 'image':
            # Binary response
            ext = os.path.splitext(path)[1].lower()
            mime = 'image/png' if ext == '.png' else 'image/jpeg'
            return content, 200, {'Content-Type': mime}
        else:
            return jsonify({"error": "Desteklenmeyen dosya türü"}), 415
    except Exception as e:
        print(f"[preview_file] Hata: {e}")
        return jsonify({"error": str(e)}), 500

@app.route('/get_local_path', methods=['GET'])
def get_local_path():
    path = request.args.get('path')
    if not path:
        return jsonify({'error': 'path gerekli'}), 400

    try:
        local_path = full_path(path.replace("/", os.sep))
        return jsonify({'local_path': local_path}), 200
    except Exception as e:
        return jsonify({'error': f'Yol dönüştürme hatası: {str(e)}'}), 500

@app.route('/sync', methods=['POST'])
@token_required
def sync_now(user):
    try:
        sync_storage_to_database()
        return jsonify({'success': True, 'message': 'Senkranizasyon başarılı'}), 200
    except Exception as e:
        return jsonify({'success': False, 'message': str(e)}), 500

@app.route('/update_project_name', methods=['POST'])
def update_project_name_endpoint():
    data = request.json
    project_id = data.get('project_id')
    new_name = data.get('new_name')

    if not project_id or not new_name:
        return jsonify({'success': False, 'message': 'Proje ID ve yeni isim gerekli.'}), 400

    try:
        # Mevcut proje bilgisi alınır
        project_response = supabase.table('projects').select('*').eq('project_id', project_id).execute()
        if not project_response.data:
            return jsonify({'success': False, 'message': 'Proje bulunamadı'}), 404
        
        old_project = project_response.data[0]
        old_storage_path = old_project['storage_path']

        # Yeni storage path hesaplanır
        if '/' not in old_storage_path:
            new_storage_path = new_name
        else:
            path_parts = old_storage_path.split('/')
            path_parts[-1] = new_name
            new_storage_path = '/'.join(path_parts)

        # Storage'da klasör rename işlemi yapılır
        success, message = rename_supabase_object(old_storage_path, new_storage_path)
        if not success:
            return jsonify({'success': False, 'message': f'Storage rename başarısız: {message}'}), 500

        # Lokal klasör rename yapılabilir (opsiyonel)
        try:
            old_local_path = full_path(old_storage_path)
            new_local_path = full_path(new_storage_path)
            if os.path.exists(old_local_path):
                os.rename(old_local_path, new_local_path)
        except Exception as e:
            print(f"Yerel klasör rename hatası: {e}")

        # projects tablosu güncellenir
        result = supabase.table('projects').update({
            'project_name': new_name,
            'storage_path': new_storage_path
        }).eq('project_id', project_id).execute()
        if not result.data:
            return jsonify({'success': False, 'message': 'Database güncelleme başarısız'}), 500

        # versions tablosundaki path'ler güncellenir
        versions_response = supabase.table('versions').select('*').like('storage_path', f"{old_storage_path}/%").execute()
        if versions_response.data:
            for version in versions_response.data:
                old_version_path = version['storage_path']
                new_version_path = old_version_path.replace(old_storage_path, new_storage_path, 1)
                supabase.table('versions').update({
                    'storage_path': new_version_path
                }).eq('version_id', version['version_id']).execute()

        # Senkronizasyon işlemi yapılabilir
        sync_storage_to_database()

        return jsonify({'success': True, 'message': 'Proje ismi ve storage başarıyla güncellendi'}), 200

    except Exception as e:
        return jsonify({'success': False, 'message': f'Hata: {str(e)}'}), 500

@app.route('/upload_file', methods=['POST'])
def upload_file_endpoint():
    try:
        # Multipart form data'dan dosya ve path bilgisini al
        if 'file' not in request.files:
            return jsonify({'success': False, 'message': 'Dosya bulunamadı'}), 400
        
        file = request.files['file']
        path = request.form.get('path', '')
        
        if file.filename == '':
            return jsonify({'success': False, 'message': 'Dosya seçilmedi'}), 400
        
        if not path:
            return jsonify({'success': False, 'message': 'Dosya yolu belirtilmedi'}), 400
        
        print(f"Dosya yükleme isteği: {path}")
        print(f"Dosya adı: {file.filename}")
        
        # Geçici dosya oluştur
        temp_file_path = os.path.join(TEMP_UPLOAD_FOLDER, file.filename)
        file.save(temp_file_path)
        
        try:
            # Supabase'e yükle
            upload_success = upload_file_to_supabase(temp_file_path, path)
            
            if upload_success:
                print(f"Dosya başarıyla yüklendi: {path}")
                return jsonify({'success': True, 'message': 'Dosya başarıyla yüklendi'}), 200
            else:
                print(f"Dosya yükleme başarısız: {path}")
                return jsonify({'success': False, 'message': 'Dosya yükleme başarısız'}), 500
                
        finally:
            # Geçici dosyayı temizle
            if os.path.exists(temp_file_path):
                os.remove(temp_file_path)
                
    except Exception as e:
        print(f"Dosya yükleme hatası: {e}")
        return jsonify({'success': False, 'message': f'Yükleme hatası: {str(e)}'}), 500

@app.route('/project_details', methods=['GET'])
@token_required
def project_details_endpoint(user):
    """Proje detaylarını getir"""
    try:
        project_id = request.args.get('project_id')
        if not project_id:
            return jsonify({"error": "project_id gerekli"}), 400
        
        # Proje bilgilerini al
        project_response = supabase.table('projects').select('*').eq('project_id', project_id).execute()
        if not project_response.data:
            return jsonify({"error": "Proje bulunamadı"}), 404
        
        project = project_response.data[0]
        
        # Projeye ait versiyonları al
        versions_response = supabase.table('versions').select('*').eq('project_id', project_id).execute()
        versions = versions_response.data
        
        return jsonify({
            "project": project,
            "versions": versions
        })
        
    except Exception as e:
        print(f"Proje detayları hatası: {e}")
        return jsonify({"error": str(e)}), 500

@app.route('/project_versions', methods=['GET'])
@token_required
def project_versions_endpoint(user):
    """Projeye ait versiyonları getir"""
    try:
        project_id = request.args.get('project_id')
        if not project_id:
            return jsonify({"error": "project_id gerekli"}), 400
        
        # Projeye ait versiyonları al
        versions_response = supabase.table('versions').select('*').eq('project_id', project_id).execute()
        versions = versions_response.data
        
        return jsonify({
            "versions": versions
        })
        
    except Exception as e:
        print(f"Proje versiyonları hatası: {e}")
        return jsonify({"error": str(e)}), 500

@app.route('/version_details', methods=['GET'])
@token_required
def version_details_endpoint(user):
    """Versiyon detaylarını getir"""
    try:
        version_id = request.args.get('version_id')
        if not version_id:
            return jsonify({"error": "version_id gerekli"}), 400
        
        # Versiyon bilgilerini al
        version_response = supabase.table('versions').select('*').eq('version_id', version_id).execute()
        if not version_response.data:
            return jsonify({"error": "Versiyon bulunamadı"}), 404
        
        version = version_response.data[0]
        
        return jsonify({
            "version": version
        })
        
    except Exception as e:
        print(f"Versiyon detayları hatası: {e}")
        return jsonify({"error": str(e)}), 500

@app.route('/get_txt_content', methods=['GET'])
@token_required
def get_txt_content_endpoint(user):
    """TXT dosyasının içeriğini getir"""
    try:
        path = request.args.get('path')
        if not path:
            return jsonify({"error": "path gerekli"}), 400
        
        # Dosyayı Supabase'den indir
        try:
            content = supabase.storage.from_(BUCKET_NAME).download(path)
            if content:
                return content.decode('utf-8'), 200, {'Content-Type': 'text/plain; charset=utf-8'}
            else:
                return jsonify({"error": "Dosya bulunamadı"}), 404
        except Exception as e:
            print(f"Dosya okuma hatası: {e}")
            return jsonify({"error": "Dosya okunamadı"}), 404
            
    except Exception as e:
        print(f"TXT içerik hatası: {e}")
        return jsonify({"error": str(e)}), 500

if __name__ == '__main__':
    is_main_process = not FLASK_DEBUG or os.environ.get("WERKZEUG_RUN_MAIN") == "true"

    if is_main_process:
        print("Supabase senkronizasyon zamanlayıcısı başlatılıyor...")
        sync_timer = threading.Timer(SYNC_INTERVAL, run_supabase_sync_periodically)
        sync_timer.daemon = True 
        sync_timer.start()

    print("Flask sunucusu başlatılıyor... http://0.0.0.0:5000")
    print(f"Debug modu: {FLASK_DEBUG}")
    print("Reload aktif: Evet" if FLASK_DEBUG else "Hayır")

    app.run(
        host='0.0.0.0',
        port=5000,
        debug=True,           # Debug mod açık
        use_reloader=True     # Otomatik yeniden başlatma
    )
