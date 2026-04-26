import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:async';
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'package:elfatekapp/models/project_tree_response.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter/foundation.dart';

const String _baseUrl = 'http://10.197.151.158:5000';

// API Response wrapper sınıfı
class ApiResponse<T> {
  final bool success;
  final T? data;
  final String? error;
  final int? statusCode;

  ApiResponse.success(this.data)
    : success = true,
      error = null,
      statusCode = 200;

  ApiResponse.error(this.error, [this.statusCode])
    : success = false,
      data = null;
}

class ApiService {
  final supabaseClient = Supabase.instance.client;

  Future<http.Response> authorizedGet(String url) async {
    var token = supabaseClient.auth.currentSession?.accessToken;
    var response = await http.get(
      Uri.parse(url),
      headers: {'Authorization': 'Bearer $token'},
    );

    if (response.statusCode == 401) {
      await supabaseClient.auth.refreshSession();
      token = supabaseClient.auth.currentSession?.accessToken;
      response = await http.get(
        Uri.parse(url),
        headers: {'Authorization': 'Bearer $token'},
      );
    }
    return response;
  }

  Future<bool> updateProjectName(String projectId, String newName) async {
    try {
      debugPrint('=== UPDATE PROJECT NAME API CALL ===');
      debugPrint('Project ID: $projectId');
      debugPrint('New Name: $newName');

      final response = await authorizedPost('$_baseUrl/update_project_name', {
        'project_id': projectId,
        'new_name': newName,
      });

      debugPrint('Update project name status: ${response.statusCode}');
      debugPrint('Update project name body: ${response.body}');

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return data['success'] == true;
      }
      return false;
    } catch (e) {
      debugPrint('Update project name error: $e');
      return false;
    }
  }

  Future<String> getBase() async {
    return _baseUrl;
  }

  // Retry mechanism ile geliştirilmiş HTTP istekleri
  Future<http.Response> authorizedRequestWithRetry(
    String method,
    String url, {
    Map<String, dynamic>? body,
    int maxRetries = 3,
  }) async {
    for (int attempt = 0; attempt < maxRetries; attempt++) {
      try {
        var token = supabaseClient.auth.currentSession?.accessToken;

        http.Response response;
        final headers = {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        };

        switch (method.toUpperCase()) {
          case 'GET':
            response = await http.get(Uri.parse(url), headers: headers);
            break;
          case 'POST':
            response = await http.post(
              Uri.parse(url),
              headers: headers,
              body: body != null ? json.encode(body) : null,
            );
            break;
          default:
            throw Exception('Unsupported HTTP method: $method');
        }

        // Token expired, refresh and retry once
        if (response.statusCode == 401 && attempt == 0) {
          debugPrint('Token expired, refreshing...');
          await supabaseClient.auth.refreshSession();
          token = supabaseClient.auth.currentSession?.accessToken;
          headers['Authorization'] = 'Bearer $token';

          switch (method.toUpperCase()) {
            case 'GET':
              response = await http.get(Uri.parse(url), headers: headers);
              break;
            case 'POST':
              response = await http.post(
                Uri.parse(url),
                headers: headers,
                body: body != null ? json.encode(body) : null,
              );
              break;
          }
        }
        return response;
      } catch (e) {
        debugPrint('Request attempt ${attempt + 1} failed: $e');
        if (attempt == maxRetries - 1) rethrow;
        await Future.delayed(Duration(milliseconds: 500 * (attempt + 1)));
      }
    }
    throw Exception('Max retry attempts reached');
  }

  Future<bool> updateVersionFiles(
    String versionPath,
    Map<String, File> files,
  ) async {
    try {
      debugPrint('=== UPDATE VERSION FILES API CALL ===');
      debugPrint('Version path: $versionPath');
      debugPrint('Files to update: ${files.keys.toList()}');

      final request = http.MultipartRequest(
        'POST',
        Uri.parse('$_baseUrl/update_version_files'),
      );

      // Authorization header ekle
      final token = supabaseClient.auth.currentSession?.accessToken;
      if (token != null) {
        request.headers['Authorization'] = 'Bearer $token';
      }

      // Version path'i ekle
      request.fields['version_path'] = versionPath;

      // Dosyaları ekle
      for (final entry in files.entries) {
        final fileKey = entry.key;
        final file = entry.value;

        // Dosya adını backend'in beklediği formata çevir
        String fileName;
        switch (fileKey) {
          case 'info_txt':
            fileName = 'info.txt';
            break;
          case 'image':
            fileName = 'image.jpg';
            break;
          case 'hex':
            fileName = 'hr.hex';
            break;
          case 'settings':
            fileName = 'settings.json';
            break;
          default:
            fileName = file.path.split('/').last;
        }

        final fileStream = http.ByteStream(file.openRead());
        final length = await file.length();

        final multipartFile = http.MultipartFile(
          fileKey,
          fileStream,
          length,
          filename: fileName,
        );

        request.files.add(multipartFile);
      }

      final streamedResponse = await request.send();
      final response = await http.Response.fromStream(streamedResponse);

      debugPrint(
        'Update version files response status: ${response.statusCode}',
      );
      debugPrint('Update version files response body: ${response.body}');

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final success = data['success'] == true;
        debugPrint('Update version files success: $success');
        if (success) {
          debugPrint('Version files updated successfully');
        } else {
          debugPrint(
            'Update version files failed: ${data['error'] ?? 'Unknown error'}',
          );
        }
        return success;
      }
      debugPrint(
        'Update version files failed with status: ${response.statusCode}',
      );
      return false;
    } catch (e) {
      debugPrint('Update version files error: $e');
      return false;
    }
  }

  Future<bool> renameNode(String oldPath, String newPath) async {
    try {
      debugPrint('=== RENAME NODE API CALL ===');
      debugPrint('Old path: $oldPath');
      debugPrint('New path: $newPath');

      // Path validation - boş veya geçersiz path kontrolü
      if (oldPath.isEmpty || newPath.isEmpty) {
        debugPrint('Error: Empty path provided');
        return false;
      }

      // Path format kontrolü
      if (oldPath == newPath) {
        debugPrint('Error: Old and new paths are the same');
        return false;
      }

      final response = await authorizedPost('$_baseUrl/rename_node', {
        'old_path': oldPath,
        'new_path': newPath,
      });

      debugPrint('Response status: ${response.statusCode}');
      debugPrint('Response body: ${response.body}');

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        bool success = data['success'] == true;

        if (!success && data['message'] != null) {
          debugPrint('Server error message: ${data['message']}');
        }

        return success;
      } else if (response.statusCode == 403) {
        debugPrint('Forbidden: Cannot rename version folders');
        return false;
      } else {
        debugPrint('HTTP Error: ${response.statusCode}');
        return false;
      }
    } catch (e) {
      debugPrint('Rename node error: $e');
      return false;
    }
  }

  Future<Map<String, File>?> pickVersionFiles() async {
    try {
      debugPrint('=== PICK VERSION FILES STARTED ===');
      Map<String, File> selectedFiles = {};

      // Tüm dosyaları tek bir dialogda seçin
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        allowMultiple: true,
        dialogTitle:
            'Select version files (info.txt, image.jpg, hr.hex, settings.json)',
      );

      if (result == null || result.files.isEmpty) {
        debugPrint('No files selected.');
        return null;
      }

      // Seçilen dosyaları uzantılarına göre ayır
      for (var file in result.files) {
        final fileName = file.name.toLowerCase();
        final filePath = file.path;

        if (filePath == null) {
          debugPrint('File path is null for file: $fileName');
          continue;
        }

        if (fileName.endsWith('.txt')) {
          selectedFiles['info_txt'] = File(filePath);
          debugPrint('info.txt file selected: $filePath');
        } else if (fileName.endsWith('.jpg') ||
            fileName.endsWith('.jpeg') ||
            fileName.endsWith('.png')) {
          selectedFiles['image'] = File(filePath);
          debugPrint('image file selected: $filePath');
        } else if (fileName.endsWith('.hex')) {
          selectedFiles['hex'] = File(filePath);
          debugPrint('hex file selected: $filePath');
        } else if (fileName.endsWith('.json')) {
          selectedFiles['settings'] = File(filePath);
          debugPrint('settings file selected: $filePath');
        } else {
          debugPrint('Skipping unrecognized file: $fileName');
        }
      }

      if (selectedFiles.isEmpty) {
        return null;
      }

      debugPrint('=== PICK VERSION FILES FINISHED ===');
      return selectedFiles;
    } catch (e) {
      debugPrint('File picker error: $e');
      return null;
    }
  }

  Future<bool> addMainFolder(String folderName) async {
    try {
      debugPrint('=== ADD MAIN FOLDER API CALL ===');
      debugPrint('Folder name: $folderName');

      final response = await authorizedPost('$_baseUrl/add_project', {
        'project_name': folderName,
      });

      debugPrint('Response status: ${response.statusCode}');
      debugPrint('Response body: ${response.body}');

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return data['success'] == true;
      }
      return false;
    } catch (e) {
      debugPrint('Add main folder error: $e');
      return false;
    }
  }

  Future<bool> syncStorage() async {
    final token = supabaseClient.auth.currentSession?.accessToken;

    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/sync'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
      );
      return response.statusCode == 200;
    } catch (e) {
      debugPrint('Sync hatası: $e');
      return false;
    }
  }

  Future<bool> addProject(String projectName, String storagePath) async {
    try {
      debugPrint('=== ADD PROJECT API CALL ===');
      debugPrint('Project name: $projectName');
      debugPrint('Storage path: $storagePath');

      final response = await authorizedPost('$_baseUrl/add_project', {
        'project_name': projectName,
        'storage_path': storagePath,
      });

      debugPrint('Add project response status: ${response.statusCode}');
      debugPrint('Add project response body: ${response.body}');

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final success = data['success'] == true;
        debugPrint('Add project success: $success');
        return success;
      } else if (response.statusCode == 409) {
        final data = json.decode(response.body);
        final message = data['message'] ?? 'Proje zaten var.';
        // Bu hatayı fırlat, UI yakalasın
        throw Exception(message);
      } else {
        debugPrint('Add project failed with status: ${response.statusCode}');
        return false;
      }
    } catch (e) {
      debugPrint('Add project exception: $e');
      rethrow;
    }
  }

  Future<void> listAllFiles() async {
    try {
      final response = await authorizedGet('$_baseUrl/list_files');
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        debugPrint('Available files: $data');
      }
    } catch (e) {
      debugPrint('List files error: $e');
    }
  }

  Future<Object> renameFolder(String oldPath, String newPath) async {
    try {
      final response = await authorizedPost('$_baseUrl/rename_folder', {
        'old_path': oldPath,
        'new_path': newPath,
      });

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return data['success'] == true;
      }

      return await renameNode(oldPath, newPath);
    } catch (e) {
      debugPrint('Rename folder error: $e');
      return false;
    }
  }

  Future<http.Response> authorizedPost(
    String url,
    Map<String, dynamic> body,
  ) async {
    var token = supabaseClient.auth.currentSession?.accessToken;
    var response = await http.post(
      Uri.parse(url),
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      },
      body: json.encode(body),
    );

    if (response.statusCode == 401) {
      await supabaseClient.auth.refreshSession();
      token = supabaseClient.auth.currentSession?.accessToken;
      response = await http.post(
        Uri.parse(url),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: json.encode(body),
      );
    }
    return response;
  }

  Future<ProjectTreeResponse> fetchProjectTree() async {
    try {
      debugPrint('=== FETCH PROJECT TREE API CALL ===');

      final response = await authorizedGet('$_baseUrl/project_tree');

      debugPrint('Fetch project tree response status: ${response.statusCode}');

      if (response.statusCode == 200) {
        final data = json.decode(utf8.decode(response.bodyBytes));
        debugPrint('Project tree fetched successfully');
        return ProjectTreeResponse.fromJson(data);
      } else {
        debugPrint(
          'Fetch project tree failed with status: ${response.statusCode}',
        );
        debugPrint('Response body: ${response.body}');
        throw Exception(
          'Proje ağacı yüklenemedi: ${response.statusCode} - ${response.body}',
        );
      }
    } catch (e) {
      debugPrint('Project tree fetch error: $e');
      rethrow;
    }
  }

  Future<String?> fetchInfoTxt(String filePath) async {
    try {
      String cleanPath = filePath.trim();
      final encodedPath = Uri.encodeComponent(cleanPath);

      List<String> endpoints = [
        '$_baseUrl/get_txt_content?path=$encodedPath',
        '$_baseUrl/download_file?path=$encodedPath',
        '$_baseUrl/download?path=$encodedPath',
      ];

      for (String endpoint in endpoints) {
        try {
          final response = await authorizedGet(endpoint);
          if (response.statusCode == 200) {
            final content = utf8.decode(response.bodyBytes);
            return content;
          } else if (response.statusCode == 404) {
            continue;
          }
        } catch (e) {
          continue;
        }
      }
      return null;
    } catch (e) {
      debugPrint('Info.txt fetch exception: $e');
      return null;
    }
  }

  Future<Uint8List?> downloadFile(String path) async {
    try {
      final response = await authorizedGet('$_baseUrl/download?path=$path');
      if (response.statusCode == 200) {
        return response.bodyBytes;
      }
      return null;
    } catch (e) {
      debugPrint('Download file error: $e');
      return null;
    }
  }

  Future<String?> getTxtContent(String path) async {
    try {
      final response = await authorizedGet(
        '$_baseUrl/get_txt_content?path=$path',
      );
      if (response.statusCode == 200) {
        return utf8.decode(response.bodyBytes);
      }
      return null;
    } catch (e) {
      debugPrint('Get TXT content error: $e');
      return null;
    }
  }

  Future<Uint8List?> fetchImageBytes(String imagePath) async {
    try {
      debugPrint('=== FETCH IMAGE BYTES API CALL ===');
      debugPrint('Image path: $imagePath');

      String filePath = imagePath;
      if (imagePath.contains('supabase.co/storage/v1/object/public/')) {
        // Extract the path after 'public/'
        final publicIndex = imagePath.indexOf('/public/');
        if (publicIndex != -1) {
          filePath = imagePath.substring(publicIndex + 8); // +8 for '/public/'
          debugPrint('Extracted file path from Supabase URL: $filePath');
        }
      }
      List<String> pathFormats = [
        filePath, // Original path: projects/PIC/EN_MID/X/v2/image.jpg
        filePath.replaceFirst(
          'projects/',
          '',
        ), // Remove projects/ prefix: PIC/EN_MID/X/v2/image.jpg
        filePath
            .split('/')
            .skip(1)
            .join('/'), // Remove first segment: PIC/EN_MID/X/v2/image.jpg
      ];

      for (int i = 0; i < pathFormats.length; i++) {
        final currentPath = pathFormats[i];
        final encodedPath = Uri.encodeComponent(currentPath);
        final url = '$_baseUrl/download_file?path=$encodedPath';

        debugPrint('Trying path format $i: $currentPath');
        debugPrint('Request URL: $url');

        final response = await authorizedGet(url);
        debugPrint('Response status: ${response.statusCode}');

        if (response.statusCode == 200) {
          debugPrint(
            'Image fetched successfully with path format $i: $currentPath',
          );
          return response.bodyBytes;
        } else if (response.statusCode == 404) {
          debugPrint('Path format $i failed (404): $currentPath');
        } else {
          debugPrint(
            'Path format $i failed with status ${response.statusCode}: $currentPath',
          );
        }
      }

      // If backend fails, try loading directly from Supabase
      if (imagePath.contains('supabase.co/storage/v1/object/public/')) {
        debugPrint('Backend failed, trying direct Supabase download');
        try {
          final response = await http.get(Uri.parse(imagePath));
          if (response.statusCode == 200) {
            debugPrint('Image fetched successfully from Supabase directly');
            return response.bodyBytes;
          } else {
            debugPrint(
              'Supabase direct download failed with status: ${response.statusCode}',
            );
          }
        } catch (e) {
          debugPrint('Supabase direct download exception: $e');
        }
      }

      debugPrint('All methods failed for image: $imagePath');
      return null;
    } catch (e) {
      debugPrint('Image fetch exception: $e');
      return null;
    }
  }

  Future<bool> updateFile(String filePath, String content) async {
    try {
      final response = await authorizedPost('$_baseUrl/update_file', {
        'supabase_path': filePath,
        'content': content,
      });

      if (response.statusCode == 200) {
        final result = json.decode(response.body);
        return result['success'] == true;
      }
      return false;
    } catch (e) {
      debugPrint('Update file error: $e');
      return false;
    }
  }

  Future<bool> updateFileContentBase64(
    String filePath,
    String contentBase64,
  ) async {
    try {
      final response = await authorizedPost('$_baseUrl/update_file', {
        'supabase_path': filePath,
        'content': contentBase64,
      });

      if (response.statusCode == 200) {
        final result = json.decode(response.body);
        return result['success'] == true;
      }
      return false;
    } catch (e) {
      debugPrint('Update file base64 error: $e');
      return false;
    }
  }

  Future<bool> createFolderOnServer(
    String parentPath,
    String folderName,
  ) async {
    try {
      debugPrint('=== CREATE FOLDER API CALL ===');
      debugPrint('Parent path: $parentPath');
      debugPrint('Folder name: $folderName');

      final response = await authorizedPost('$_baseUrl/create_folder', {
        'folder_path': '$parentPath/$folderName',
      });

      debugPrint('Create folder response status: ${response.statusCode}');
      debugPrint('Create folder response body: ${response.body}');

      if (response.statusCode == 200) {
        final result = json.decode(response.body);
        final success = result['success'] == true;
        debugPrint('Create folder success: $success');
        return success;
      } else {
        debugPrint('Create folder failed with status: ${response.statusCode}');
        return false;
      }
    } catch (e) {
      debugPrint('Create folder exception: $e');
      return false;
    }
  }

  Future<bool> deleteFolder(String folderPath) async {
    try {
      debugPrint('=== DELETE FOLDER API CALL ===');
      debugPrint('Folder path: $folderPath');

      // Check if path is empty or null
      if (folderPath.isEmpty) {
        debugPrint('Error: Folder path is empty');
        return false;
      }

      // Clean the path - remove any leading/trailing slashes
      String cleanPath = folderPath.trim();
      if (cleanPath.startsWith('/')) {
        cleanPath = cleanPath.substring(1);
      }
      if (cleanPath.endsWith('/')) {
        cleanPath = cleanPath.substring(0, cleanPath.length - 1);
      }

      debugPrint('Cleaned path: $cleanPath');

      // First attempt: Send additional parameters to ensure the entire folder is deleted
      // If backend doesn't support these parameters, it will ignore them
      final response = await authorizedPost(
        '$_baseUrl/delete_version_or_project',
        {
          'path': cleanPath,
          'recursive': 'true', // Klasörün tamamını sil
          'include_folder': 'true', // Klasörün kendisini de sil
          'delete_entire_folder': 'true', // Alternatif parametre
        },
      );

      debugPrint('Delete folder response status: ${response.statusCode}');
      debugPrint('Delete folder response body: ${response.body}');

      if (response.statusCode == 200) {
        final result = json.decode(response.body);
        final success = result['success'] == true;
        final localDeleted = result['local_deleted'] == true;

        debugPrint('Delete folder success: $success');
        debugPrint('Delete folder local_deleted: $localDeleted');

        // If the version was deleted locally but not from Supabase, we still consider it a success
        // because the user can see the change immediately
        if (localDeleted) {
          debugPrint('Version was deleted locally, considering as success');
          return true;
        }

        // If the first attempt didn't work, try a second attempt with just the path
        // This might be needed if the backend doesn't support the additional parameters
        if (!success) {
          debugPrint(
            'First attempt failed, trying second attempt with just path',
          );
          final secondResponse = await authorizedPost(
            '$_baseUrl/delete_version_or_project',
            {'path': cleanPath},
          );

          if (secondResponse.statusCode == 200) {
            final secondResult = json.decode(secondResponse.body);
            final secondSuccess = secondResult['success'] == true;
            final secondLocalDeleted = secondResult['local_deleted'] == true;

            debugPrint('Second attempt success: $secondSuccess');
            debugPrint('Second attempt local_deleted: $secondLocalDeleted');

            if (secondLocalDeleted || secondSuccess) {
              return true;
            }
          }
        }

        return success;
      } else {
        debugPrint('Delete folder failed with status: ${response.statusCode}');
        debugPrint('Delete folder error response: ${response.body}');
        return false;
      }
    } catch (e) {
      debugPrint('Delete folder exception: $e');
      return false;
    }
  }

  Future<bool> addVersion(
    String projectPath,
    String versionName,
    Map<String, File> files,
  ) async {
    try {
      debugPrint('=== ADD VERSION API CALL ===');
      debugPrint('Project path: $projectPath');
      debugPrint('Version name: $versionName');
      debugPrint('Files count: ${files.length}');

      var token = supabaseClient.auth.currentSession?.accessToken;
      if (token == null) {
        await supabaseClient.auth.refreshSession();
        token = supabaseClient.auth.currentSession?.accessToken;
      }

      var request = http.MultipartRequest(
        'POST',
        Uri.parse('$_baseUrl/add_version'),
      );
      request.headers['Authorization'] = 'Bearer $token';
      request.fields['project'] = projectPath;
      request.fields['version'] = versionName;

      for (final entry in files.entries) {
        final fileKey = entry.key;
        final file = entry.value;

        debugPrint('Adding file: $fileKey -> ${file.path}');
        request.files.add(
          await http.MultipartFile.fromPath(fileKey, file.path),
        );
      }

      final response = await request.send();
      final responseBody = await response.stream.bytesToString();

      debugPrint('Add version response status: ${response.statusCode}');
      debugPrint('Add version response body: $responseBody');

      if (response.statusCode == 200) {
        final result = json.decode(responseBody);
        final success = result['success'] == true;
        debugPrint('Add version success: $success');
        return success;
      } else {
        debugPrint('Add version failed with status: ${response.statusCode}');
        return false;
      }
    } catch (e) {
      debugPrint('Add version error: $e');
      return false;
    }
  }

  Future<bool> createProject(String projectName) async {
    try {
      debugPrint('=== CREATE PROJECT API CALL ===');
      debugPrint('Project name: $projectName');

      final response = await authorizedPost('$_baseUrl/create_project', {
        'project_name': projectName,
      });

      debugPrint('Create project response status: ${response.statusCode}');
      debugPrint('Create project response body: ${response.body}');

      if (response.statusCode == 200) {
        final result = json.decode(response.body);
        final success = result['success'] == true;
        debugPrint('Create project success: $success');
        return success;
      } else {
        debugPrint('Create project failed with status: ${response.statusCode}');
        return false;
      }
    } catch (e) {
      debugPrint('Create project error: $e');
      return false;
    }
  }

  Future<bool> updateVersion(
    String versionPath,
    Map<String, File> files,
  ) async {
    try {
      debugPrint('=== UPDATE VERSION API CALL ===');
      debugPrint('Version path: $versionPath');
      debugPrint('Files count: ${files.length}');

      var token = supabaseClient.auth.currentSession?.accessToken;
      if (token == null) {
        await supabaseClient.auth.refreshSession();
        token = supabaseClient.auth.currentSession?.accessToken;
      }

      if (token == null) {
        debugPrint('No valid token available');
        return false;
      }

      var request = http.MultipartRequest(
        'POST',
        Uri.parse('$_baseUrl/update_version'),
      );
      request.headers['Authorization'] = 'Bearer $token';

      // ✅ DÜZELTME: Backend'in beklediği field adını kullan
      request.fields['version_path'] =
          versionPath; // Backend 'version_path' bekliyor!

      debugPrint('Sending version_path: $versionPath');

      // ✅ Dosyaları backend'in beklediği key'lerle gönder
      for (final entry in files.entries) {
        final fileKey = entry.key;
        final file = entry.value;

        debugPrint('Adding file: $fileKey -> ${file.path}');

        // Dosya var mı kontrol et
        if (!await file.exists()) {
          debugPrint('File does not exist: ${file.path}');
          continue;
        }

        // Dosya boyutunu kontrol et
        final fileSize = await file.length();
        if (fileSize == 0) {
          debugPrint('File is empty: ${file.path}');
          continue;
        }

        // ✅ MultipartFile oluştur
        final multipartFile = await http.MultipartFile.fromPath(
          fileKey,
          file.path,
          filename: _getCorrectFileName(fileKey, file.path),
        );

        request.files.add(multipartFile);
        debugPrint('Added file: ${multipartFile.filename} (${fileSize} bytes)');
      }

      debugPrint('Total files to upload: ${request.files.length}');
      debugPrint('Request fields: ${request.fields}');

      // ✅ Request gönder
      final response = await request.send();
      final responseBody = await response.stream.bytesToString();

      debugPrint('Update version response status: ${response.statusCode}');
      debugPrint('Update version response body: $responseBody');

      if (response.statusCode == 200) {
        try {
          final result = json.decode(responseBody);
          final success = result['success'] == true;

          if (!success && result['message'] != null) {
            debugPrint('Server error: ${result['message']}');
          }

          debugPrint('Update version success: $success');
          return success;
        } catch (jsonError) {
          debugPrint('JSON parse error: $jsonError');
          debugPrint('Raw response: $responseBody');
          return false;
        }
      } else if (response.statusCode == 400) {
        debugPrint('Bad request - check field names and required data');
        try {
          final errorResult = json.decode(responseBody);
          debugPrint('Error message: ${errorResult['message']}');
        } catch (e) {
          debugPrint('Could not parse error response');
        }
        return false;
      } else {
        debugPrint('Update version failed with status: ${response.statusCode}');
        return false;
      }
    } catch (e) {
      debugPrint('Update version error: $e');
      return false;
    }
  }

  String _getCorrectFileName(String fileKey, String filePath) {
    final originalFileName = filePath.split('/').last;

    switch (fileKey) {
      case 'info_txt':
        return 'info.txt';
      case 'image':
        // Orijinal uzantıyı koru ama adı image yap
        final ext = originalFileName.contains('.')
            ? originalFileName.split('.').last
            : 'jpg';
        return 'image.$ext';
      case 'hex':
        return 'hr.hex';
      case 'settings':
        return 'settings.json';
      default:
        return originalFileName;
    }
  }

  Future<bool> createVersionWithFiles(
    String projectPath,
    String versionName,
    Map<String, File> files,
  ) async {
    try {
      debugPrint('=== CREATE VERSION WITH FILES API CALL ===');
      debugPrint('Project path: $projectPath');
      debugPrint('Version name: $versionName');
      debugPrint('Files count: ${files.length}');

      var token = supabaseClient.auth.currentSession?.accessToken;
      if (token == null) {
        await supabaseClient.auth.refreshSession();
        token = supabaseClient.auth.currentSession?.accessToken;
      }

      final request = http.MultipartRequest(
        'POST',
        Uri.parse('$_baseUrl/add_version'),
      );
      request.headers['Authorization'] = 'Bearer $token';
      request.fields['project'] = projectPath;
      request.fields['version'] = versionName;

      for (final entry in files.entries) {
        final fileKey = entry.key;
        final file = entry.value;

        debugPrint('Adding file: $fileKey -> ${file.path}');
        request.files.add(
          await http.MultipartFile.fromPath(fileKey, file.path),
        );
      }

      final response = await request.send();
      final responseBody = await response.stream.bytesToString();

      debugPrint('Create version response status: ${response.statusCode}');
      debugPrint('Create version response body: $responseBody');

      if (response.statusCode == 200) {
        final result = json.decode(responseBody);
        final success = result['success'] == true;
        debugPrint('Create version success: $success');
        return success;
      } else {
        debugPrint('Create version failed with status: ${response.statusCode}');
        return false;
      }
    } catch (e) {
      debugPrint('Create version error: $e');
      return false;
    }
  }

  Future<bool> openFolder(String folderPath) async {
    try {
      if (Platform.isWindows) {
        final result = await Process.run('explorer', [folderPath]);
        return result.exitCode == 0;
      } else if (Platform.isMacOS) {
        final result = await Process.run('open', [folderPath]);
        return result.exitCode == 0;
      } else if (Platform.isLinux) {
        final result = await Process.run('xdg-open', [folderPath]);
        return result.exitCode == 0;
      }
      return false;
    } catch (e) {
      debugPrint('Open folder error: $e');
      return false;
    }
  }

  Future<String?> getLocalFolderPath(String supabasePath) async {
    try {
      final response = await authorizedGet(
        '$_baseUrl/get_local_path?path=$supabasePath',
      );
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return data['local_path'];
      }
      return null;
    } catch (e) {
      debugPrint('Get local folder path error: $e');
      return null;
    }
  }
}
