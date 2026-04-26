import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;
import 'package:elfatekapp/services/api_service.dart';
import '../models/project_tree_response.dart';
import 'dart:async';
import 'package:http/http.dart' as http;

Uint8List? _imageBytes;
String? _selectedImagePath;

class ProjectPage extends StatefulWidget {
  final String username;
  final bool isAdmin;

  const ProjectPage({super.key, required this.username, this.isAdmin = false});

  @override
  State<ProjectPage> createState() => _ProjectPageState();
}

class _ProjectPageState extends State<ProjectPage> {
  ProjectTreeResponse? _projectTreeResponse;
  ProjectNode? _currentDrillDownNode;
  bool _isLoading = true;
  int selectedAnaKlasorIndex = 0;
  String? _selectedFolderPath;
  String? _infoTxtContent;
  bool _isAdmin = false;

  String get currentFolderPath => _currentDrillDownNode?.path ?? '';
  Timer? _timer;
  final ApiService _apiService = ApiService();

  @override
  void initState() {
    super.initState();
    _isAdmin = widget.isAdmin;
    _fetchProjectTreeAndInit();
    // Otomatik yenileme kaldırıldı
    // _timer = Timer.periodic(const Duration(seconds: 10), (timer) {
    //   _fetchProjectTreeAndInit(showLoading: false);
    // });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _fetchProjectTreeAndInit({bool showLoading = true}) async {
    if (showLoading) {
      setState(() => _isLoading = true);
    }
    try {
      final response = await _apiService.fetchProjectTree();
      if (!mounted) return;
      setState(() {
        _projectTreeResponse = response;

        // projects klasörünü filtrele
        List<ProjectNode> anaKlasorler = [];
        if (response.root.children.isNotEmpty) {
          final rootChildren = response.root.children;
          if (rootChildren.length == 1 && rootChildren[0].name == "projects") {
            anaKlasorler = rootChildren[0].children;
          } else {
            anaKlasorler = rootChildren;
          }
        }

        if (anaKlasorler.isNotEmpty) {
          _currentDrillDownNode = anaKlasorler[selectedAnaKlasorIndex];
          _selectedFolderPath = _currentDrillDownNode?.path;
        } else {
          _currentDrillDownNode = response.root;
          _selectedFolderPath = null;
        }
        _infoTxtContent = null;
        _imageBytes = null;
        _selectedImagePath = null;
      });
    } catch (e) {
      debugPrint('Proje ağacı yüklenirken hata oluştu: $e');
      _showSnackBar('Proje ağacı yüklenirken hata: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _reloadTree() async {
    try {
      debugPrint('=== RELOAD TREE START ===');

      setState(() {
        _isLoading = true; // Bu değişken varsa kullan
      });

      final resp = await _apiService.fetchProjectTree();

      debugPrint('Tree fetched successfully');
      debugPrint('Root children count: ${resp.root.children.length}');

      setState(() {
        _projectTreeResponse = resp;

        List<ProjectNode> anaKlasorler = [];
        if (resp.root.children.isNotEmpty) {
          final rootChildren = resp.root.children;
          if (rootChildren.length == 1 && rootChildren[0].name == "projects") {
            anaKlasorler = rootChildren[0].children;
          } else {
            anaKlasorler = rootChildren
                .where((node) => node.name != "projects")
                .toList();
          }
        }

        debugPrint('Ana klasörler count: ${anaKlasorler.length}');

        // ✅ Index kontrolü ve reset
        if (selectedAnaKlasorIndex >= anaKlasorler.length) {
          debugPrint(
            'Resetting selectedAnaKlasorIndex from $selectedAnaKlasorIndex to 0',
          );
          selectedAnaKlasorIndex = 0;
        }

        final selectedFolder = anaKlasorler.isNotEmpty
            ? anaKlasorler[selectedAnaKlasorIndex]
            : null;

        // ✅ Current node'u güncelle
        _currentDrillDownNode = selectedFolder ?? resp.root;
        _selectedFolderPath = selectedFolder?.path ?? "";

        // ✅ Loading state kapat
        _isLoading = false;

        debugPrint('Selected folder: ${selectedFolder?.name}');
        debugPrint('Selected path: $_selectedFolderPath');
        debugPrint('Current drill down node: ${_currentDrillDownNode?.name}');
      });

      debugPrint('=== RELOAD TREE SUCCESS ===');
    } catch (e) {
      debugPrint('=== RELOAD TREE ERROR ===');
      debugPrint('Error: $e');

      setState(() {
        _isLoading = false;
      });

      _showSnackBar('Projeler yenilenirken hata oluştu: $e');
    }
  }

  void _navigateToNode(ProjectNode node) {
    if (_currentDrillDownNode?.path == node.path && node.isVersion) {
      return;
    }
    setState(() {
      _currentDrillDownNode = node;
      _selectedFolderPath = node.path;
      _infoTxtContent = null;
      _selectedImagePath = null;
      _imageBytes = null;
    });

    if (node.isVersion) {
      if (node.infoTxtPath != null) {
        _loadSelectedVersionContent(node.infoTxtPath!);
      }
      if (node.imageUrl != null && node.imageUrl!.isNotEmpty) {
        _selectedImagePath = node.imageUrl;
        _loadSelectedImage();
      }
    } else {
      // Normal klasörler için normal davranış
      if (node.imageUrl != null && node.imageUrl!.isNotEmpty) {
        _selectedImagePath = node.imageUrl;
        _loadSelectedImage();
      } else if (node.infoTxtPath != null) {
        _loadSelectedVersionContent(node.path);
      }
    }
  }

  Future<void> _loadSelectedVersionContent(String? folderPath) async {
    if (folderPath == null) return;
    setState(() {
      _selectedFolderPath = folderPath;
      _infoTxtContent = null;
    });

    try {
      final isInfoPath = folderPath.endsWith('info.txt');
      final infoTxtFullPath = isInfoPath ? folderPath : '$folderPath/info.txt';

      final infoContent = await _apiService.fetchInfoTxt(infoTxtFullPath);

      if (!mounted) return;
      setState(() {
        _infoTxtContent = infoContent;
      });
    } catch (e) {
      _showSnackBar('Versiyon içeriği yüklenirken hata: $e');
    }
  }

  void _showSnackBar(String message) {
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  IconData _getFileIcon(String fileName) {
    final ext = fileName.split('.').last.toLowerCase();
    switch (ext) {
      case 'hex':
        return Icons.memory;
      case 'jpg':
      case 'jpeg':
      case 'png':
      case 'gif':
        return Icons.image;
      case 'txt':
        return Icons.description;
      case 'json':
        return Icons.code;
      default:
        return Icons.insert_drive_file;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _buildAppBar(),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _projectTreeResponse == null ||
                _projectTreeResponse!.root.children.isEmpty
          ? _buildErrorScreen()
          : Builder(
              builder: (context) {
                // projects klasörünü tamamen filtrele - sadece içindeki klasörleri al
                List<ProjectNode> anaKlasorler = [];
                if (_projectTreeResponse!.root.children.isNotEmpty) {
                  final rootChildren = _projectTreeResponse!.root.children;
                  // Eğer root'un ilk child'ı "projects" ise, onun children'larını al
                  if (rootChildren.length == 1 &&
                      rootChildren[0].name == "projects") {
                    anaKlasorler = rootChildren[0].children;
                  } else {
                    // Eğer projects klasörü yoksa, tüm root children'larını al
                    anaKlasorler = rootChildren
                        .where((node) => node.name != "projects")
                        .toList();
                  }
                }

                if (selectedAnaKlasorIndex >= anaKlasorler.length) {
                  selectedAnaKlasorIndex = 0;
                }

                final selectedFolder = anaKlasorler.isNotEmpty
                    ? anaKlasorler[selectedAnaKlasorIndex]
                    : null;
                _currentDrillDownNode ??=
                    selectedFolder ?? _projectTreeResponse!.root;
                _selectedFolderPath ??= selectedFolder?.path ?? "";

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      height: 1,
                      color: const Color.fromARGB(255, 0, 0, 0),
                    ),
                    const SizedBox(height: 20),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12.0),
                      child: SizedBox(
                        height: 120,
                        child: ListView.builder(
                          scrollDirection: Axis.horizontal,
                          itemCount: anaKlasorler.length,
                          itemBuilder: (context, index) {
                            final folder = anaKlasorler[index];
                            final bool isSelected =
                                selectedAnaKlasorIndex == index;

                            return GestureDetector(
                              onTap: () {
                                setState(() {
                                  selectedAnaKlasorIndex = index;
                                  _navigateToNode(folder);
                                });
                              },
                              onLongPress: () => _showContextMenu(
                                context,
                                folder,
                                isTopLevelFolder: true,
                              ),
                              child: Container(
                                width: MediaQuery.of(context).size.width * 0.4,
                                height: 200,
                                margin: const EdgeInsets.only(right: 12),
                                decoration: BoxDecoration(
                                  gradient: isSelected
                                      ? const LinearGradient(
                                          colors: [
                                            Color.fromARGB(255, 82, 121, 250),
                                            Color.fromARGB(255, 0, 0, 0),
                                          ],
                                          begin: Alignment.topLeft,
                                          end: Alignment.bottomRight,
                                        )
                                      : const LinearGradient(
                                          colors: [
                                            Color.fromARGB(255, 51, 0, 255),
                                            Color.fromARGB(255, 255, 255, 255),
                                          ],
                                          begin: Alignment.topLeft,
                                          end: Alignment.bottomRight,
                                        ),
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(
                                    color: isSelected
                                        ? const Color.fromARGB(255, 0, 0, 0)
                                        : const Color.fromARGB(
                                            255,
                                            255,
                                            255,
                                            255,
                                          ),
                                    width: 2,
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withOpacity(0.1),
                                      spreadRadius: 1,
                                      blurRadius: 4,
                                      offset: const Offset(0, 2),
                                    ),
                                  ],
                                ),
                                child: Center(
                                  child: Padding(
                                    padding: const EdgeInsets.all(8.0),
                                    child: Text(
                                      folder.name,
                                      style: TextStyle(
                                        color: isSelected
                                            ? const Color.fromARGB(
                                                255,
                                                255,
                                                255,
                                                255,
                                              )
                                            : Colors.black87,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 14,
                                      ),
                                      textAlign: TextAlign.center,
                                    ),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        child: Column(
                          children: [
                            Expanded(
                              flex: 1,
                              child: Container(
                                width: double.infinity,
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: Colors.grey.shade300,
                                    width: 2,
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withOpacity(0.05),
                                      spreadRadius: 1,
                                      blurRadius: 4,
                                      offset: const Offset(0, 2),
                                    ),
                                  ],
                                ),
                                child: _buildProjectTreeSection(),
                              ),
                            ),
                            const SizedBox(height: 20),
                            Expanded(
                              flex: 2,
                              child: _buildContentPreviewSection(),
                            ),
                            const SizedBox(height: 150),
                          ],
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: _openAdminMenu,
        backgroundColor: Colors.deepOrange,
        child: const Icon(Icons.settings, color: Colors.white),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      centerTitle: true,
      title: Image.asset('assets/images/elfatek_logo.jpg', height: 20),
      backgroundColor: const Color.fromARGB(255, 255, 255, 255),
      elevation: 0,
      iconTheme: const IconThemeData(color: Colors.blue),

      // Geri butonu sola alındı
      leading:
          (_currentDrillDownNode != null &&
              _currentDrillDownNode != _projectTreeResponse!.root &&
              _currentDrillDownNode!.path.isNotEmpty)
          ? IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: handleBackNavigation,
              tooltip: 'Geri',
            )
          : null,

      // Sağda sadece yenile butonu kaldı
      actions: [
        IconButton(
          icon: const Icon(Icons.refresh),
          onPressed: _reloadTree,
          tooltip: 'Yenile',
        ),
      ],
    );
  }

  Widget _buildErrorScreen() {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.error_outline, color: Colors.red, size: 48),
          SizedBox(height: 16),
          Text(
            'Proje verileri yüklenemedi veya sistemde proje bulunmuyor.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 16, color: Colors.grey),
          ),
        ],
      ),
    );
  }

  Widget _buildProjectTreeSection() {
    final isInFolder =
        _currentDrillDownNode != null && _currentDrillDownNode!.path.isNotEmpty;
    final title = isInFolder ? _currentDrillDownNode!.name : ' İçerik';
    final nodesToShow = _currentDrillDownNode?.children ?? [];

    List<Widget> buildNodeTiles() {
      // Versiyon klasöründeyse içeriği gösterme
      if (_currentDrillDownNode?.isVersion == true) {
        return [const Center(child: Text('Versiyon klasörü - İçerik gizli'))];
      }

      if (nodesToShow.isEmpty && _currentDrillDownNode?.isFolder == true) {
        return [const Center(child: Text('Bu klasörde içerik yok.'))];
      }

      // projects klasörünü filtrele
      final filteredNodes = nodesToShow
          .where((node) => node.name != "projects")
          .toList();

      final folders = filteredNodes.where((n) => n.isFolder).toList()
        ..sort((a, b) => a.name.compareTo(b.name));
      final files = filteredNodes.where((n) => !n.isFolder).toList()
        ..sort((a, b) => a.name.compareTo(b.name));

      return [
        ...folders.map(
          (node) => GestureDetector(
            onLongPress: () => _showContextMenu(context, node),
            child: ListTile(
              leading: const Icon(Icons.folder, color: Colors.blueGrey),
              title: Text(node.name),
              onTap: () {
                _navigateToNode(node);
                if (node.isFolder && node.isVersion == true) {
                  _loadSelectedVersionContent(node.path);
                }
              },
            ),
          ),
        ),
        ...files.map(
          (node) => GestureDetector(
            onLongPress: () => _showContextMenu(context, node),
            child: ListTile(
              leading: Icon(_getFileIcon(node.name), color: Colors.blue),
              title: Text(node.name),
              onTap: () => _onFileTap(node),
            ),
          ),
        ),
      ];
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: Text(
            title,
            style: const TextStyle(fontSize: 27.1, fontWeight: FontWeight.bold),
          ),
        ),
        Expanded(child: ListView(children: buildNodeTiles())),
      ],
    );
  }

  void _showContextMenu(
    BuildContext context,
    ProjectNode node, {
    bool isTopLevelFolder = false,
  }) {
    showModalBottomSheet(
      context: context,
      builder: (BuildContext bc) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              // Ana Klasör Menüsü (ARM, STM, PIC gibi)
              if (node.isFolder && isTopLevelFolder) ...[
                if (_isAdmin)
                  ListTile(
                    leading: const Icon(Icons.create_new_folder),
                    title: const Text('Ana Klasör Ekle'),
                    onTap: () {
                      Navigator.pop(bc);
                      _showCreateProjectFolderDialog(
                        parentPath: '',
                        isMainFolder: true,
                      );
                    },
                  ),
                if (_isAdmin)
                  ListTile(
                    leading: const Icon(Icons.folder_open),
                    title: const Text('Proje Ekle'),
                    onTap: () {
                      Navigator.pop(bc);
                      _showCreateProjectFolderDialog(
                        parentPath:
                            '$_selectedFolderPath', // 'TSY' yerine mevcut değişken kullanıldı
                        isMainFolder: false,
                      );
                    },
                  ),
                if (_isAdmin)
                  ListTile(
                    leading: const Icon(Icons.delete),
                    title: const Text('Ana Klasörü Sil'),
                    onTap: () {
                      Navigator.pop(bc);
                      _handleDeleteFolder(node.path);
                    },
                  ),
              ],
              // Proje Klasörü Menüsü (JOY, Otomotiv gibi, leaf)
              if (node.isFolder &&
                  !isTopLevelFolder &&
                  !node.isVersion &&
                  (node.children.isEmpty ||
                      node.children.every((c) => c.isVersion))) ...[
                if (_isAdmin)
                  ListTile(
                    leading: const Icon(Icons.folder_copy),
                    title: const Text('Versiyon Ekle'),
                    onTap: () {
                      Navigator.pop(bc);
                      _showCreateVersionWithFilesDialog(node);
                    },
                  ),
                ListTile(
                  leading: const Icon(Icons.edit),
                  title: const Text('Adı Değiştir'),
                  onTap: () {
                    Navigator.pop(bc);
                    _showRenameDialog(node);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.delete),
                  title: const Text('Projeyi Sil'),
                  onTap: () {
                    Navigator.pop(bc);
                    _handleDeleteFolder(node.path);
                  },
                ),
              ],
              // Versiyon Klasörü Menüsü (v1, v2 gibi)
              if (node.isFolder && node.isVersion) ...[
                ListTile(
                  leading: const Icon(Icons.update),
                  title: const Text('Versiyonu Güncelle'),
                  onTap: () {
                    Navigator.pop(bc);
                    _showUpdateVersionDialog(node);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.delete_forever),
                  title: const Text('Versiyonu Sil'),
                  onTap: () {
                    Navigator.pop(bc);
                    _handleDeleteVersion(node);
                  },
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  void _onFileTap(ProjectNode node) {
    final parentPath = node.path.substring(0, node.path.lastIndexOf('/'));
    _loadSelectedVersionContent(parentPath);

    final ext = node.name.toLowerCase();
    if (ext.endsWith('.png') || ext.endsWith('.jpg') || ext.endsWith('.jpeg')) {
      String? imageUrl;
      try {
        imageUrl = supabase.Supabase.instance.client.storage
            .from('projects')
            .getPublicUrl(node.path);
        if (imageUrl.endsWith('?')) {
          imageUrl = imageUrl.substring(0, imageUrl.length - 1);
        }
      } catch (e) {
        debugPrint('Resim dosyası için genel URL alınamadı: $e');
        imageUrl = null;
      }

      setState(() {
        _selectedImagePath = imageUrl;
      });
      _loadSelectedImage();
    } else {
      setState(() {
        _selectedImagePath = null;
        _imageBytes = null;
      });
    }
  }

  void handleBackNavigation() {
    if (_currentDrillDownNode != null &&
        _currentDrillDownNode != _projectTreeResponse!.root) {
      final segments = _currentDrillDownNode!.path.split('/');
      if (segments.length > 1) {
        final parentPath = segments.sublist(0, segments.length - 1).join('/');
        final parentNode = _findNodeByPath(
          _projectTreeResponse!.root,
          parentPath,
        );
        _navigateToNode(parentNode ?? _projectTreeResponse!.root);
      } else {
        _navigateToNode(_projectTreeResponse!.root);
      }
    }
  }

  ProjectNode? _findNodeByPath(ProjectNode currentNode, String targetPath) {
    if (currentNode.path == targetPath) return currentNode;
    for (var child in currentNode.children) {
      if (targetPath.startsWith(child.path)) {
        final foundNode = _findNodeByPath(child, targetPath);
        if (foundNode != null) return foundNode;
      }
    }
    return null;
  }

  Future<void> _loadSelectedImage() async {
    if (_selectedImagePath != null && _selectedImagePath!.isNotEmpty) {
      Uint8List? bytes;
      try {
        if (_selectedImagePath!.startsWith('http://') ||
            _selectedImagePath!.startsWith('https://')) {
          final response = await http.get(Uri.parse(_selectedImagePath!));
          if (response.statusCode == 200) {
            bytes = response.bodyBytes;
          } else {
            debugPrint('URL\'den resim yüklenemedi: ${response.statusCode}');
          }
        } else {
          bytes = await _apiService.fetchImageBytes(_selectedImagePath!);
        }
      } catch (e) {
        debugPrint('Resim yüklenirken hata: $e');
        bytes = null;
      }

      if (!mounted) return;
      setState(() {
        _imageBytes = bytes;
      });
    } else {
      if (!mounted) return;
      setState(() {
        _imageBytes = null;
      });
    }
  }

  Widget _buildContentPreviewSection() {
    return Container(
      padding: const EdgeInsets.all(12.0),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8.0),
        boxShadow: [
          BoxShadow(
            color: Colors.grey.withOpacity(0.2),
            spreadRadius: 2,
            blurRadius: 5,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Resim Önizleme',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
                const SizedBox(height: 10),
                Expanded(
                  child: Container(
                    width: double.infinity,
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey.shade300),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: _imageBytes != null
                        ? ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.memory(
                              _imageBytes!,
                              fit: BoxFit.contain,
                              errorBuilder: (context, error, stackTrace) =>
                                  const Center(
                                    child: Text('Resim yüklenemedi'),
                                  ),
                            ),
                          )
                        : _selectedImagePath != null
                        ? const Center(child: CircularProgressIndicator())
                        : const Center(child: Text('Gösterilecek resim yok')),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          const VerticalDivider(thickness: 1),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'info.txt İçeriği',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                    if (_infoTxtContent != null && _infoTxtContent!.isNotEmpty)
                      Text(
                        '${_infoTxtContent!.length} karakter',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.grey,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                Expanded(
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey.shade300),
                      borderRadius: BorderRadius.circular(8),
                      color: Colors.grey.shade50,
                    ),
                    child:
                        _infoTxtContent != null && _infoTxtContent!.isNotEmpty
                        ? SingleChildScrollView(
                            child: SelectableText(
                              _infoTxtContent!,
                              style: const TextStyle(
                                fontSize: 14,
                                fontFamily: 'monospace',
                                height: 1.4,
                              ),
                            ),
                          )
                        : const Center(
                            child: Text(
                              'Gösterilecek bilgi yok',
                              style: TextStyle(
                                color: Colors.grey,
                                fontStyle: FontStyle.italic,
                              ),
                            ),
                          ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _showRenameDialog(ProjectNode node) {
    final TextEditingController nameController = TextEditingController(
      text: node.name,
    );

    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Adı Değiştir'),
          content: TextField(
            controller: nameController,
            decoration: const InputDecoration(labelText: 'Yeni Ad'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('İptal'),
            ),
            TextButton(
              onPressed: () async {
                final newName = nameController.text.trim();

                if (newName.isEmpty) {
                  _showSnackBar('Lütfen bir ad girin');
                  return;
                }

                if (newName == node.name) {
                  _showSnackBar('Yeni ad mevcut adla aynı olamaz');
                  return;
                }

                if (newName.contains('/') || newName.contains('\\')) {
                  _showSnackBar('Ad özel karakterler içeremez (/ \\)');
                  return;
                }

                if (!node.isVersion &&
                    node.projectId != null &&
                    _projectTreeResponse != null) {
                  bool duplicate = false;
                  void checkDuplicate(ProjectNode n) {
                    if (n.projectId != null &&
                        n.name == newName &&
                        n.projectId != node.projectId) {
                      duplicate = true;
                    }
                    for (final c in n.children) {
                      checkDuplicate(c);
                    }
                  }

                  checkDuplicate(_projectTreeResponse!.root);
                  if (duplicate) {
                    _showSnackBar('Bu isimde bir proje zaten var.');
                    return;
                  }
                }

                Navigator.of(context).pop();

                debugPrint('=== RENAME DIALOG DEBUG ===');
                debugPrint('Node name: ${node.name}');
                debugPrint('Node path: ${node.path}');
                debugPrint('Node isVersion: ${node.isVersion}');
                debugPrint('New name: $newName');

                bool success = false;

                try {
                  // Proje klasöründeyse DB tabanlı rename kullan (ID korunur)
                  if (!node.isVersion && (node.projectId != null)) {
                    success = await _apiService.updateProjectName(
                      node.projectId!,
                      newName,
                    );
                  } else {
                    // Diğer durumlarda Storage path rename
                    final oldPath = node.path;
                    final newPath = _buildNewPath(oldPath, newName);

                    debugPrint('Old path: $oldPath');
                    debugPrint('New path: $newPath');

                    if (oldPath.isEmpty || newPath.isEmpty) {
                      _showSnackBar('Geçersiz yol bilgisi');
                      return;
                    }

                    success = await _apiService.renameNode(oldPath, newPath);
                  }

                  debugPrint('Rename success: $success');

                  if (success) {
                    _showSnackBar('Ad başarıyla güncellendi');
                    await _fetchProjectTreeAndInit();
                  } else {
                    _showSnackBar('Ad güncellenemedi. Lütfen tekrar deneyin.');
                  }
                } catch (e) {
                  debugPrint('Rename error: $e');
                  String errorMessage = 'Ad değiştirme sırasında hata oluştu';
                  if (e.toString().contains('403')) {
                    errorMessage =
                        'Bu öğe yeniden adlandırılamaz (versiyon klasörü)';
                  } else if (e.toString().contains('500')) {
                    errorMessage =
                        'Sunucu hatası: Lütfen daha sonra tekrar deneyin.';
                  } else if (e.toString().contains('zaten var')) {
                    errorMessage = 'Bu isimde bir öğe zaten var';
                  }
                  _showSnackBar(errorMessage);
                }
              },
              child: const Text('Güncelle'),
            ),
          ],
        );
      },
    );
  }

  String _buildNewPath(String oldPath, String newName) {
    final pathParts = oldPath.split('/');
    pathParts[pathParts.length - 1] = newName;
    return pathParts.join('/');
  }

  void _showChangePasswordDialog() {
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Şifre Değiştir'),
          content: TextField(
            controller: ctrl,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Yeni Şifre'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('İptal'),
            ),
            ElevatedButton(
              onPressed: () async {
                final newPass = ctrl.text.trim();
                if (newPass.isEmpty) return;
                try {
                  await supabase.Supabase.instance.client.auth.updateUser(
                    supabase.UserAttributes(password: newPass),
                  );
                  if (!mounted) return;
                  Navigator.pop(context);
                  _showSnackBar('Şifre değiştirildi');
                } catch (e) {
                  Navigator.pop(context);
                  _showSnackBar('Hata: $e');
                }
              },
              child: const Text('Kaydet'),
            ),
          ],
        );
      },
    );
  }

  void _logout() async {
    try {
      await supabase.Supabase.instance.client.auth.signOut();
      if (!mounted) return;
      Navigator.of(context).pushNamedAndRemoveUntil('/', (route) => false);
    } catch (e) {
      _showSnackBar('Çıkış yapılamadı: $e');
    }
  }

  Future<void> _showUpdateVersionDialog(ProjectNode versionNode) async {
    if (!versionNode.isVersion) {
      _showSnackBar('Bu işlem sadece versiyon klasörleri için geçerlidir.');
      return;
    }

    debugPrint('=== UPDATE VERSION DIALOG DEBUG ===');
    debugPrint('Version node name: ${versionNode.name}');
    debugPrint('Version node path: ${versionNode.path}');

    // Dosya seçimi için değişkenler
    PlatformFile? infoTxtFile;
    PlatformFile? imageFile;
    PlatformFile? hexFile;
    PlatformFile? settingsFile;

    Map<String, String> selectedFileNames = {
      'info_txt': 'info.txt Seç (Opsiyonel)',
      'image': 'Resim Dosyası Seç (Opsiyonel)',
      'hex': 'Firmware (.hex) Seç (Opsiyonel)',
      'settings': 'Settings (.json) Seç (Opsiyonel)',
    };

    void Function(void Function())? setDialogState;

    Future<void> pickFile(
      String fileKey,
      List<String> allowedExtensions,
    ) async {
      final result = await FilePicker.platform.pickFiles(type: FileType.any);
      if (!mounted) return;

      if (result != null && result.files.isNotEmpty) {
        final file = result.files.first;
        // Dosya uzantısını al ve küçük harfe çevir
        final ext = file.name.split('.').last.toLowerCase();
        if (!allowedExtensions.contains(ext)) {
          _showSnackBar('Geçersiz dosya türü: .$ext');
          return;
        }
        if (fileKey == 'info_txt') infoTxtFile = file;
        if (fileKey == 'image') imageFile = file;
        if (fileKey == 'hex') hexFile = file;
        if (fileKey == 'settings') settingsFile = file;

        setDialogState?.call(() {
          selectedFileNames[fileKey] = '${file.name} seçildi';
        });
        _showSnackBar('${file.name} seçildi');
      }
    }

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            setDialogState = setState;
            return AlertDialog(
              title: Text('${versionNode.name} Versiyonunu Güncelle'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Güncellemek istediğiniz dosyaları seçin:',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: () => pickFile('info_txt', ['txt']),
                      child: Text(selectedFileNames['info_txt']!),
                    ),
                    ElevatedButton(
                      onPressed: () => pickFile('image', ['jpg', 'png']),
                      child: Text(selectedFileNames['image']!),
                    ),
                    ElevatedButton(
                      onPressed: () => pickFile('hex', ['hex']),
                      child: Text(selectedFileNames['hex']!),
                    ),
                    ElevatedButton(
                      onPressed: () => pickFile('settings', ['json']),
                      child: Text(selectedFileNames['settings']!),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('İptal'),
                ),
                ElevatedButton(
                  onPressed: () async {
                    // En az bir dosya seçilmiş olmalı
                    if (infoTxtFile == null &&
                        imageFile == null &&
                        hexFile == null &&
                        settingsFile == null) {
                      _showSnackBar('Lütfen en az bir dosya seçin.');
                      return;
                    }

                    Navigator.pop(context);

                    try {
                      _showSnackBar('Versiyon güncelleniyor...');

                      // Seçilen dosyaları yükle
                      Map<String, File> filesToUpload = {};
                      if (infoTxtFile != null)
                        filesToUpload['info_txt'] = File(infoTxtFile!.path!);
                      if (imageFile != null)
                        filesToUpload['image'] = File(imageFile!.path!);
                      if (hexFile != null)
                        filesToUpload['hex'] = File(hexFile!.path!);
                      if (settingsFile != null)
                        filesToUpload['settings'] = File(settingsFile!.path!);

                      // Backend'e versiyon güncelleme isteği gönder
                      final updateSuccess = await _apiService.updateVersion(
                        versionNode.path,
                        filesToUpload,
                      );

                      if (!mounted) return;

                      if (updateSuccess) {
                        _showSnackBar('Versiyon başarıyla güncellendi');
                        await _fetchProjectTreeAndInit();
                      } else {
                        _showSnackBar('Versiyon güncellenirken hata oluştu');
                      }
                    } catch (e) {
                      debugPrint('Update version error: $e');
                      _showSnackBar('Versiyon güncelleme hatası: $e');
                    }
                  },
                  child: const Text('Güncelle'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _handleDeleteVersion(ProjectNode versionNode) async {
    if (versionNode.path.isEmpty) {
      _showSnackBar('Versiyon yolu bulunamadı.');
      return;
    }

    debugPrint('=== DELETE VERSION DEBUG ===');
    debugPrint('Version node name: ${versionNode.name}');
    debugPrint('Version node path: ${versionNode.path}');
    debugPrint('Version node isVersion: ${versionNode.isVersion}');

    final bool confirm =
        await showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Versiyonu Sil'),
            content: Text(
              '${versionNode.name} versiyonunu silmek istediğinizden emin misiniz? Bu işlem geri alınamaz.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('İptal'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(context, true),
                style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                child: const Text('Sil'),
              ),
            ],
          ),
        ) ??
        false;

    if (!confirm) return;

    try {
      _showSnackBar('Versiyon siliniyor...');
      debugPrint('Attempting to delete version: ${versionNode.path}');

      // Ensure the path is properly formatted
      String pathToDelete = versionNode.path;
      if (pathToDelete.startsWith('/')) {
        pathToDelete = pathToDelete.substring(1);
      }

      debugPrint('Formatted path for deletion: $pathToDelete');

      final ok = await _apiService.deleteFolder(pathToDelete);
      if (!mounted) return;

      debugPrint('Delete result: $ok');

      if (ok) {
        _showSnackBar('Versiyon başarıyla silindi');
        await _fetchProjectTreeAndInit();

        // Navigate back to the parent of the deleted version
        final segments = versionNode.path.split('/');
        if (segments.length > 1) {
          final parentPath = segments.sublist(0, segments.length - 1).join('/');
          debugPrint('Parent path: $parentPath');
          final parentNode = _findNodeByPath(
            _projectTreeResponse!.root,
            parentPath,
          );
          if (parentNode != null) {
            _navigateToNode(parentNode);
          }
        }
      } else {
        // Check if the version was deleted locally but not from Supabase
        _showSnackBar(
          'Versiyon yerel olarak silindi ancak Supabase\'den silinemedi. Lütfen tekrar deneyin.',
        );
        await _fetchProjectTreeAndInit();
      }
    } catch (e) {
      debugPrint('Delete version error: $e');
      _showSnackBar('Versiyon silme hatası: $e');
    }
  }

  void _openAdminMenu() {
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: "AdminMenu",
      transitionDuration: const Duration(milliseconds: 250),
      pageBuilder: (context, anim1, anim2) {
        return Align(
          alignment: Alignment.centerLeft,
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: 280,
              height: double.infinity,
              color: Colors.blueGrey.shade900,
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  DrawerHeader(
                    decoration: const BoxDecoration(color: Colors.blueGrey),
                    child: Column(
                      children: [
                        const CircleAvatar(
                          radius: 40,
                          backgroundImage: AssetImage(
                            'assets/images/profile.jpg',
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          widget.username,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_isAdmin)
                    ListTile(
                      leading: const Icon(Icons.create_new_folder),
                      title: const Text(
                        'Ana Klasör Ekle',
                      ), // Changed from 'Yeni Proje Ekle'
                      onTap: () {
                        Navigator.pop(context);
                        _showCreateProjectFolderDialog(
                          parentPath: '',
                          isMainFolder: true,
                        );
                      },
                    ),
                  _drawerItem(
                    Icons.lock,
                    'Şifre Değiştir',
                    onTap: _showChangePasswordDialog,
                    visible: true,
                  ),
                  _drawerItem(
                    Icons.logout,
                    'Çıkış Yap',
                    onTap: _logout,
                    visible: true,
                  ),
                ],
              ),
            ),
          ),
        );
      },
      transitionBuilder: (context, anim1, anim2, child) {
        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(-1, 0),
            end: Offset.zero,
          ).animate(anim1),
          child: child,
        );
      },
    );
  }

  Widget _drawerItem(
    IconData icon,
    String title, {
    VoidCallback? onTap,
    required bool visible,
  }) {
    if (!visible) return const SizedBox.shrink(); // Hide if not visible
    return ListTile(
      leading: Icon(icon, color: Colors.white),
      title: Text(title, style: const TextStyle(color: Colors.white)),
      onTap: () {
        Navigator.pop(context); // Close the drawer
        onTap?.call();
      },
    );
  }

  Future<void> _showCreateProjectFolderDialog({
    required String parentPath,
    required bool isMainFolder,
  }) async {
    if (!_isAdmin) {
      _showSnackBar('Bu işlem sadece admin kullanıcıları için geçerlidir.');
      return;
    }

    final ctrl = TextEditingController();
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          isMainFolder ? 'Yeni Ana Proje Ekle' : 'Yeni Proje Klasörü Oluştur',
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (parentPath.isNotEmpty)
              Text(
                'Konum: $parentPath',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            const SizedBox(height: 8),
            TextField(
              controller: ctrl,
              decoration: const InputDecoration(
                labelText: 'Proje Adı',
                hintText: 'Örnek: STM32F103, JOY_Controller',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('İptal'),
          ),
          ElevatedButton(
            onPressed: () async {
              final name = ctrl.text.trim();
              if (name.isEmpty) {
                _showSnackBar('Lütfen proje adı girin');
                return;
              }

              Navigator.pop(ctx);

              debugPrint('Creating project folder: $name under $parentPath');
              final success = await _apiService.createFolderOnServer(
                parentPath,
                name,
              );

              if (success) {
                _showSnackBar('Proje klasörü başarıyla oluşturuldu');
                await _fetchProjectTreeAndInit();
              } else {
                _showSnackBar('Proje klasörü oluşturulamadı');
              }
            },
            child: const Text('Oluştur'),
          ),
        ],
      ),
    );
  }

  Future<void> _showCreateVersionWithFilesDialog(
    ProjectNode projectNode,
  ) async {
    // Admin kontrolü
    if (!_isAdmin) {
      _showSnackBar('Bu işlem sadece admin kullanıcıları için geçerlidir.');
      return;
    }

    if (!projectNode.isFolder) {
      _showSnackBar('Lütfen bir proje klasörü seçin.');
      return;
    }

    final versionNameController = TextEditingController();

    PlatformFile? infoTxtFile;
    PlatformFile? imageFile;
    PlatformFile? hexFile;
    PlatformFile? settingsFile;

    Map<String, String> selectedFileNames = {
      'info_txt': 'info.txt Seç',
      'image': 'Resim Dosyası Seç (jpg/png)',
      'hex': 'Firmware (.hex) Seç',
      'settings': 'Settings (.json) Seç',
    };

    void Function(void Function())? setDialogState;

    Future<void> pickFile(
      String type,
      String fileKey,
      List<String> allowedExtensions,
    ) async {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        allowMultiple: false,
      );

      if (!mounted) return;

      if (result != null && result.files.isNotEmpty) {
        final file = result.files.first;
        final ext = file.name.split('.').last.toLowerCase();
        if (!allowedExtensions.contains(ext)) {
          _showSnackBar('Geçersiz dosya türü: .$ext');
          return;
        }

        if (fileKey == 'info_txt') infoTxtFile = file;
        if (fileKey == 'image') imageFile = file;
        if (fileKey == 'hex') hexFile = file;
        if (fileKey == 'settings') settingsFile = file;

        setDialogState?.call(() {
          selectedFileNames[fileKey] = '${file.name} seçildi';
        });
        _showSnackBar('${file.name} seçildi');
      }
    }

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            setDialogState = setState;
            return AlertDialog(
              title: const Text('Yeni Versiyon Oluştur ve Dosyaları Seç'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: versionNameController,
                      decoration: const InputDecoration(
                        labelText: 'Versiyon Adı (örn: v1.0)',
                      ),
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: () => pickFile('txt', 'info_txt', ['txt']),
                      child: Text(selectedFileNames['info_txt']!),
                    ),
                    ElevatedButton(
                      onPressed: () =>
                          pickFile('image', 'image', ['jpg', 'jpeg', 'png']),
                      child: Text(selectedFileNames['image']!),
                    ),
                    ElevatedButton(
                      onPressed: () => pickFile('hex', 'hex', ['hex']),
                      child: Text(selectedFileNames['hex']!),
                    ),
                    ElevatedButton(
                      onPressed: () => pickFile('json', 'settings', ['json']),
                      child: Text(selectedFileNames['settings']!),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('İptal'),
                ),
                ElevatedButton(
                  onPressed: () async {
                    final versionName = versionNameController.text.trim();
                    if (versionName.isEmpty) {
                      _showSnackBar('Lütfen versiyon adı girin.');
                      return;
                    }

                    if (infoTxtFile == null ||
                        imageFile == null ||
                        hexFile == null ||
                        settingsFile == null) {
                      _showSnackBar('Lütfen tüm gerekli dosyaları seçin.');
                      return;
                    }

                    Map<String, File> filesToUpload = {};
                    if (infoTxtFile != null)
                      filesToUpload['info_txt'] = File(infoTxtFile!.path!);
                    if (imageFile != null)
                      filesToUpload['image'] = File(imageFile!.path!);
                    if (hexFile != null)
                      filesToUpload['hex'] = File(hexFile!.path!);
                    if (settingsFile != null)
                      filesToUpload['settings'] = File(settingsFile!.path!);

                    final uploadSuccess = await _apiService.addVersion(
                      projectNode.path,
                      versionName,
                      filesToUpload,
                    );

                    if (!mounted) return;
                    Navigator.pop(context);
                    _showSnackBar(
                      uploadSuccess
                          ? 'Versiyon ve dosyalar başarıyla oluşturuldu'
                          : 'Versiyon veya dosya yükleme sırasında hata oluştu',
                    );

                    if (uploadSuccess) await _fetchProjectTreeAndInit();
                  },
                  child: const Text('Oluştur'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _handleDeleteFolder(String folderPath) async {
    if (folderPath.isEmpty || folderPath == _projectTreeResponse!.root.path) {
      _showSnackBar('Kök klasör silinemez.');
      return;
    }

    final bool confirm =
        await showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Klasörü Sil'),
            content: Text(
              '$folderPath klasörünü silmek istediğinizden emin misiniz? Bu işlem geri alınamaz.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('İptal'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(context, true),
                style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                child: const Text('Sil'),
              ),
            ],
          ),
        ) ??
        false;

    if (!confirm) return;
    final ok = await _apiService.deleteFolder(folderPath);
    if (!mounted) return;

    if (ok) {
      _showSnackBar('Klasör başarıyla silindi.');
    } else {
      _showSnackBar('Klasör silinemedi.');
    }
    if (ok) {
      await _fetchProjectTreeAndInit();
      // Navigate back to the parent of the deleted folder or the root
      final segments = folderPath.split('/');
      if (segments.length > 1) {
        final parentPath = segments.sublist(0, segments.length - 1).join('/');
        final parentNode = _findNodeByPath(
          _projectTreeResponse!.root,
          parentPath,
        );
        _navigateToNode(parentNode ?? _projectTreeResponse!.root);
      } else {
        _navigateToNode(_projectTreeResponse!.root);
      }
    }
  }
}
