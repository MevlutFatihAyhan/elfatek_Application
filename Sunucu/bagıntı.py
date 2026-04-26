from __future__ import annotations

import os
import time
from datetime import datetime
from typing import Dict, List, Tuple

from supabase import StorageException, create_client, Client

from config import SUPABASE_URL, SUPABASE_KEY, BUCKET_NAME, DESKTOP_FOLDER

# Tekil Supabase istemcisi (sunucu.py bu değişkeni import ediyor)
supabase: Client = create_client(SUPABASE_URL, SUPABASE_KEY)


def _normalize_path(path: str) -> str:
    p = (path or "").strip().strip("/")
    return p[9:] if p.startswith("projects/") else p


def _content_type_for(path: str) -> str:
    lower = path.lower()
    if lower.endswith(".txt"):
        return "text/plain; charset=utf-8"
    if lower.endswith(".json"):
        return "application/json"
    if lower.endswith(".jpg") or lower.endswith(".jpeg"):
        return "image/jpeg"
    if lower.endswith(".png"):
        return "image/png"
    if lower.endswith(".hex"):
        return "application/octet-stream"
    return "application/octet-stream"


def list_storage(path: str = "") -> Dict[str, List[str]]:
    try:
        clean_path = _normalize_path(path)

        candidates = [clean_path]
        if clean_path and not clean_path.startswith("projects/"):
            candidates.append(f"projects/{clean_path}")

        for candidate in candidates:
            try:
                items = supabase.storage.from_(BUCKET_NAME).list(
                    candidate, options={"sortBy": {"column": "name"}}
                )
                if items is None:
                    continue
                folders: List[str] = []
                files: List[str] = []
                for item in items:
                    # Supabase list çıktısında klasörler için id/updated_at yok
                    if item.get("id") is None and item.get("name"):
                        folders.append(item["name"])  # alt klasör adı
                    elif item.get("name"):
                        files.append(item["name"])     # dosya adı
                return {"folders": sorted(folders), "files": sorted(files)}
            except Exception:
                continue

        return {"folders": [], "files": []}
    except Exception as e:
        print(f"[list_storage] Hata ('{path}'): {e}")
        return {"folders": [], "files": []}


def list_storage_recursive(path: str = "") -> Dict[str, List[str]]:
    all_folders: List[str] = []
    all_files: List[str] = []

    def _walk(current_path: str) -> None:
        items = list_storage(current_path)
        for folder_name in items.get("folders", []):
                full_folder_path = os.path.join(current_path, folder_name).replace("\\", "/")
                all_folders.append(full_folder_path)
                _walk(full_folder_path)
        for file_name in items.get("files", []):
                full_file_path = os.path.join(current_path, file_name).replace("\\", "/")
                all_files.append(full_file_path)

    try:
        _walk(path.strip("/"))
        return {"folders": sorted(all_folders), "files": sorted(all_files)}
    except Exception as e:
        print(f"[list_storage_recursive] Hata: {e}")
        return {"folders": [], "files": []}


def read_file_from_storage(path: str):
    try:
        content = supabase.storage.from_(BUCKET_NAME).download(path)
        if path.lower().endswith(".txt"):
            return content.decode("utf-8"), "text"
        if path.lower().endswith((".png", ".jpg", ".jpeg")):
            return content, "image"
        return content, "binary"
    except Exception as e:
        print(f"[read_file_from_storage] Hata: {e}")
        return None, None


def build_tree_from_paths(file_paths: List[str]) -> Dict:
    tree: Dict = {"folders": {}, "files": []}
    for full_path in sorted(file_paths):
        parts = [p for p in full_path.split("/") if p]
        current = tree
        for i, part in enumerate(parts):
            if i == len(parts) - 1:
                current.setdefault("files", []).append(part)
            else:
                current.setdefault("folders", {})
                if part not in current["folders"]:
                    current["folders"][part] = {"folders": {}, "files": []}
                current = current["folders"][part]
    return tree


def get_full_project_tree(user_id=None, is_admin: bool = False) -> Dict:
    try:
        print("Veritabanından proje ağacı çekiliyor...")

        if is_admin:
            projects_response = (
                supabase.table("projects").select("project_id, project_name, storage_path").execute()
            )
            allowed_paths = [p["storage_path"] for p in projects_response.data]
        else:
            user_projects_response = (
                supabase.table("user_projects")
                .select("projects(storage_path), project_id")
                .eq("user_id", user_id)
                .execute()
            )
            allowed_paths = [
                up["projects"]["storage_path"]
                for up in user_projects_response.data
                if up.get("projects") and up["projects"].get("storage_path")
            ]

        if not allowed_paths:
            return {"name": "root", "is_folder": True, "path": "", "children": []}

        root_path = "" if is_admin or len(allowed_paths) != 1 else allowed_paths[0]

        projects_response = (
            supabase.table("projects").select("project_id, project_name, storage_path").execute()
        )
        projects_data = [
            p
            for p in projects_response.data
            if is_admin or any(p["storage_path"].startswith(path) for path in allowed_paths)
        ]

        versions_response = (
            supabase.table("versions").select("version_id, project_id, version_name, storage_path").execute()
        )
        versions_data = [
            v
            for v in versions_response.data
            if is_admin or any(v["storage_path"].startswith(path) for path in allowed_paths)
        ]

        project_tree = {"name": root_path.split("/")[-1] if root_path else "root", "is_folder": True, "path": root_path, "children": []}
        nodes_by_path = {root_path: project_tree}

        for p in projects_data:
            if root_path and not p["storage_path"].startswith(root_path):
                continue
            path_parts = [part for part in p["storage_path"].split("/") if part]
            current_parent_path = ""
            current_parent_node = project_tree
            for part in path_parts:
                full_part_path = os.path.join(current_parent_path, part).replace("\\", "/")
                if full_part_path not in nodes_by_path:
                    new_folder_node = {
                        "name": part,
                        "is_folder": True,
                        "path": full_part_path,
                        "project_id": p["project_id"],
                        "children": [],
                    }
                    current_parent_node["children"].append(new_folder_node)
                    nodes_by_path[full_part_path] = new_folder_node
                current_parent_node = nodes_by_path[full_part_path]
                current_parent_path = full_part_path

        for version in versions_data:
            parent_path = "/".join(version["storage_path"].split("/")[:-1])
            if parent_path in nodes_by_path:
                parent_node = nodes_by_path[parent_path]
                image_path = f"{version['storage_path']}/image.jpg"
                info_txt_path = f"{version['storage_path']}/info.txt"
                version_node = {
                    "name": version["version_name"],
                    "is_folder": True,
                    "is_version": True,
                    "path": version["storage_path"],
                    "version_id": version["version_id"],
                    "project_id": version["project_id"],
                    "storage_path": version["storage_path"],
                    "image_url": supabase.storage.from_(BUCKET_NAME).get_public_url(image_path).rstrip("?"),
                    "info_txt_path": info_txt_path,
                    "children": [
                        {"name": "image.jpg", "is_folder": False, "path": image_path},
                        {"name": "info.txt", "is_folder": False, "path": info_txt_path},
                        {"name": "settings.json", "is_folder": False, "path": f"{version['storage_path']}/settings.json"},
                        {"name": "hr.hex", "is_folder": False, "path": f"{version['storage_path']}/hr.hex"},
                    ],
                }
                parent_node["children"].append(version_node)
                nodes_by_path[version["storage_path"]] = version_node

        return project_tree
    except Exception as e:
        print(f"[get_full_project_tree] Hata: {e}")
        return {"name": "root", "is_folder": True, "path": "", "children": []}


def delete_file_from_supabase(supabase_path: str) -> bool:
    try:
        variants = [supabase_path]
        if not supabase_path.startswith("projects/"):
            variants.append(f"projects/{supabase_path}")
        if supabase_path.startswith("projects/"):
            variants.append(supabase_path[9:])

        for variant in variants:
            try:
                res = supabase.storage.from_(BUCKET_NAME).remove([variant])
                if isinstance(res, list) and len(res) > 0 and "name" in res[0]:
                    return True
            except Exception:
                continue
        return False
    except Exception as e:
        print(f"[delete_file_from_supabase] Hata: {e}")
        return False


def download_file_from_supabase(supabase_path: str, local_path: str) -> bool:
    try:
        os.makedirs(os.path.dirname(local_path), exist_ok=True)
        variants = [supabase_path]
        if not supabase_path.startswith("projects/"):
            variants.append(f"projects/{supabase_path}")
        if supabase_path.startswith("projects/"):
            variants.append(supabase_path[9:])

        for variant in variants:
            try:
                data = supabase.storage.from_(BUCKET_NAME).download(variant)
                if data is not None:
                    with open(local_path, "wb") as f:
                        f.write(data)
                return True
            except Exception:
                continue
                return False
    except Exception as e:
        print(f"[download_file_from_supabase] Hata: {e}")
        return False


def upload_file_to_supabase(local_file_path: str, supabase_path: str, max_retries: int = 3) -> bool:
    if not os.path.exists(local_file_path):
        print(f"[UPLOAD] Yerel dosya bulunamadı: {local_file_path}")
        return False

    clean_supabase_path = supabase_path.strip("/")
    content_type = _content_type_for(clean_supabase_path)

    for attempt in range(max_retries):
        try:
            with open(local_file_path, "rb") as f:
                file_bytes = f.read()

            file_exists = False
            try:
                supabase.storage.from_(BUCKET_NAME).download(clean_supabase_path)
                file_exists = True
            except StorageException as e:
                if "not found" in str(e).lower():
                    file_exists = False
                else:
                    raise
            except Exception:
                file_exists = False

            if file_exists:
                res = supabase.storage.from_(BUCKET_NAME).update(
                    clean_supabase_path,
                    file_bytes,
                    file_options={"cache-control": "3600", "content-type": content_type},
                )
            else:
                res = supabase.storage.from_(BUCKET_NAME).upload(
                    clean_supabase_path,
                    file_bytes,
                    file_options={"cache-control": "3600", "content-type": content_type},
                )
        
            if res:
                return True
        except Exception as e:
            print(f"[UPLOAD] Hata (deneme {attempt + 1}): {e}")
            if attempt < max_retries - 1:
                time.sleep(2 * (attempt + 1))

            return False


def insert_file_record_to_db(file_path: str, user_id: str | None = None, retry_count: int = 3) -> bool:
    if not file_path:
        return False

    clean_path = file_path.strip("/")
    path_parts = clean_path.split("/")
    if len(path_parts) < 4:
        # En azından <...>/<...>/<project>/<version>/<file>
        return False

    category = path_parts[0]
    brand = path_parts[1]
    project_name = path_parts[2]
    version_name = path_parts[3]

    project_storage_path = f"{category}/{brand}/{project_name}"
    version_storage_path = f"{project_storage_path}/{version_name}"

    for attempt in range(retry_count):
        try:
            project_response = (
                supabase.table("projects").select("project_id").eq("storage_path", project_storage_path).execute()
            )
            if project_response.data:
                project_id = project_response.data[0]["project_id"]
            else:
                pr_ins = supabase.table("projects").insert(
                    {"project_name": project_name, "storage_path": project_storage_path, "created_at": datetime.now().isoformat()}
                ).execute()
                if not pr_ins.data:
                    return False
                project_id = pr_ins.data[0]["project_id"]

            version_response = (
                supabase.table("versions").select("version_id").eq("storage_path", version_storage_path).execute()
            )
            if version_response.data:
                version_id = version_response.data[0]["version_id"]
            else:
                vr_ins = supabase.table("versions").insert(
                    {
                        "project_id": project_id,
                        "version_name": version_name,
                        "storage_path": version_storage_path,
                        "created_at": datetime.now().isoformat(),
                    }
                ).execute()
                if not vr_ins.data:
                    return False
                version_id = vr_ins.data[0]["version_id"]

            if user_id:
                try:
                    existing = (
                        supabase.table("user_projects")
                        .select("user_id")
                        .eq("user_id", user_id)
                        .eq("project_id", project_id)
                        .execute()
                    )
                    if not existing.data:
                        supabase.table("user_projects").insert(
                            {"user_id": user_id, "project_id": project_id, "assigned_at": datetime.now().isoformat()}
                        ).execute()
                except Exception as e:
                    print(f"[insert_file_record_to_db] user_projects atama uyarısı: {e}")

            return True
        except Exception as e:
            print(f"[insert_file_record_to_db] Deneme {attempt + 1} hata: {e}")
            if attempt == retry_count - 1:
                return False
            time.sleep(2 * (attempt + 1))

            return False


def update_file_content(local_path: str, supabase_path: str, content: str) -> bool:
    try:
        os.makedirs(os.path.dirname(local_path), exist_ok=True)
        with open(local_path, "w", encoding="utf-8") as f:
            f.write(content)
        uploaded = upload_file_to_supabase(local_path, supabase_path)
        if uploaded:
            insert_file_record_to_db(supabase_path)
        return uploaded
    except Exception as e:
        print(f"[update_file_content] Hata: {e}")
        return False


def rename_supabase_object(old_path: str, new_path: str) -> Tuple[bool, str]:
    try:
        old_norm = _normalize_path(old_path)
        new_norm = _normalize_path(new_path)
        if not old_norm or not new_norm:
            return False, "Geçersiz yol"
        if old_norm == new_norm:
            return False, "Eski ve yeni yol aynı"

        parent_path = new_norm.rsplit("/", 1)[0] if "/" in new_norm else ""
        new_name = new_norm.rsplit("/", 1)[-1]
        try:
            listing = supabase.storage.from_(BUCKET_NAME).list(parent_path)
            for item in listing or []:
                if item.get("name") == new_name:
                    return False, f"'{new_name}' zaten var"
        except Exception:
            pass

        all_items = list_storage_recursive(old_norm)
        files_under_prefix = all_items.get("files", [])

        def _download_any(path: str):
            candidates = [path]
            if not path.startswith("projects/"):
                candidates.append(f"projects/{path}")
            if path.startswith("projects/"):
                candidates.append(path[9:])
            for var in candidates:
                try:
                    data = supabase.storage.from_(BUCKET_NAME).download(var)
                    if data:
                        return data
                except Exception:
                    continue
            return None

        if files_under_prefix:
            moved = 0
            for old_file in files_under_prefix:
                relative = old_file[len(old_norm):].lstrip("/") if old_file.startswith(old_norm) else os.path.basename(old_file)
                new_file = f"{new_norm}/{relative}" if relative else new_norm
                data = _download_any(old_file)
                if data is None:
                    continue
                ct = _content_type_for(new_file)
                supabase.storage.from_(BUCKET_NAME).upload(new_file, data, file_options={"cache-control": "3600", "content-type": ct})
                delete_file_from_supabase(old_file)
                moved += 1
            if moved == 0:
                return False, "Taşınacak dosya bulunamadı"
            return True, f"{moved} dosya taşındı"

        data = _download_any(old_norm)
        if data is None:
            return False, "Kaynak bulunamadı"
        ct = _content_type_for(new_norm)
        supabase.storage.from_(BUCKET_NAME).upload(new_norm, data, file_options={"cache-control": "3600", "content-type": ct})
        delete_file_from_supabase(old_norm)
        return True, "Dosya taşındı"
    except Exception as e:
        return False, f"Hata: {e}"


